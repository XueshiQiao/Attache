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
    /// This connection's identity, for its whole life. Known before the attach
    /// because `list-sessions` reports it, so there is no window in which a
    /// command has to be held back for want of a target — and, more to the
    /// point, no way for a rename to turn this object into a stranger.
    let sessionID: String

    /// What the user currently calls this session. Display and logging only;
    /// nothing is keyed by it. Changes whenever tmux says it did, which is why
    /// it is a `var` — the old `let` is what made a rename look to the rest of
    /// the app like one session vanishing and another appearing.
    private(set) var sessionName: String

    let router = TmuxOutputRouter()
    let metrics = TmuxMetrics()

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

    init(tmuxPath: String, sessionID: String, sessionName: String) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        client = TmuxControlClient(
            tmuxPath: tmuxPath, sessionID: sessionID, sessionName: sessionName
        )

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
        // Before the client goes: a command completion is the only other thing
        // that removes these, and a client that is being torn down will never
        // deliver one. What would be left behind is the user's clipboard.
        for url in pasteFilesInFlight { try? FileManager.default.removeItem(at: url) }
        pasteFilesInFlight.removeAll()
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
        reclaimedAt = nil
        client.send("refresh-client -C \(columns)x\(rows)")
    }

    /// The window size this connection last found itself losing an argument
    /// about, and how many times it has argued. Cleared whenever the app's own
    /// grid changes, because that is a new argument.
    private var reclaimedAt: String?
    private var reclaimAttempts = 0

    /// More than one, because the first can lose a race rather than an
    /// argument: the other client's `refresh-client` and this app's reaction to
    /// the layout change it caused are milliseconds apart, and whichever lands
    /// second wins. Bounded because a session whose `window-size` is `smallest`
    /// or `manual` is one this app cannot win and should not keep trying — that
    /// is the user's setting, not a fault.
    private static let reclaimAttemptLimit = 3

    /// Take the window size back when another terminal has taken it.
    ///
    /// tmux's default `window-size latest` sizes a session's windows to "the
    /// client that had the most recent activity". Attaching a second terminal
    /// to the same session therefore resizes every window in it to fit that
    /// terminal — and this app goes on drawing panes at a size it no longer
    /// has, leaving dead space below them until something else happens to make
    /// the app's own grid change.
    ///
    /// Re-sending `refresh-client -C` does not take it back, which is the
    /// non-obvious part. Measured on tmux 3.6a against an isolated server, with
    /// client B holding the window: A re-sending its size, sending a genuinely
    /// different size, and jiggling through a third value all leave the window
    /// at B's. `refresh-client` is not *activity*. A command that is — a
    /// `switch-client` to the session this client is already attached to, which
    /// changes nothing — makes this client the latest, and the size that
    /// follows it is honoured.
    ///
    /// Sent at most once per distinct size tmux is holding, so a session whose
    /// `window-size` is `smallest` or `manual` — where this app cannot win and
    /// should not — costs two commands rather than two per notification.
    ///
    /// - Parameter isUserReturning: true when the app has just been brought back
    ///   to the front. That resets the attempt counter, because the counter
    ///   exists to stop this connection arguing forever with a `window-size`
    ///   setting it cannot beat — and a person switching back to this window is
    ///   not that argument continuing, it is a new one they just started. Left
    ///   counted, the third notification-driven attempt against some earlier
    ///   size would silence every later return to the app, which is exactly the
    ///   case this whole method exists for.
    func reclaimWindowSizeIfTaken(isUserReturning: Bool = false) {
        if isUserReturning {
            reclaimedAt = nil
            reclaimAttempts = 0
        }
        guard let want = lastReportedGrid,
              let size = activeWindow?.visibleLayout?.frame,
              size.columns != want.columns || size.rows != want.rows
        else {
            reclaimedAt = nil
            reclaimAttempts = 0
            return
        }

        let disagreement = "\(size.columns)x\(size.rows)"
        if reclaimedAt != disagreement {
            reclaimedAt = disagreement
            reclaimAttempts = 0
        }
        guard reclaimAttempts < Self.reclaimAttemptLimit else { return }
        reclaimAttempts += 1

        // Which trigger fired is in the line, because the two are the whole
        // story when this goes wrong and they are indistinguishable otherwise:
        // the notification path can exhaust its attempts against a client that
        // keeps taking the size, and only the return path resets that.
        TmuxLog.lifecycle(
            "window is \(disagreement) but this app is laid out for"
                + " \(want.columns)x\(want.rows) — another client has the size;"
                + " taking it back (attempt \(reclaimAttempts),"
                + " \(isUserReturning ? "user returned to the app" : "tmux notification"))",
            session: sessionName
        )
        client.send("switch-client -t \(sessionTarget)")
        client.send("refresh-client -C \(want.columns)x\(want.rows)")
    }

    /// The name this connection's activity subscription goes out under. Only
    /// ever compared against what comes back, so any string would do; this one
    /// says where it came from if it shows up in someone else's `tmux` output.
    private static let activitySubscription = "tmuxgui-activity"
    private var subscribedToActivity = false

    /// Ask tmux to tell us when a window gains or loses activity, instead of
    /// finding out by accident.
    ///
    /// Output arriving in a background window produces **only `%output`** on
    /// the control stream — no structural notification — while
    /// `window_activity_flag` flips server-side. So the sidebar dot used to
    /// appear whenever the next unrelated notification happened to arrive,
    /// which for a quiet session is never: exactly the case the dot exists for,
    /// which is that you are in session A and the agent in session B has gone
    /// quiet.
    ///
    /// `@*` is every window in this session, so one subscription replaces the
    /// accidental coupling. Verified on tmux 3.6a: subscribing produces one
    /// `%subscription-changed` per window immediately, so the dots are right
    /// from the attach rather than only after the first change.
    ///
    /// This depends on the user's `monitor-activity` — measured, the flag stays
    /// 0 for a background window's output with it off, which is tmux's default.
    /// That is not something for this app to override: it is the same setting
    /// that decides whether a plain `tmux attach` shows the `#` in its status
    /// line, and the dot is meant to mean the same thing.
    private func subscribeToActivity() {
        guard !subscribedToActivity else { return }
        subscribedToActivity = true
        client.send(
            "refresh-client -B '\(Self.activitySubscription):@*:#{window_activity_flag}'"
        )
    }

    /// Files this connection has written for a paste and not yet cleaned up.
    /// Emptied by `stop()`, because the only other cleanup runs in a command
    /// completion and a client that dies never delivers one.
    private var pasteFilesInFlight = Set<URL>()
    /// Distinguishes one paste from the next. tmux's paste buffers are
    /// server-global and a fixed name is a shared mutable slot: two pastes in
    /// flight — from two sessions, or from one ⌘V too soon after another —
    /// could have the second `load-buffer` land before the first
    /// `paste-buffer`, and the first pane would receive the other's clipboard.
    /// Clipboards hold passwords and shells run what is pasted into them, so
    /// this is not a cosmetic race.
    private var pasteCounter = 0

    /// Paste through tmux, so tmux decides whether to bracket it.
    ///
    /// Returns false when it could not be attempted, and the caller falls back
    /// to libghostty's own paste.
    ///
    /// **The text goes through a file, and that is the whole design.** tmux's
    /// command parser expands `$VAR` inside a double-quoted argument — measured
    /// on 3.6a, `set-buffer -b probe "…$HOME…"` stores `/Users/joey` — and a
    /// single-quoted argument is literal but can carry neither a newline nor a
    /// single quote. Clipboard text is arbitrary and often multi-line, so there
    /// is no quoting of it that is both correct and safe. `load-buffer` takes a
    /// path instead, and the only thing interpolated into the command line is a
    /// path this app chose. That is the same reasoning as targeting tmux by id:
    /// remove the category rather than escape around it.
    ///
    /// The file is created owner-only in one step, deleted the moment tmux
    /// answers, and deleted again by `stop()` if that answer never comes,
    /// because a clipboard holds whatever the user last copied and none of it
    /// belongs in a file that outlives the paste. `-d` on the paste drops the
    /// buffer for the same reason, and keeps the user's own paste buffers
    /// untouched.
    ///
    /// Verified end to end on tmux 3.6a over a control mode client: a file with
    /// `$HOME`, double quotes and `#{format}` in it arrives at the program
    /// character for character, wrapped in `ESC[200~`/`ESC[201~` when the
    /// program has asked for bracketed paste and bare when it has not, and
    /// `list-buffers` is empty afterwards.
    @discardableResult
    func paste(text: String, into paneID: String) -> Bool {
        guard !text.isEmpty else { return false }
        pasteCounter += 1
        let token = "\(sessionID.dropFirst())-\(pasteCounter)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmuxgui-paste-\(token).txt")
        let path = url.path
        // The path is this app's own, but the temporary directory comes from
        // the system and a quote in it would end the argument early. Refusing
        // is the only answer that cannot send half a command.
        guard !path.contains("'"), !path.contains("\n") else { return false }

        // Permissions at creation rather than afterwards: setting them as a
        // second step leaves the text world-readable for the moment in
        // between, and leaves a file behind if that step is the one that fails.
        guard FileManager.default.createFile(
            atPath: path, contents: Data(text.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { return false }
        pasteFilesInFlight.insert(url)

        let buffer = "tmuxgui-paste-\(token)"
        client.run("load-buffer -b \(buffer) '\(path)'") { [weak self] _, failed in
            // Deleted whatever happened. tmux has finished with the file by the
            // time it answers, and a paste that failed is not a reason to leave
            // the user's clipboard sitting in the temporary directory.
            self?.discardPasteFile(url)
            guard let self, !failed else { return }
            self.client.run("paste-buffer -p -d -b \(buffer) -t \(paneID)") { [weak self] _, failed in
                guard failed else { return }
                // `-d` deletes the buffer *as part of pasting*, so a paste that
                // never happened is also a buffer that was never deleted — the
                // user's clipboard left sitting in the tmux server, readable by
                // anything that can reach it, for as long as the server lives.
                // The pane really can be gone by now: naming it and pasting to
                // it are a round trip apart, and a drop names a pane the
                // pointer was over rather than one anybody is typing in.
                self?.client.send("delete-buffer -b \(buffer)")
            }
        }
        return true
    }

    private func discardPasteFile(_ url: URL) {
        pasteFilesInFlight.remove(url)
        try? FileManager.default.removeItem(at: url)
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
        client.send("new-window -t \(sessionTarget)")
    }

    func killWindow(id: String) {
        client.send("kill-window -t \(id)")
    }

    func renameSession(to name: String) {
        client.send("rename-session -t \(sessionTarget) \(TmuxCommand.quote(name))")
    }

    func renameWindow(id: String, to name: String) {
        client.send("rename-window -t \(id) \(TmuxCommand.quote(name))")
    }

    /// Put a window immediately before the one currently at `index`, then
    /// renumber.
    ///
    /// `-b` inserts *before* the target and shuffles the rest up, which is the
    /// behaviour a drag implies; a plain move to an occupied index fails with
    /// `index in use`. The follow-up `-r` closes the gaps so indexes stay
    /// contiguous, which is what stops a session's numbers drifting past 9 and
    /// out of ⌘0-9's reach after enough moves.
    ///
    /// `index` must be an index a window actually has. Measured on tmux 3.6a
    /// against an isolated `-L` server: given windows at 0-3, `-b -t t:5` does
    /// **not** append — it clamps to the last window and inserts before *that*,
    /// so a drag to the bottom of the list would land one short of where the
    /// insertion line promised. `moveWindow(id:toFreeIndex:)` is the end of the
    /// list; this one is every other position.
    ///
    /// The target has to be `session:index`; without the colon tmux reads
    /// `$10` plus `4` as the single token `$104` and silently does nothing.
    @discardableResult
    func moveWindow(id: String, beforeIndex index: Int) -> Bool {
        client.send("move-window -b -d -s \(id) -t \(sessionTarget):\(index)")
        client.send("move-window -r -t \(sessionTarget)")
        reselectIfItWasActive(id)
        return true
    }

    /// Put a window in this session, before the one with `anchor` — or after
    /// everything when `anchor` is nil or names a window this session no longer
    /// has. Returns false when nothing was sent.
    ///
    /// The index is worked out here, at the last possible moment, from this
    /// session's current window list. That is the whole point of taking an id:
    /// an index captured when the user let go of the mouse can name a different
    /// window by the time the command goes out — another client reorders, or a
    /// confirmation sits open for a few seconds — and `move-window -b` onto an
    /// occupied index does not fail, it quietly inserts in the wrong place.
    @discardableResult
    func moveWindow(id: String, before anchor: String?) -> Bool {
        guard let anchor, let index = windows.first(where: { $0.id == anchor })?.index else {
            guard let free = freeIndexAtEnd else { return false }
            return moveWindow(id: id, toFreeIndex: free)
        }
        return moveWindow(id: id, beforeIndex: index)
    }

    /// An index no window in this session uses, above every one that does — the
    /// argument `moveWindow(id:toFreeIndex:)` wants, worked out in the one place
    /// that knows this session's window list.
    ///
    /// A margin rather than one past the highest, because one past the highest
    /// is exactly the index `new-window` takes: another client creating a window
    /// between reading this and tmux running the move would collide, and a plain
    /// move onto an occupied index fails outright.
    ///
    /// Clamped, and `nil` when there is no room: tmux keeps a window index in an
    /// `int`, so a margin added blindly to an index already near `INT_MAX` names
    /// an index tmux cannot represent. Read from tmux's own list rather than
    /// assuming 1...n — `base-index` is a user option and a session whose
    /// windows were killed without a renumber has gaps.
    var freeIndexAtEnd: Int? {
        let last = windows.map(\.index).max() ?? 0
        let ceiling = Int(Int32.max)
        guard last < ceiling else { return nil }
        return min(last + 1000, ceiling)
    }

    /// Move a window to an index nothing occupies, then renumber — the only
    /// way to put one at the *end* of its session.
    ///
    /// No `-b`, because that is what makes tmux take the index literally rather
    /// than as "before whatever is there". The caller owes the guarantee that
    /// the index is free: measured on tmux 3.6a, a plain move onto an occupied
    /// index fails outright with `index in use: 2` and a non-zero status, so
    /// getting this wrong is a move that silently does not happen.
    @discardableResult
    func moveWindow(id: String, toFreeIndex index: Int) -> Bool {
        client.send("move-window -d -s \(id) -t \(sessionTarget):\(index)")
        client.send("move-window -r -t \(sessionTarget)")
        reselectIfItWasActive(id)
        return true
    }

    /// Whether this session's windows currently hold `id`.
    ///
    /// Asked before a move that a human has been sitting in front of a
    /// confirmation for: `move-window -s @25` takes the window from wherever it
    /// is *now*, and the sentence the user agreed to named a particular session.
    func holds(windowID id: String) -> Bool {
        windows.contains { $0.id == id }
    }

    /// Put the selection back on a window that was just moved.
    ///
    /// `-d` is what stops a drag of a *background* window from also switching
    /// to it, and it is needed for that. But a move is an unlink followed by a
    /// link, so when the window being moved is the one that is *currently
    /// active*, `-d` also means it does not get selected again — tmux hands the
    /// active flag to whatever else is in the session.
    ///
    /// Verified on tmux 3.6a against an isolated `-L` server: with w5 active,
    /// `move-window -b -d -s @4 -t t:1` leaves w5 where it was asked to go and
    /// `window_active` on w1 instead. Reordering must not move the selection —
    /// dragging the row you are looking at and landing on a different pane is
    /// exactly the surprise a mirror-of-tmux GUI should not produce — so it
    /// goes back. Sent unconditionally rather than after checking a reply,
    /// because `select-window` on the window that is already active is a no-op
    /// and tmux answers a redundant one without complaint.
    ///
    /// The guard is also what makes these two methods safe to call on a *other*
    /// session's connection, which is how a window is dragged from one session
    /// into another: an arriving foreign window cannot be this session's active
    /// one, so nothing is sent — and nothing should be. Verified on tmux 3.6a
    /// that `-d` holds across sessions, so the destination's current window
    /// does not move; a `select-window` here would flip it for every client
    /// attached there.
    private func reselectIfItWasActive(_ id: String) {
        guard activeWindowID == id else { return }
        client.send("select-window -t \(id)")
    }

    /// Resize a pane to an exact cell size — used when the user drags a
    /// splitter, so tmux's layout follows the GUI rather than the reverse.
    func resizePane(id: String, columns: Int?, rows: Int?) {
        var command = "resize-pane -t \(id)"
        if let columns { command += " -x \(columns)" }
        if let rows { command += " -y \(rows)" }
        client.send(command)
    }

    /// Read a pane: its scrollback, its visible screen, and its cursor.
    ///
    /// `-e` keeps colours. `-J` is deliberately not used: joining wrapped lines
    /// would rewrap them at whatever width they are replayed into, which is not
    /// where the user saw them break.
    ///
    /// **Two captures, not one.** `-S -N` on its own returns the history and
    /// the visible screen run together, and a caller given that cannot tell
    /// where one ends and the other begins — which is exactly what tmux's
    /// cursor row is relative to. `-S -N -E -1` ends one row *above* the
    /// visible screen: measured on tmux 3.6a, a 10-row pane with 52 rows of
    /// history answers `-S -1000 -E -1` with 52 rows ending `L51`, and the
    /// plain capture answers with 10 rows starting `L52`. No overlap, no gap.
    /// That correspondence is what lets the cursor be restored on a pane's
    /// first paint, which the comment this replaces called impossible.
    ///
    /// It is also what an alternate-screen pane needs. Measured on 3.6a with
    /// `less` running: the history capture returns the *primary* screen's
    /// scrollback and the plain capture returns the alternate screen. Asked for
    /// as one range they come back as a single undifferentiated block.
    ///
    /// Bytes, not `String`. What comes back is a pane's screen with its colour
    /// sequences in it, headed for a terminal parser, and that is the same
    /// argument `%output` already wins — a `String` round trip replaces
    /// anything that is not valid UTF-8 with U+FFFD and there is no way back.
    /// tmux 3.6a happens not to hand us such a byte here, because it replaces
    /// invalid input with U+FFFD in its own grid before we ever ask; that is
    /// tmux's guarantee to keep or break, not this app's.
    ///
    /// The commands go down one pipe back to back, so tmux runs them in order,
    /// and the caller only asks once the pane has stopped writing — so they all
    /// describe the same screen.
    ///
    /// - Parameter historyLines: how far back to read, or nil for the visible
    ///   screen alone. tmux clamps to what the pane actually has, so asking for
    ///   more than it has is free.
    func capturePane(
        paneID: String,
        historyLines: Int?,
        completion: @escaping (TmuxPaneSnapshot) -> Void
    ) {
        captureHistory(paneID: paneID, lines: historyLines) { [weak self] history in
            guard let self else {
                completion(TmuxPaneSnapshot(
                    history: [], screen: [], cursor: nil, modes: nil
                ))
                return
            }
            self.client.runBytes("capture-pane -p -e -t \(paneID)") { [weak self] output, failed in
                guard let self, !failed else {
                    completion(TmuxPaneSnapshot(
                        history: history, screen: [], cursor: nil, modes: nil
                    ))
                    return
                }
                self.client.run("display-message -p -t \(paneID) '\(Self.stateFormat)'") { reply, failed in
                    let state = failed ? nil : Self.parseState(reply.first)
                    let cursor = state?.cursor
                    completion(TmuxPaneSnapshot(
                        history: history,
                        // Every row when the cursor is known, because the
                        // replay places the cursor by row number and that only
                        // means anything if the rows written are the rows tmux
                        // has. Without a cursor, dropping the trailing blanks
                        // is what stops the cursor parking on the bottom row of
                        // an otherwise empty screen — the old behaviour, kept
                        // for the one case that still needs it.
                        screen: cursor == nil ? Self.trimmingTrailingBlanks(output) : output,
                        cursor: cursor,
                        modes: state?.modes
                    ))
                }
            }
        }
    }

    /// The rows above the visible screen, and nothing else. See `capturePane`
    /// for why the boundary matters.
    private func captureHistory(
        paneID: String, lines: Int?, completion: @escaping ([Data]) -> Void
    ) {
        guard let lines, lines > 0 else {
            completion([])
            return
        }
        client.runBytes("capture-pane -p -e -t \(paneID) -S -\(lines) -E -1") { output, failed in
            completion(failed ? [] : output)
        }
    }

    /// The pane's cursor and every mode it is in, as one `display-message`.
    ///
    /// Comma-separated and positional rather than `key=value`, because every
    /// value here is either digits or one of tmux's four cursor-shape words —
    /// none of them can contain a comma, and a positional list cannot be
    /// half-parsed into something plausible the way a key-value list can.
    ///
    /// Every variable was checked against tmux 3.6a with `less --mouse`
    /// running before being relied on. A variable this tmux does not have
    /// expands to nothing, which shortens the reply and makes the field-count
    /// guard below reject the whole thing rather than shift every later field
    /// left by one.
    private static let stateFormat = [
        "#{cursor_x}", "#{cursor_y}",
        "#{alternate_on}", "#{cursor_flag}", "#{wrap_flag}", "#{insert_flag}",
        "#{origin_flag}", "#{keypad_cursor_flag}", "#{keypad_flag}",
        "#{mouse_standard_flag}", "#{mouse_button_flag}", "#{mouse_all_flag}",
        "#{mouse_sgr_flag}", "#{mouse_utf8_flag}",
        "#{scroll_region_upper}", "#{scroll_region_lower}",
        "#{cursor_shape}", "#{cursor_blinking}",
    ].joined(separator: ",")

    private struct PaneState {
        let cursor: TmuxPaneCursor
        let modes: TmuxPaneModes
    }

    /// All or nothing. A half-read reply would put the app in some *other*
    /// terminal's modes, which is worse than staying in none of them — and the
    /// caller already has a well-defined behaviour for "tmux would not say".
    private static func parseState(_ reply: String?) -> PaneState? {
        // Empty fields kept: `split` drops them by default, and a variable
        // that expanded to nothing would then shift every later field left
        // instead of failing the count.
        let parts = (reply ?? "").split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 18 else { return nil }
        let numbers = parts.map { Int($0) }
        func flag(_ index: Int) -> Bool? { numbers[index].map { $0 != 0 } }

        guard let column = numbers[0], let row = numbers[1], column >= 0, row >= 0,
              let alternate = flag(2), let cursorVisible = flag(3), let wrap = flag(4),
              let insert = flag(5), let origin = flag(6), let cursorKeys = flag(7),
              let keypad = flag(8), let mouseStandard = flag(9), let mouseButton = flag(10),
              let mouseAll = flag(11), let mouseSGR = flag(12), let mouseUTF8 = flag(13),
              let upper = numbers[14], let lower = numbers[15], upper >= 0, lower >= upper,
              let blinking = flag(17)
        else { return nil }

        return PaneState(
            cursor: TmuxPaneCursor(column: column, row: row),
            modes: TmuxPaneModes(
                alternateScreen: alternate,
                cursorVisible: cursorVisible,
                wrap: wrap,
                insert: insert,
                origin: origin,
                applicationCursorKeys: cursorKeys,
                applicationKeypad: keypad,
                mouseStandard: mouseStandard,
                mouseButton: mouseButton,
                mouseAll: mouseAll,
                mouseSGR: mouseSGR,
                mouseUTF8: mouseUTF8,
                scrollRegionUpper: upper,
                scrollRegionLower: lower,
                cursorShape: String(parts[16]),
                cursorBlinking: blinking
            )
        )
    }

    /// `capture-pane` returns one line per row of the pane, blanks included.
    /// Painting all of them leaves the cursor parked on the bottom row, so the
    /// next thing the shell writes — a prompt redraw after SIGWINCH, say —
    /// lands at the bottom of an otherwise empty screen instead of following
    /// the text. Dropping the trailing blanks puts the cursor where the
    /// content actually ends.
    ///
    /// Only reached when tmux would not say where the cursor is. Placing it
    /// explicitly is the better answer and is what normally happens.
    private static func trimmingTrailingBlanks(_ lines: [Data]) -> [Data] {
        var lines = lines
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        return lines
    }

    /// Decide blankness on a lossy reading and keep the bytes themselves.
    ///
    /// Everything the test looks for — spaces, and the CSI sequences
    /// `TmuxText.plain` strips — is ASCII, so no byte a lossy decode mangles
    /// can change the answer. A line made entirely of undecodable bytes reads
    /// as U+FFFD, which is not blank, which is the right answer for a line
    /// that has something on it.
    private static func isBlank(_ line: Data) -> Bool {
        let text = String(decoding: line, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespaces).isEmpty || TmuxText.plain(text).isEmpty
    }

    private var sessionTarget: String { sessionID }

    /// Adopt a name tmux reports outside a `%session-renamed` — the one that
    /// arrives with `list-sessions`. Covers the rename this app was not
    /// listening for: one that happened before it launched, or between a
    /// session being listed and its client finishing the attach.
    func noteName(_ name: String) {
        guard name != sessionName, !name.isEmpty else { return }
        adoptName(name)
    }

    private func adoptName(_ name: String) {
        TmuxLog.lifecycle(
            "\(sessionID) is now called \(name) (was \(sessionName))", session: sessionName
        )
        sessionName = name
        client.sessionLabel = name
        onStatusChange?(describeActive())
        notifyModelChanged()
    }

    // MARK: - Notifications

    private func handle(_ notification: TmuxNotification) {
        switch notification {
        case .sessionChanged(let id, let name):
            // A check now, not a source: the id came from `list-sessions`
            // before this client existed. A client that finds itself in some
            // other session is a state this app never asks for and cannot
            // represent — every command it sends targets the session it was
            // made for — so it is logged rather than followed.
            if id != sessionID {
                TmuxLog.lifecycle(
                    "control client for \(sessionID) reports it is attached to \(id) (\(name));"
                        + " commands still target \(sessionID)",
                    session: sessionName
                )
            } else {
                // This carries the session's name *now*, and the attach is the
                // one moment the name from `list-sessions` can already be
                // stale: a rename between the listing and the attach is
                // announced to clients that existed at the time, and this one
                // did not. Without this the connection keeps the listed name
                // until some unrelated refresh happens to correct it.
                noteName(name)
            }
            subscribeToActivity()
            refreshWindows()

        case .subscriptionChanged(let name, let window, let value):
            guard name == Self.activitySubscription, let window,
                  let index = windows.firstIndex(where: { $0.id == window }) else { return }
            let active = value == "1"
            guard windows[index].hasActivity != active else { return }
            windows[index].hasActivity = active
            notifyModelChanged()

        case .sessionRenamed(let id, let name):
            // The id test is the whole point. This notification is broadcast to
            // every control client on the server — measured on tmux 3.6a, a
            // client attached to `$0` is told about `$1` — so a connection that
            // took the name unconditionally would end up named after whichever
            // session was renamed most recently.
            guard id == sessionID else { return }
            noteName(name)

        case .layoutChange(let windowID, let saved, let visible):
            guard let index = windows.firstIndex(where: { $0.id == windowID }) else {
                refreshWindows()
                return
            }
            // Both, and the early return has to test both. A zoom changes only
            // the visible layout and an unzoom changes only it back, so a
            // comparison against the saved one alone reads every `prefix z` as
            // "nothing changed" and returns before anything redraws.
            guard windows[index].visibleLayoutText != visible
                || windows[index].savedLayoutText != saved else { return }
            windows[index].visibleLayoutText = visible
            windows[index].savedLayoutText = saved
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
        client.run("list-windows -t \(sessionTarget) -F '\(TmuxWindow.listFormat)'") { [weak self] lines, failed in
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
        let target = sessionTarget
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
        var debugSessionID: String { sessionID }
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
