//
//  TmuxSessionConnection.swift
//  Attache
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
        // The diagnostics tap: the mirror just moved, so expectations checked
        // against it can be answered now rather than at the next sweep.
        DiagnosticsCenter.shared.modelChanged(self)
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

    /// Unlocked on purpose. Every `%output` arrives on the one serial queue
    /// `FileHandle.readabilityHandler` uses, so this is only ever touched from
    /// there — and the point of the whole path is that it does not wait on
    /// anything.
    private var renameStrings = TmuxRenameString()


    init(tmuxPath: String, sessionID: String, sessionName: String) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        client = TmuxControlClient(
            tmuxPath: tmuxPath, sessionID: sessionID, sessionName: sessionName
        )

        // Deliberately empty, and it is the shortest way to say what changed.
        //
        // This used to decode, scan and store every byte of every pane. Nothing
        // read any of it: the pane renderer was removed on 2026-07-31 and tmux
        // draws the panes itself now, so `TmuxOutputRouter.register` has had no
        // call site since, and the bytes went into a per-pane backlog nothing
        // drains. `subscribeToActivity` now sends `refresh-client -f no-output`,
        // so tmux stops sending them at all and this closure barely fires —
        // only in the window between attach and that command landing, which is
        // why it must not accumulate anything.
        //
        // Left in place rather than deleted because it is the one seam a pane
        // renderer would reattach at, and because `TmuxRenameString` and
        // `TmuxOutputRouter` are kept for the same reason `TerminalReply` is:
        // correct, checked against a table, and with no caller since that
        // deletion. See CLAUDE.md.
        client.onPaneOutput = { _, _ in }
        client.onNotification = { [weak self] notification in
            self?.handle(notification)
        }
        client.onExit = { [weak self] reason in
            self?.onExit?(reason)
        }
        // Held weakly there, so registration does not extend this object's
        // life — see `DiagnosticsCenter`.
        DiagnosticsCenter.shared.register(self)
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

        // Reset with the rest of the state, and this line is insurance rather
        // than a fix for anything that happens today. A connection is
        // single-use — one construction site, one `start()`, and a Foundation
        // `Process` that cannot be launched twice — so a client that dies is
        // always replaced by a *new* connection whose guard is already false.
        //
        // The moment somebody adds an in-place reconnect, leaving this set
        // silently skips every command in `subscribeToActivity`: not only the
        // `no-output` flag, but all three `-B` subscriptions. Activity dots,
        // pane paths and agent state would go dark at once, with no error
        // anywhere, on a connection that otherwise looks healthy.
        subscribedToActivity = false

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
    private static let activitySubscription = "attache-activity"
    /// The active pane's working directory, per window. Window scope on
    /// purpose: a pane-scoped variable asked at window scope resolves against
    /// that window's *active* pane and re-fires on `select-pane` — verified on
    /// tmux 3.6a — which is exactly the question the row is asking and removes
    /// a pane→window mapping layer here.
    private static let pathSubscription = "attache-path"
    /// Agent state, per pane. Pane scope, because a window with four panes can
    /// have an agent in any of them and the row has to speak for all of them.
    private static let agentSubscription = "attache-agent"
    private var subscribedToActivity = false

    /// The active pane's path for each window, keyed by window id. Not on
    /// `TmuxWindow`: that struct is a mirror of a `list-windows` reply and this
    /// arrives on a different channel, so keeping it separate stops the two
    /// from having to be refreshed together.
    private(set) var pathByWindow = [String: String]()
    /// When the user last looked at each window, from `@agent_seen`.
    ///
    /// Written by this app when a window is selected and read back through the
    /// same subscription as everything else, so it is tmux's value rather than
    /// the GUI's memory of it — which is what keeps "have I seen this" from
    /// becoming a third piece of locally authored state, and what lets a plain
    /// `tmux attach` elsewhere agree about it.
    private(set) var seenByWindow = [String: TimeInterval]()
    /// The agent badge for each pane that has one, keyed by pane id.
    private(set) var agentByPane = [String: AgentBadge]()

    /// What each pane has told us, before any strategy has had an opinion.
    ///
    /// Kept raw so switching `AppSettings.agentStateSource` re-decides
    /// immediately instead of waiting for tmux to repeat itself — the whole
    /// point of the setting is to be able to compare the two, and a switch that
    /// showed nothing until the next notification would make that impossible.
    private var evidenceByPane = [String: AgentEvidence]()
    /// What each pane's Claude Code session says about itself, parsed from
    /// `@agent_stat`. Only panes whose status line wrapper is installed appear
    /// here, so it is usually smaller than `evidenceByPane` and often empty.
    private var statsByPane = [String: AgentStats]()
    /// The previous capture, so "is this pane repainting" can be answered.
    private var lastScreenByPane = [String: [String]]()
    private var screenPollTimer: Timer?
    /// Suspended while nobody can see the rail.
    ///
    /// The Git service has had this from the start and this did not, which is
    /// the whole argument for it: capturing every agent pane every two seconds
    /// to draw a sidebar that is behind another window is the same waste, on
    /// the same laptop, for the same nobody.
    private var isPaused = false

    /// Forget panes tmux no longer has.
    ///
    /// Without this the map only ever grows, and the capture loop keeps sending
    /// `capture-pane` at panes that closed — one failing round trip per dead
    /// pane per tick, forever, for a row that no longer exists. The pane set
    /// comes from the *saved* layout for the reason it always does here: a
    /// zoomed window's visible layout lists one pane, and pruning against that
    /// would forget the others every time somebody pressed `prefix z`.
    private func pruneVanishedPanes() {
        let live = Set(windows.flatMap(\.paneIDs))
        guard !live.isEmpty else { return }
        let gone = evidenceByPane.keys.filter { !live.contains($0) }
        guard !gone.isEmpty else { return }
        for pane in gone {
            AgentTransitionLog.recordPaneClosed(
                paneID: pane, session: sessionID, window: "@?", windowName: "closed"
            )
            evidenceByPane.removeValue(forKey: pane)
            lastScreenByPane.removeValue(forKey: pane)
            agentByPane.removeValue(forKey: pane)
            statsByPane.removeValue(forKey: pane)
        }
        notifyModelChanged()
    }

    /// Re-decide every pane's badge from the evidence on hand.
    ///
    /// Cheap and called often: the strategies are pure functions over a value
    /// that is already in memory, and the notification only goes out when the
    /// result actually moved.
    private func recomputeAgentBadges() {
        let source = AppSettings.agentStateSource
        var next = [String: AgentBadge]()
        for (pane, evidence) in evidenceByPane {
            guard var badge = source.badge(from: evidence) else { continue }
            // **When did this state begin?**
            //
            // Only the hook strategy can answer that on its own — the agent
            // stamps `@agent_at` as it reports. The screen strategy has no
            // clock at all, it has a picture, so every badge it makes carries a
            // nil `since`. Left that way, `AgentBadge.isSettled` compares
            // against `.distantPast` and *any* seen-timestamp settles it: click
            // a window once and its green mark never returns, however many
            // turns the agent finishes afterwards. The "unread" model is
            // exactly what that breaks.
            //
            // So the transition is stamped here, where the previous badge is
            // known, and carried forward while the state does not change —
            // carried rather than re-stamped, or every recompute would produce
            // a different value and notify forever.
            if badge.since == nil {
                let previous = agentByPane[pane]
                badge.since = previous?.state == badge.state ? previous?.since : Date()
            }
            next[pane] = badge
        }

        // Logged before the equality check, because a pane whose *reason*
        // changed without its state changing is exactly the case the check
        // filters out — and the log's own de-duplication is on state, so
        // nothing is written twice.
        let sourceName = AppSettings.agentStateSource.rawValue
        for (pane, badge) in next {
            guard let window = windows.first(where: { $0.paneIDs.contains(pane) }) else { continue }
            AgentTransitionLog.record(
                paneID: pane, state: badge.state, reason: badge.reason, source: sourceName,
                session: sessionID, window: window.id, windowName: window.name
            )
        }

        guard next != agentByPane else { return }
        agentByPane = next
        notifyModelChanged()
    }

    /// Start, stop, or re-time the pane capture the screen strategy needs.
    ///
    /// One `capture-pane` per agent pane per tick. That is a real cost and the
    /// reason it is opt-in: with hooks the app is told, and here it has to go
    /// and look. Only panes whose foreground process looks like an agent are
    /// captured, so a session of shells costs nothing either way.
    /// Stop or resume the screen capture with the window's visibility.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        applyAgentStateSource()
    }

    func applyAgentStateSource() {
        screenPollTimer?.invalidate()
        screenPollTimer = nil

        guard !isPaused else { return }
        guard AppSettings.agentStateSource.needsScreen else {
            // Drop what was captured. Left behind, it would be handed to a
            // strategy that never asked for it the next time this switches.
            for pane in evidenceByPane.keys { evidenceByPane[pane]?.screen = nil }
            lastScreenByPane.removeAll()
            recomputeAgentBadges()
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.captureAgentScreens()
        }
        RunLoop.main.add(timer, forMode: .common)
        screenPollTimer = timer
        captureAgentScreens()
    }

    private func captureAgentScreens() {
        pruneVanishedPanes()
        for (pane, evidence) in evidenceByPane
            where AgentDetector.isAgentCommand(evidence.currentCommand)
        {
            // The visible screen only, no history: the question is what the
            // pane is doing *now*, and scrollback from an hour ago answers a
            // different one — including, wrongly, with text that matches a rule.
            // `runBytes`, not `run`. This file says why twice over: a reply
            // decoded to `String` on the way past substitutes U+FFFD for
            // anything that is not valid UTF-8, `failed` stays false, and no
            // later code can tell. A pane's own bytes are exactly what that
            // ruins — and a corrupted line changes what a `contains` rule
            // matches with no signal at all. The other two `capture-pane` call
            // sites in this file already use it.
            client.runBytes("capture-pane -p -t \(pane)") { [weak self] output, failed in
                guard let self, !failed else { return }
                let lines = output.map { TmuxText.plain(String(decoding: $0, as: UTF8.self)) }
                let previous = self.lastScreenByPane[pane]
                self.lastScreenByPane[pane] = lines
                self.evidenceByPane[pane]?.screen = lines
                // Only once there is something to compare against. A first
                // capture is not evidence of a repaint.
                self.evidenceByPane[pane]?.screenChanged = previous != nil && previous != lines
                self.recomputeAgentBadges()
            }
        }
    }

    /// The most urgent agent badge among a window's panes, or nil.
    ///
    /// Reads the pane set from the *saved* layout, not the visible one: while a
    /// pane is zoomed the visible layout is a single-pane tree, and a window
    /// whose badge came from the visible one would drop the other panes' agents
    /// on every `prefix z`.
    func agentBadge(forWindow windowID: String) -> AgentBadge? {
        guard let window = windows.first(where: { $0.id == windowID }) else { return nil }
        var badge = window.paneIDs.reduce(nil) { AgentBadge.moreUrgent($0, agentByPane[$1]) }
        // Stamped here rather than in a strategy: whether the *user* has looked
        // is a property of the window, not of the pane the agent happens to be
        // in, and no strategy has any business knowing about it.
        badge?.seenAt = seenByWindow[windowID].map { Date(timeIntervalSince1970: $0) }
        return badge
    }

    /// What the agent in a window says about itself, or nil.
    ///
    /// Takes the numbers from **the same pane the badge came from**, so a row
    /// never reads `needs you` beside another pane's model and cost. Same pane
    /// set as `agentBadge(forWindow:)` and for the same zoom reason.
    func agentStats(forWindow windowID: String) -> AgentStats? {
        agentPane(forWindow: windowID).flatMap { statsByPane[$0] }
    }

    /// What the conversation rail needs to find this window's transcript.
    ///
    /// Deliberately the **same pane** `agentStats(forWindow:)` reads, so the
    /// conversation on the right and the model and cost on the left are always
    /// about the same agent. A window with two agents in it otherwise shows one
    /// pane's numbers over the other pane's conversation, which is the kind of
    /// disagreement this codebase exists to avoid.
    func conversationEvidence(forWindow windowID: String) -> AgentPaneEvidence? {
        guard let pane = agentPane(forWindow: windowID),
              let evidence = evidenceByPane[pane]
        else { return nil }
        return AgentPaneEvidence(
            paneID: pane,
            kind: evidence.optionKind,
            currentCommand: evidence.currentCommand,
            statusPayload: evidence.optionStats,
            // Nothing writes a session id straight to a pane yet. Claude Code
            // publishes its own inside the status payload; the field is here
            // for an agent that has no status line to put one in — Codex's
            // hooks are expected to be the first.
            sessionID: ""
        )
    }

    /// Which pane speaks for a window, by the badge's own ranking.
    private func agentPane(forWindow windowID: String) -> String? {
        guard let window = windows.first(where: { $0.id == windowID }) else { return nil }
        var best: (pane: String, badge: AgentBadge)?
        for pane in window.paneIDs {
            guard let badge = agentByPane[pane] else { continue }
            guard let current = best else { best = (pane, badge); continue }

            // **Asked both ways round, and that is the fix.** `moreUrgent`
            // answers with one of its arguments and returns the first on a
            // tie, so a single comparison cannot tell "strictly more urgent"
            // from "identical" — and identical is not hypothetical here, since
            // `@agent_at` has one-second resolution and two panes that changed
            // state in the same second produce equal badges. Reading a single
            // comparison as a win silently preferred the later pane, which
            // hid the numbers whenever that pane was the one without them.
            let challengerWins = AgentBadge.moreUrgent(badge, current.badge) == badge
            let holderWins = AgentBadge.moreUrgent(current.badge, badge) == current.badge
            if challengerWins, !holderWins {
                best = (pane, badge)
            } else if challengerWins, holderWins {
                // Equal rank. Prefer whichever pane actually reported, rather
                // than drawing nothing while the answer sits one pane away.
                // The badge is the same either way — equal rank means the same
                // word on the row — so this cannot disagree with
                // `agentBadge(forWindow:)` about what is being shown.
                if statsByPane[current.pane] == nil, statsByPane[pane] != nil {
                    best = (pane, badge)
                }
            }
        }
        return best?.pane
    }

    /// The freshest account-wide rate-limit snapshot any pane here has
    /// reported, or nil.
    ///
    /// Every open Claude Code session writes the same two windows, and an idle
    /// one keeps re-writing whatever it saw when it was last busy — so this is
    /// a `fresher` reduce rather than "whichever pane answered last". Taking
    /// the last writer is what makes the number jump about.
    var accountUsage: AccountUsage? {
        statsByPane.values.reduce(nil) { AccountUsage.fresher($0, $1.usage) }
    }

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

        // First, and it is the cheapest line in the file. tmux sends a control
        // client every byte every pane in the session produces, and this app has
        // not drawn a pane from that stream since the renderer was removed —
        // tmux draws them, on a pty of its own. So every one of those bytes was
        // being unescaped, scanned for `ESC k`, counted under a lock, and then
        // appended to a per-pane backlog that nothing drains, up to 256 KB each.
        // `no-output` stops tmux sending them at all, which is the only fix that
        // costs nothing rather than throwing the bytes away more cheaply.
        //
        // Measured on tmux 3.6a against an isolated `-L` server, because the
        // flag's blast radius is the whole question and the name does not settle
        // it. It is **per client**: a second control client attached to the same
        // session still received all 35 `%output` lines and the marker while
        // this one received none — so the `tmux attach` that actually draws the
        // panes is untouched. And it suppresses only pane output: commands still
        // run, `%begin` reply blocks still come back with real data, and
        // `%subscription-changed` still arrives, which is what the rail's
        // activity, path and agent state are all read from.
        //
        // What it cost was `TmuxMetrics`, whose only input was `onPaneOutput`.
        // With nothing feeding it and nothing reading it, the type and the
        // sidebar footer's byte rate were both removed rather than left to read
        // "idle" for ever — a meter that cannot tell a live idle connection from
        // a dead one is worse than no meter.
        client.send("refresh-client -f no-output")

        client.send(
            "refresh-client -B '\(Self.activitySubscription):@*:#{window_activity_flag}'"
        )
        // Both are registered here rather than lazily when the rail first wants
        // them, for the reason the activity one is: subscribing emits the
        // current value for every matching item immediately, so the rail is
        // right from the attach instead of only after the first change.
        //
        // Single-quoted as one shell word. The formats contain `#{...}` and
        // U+0001 separators, and `TmuxCommand.quote` is reserved for real user
        // text — these are constants written here, so there is nothing to
        // escape and nothing a name could smuggle in.
        client.send(
            "refresh-client -B '\(Self.pathSubscription):@*:"
                + "#{pane_current_path}\u{01}#{@agent_seen}'"
        )
        client.send(
            "refresh-client -B '\(Self.agentSubscription):%*:\(AgentDetector.paneFormat)'"
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
            .appendingPathComponent("attache-paste-\(token).txt")
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

        let buffer = "attache-paste-\(token)"
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

    /// Ask tmux to move the active pane, then re-read what it actually is.
    ///
    /// **The refresh is not belt-and-braces; it is the only thing that can
    /// repair a stale window list.** tmux announces `%window-pane-changed` when
    /// the active pane *changes*, so a `select-pane` naming the pane tmux has
    /// already selected is answered by silence — and if this app's mirror was
    /// wrong, silence leaves it wrong for ever. Reading the reply costs one
    /// `list-windows` per pane click and closes that hole: every command whose
    /// point is to move the active pane now ends with tmux being asked what the
    /// active pane is.
    func focus(paneID: String) {
        client.run("select-pane -t \(paneID)") { [weak self] _, _ in
            self?.refreshWindows()
        }
    }

    func selectWindow(id: String) {
        client.send("select-window -t \(id)")
        markSeen(windowID: id)
    }

    /// Record that the user has looked at this window.
    ///
    /// This is what retires a finished agent's green mark, instead of a timer.
    /// A clock is arbitrary and throws the information away exactly when it is
    /// worth most — come back after an hour and everything that finished while
    /// you were gone has already faded. "Seen" is the predicate that was
    /// actually meant, and it is the same one tmux uses for its own activity
    /// flag.
    ///
    /// Sent even when the window is already selected, so clicking a row is
    /// always a way to dismiss its mark.
    func markSeen(windowID: String) {
        client.send("set-option -w -t \(windowID) @agent_seen \(Int(Date().timeIntervalSince1970))")
    }

    /// Send a command the user wrote, verbatim.
    ///
    /// The one place in this app where a whole command line comes from outside
    /// it, and it is deliberately not quoted, escaped or validated. Everywhere
    /// else the rule is to target tmux by id precisely because names are
    /// arbitrary user text being interpolated into a command *this app* built —
    /// there, the app is responsible for the shape of the line. Here the user
    /// wrote the whole line, in a settings field, on their own machine; it is
    /// their `.tmux.conf` with a different editor, and quoting it would only
    /// mean their command does not run.
    ///
    /// No target is added for the same reason: a Quick Action is meant to read
    /// like a tmux binding, and a binding's relative target is the client's
    /// session. This connection is attached to exactly one session, so
    /// `set status` lands on the session the user is looking at.
    func runUserCommand(_ command: String) {
        client.send(command)
    }

    func newWindow() {
        client.send("new-window -t \(sessionTarget)")
    }

    func killWindow(id: String) {
        client.send("kill-window -t \(id)")
    }

    /// Split a pane in two. `-h` puts the new pane beside it, `-v` below it.
    ///
    /// tmux's own letters, and worth knowing that iTerm uses "Split
    /// Vertically" for the exact arrangement tmux calls `-h` — which is why
    /// the menu items name the *result* ("Split Right" / "Split Down") and
    /// neither of those words. See `SessionViewController.PaneSplit`.
    ///
    /// `-c '#{pane_current_path}'` is what makes the new pane open in the
    /// directory the user is already in, which is the whole point of splitting
    /// rather than opening a window. It looks like interpolated text and is
    /// not: tmux parses the command line first and expands the format
    /// afterwards, inside `-c`'s value, so a path holding a quote or a space
    /// cannot escape the argument. That is why this does not violate the rule
    /// about only ever naming tmux objects by id.
    ///
    /// Nothing local is drawn or predicted. tmux answers with `%layout-change`
    /// and `%window-pane-changed`, and the new pane's surface is built from
    /// those — the same path a split typed into `tmux attach` takes.
    func splitPane(id: String, horizontally: Bool) {
        client.send("split-window \(horizontally ? "-h" : "-v") -t \(id) -c '#{pane_current_path}'")
    }

    /// End one pane. Everything running in it dies with it; the caller is
    /// responsible for having asked first.
    ///
    /// Killing the last pane of a window kills the window, which is tmux's
    /// behaviour and not something this app second-guesses.
    func killPane(id: String) {
        client.send("kill-pane -t \(id)")
    }

    /// Toggle this pane filling its window.
    ///
    /// `-Z` is a toggle in tmux, so there is no zoom state to keep here. What
    /// zoom currently is gets read back off `window_visible_layout` differing
    /// from `window_layout` — see `TmuxWindow`.
    func toggleZoom(paneID: String) {
        client.send("resize-pane -Z -t \(paneID)")
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
    /// The directory of the pane covering one cell of the window on screen.
    ///
    /// The one thing that can resolve a relative path clicked inside a pane:
    /// `src/main.swift` means nothing without it.
    ///
    /// **Asked of tmux by coordinate rather than worked out from the cached
    /// model, and that is the whole point of it.** `windows` on this object is
    /// refreshed by a control-mode notification followed by a `list-windows`
    /// round trip, so in the moment after the user switches windows in the
    /// embedded client the screen already shows the new window while this side
    /// still holds the old one's layout. A click resolved against that names a
    /// pane which is not under the pointer any more, and hands a relative path
    /// some other directory entirely. `list-panes -t <session>` reports the
    /// *current* window — the one being drawn — and gives the geometry and the
    /// directory in the same reply.
    ///
    /// `pane_right` and `pane_bottom` are inclusive. Measured on tmux 3.6a: an
    /// 80-column window split left/right gives panes at 0...39 and 41...79, and
    /// the missing column is the divider, which belongs to no pane and
    /// correctly answers nil here.
    ///
    /// **Known limitation: a `display-popup` is not accounted for.** A popup is
    /// drawn *over* the panes and is not one of them, so a click inside it
    /// resolves to whichever pane lies underneath, and a relative link clicked
    /// in a popup opens against that pane's directory instead of the popup's.
    /// Absolute paths and URLs are unaffected, since they never ask this
    /// question. It is left standing because nothing on 3.6a reports a popup's
    /// own directory, and refusing every relative link that *might* be in a
    /// popup would mean refusing all of them.
    func workingDirectory(
        atColumn column: Int,
        row: Int,
        completion: @escaping (String?) -> Void
    ) {
        // The zoom flag and the active flag travel together as two characters,
        // because **a zoomed window still reports every pane's old rectangle**.
        // Measured on tmux 3.6a: zoom the right-hand pane of an 80-column split
        // and the hidden left pane goes on claiming 0...39 while the zoomed one
        // claims 0...79. They overlap, the hidden pane is listed first, and
        // taking the first match would answer a click on the left half of a
        // zoomed pane with the directory of a pane that is not on screen at all.
        let format = "#{pane_left} #{pane_top} #{pane_right} #{pane_bottom}"
            + " #{window_zoomed_flag}#{pane_active} #{pane_current_path}"
        client.run("list-panes -t \(sessionTarget) -F '\(format)'") { reply, failed in
            guard !failed else {
                completion(nil)
                return
            }
            for line in reply {
                // A path can hold spaces, so only the five fields ahead of it
                // are split off.
                let parts = line.split(
                    separator: " ", maxSplits: 5, omittingEmptySubsequences: false
                )
                guard parts.count == 6,
                      let left = Int(parts[0]), let top = Int(parts[1]),
                      let right = Int(parts[2]), let bottom = Int(parts[3]),
                      // Zoomed, and not the pane being shown: it is off screen.
                      parts[4] != "10",
                      column >= left, column <= right, row >= top, row <= bottom
                else { continue }
                let path = parts[5].trimmingCharacters(in: .whitespaces)
                completion(path.isEmpty ? nil : path)
                return
            }
            completion(nil)
        }
    }

    /// Put one line on tmux's own status line, where the user can actually see
    /// it. Used to say that a link led nowhere.
    ///
    /// Two things here are not obvious, and the first version got both wrong.
    ///
    /// **`-c`, because this connection is not the client on screen.** Every
    /// session here has two clients: this one, a `tmux -C attach` control
    /// client with no tty, and the plain `tmux attach` libghostty runs, which
    /// is the one being drawn. `display-message` with no `-c` goes to the
    /// *current* client — the control one — which draws no status line at all,
    /// so the message was sent, logged, and invisible. That is exactly the
    /// shape of mistake to distrust: the log said it happened. Verified
    /// against the running app on 2026-07-31, where `list-clients` showed
    /// `client-48395 control=1` beside `/dev/ttys027 control=0` for one
    /// session. All the non-control clients get it, because a person watching
    /// the same session from their own terminal is watching the same thing.
    ///
    /// **`-l`, because the message is expanded as a tmux format otherwise.**
    /// `TmuxCommand.quote` settles how tmux's *command parser* reads the
    /// argument and stops there; format expansion happens afterwards, on the
    /// text. The text is a path that came off the screen, and a pane can print
    /// anything — an OSC 8 hyperlink's target never has to look like a path to
    /// begin with. Measured on tmux 3.6a: `display-message -p "A#{pane_id}B"`
    /// prints `A%0B`, so `#{...}` is substituted, while `-l` prints it
    /// literally. `#(shell-command)` did *not* execute in that same test — two
    /// runs, no file created — but leaving it to a version's behaviour when
    /// there is a flag that means "literal" is not a trade worth making.
    func showStatusMessage(_ text: String) {
        client.run("list-clients -t \(sessionTarget) -F '#{client_control_mode}#{client_name}'") {
            [weak self] reply, failed in
            guard let self, !failed else { return }
            for line in reply where line.hasPrefix("0") {
                let name = String(line.dropFirst())
                guard !name.isEmpty else { continue }
                self.client.send(
                    "display-message -l -c \(TmuxCommand.quote(name)) \(TmuxCommand.quote(text))"
                )
            }
        }
    }

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
            // After the subscriptions, so the first capture has a pane list to
            // work from rather than starting on an empty one.
            applyAgentStateSource()
            refreshWindows()

        case .subscriptionChanged(let name, let window, let pane, let value):
            switch name {
            case Self.activitySubscription:
                guard let window,
                      let index = windows.firstIndex(where: { $0.id == window }) else { return }
                let active = value == "1"
                guard windows[index].hasActivity != active else { return }
                windows[index].hasActivity = active
                notifyModelChanged()

            case Self.pathSubscription:
                guard let window else { return }
                let parts = value.components(separatedBy: "\u{01}")
                let value = parts.first ?? ""
                let seen = parts.count > 1 ? TimeInterval(parts[1]) : nil
                let seenChanged = seenByWindow[window] != seen
                seenByWindow[window] = seen
                // An empty path is what a window whose pane has already died
                // reports. Dropping the entry rather than storing "" keeps
                // "we have never been told" and "it is nothing" the same
                // answer for the row, which is to draw no second line.
                let changed = value.isEmpty
                    ? pathByWindow.removeValue(forKey: window) != nil
                    : pathByWindow.updateValue(value, forKey: window) != value
                if changed || seenChanged { notifyModelChanged() }

            case Self.agentSubscription:
                guard let pane else { return }
                let fields = value.components(separatedBy: "\u{01}")
                guard fields.count >= 4 else { return }
                var evidence = evidenceByPane[pane]
                    ?? AgentEvidence(paneID: pane, currentCommand: fields[3])
                evidence.currentCommand = fields[3]
                evidence.optionState = fields[0]
                evidence.optionKind = fields[1]
                evidence.optionAt = fields[2]
                evidence.optionWhy = fields.count > 4 ? fields[4] : ""

                // **Re-parse only when the text moved.** The status line
                // wrapper rewrites `@agent_stat` on every render — every five
                // seconds, per agent pane — while the numbers a person can see
                // move far less often. Comparing the raw string first keeps a
                // 1.3 KB JSON parse off most of those notifications, and
                // comparing the *parsed* value afterwards keeps the rail from
                // rebuilding when only a fraction of a cent changed. That
                // second comparison is the one that matters: `AgentStats`
                // rounds context to a whole percent and cost to cents for
                // exactly this reason.
                var statsDidChange = false
                let rawStats = fields.count > 5 ? fields[5] : ""
                if rawStats != evidence.optionStats {
                    evidence.optionStats = rawStats
                    let parsed = AgentStats.parse(rawStats)
                    if statsByPane[pane] != parsed {
                        if let parsed { statsByPane[pane] = parsed }
                        else { statsByPane.removeValue(forKey: pane) }
                        statsDidChange = true
                    }
                }

                evidenceByPane[pane] = evidence
                recomputeAgentBadges()
                // After the recompute, which sends its own notification only
                // when a badge moved. A cost that ticked up while the state
                // stayed `working` moves no badge at all.
                if statsDidChange { notifyModelChanged() }

            default:
                return
            }

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
            // The first non-diagnostic producer: this used to be a status-bar
            // string nobody saw. Same fact, now somewhere a person looks.
            DiagnosticsCenter.shared.notice(AppNotice(
                severity: .warning,
                title: "tmux paused a pane",
                body: "Pane \(pane) in \(sessionName) is producing output faster"
                    + " than it can be read; tmux paused it.",
                session: sessionName
            ))

        default:
            break
        }
    }

    /// Re-read the whole window list rather than patching it incrementally.
    /// A `list-windows` round trip is cheap and it cannot drift; incremental
    /// updates from six notification types eventually can.
    private func refreshWindows() {
        let label = sessionName
        client.run("list-windows -t \(sessionTarget) -F '\(TmuxWindow.listFormat)'") { [weak self] lines, failed in
            guard let self, !failed else {
                if failed { TmuxLog.lifecycle("list-windows failed — window list not refreshed", session: label) }
                return
            }
            let parsed = lines.compactMap(TmuxWindow.parse(listLine:)).map { window -> TmuxWindow in
                var window = window
                // Window names come from `automatic-rename`, which copies
                // whatever the pane last ran — escape sequences included.
                window.name = TmuxText.plain(window.name)
                return window
            }
            // An empty answer to `list-windows` is not a session with no
            // windows — a session cannot have none — so it is a reply that did
            // not belong to this command. Dropping it is right; dropping it
            // *silently* is what made a mispaired reply present as the keyboard
            // moving on its own, with the model frozen on a pane tmux had
            // already left. See `TmuxControlClient`'s `%end` handling.
            guard !parsed.isEmpty else {
                TmuxLog.lifecycle(
                    "list-windows answered \(lines.count) line(s) that parsed as no windows —"
                        + " keeping the previous list",
                    session: label
                )
                return
            }

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

// MARK: - Diagnostics truth

extension TmuxSessionConnection {
    /// The ground-truth half of a diagnostics snapshot: what tmux itself says
    /// about this session's windows and panes, right now, through the same
    /// channel the anomaly is about.
    ///
    /// Read-only by construction — two `list-*` queries and nothing else —
    /// which is what keeps `DiagnosticsCenter` inside its write-only contract
    /// while still letting a snapshot compare mirror against reality. Lives in
    /// this file because `client` is private, and widening `client`'s access
    /// for a probe would hand diagnostics the one thing it must never have: a
    /// way to send arbitrary commands.
    ///
    /// The timeout is the interesting half. On a deaf channel these queries
    /// never answer, and the snapshot then records that the truth query itself
    /// went unanswered — for that anomaly, the most incriminating fact a
    /// snapshot can hold.
    func diagnosticsTruth(timeout: TimeInterval, completion: @escaping ([String: Any]) -> Void) {
        var truth = [String: Any]()
        var remaining = 2
        var delivered = false

        // Everything below runs on the main queue: `client.run` calls back
        // there and the deadline is scheduled there, so plain captured vars
        // are enough.
        let deadline = DispatchWorkItem {
            guard !delivered else { return }
            delivered = true
            truth["unanswered"] = "truth queries got no reply within \(timeout)s"
                + " — the channel itself is not answering"
            completion(truth)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
        let deliverIfReady = {
            guard remaining == 0, !delivered else { return }
            delivered = true
            deadline.cancel()
            completion(truth)
        }

        client.run(
            "list-windows -t \(sessionTarget) -F '#{window_id} #{window_index}"
                + " #{window_name} active=#{window_active} panes=#{window_panes}"
                + " layout=#{window_layout} visible=#{window_visible_layout}'"
        ) { lines, failed in
            truth["windows"] = failed ? ["<query failed>"] : lines
            remaining -= 1
            deliverIfReady()
        }
        client.run(
            "list-panes -s -t \(sessionTarget) -F '#{window_id} #{pane_id}"
                + " active=#{pane_active} #{pane_width}x#{pane_height}"
                + " cmd=#{pane_current_command}'"
        ) { lines, failed in
            truth["panes"] = failed ? ["<query failed>"] : lines
            remaining -= 1
            deliverIfReady()
        }
    }
}

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
