//
//  TmuxSessionConnection.swift
//  TmuxGUI
//

import Foundation

/// One tmux session, seen through one control mode client.
///
/// Holds no authored state: the window list, which window is active, and every
/// pane layout all come from tmux. Anything the user does in the GUI turns
/// into a tmux command and comes back as a notification, so a plain
/// `tmux attach` in another terminal always agrees with what is on screen.
///
/// ## Targets are ids, never names
///
/// Every command below addresses tmux by id — `$10`, `@25`, `%42` — rather
/// than by session or window name. Names are arbitrary user text that gets
/// interpolated into a command line; ids are `[$@%]\d+` and cannot carry a
/// quote, a space, or a newline. This removes command injection as a category
/// rather than trying to escape around it. `TmuxCommand.quote` exists for the
/// one place real text has to be sent — renaming.
final class TmuxSessionConnection {
    let sessionName: String
    let router = TmuxOutputRouter()
    let metrics = TmuxMetrics()

    /// tmux's session id, learned from `%session-changed`. All later commands
    /// target this instead of the name.
    private(set) var sessionID: String?

    private(set) var windows = [TmuxWindow]()
    private(set) var activeWindowID: String?

    /// Fires on the main queue whenever the window list, the active window, or
    /// a layout changed — i.e. whenever the UI needs to redraw structure.
    ///
    /// A list rather than a single closure: both the sidebar (for window
    /// counts and activity dots) and the session's own view controller need
    /// these, and a plain property meant whichever registered last silently
    /// unsubscribed the other.
    private var modelObservers = [() -> Void]()

    func addModelObserver(_ observer: @escaping () -> Void) {
        modelObservers.append(observer)
    }

    private func notifyModelChanged() {
        for observer in modelObservers { observer() }
    }
    var onStatusChange: ((String) -> Void)?
    var onExit: ((String?) -> Void)?
    /// A session was created or destroyed anywhere on the server. Every
    /// connection sees this, so the server picks one to act on it.
    var onServerSessionsChanged: (() -> Void)?

    /// True when any window in this session has unseen output. Reuses tmux's
    /// own activity flag so the sidebar dot means the same thing as the `#`
    /// in a tmux status line.
    var hasActivity: Bool {
        windows.contains { $0.hasActivity && $0.id != activeWindowID }
    }

    private let client: TmuxControlClient
    private var lastReportedGrid: (columns: Int, rows: Int)?

    /// Pane whose arrival gaps the metrics track. Normally the focused pane;
    /// the throughput probe points it at a synthetic heartbeat instead.
    private var measuredPane: String?
    private let measuredPaneLock = NSLock()
    private var probeInFlight = false

    init(tmuxPath: String, sessionName: String) {
        self.sessionName = sessionName
        client = TmuxControlClient(tmuxPath: tmuxPath, sessionName: sessionName)

        client.onPaneOutput = { [weak self] pane, data in
            guard let self else { return }
            self.measuredPaneLock.lock()
            let measured = self.measuredPane
            self.measuredPaneLock.unlock()
            self.metrics.record(pane: pane, watched: pane == measured, byteCount: data.count)
            self.router.deliver(paneID: pane, data: data)
        }
        client.onNotification = { [weak self] notification in
            self?.handle(notification)
        }
        client.onExit = { [weak self] reason in
            self?.onExit?(reason)
        }
    }

    // MARK: - Lifecycle

    func start() {
        do {
            try client.start()
            onStatusChange?("Connecting to \(sessionName)…")
        } catch {
            onStatusChange?("Connection failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        router.removeAll()
        client.stop()
    }

    /// Re-emit the current status. Switching sessions has to repaint the
    /// title even though nothing about the session itself changed.
    func announceStatus() {
        onStatusChange?(describeActive())
    }

    var window: (String) -> TmuxWindow? {
        { [weak self] id in self?.windows.first { $0.id == id } }
    }

    var activeWindow: TmuxWindow? {
        guard let activeWindowID else { return nil }
        return windows.first { $0.id == activeWindowID }
    }

    // MARK: - Commands the UI issues

    /// Report the grid the panes are being laid out on. tmux sizes the
    /// session's windows from its clients, so this is what makes the GUI the
    /// authority on layout instead of whatever terminal attached last.
    func reportGrid(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        guard lastReportedGrid?.columns != columns || lastReportedGrid?.rows != rows else { return }
        lastReportedGrid = (columns, rows)
        client.send("refresh-client -C \(columns)x\(rows)")
    }

    func sendKeys(paneID: String, data: Data) {
        client.sendKeys(pane: paneID, data: data)
    }

    func focus(paneID: String) {
        measuredPaneLock.lock()
        measuredPane = paneID
        measuredPaneLock.unlock()
        client.send("select-pane -t \(paneID)")
    }

    func selectWindow(id: String) {
        client.send("select-window -t \(id)")
    }

    func newWindow() {
        guard let target = sessionTarget else { return }
        client.send("new-window -t \(target)")
    }

    func killWindow(id: String) {
        client.send("kill-window -t \(id)")
    }

    func renameSession(to name: String) {
        guard let target = sessionTarget else { return }
        client.send("rename-session -t \(target) \(TmuxCommand.quote(name))")
    }

    func renameWindow(id: String, to name: String) {
        client.send("rename-window -t \(id) \(TmuxCommand.quote(name))")
    }

    /// Move a window to a new index, then renumber.
    ///
    /// `-b` inserts *before* the target and shuffles the rest up, which is the
    /// behaviour a tab drag implies; a plain move to an occupied index fails.
    /// The follow-up `-r` closes the gaps so indexes stay contiguous — that is
    /// what keeps ⌘1-9 matching what the strip shows.
    ///
    /// The target has to be `session:index`; without the colon tmux reads
    /// `$10` plus `4` as the single token `$104` and silently does nothing.
    func moveWindow(id: String, toIndex index: Int) {
        guard let target = sessionTarget else { return }
        client.send("move-window -b -d -s \(id) -t \(target):\(index)")
        client.send("move-window -r -t \(target)")
    }

    /// Resize a pane to an exact cell size — used when the user drags a
    /// splitter, so tmux's layout follows the GUI rather than the reverse.
    func resizePane(id: String, columns: Int?, rows: Int?) {
        var command = "resize-pane -t \(id)"
        if let columns { command += " -x \(columns)" }
        if let rows { command += " -y \(rows)" }
        client.send(command)
    }

    /// Pull a pane's scrollback plus its visible screen.
    ///
    /// `-S -N` starts N lines above the top of the visible region and tmux
    /// clamps to what actually exists, so asking for more than the pane has
    /// is free. `-e` keeps colours. `-J` is deliberately not used: joining
    /// wrapped lines would rewrap them at whatever width they are replayed
    /// into, which is not where the user saw them break.
    ///
    /// This is how the GUI gets scrollback at all — tmux owns the history and
    /// never replays it to a joining client, so a surface that is only fed
    /// live `%output` can scroll back exactly as far as the moment it opened.
    func captureScrollback(paneID: String, lines: Int, completion: @escaping ([String]) -> Void) {
        client.run("capture-pane -p -e -t \(paneID) -S -\(lines)") { output, failed in
            completion(failed ? [] : Self.trimmingTrailingBlanks(output))
        }
    }

    func capturePane(paneID: String, completion: @escaping ([String]) -> Void) {
        client.run("capture-pane -p -e -t \(paneID)") { output, failed in
            completion(failed ? [] : Self.trimmingTrailingBlanks(output))
        }
    }

    /// `capture-pane` returns one line per row of the pane, blanks included.
    /// Painting all of them leaves the cursor parked on the bottom row, so the
    /// next thing the shell writes — a prompt redraw after SIGWINCH, say —
    /// lands at the bottom of an otherwise empty screen instead of following
    /// the text. Dropping the trailing blanks puts the cursor where the
    /// content actually ends.
    private static func trimmingTrailingBlanks(_ lines: [String]) -> [String] {
        var lines = lines
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty
                  || TmuxText.plain(last).isEmpty
        {
            lines.removeLast()
        }
        return lines
    }

    private var sessionTarget: String? { sessionID }

    // MARK: - Notifications

    private func handle(_ notification: TmuxNotification) {
        switch notification {
        case .sessionChanged(let id, _):
            sessionID = id
            refreshWindows()

        case .layoutChange(let windowID, let layout):
            guard let index = windows.firstIndex(where: { $0.id == windowID }) else {
                refreshWindows()
                return
            }
            guard windows[index].layoutText != layout else { return }
            windows[index].layoutText = layout
            notifyModelChanged()

        case .windowAdd, .windowClose:
            refreshWindows()

        case .windowRenamed(let windowID, let name):
            guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
            windows[index].name = TmuxText.plain(name)
            notifyModelChanged()

        case .other(let verb, _) where verb == "%sessions-changed":
            onServerSessionsChanged?()
            refreshWindows()

        case .other(let verb, _) where verb == "%session-window-changed"
            || verb == "%window-pane-changed"
            || verb == "%unlinked-window-add":
            refreshWindows()

        case .paused(let pane):
            onStatusChange?("⚠️ tmux paused pane \(pane) — output backed up")

        default:
            break
        }
    }

    /// Re-read the whole window list rather than patching it incrementally.
    /// A `list-windows` round trip is cheap and it cannot drift; incremental
    /// updates from six notification types eventually can.
    private func refreshWindows() {
        guard let target = sessionTarget else { return }
        client.run("list-windows -t \(target) -F '\(TmuxWindow.listFormat)'") { [weak self] lines, failed in
            guard let self, !failed else { return }
            let parsed = lines.compactMap(TmuxWindow.parse(listLine:)).map { window -> TmuxWindow in
                var window = window
                // Window names come from `automatic-rename`, which copies
                // whatever the pane last ran — escape sequences included.
                window.name = TmuxText.plain(window.name)
                return window
            }
            guard !parsed.isEmpty else { return }

            let previousActive = self.activeWindowID
            self.windows = parsed.sorted { $0.index < $1.index }
            self.activeWindowID = parsed.first(where: \.isActive)?.id ?? parsed.first?.id
            if self.activeWindowID != previousActive || previousActive == nil {
                self.onStatusChange?(self.describeActive())
            }
            self.notifyModelChanged()
        }
    }

    private func describeActive() -> String {
        guard let window = activeWindow else { return sessionName }
        let paneCount = window.paneIDs.count
        return "\(sessionName) → \(window.index):\(window.name)"
            + (paneCount > 1 ? " · \(paneCount) panes" : "")
    }
}

// MARK: - Throughput probe

extension TmuxSessionConnection {
    /// Measure whether one busy pane starves the others.
    ///
    /// Control mode multiplexes every pane in the session onto one pipe, so
    /// the risk is not raw bandwidth — it is that an AI agent redrawing at
    /// full speed in one window makes another feel laggy. Byte counters cannot
    /// see that, so this runs an A/B against a synthetic heartbeat:
    ///
    ///   A — a pane printing one byte every 50ms, alone.
    ///   B — the same pane, while a second pane floods the pipe.
    ///
    /// Both helper windows are created detached and killed afterwards, so
    /// nothing the user is looking at is disturbed.
    func runThroughputProbe(phaseSeconds: TimeInterval = 8, completion: @escaping (String) -> Void) {
        guard let target = sessionTarget else {
            completion("Not connected to tmux yet.")
            return
        }
        guard !probeInFlight else {
            completion("A probe is already running.")
            return
        }
        probeInFlight = true
        onStatusChange?("Probing: phase A — heartbeat alone…")

        let heartbeat = "while :; do printf .; sleep 0.05; done"
        client.run("new-window -d -P -F '#{window_id}\u{01}#{pane_id}' -t \(target) -n tmuxgui-probe '\(heartbeat)'") { [weak self] lines, failed in
            guard let self else { return }
            let ids = (lines.first ?? "").components(separatedBy: "\u{01}")
            guard !failed, ids.count == 2 else {
                self.finishProbe(completion, "Could not create the heartbeat window: \(lines.joined(separator: " "))")
                return
            }
            let probeWindow = ids[0]
            self.measuredPaneLock.lock()
            let restore = self.measuredPane
            self.measuredPane = ids[1]
            self.measuredPaneLock.unlock()

            // Let the new pane's shell finish starting; its startup output
            // would otherwise be counted as heartbeat.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.metrics.reset()
                DispatchQueue.main.asyncAfter(deadline: .now() + phaseSeconds) {
                    let baseline = self.metrics.snapshot()
                    self.runFloodPhase(
                        target: target,
                        phaseSeconds: phaseSeconds,
                        probeWindow: probeWindow,
                        restoreMeasured: restore,
                        baseline: baseline,
                        completion: completion
                    )
                }
            }
        }
    }

    private func runFloodPhase(
        target: String,
        phaseSeconds: TimeInterval,
        probeWindow: String,
        restoreMeasured: String?,
        baseline: TmuxMetrics.Snapshot,
        completion: @escaping (String) -> Void
    ) {
        onStatusChange?("Probing: phase B — heartbeat plus a flooding pane…")
        let filler = String(repeating: "0123456789ABCDEF", count: 4)

        client.run("new-window -d -P -F '#{window_id}' -t \(target) -n tmuxgui-flood 'yes \(filler)'") { [weak self] lines, failed in
            guard let self else { return }
            guard !failed, let floodWindow = lines.first?.trimmingCharacters(in: .whitespaces),
                  !floodWindow.isEmpty
            else {
                self.client.send("kill-window -t \(probeWindow)")
                self.measuredPane = restoreMeasured
                self.finishProbe(completion, "Could not create the flood window: \(lines.joined(separator: " "))")
                return
            }

            self.metrics.reset()
            DispatchQueue.main.asyncAfter(deadline: .now() + phaseSeconds) {
                let loaded = self.metrics.snapshot()
                self.client.send("kill-window -t \(floodWindow)")
                self.client.send("kill-window -t \(probeWindow)")
                self.measuredPaneLock.lock()
                self.measuredPane = restoreMeasured
                self.measuredPaneLock.unlock()
                self.finishProbe(completion, Self.compare(baseline: baseline, loaded: loaded))
            }
        }
    }

    private func finishProbe(_ completion: @escaping (String) -> Void, _ text: String) {
        probeInFlight = false
        metrics.reset()
        onStatusChange?(describeActive())
        completion(text)
    }

    private static func compare(baseline: TmuxMetrics.Snapshot, loaded: TmuxMetrics.Snapshot) -> String {
        let ms = { (value: TimeInterval) in String(format: "%.0f", value * 1000) }
        let degradation = baseline.p99Gap > 0 ? loaded.p99Gap / baseline.p99Gap : 0
        let floodRate = Double(loaded.otherBytes) / max(loaded.elapsed, 0.001) / 1_048_576

        return """
        A · heartbeat alone (one byte every 50ms)
            arrival gaps  median \(ms(baseline.medianGap))ms · p99 \(ms(baseline.p99Gap))ms · worst \(ms(baseline.worstGap))ms
            samples       \(baseline.watchedChunks)

        B · heartbeat plus another pane flooding
            arrival gaps  median \(ms(loaded.medianGap))ms · p99 \(ms(loaded.p99Gap))ms · worst \(ms(loaded.worstGap))ms
            samples       \(loaded.watchedChunks)
            flood output  \(loaded.otherBytes) bytes (\(String(format: "%.1f", floodRate)) MB/s)

        Result
            p99 went from \(ms(baseline.p99Gap))ms to \(ms(loaded.p99Gap))ms, \
        \(degradation > 0 ? String(format: "a factor of %.1f", degradation) : "not comparable").
            The heartbeat is constant by construction, so whatever B drifts by
            is the delay the flood adds by sharing the pipe.
        """
    }
}

#if DEBUG

    // Read-only windows onto state the debug inspector needs and nothing else
    // has any business seeing. Same file, so `private` still means private
    // everywhere that matters.
    extension TmuxSessionConnection {
        var debugSessionID: String? { sessionID }
        /// The last size this app sent with `refresh-client -C`, which is what
        /// tmux should be sizing the session's windows to.
        var debugLastReportedGrid: (columns: Int, rows: Int)? { lastReportedGrid }
    }

#endif

// MARK: - Quoting

enum TmuxCommand {
    /// Quote a string for tmux's command parser.
    ///
    /// Only needed for genuine user text such as a new window name — every
    /// other target in this app is an id. tmux treats a single-quoted string
    /// as literal with no escapes available inside it, so an embedded quote
    /// has to close, escape, and reopen, the same trick sh uses.
    static func quote(_ text: String) -> String {
        // Control characters have no business in a window name and would let
        // a newline split the command line in two.
        let cleaned = text.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7f }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        return "'" + cleaned.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
