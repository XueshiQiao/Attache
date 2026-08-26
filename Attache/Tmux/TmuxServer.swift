//
//  TmuxServer.swift
//  Attache
//

import Foundation

/// Every session on the tmux server, each with its own control mode client.
///
/// One connection per session rather than one shared connection that switches:
/// control mode only reports output for the session a client is attached to,
/// so a single connection would go blind to every session but the current one.
/// Six pipes is a cheap price for switching that is instant and for activity
/// dots that stay live while you are looking somewhere else — and the
/// one pipe per session is not the bottleneck it looks like.
///
/// Pane surfaces are still built lazily, when a session is first shown. A
/// connection costs a pipe; a surface costs GPU memory.
@MainActor
final class TmuxServer {
    /// Which server, fixed for the life of the app. Everything here is keyed
    /// by bare session ids, which are unique only within one server — so one
    /// `TmuxServer` is one transport (one socket on one machine), and
    /// changing the setting means relaunching.
    let transport: TmuxTransport

    /// The server's version, probed by `HostContext` before `start()`. What
    /// it gates: reply-block decoding (3.5 escapes, 3.6 does not) and the
    /// `refresh-client -B` subscriptions. nil means "never probed", which
    /// only a caller that skipped `HostContext` can produce.
    var tmuxVersion: TmuxVersion?

    /// tmux's session ids, in tmux's own order. The identity of a session
    /// everywhere in this app: a name is user text and any terminal can change
    /// it at any moment, which used to read here as the session disappearing.
    private(set) var sessionIDs = [String]()
    /// Keyed by `$N`, for the same reason.
    private(set) var connections = [String: TmuxSessionConnection]()

    /// Fires when the set of sessions changes, or when any session's window
    /// list changes in a way the sidebar shows.
    var onChange: (() -> Void)?

    init(transport: TmuxTransport) {
        self.transport = transport
    }

    func start() {
        // Resettable, which it did not use to be: a remote host's server is
        // stopped whenever its ssh master drops and started again when the
        // pre-flight recovers, so "stopped" is a phase now, not a terminal
        // state. The local server still calls this once and never stops.
        stopped = false
        refreshSessions()
    }

    func stop() {
        stopped = true
        TmuxLog.destructive(
            "stopping every connection: \(describeConnections())"
        )
        for connection in connections.values { connection.stop() }
        connections.removeAll()
    }

    func connection(id: String) -> TmuxSessionConnection? {
        connections[id]
    }

    /// What tmux currently calls a session. Read from the connection rather
    /// than stored here, so there is one place a name lives and no second copy
    /// to go stale between a `%session-renamed` and the next `list-sessions`.
    func name(ofSession id: String) -> String? {
        connections[id]?.sessionName
    }

    /// The session a *name* refers to right now.
    ///
    /// For the debug inspector, whose routes a human types, and for nothing
    /// else. Anything inside the app that already has a session in hand has its
    /// id and should keep using it: two sessions cannot share a name at any one
    /// instant, but the name a user typed a moment ago can belong to a
    /// different session by the time it is looked up.
    func sessionID(named name: String) -> String? {
        connections.first { $0.value.sessionName == name }?.key
    }

    private func describeConnections() -> String {
        sessionIDs.compactMap { id in
            connections[id].map { "\(id) (\($0.sessionName))" }
        }.joined(separator: ", ")
    }

    /// One `list-sessions` in flight at a time, and at most one queued want
    /// behind it. The ask blocks for a network round trip on a remote host,
    /// so it runs off the main thread — and without the coalescing, the 1 Hz
    /// re-ask against a slow host would stack asks faster than that host
    /// answers them.
    private var listingInFlight = false
    private var relistWanted = false

    /// Reconcile the connection set with what tmux currently has.
    ///
    /// A one-shot `list-sessions` rather than asking an existing connection:
    /// this also runs at startup, before there is a connection to ask, and
    /// keeping one code path avoids the two drifting apart.
    ///
    /// The ask itself happens on a background queue and the reconcile lands
    /// back here. It was synchronous on the main actor for as long as the
    /// only server was local — a few milliseconds, invisible — and became
    /// the whole interface stuttering the day eight remote hosts joined:
    /// sampled at 48% of the main thread blocked in this one read.
    func refreshSessions() {
        guard !stopped else { return }
        if listingInFlight {
            relistWanted = true
            return
        }
        listingInFlight = true
        let transport = transport
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = TmuxControlClient.listSessions(transport: transport)
            DispatchQueue.main.async { self?.reconcile(with: result) }
        }
    }

    private func reconcile(with result: TmuxControlClient.SessionListResult) {
        listingInFlight = false
        // A refresh asked for while this one was on the wire ran against a
        // list that may already be stale; honour it after reconciling.
        defer {
            if relistWanted {
                relistWanted = false
                refreshSessions()
            }
        }
        guard !stopped else { return }
        // An empty answer used to return here, and that was the one case the
        // vanished-session cleanup could not reach: `onChange` never fired, so
        // nothing dropped the connection, the controller, or the surfaces of a
        // session that no longer existed, and the app went on showing a session
        // the server had lost — with no route out of it, because every trigger
        // that would re-ask is carried by a connection. Now only "could not ask
        // tmux at all" returns early; no server and an empty list both
        // reconcile like any other answer. A failed ask keeps the re-ask alive
        // when there is nothing left to hear from — returning silently there
        // used to end the loop for good, since the re-ask is the only trigger
        // that does not need a connection.
        let listed: [TmuxSessionListing]
        switch result {
        case .failed(let message):
            TmuxLog.lifecycle("list-sessions failed, changing nothing: \(message)")
            // Retry unconditionally, not only when `connections` is empty:
            // the dictionary still holds a connection whose client has
            // *exited* — reconciliation is what removes entries, and it needs
            // a successful listing to run. Gating the retry on emptiness left
            // exactly that state stuck forever, because a dead client sends
            // no further notifications to trigger anything. A retry against a
            // healthy server is one list-sessions and then silence, so the
            // 1 Hz cadence the gone-server loop already uses is fine here.
            scheduleRetryAfterFailedListing()
            return
        case .noServer:
            listed = []
        case .sessions(let sessions):
            listed = sessions
        }
        sessionIDs = listed.map(\.id)

        // A connection whose client has *exited* while its session lives on —
        // an ssh channel dying under it is the common way — is dead weight the
        // recreate loop below would otherwise skip forever: entries only leave
        // this dictionary when their session leaves the listing.
        for session in listed {
            guard let existing = connections[session.id], !existing.clientIsRunning
            else { continue }
            TmuxLog.lifecycle(
                "connection for \(session.id) has a dead client — remaking it",
                session: existing.sessionName
            )
            existing.stop()
            connections.removeValue(forKey: session.id)
        }

        for session in listed where connections[session.id] == nil {
            let connection = TmuxSessionConnection(
                transport: transport,
                sessionID: session.id, sessionName: session.name,
                decodesOctalReplies: tmuxVersion?.escapesControlModeReplies ?? false
            )
            connection.addModelObserver { [weak self] in self?.onChange?() }
            connection.onServerSessionsChanged = { [weak self] in
                // Coalesced onto the next runloop turn: every connection sees
                // this notification, so a six-session server would otherwise
                // relist six times for one `new-session`.
                self?.scheduleSessionRefresh()
            }
            connection.onExit = { [weak self] _ in self?.scheduleSessionRefresh() }
            connections[session.id] = connection
            connection.start()
        }

        // A rename this app was not listening for: one that happened before it
        // launched, or while a connection was still finishing its attach.
        // `%session-renamed` covers every rename after that and this covers the
        // rest, for the price of a string comparison per session.
        for session in listed { connections[session.id]?.noteName(session.name) }

        let gone = Set(connections.keys).subtracting(sessionIDs)
        if !gone.isEmpty {
            // The app did not necessarily do this — a session can be destroyed
            // from any terminal. Logged so that "the session vanished" can be
            // told apart from "this app dropped it". By id and name both: the
            // id is what was dropped, the name is what the user would recognise.
            TmuxLog.destructive(
                "sessions no longer on the server, dropping connections: "
                    + gone.sorted().map { id in
                        connections[id].map { "\(id) (\($0.sessionName))" } ?? id
                    }.joined(separator: ", ")
            )
        }
        for id in gone {
            connections[id]?.stop()
            connections.removeValue(forKey: id)
        }

        // Everything else here is notification-driven, and a notification needs
        // a connection to arrive on. With none left there is nothing to hear
        // from, so this is the one place the app has to ask again on its own —
        // otherwise a server that comes back is invisible until the user presses
        // the rail's +. It stops as soon as there is a connection again.
        if connections.isEmpty { askAgainWhileServerIsGone() }

        onChange?()
    }

    /// Create a detached session. Detached so the GUI decides when to show
    /// it, rather than tmux yanking every attached client over to it.
    ///
    /// Off the main thread for the same reason the listing is: on a remote
    /// host this is an ssh round trip, and it is wired to a button.
    func newSession() {
        // A word, not tmux's next number — picked against the sessions this
        // server currently has. Another client can win the same name in the
        // gap, so a duplicate answer falls back to a nameless create rather
        // than failing the click.
        let name = SessionNames.pick(avoiding: Set(connections.values.map(\.sessionName)))
        // Not sent through a control client, so it bypasses the logging choke
        // point in `TmuxControlClient.enqueue` and has to record itself.
        TmuxLog.command("new-session -d -s \(name)", session: "-")
        let transport = transport
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var problem = TmuxControlClient.createDetachedSession(transport: transport, named: name)
            if problem?.localizedCaseInsensitiveContains("duplicate session") == true {
                problem = TmuxControlClient.createDetachedSession(transport: transport)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let problem {
                    // A refused create used to go to /dev/null and read as
                    // the + button doing nothing. tmux's own words, or there
                    // is nothing for the user to act on.
                    TmuxLog.lifecycle("new-session -d failed: \(problem)")
                    DiagnosticsCenter.shared.notice(AppNotice(
                        severity: .error,
                        title: "tmux could not create a session",
                        body: problem
                    ))
                } else {
                    TmuxLog.lifecycle("new-session -d succeeded")
                }
                self.refreshSessions()
            }
        }
    }

    private var refreshScheduled = false
    private var reaskScheduled = false
    /// Set by `stop()`. Control clients report their exit *after* teardown
    /// finishes — 1ms after, in the log — and each of those exits schedules a
    /// re-ask. Today the process dies before the main queue turns again; the
    /// re-ask below waits a second, which is long enough to matter.
    private var stopped = false

    /// How long to wait between asks when only asking can move things
    /// forward. A second for the local server — cheap, and it is what makes
    /// a freshly started server appear promptly — but five for a remote
    /// one: every ask is a full ssh round trip, and eight quiet hosts at
    /// 1 Hz is a background hum of connections nobody is listening to.
    private var reaskDelay: TimeInterval { transport.pathsAreLocal ? 1 : 5 }

    private func askAgainWhileServerIsGone() {
        guard !reaskScheduled, !stopped else { return }
        reaskScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + reaskDelay) { [weak self] in
            guard let self else { return }
            self.reaskScheduled = false
            guard self.connections.isEmpty else { return }
            self.refreshSessions()
        }
    }

    /// The failed-listing counterpart of `askAgainWhileServerIsGone`, without
    /// its emptiness guard: after a failure the next attempt must run even
    /// though connections — possibly all dead — are still in the dictionary.
    private func scheduleRetryAfterFailedListing() {
        guard !reaskScheduled, !stopped else { return }
        reaskScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + reaskDelay) { [weak self] in
            guard let self else { return }
            self.reaskScheduled = false
            self.refreshSessions()
        }
    }

    private func scheduleSessionRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshSessions()
        }
    }
}
