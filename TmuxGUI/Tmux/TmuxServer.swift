//
//  TmuxServer.swift
//  TmuxGUI
//

import Foundation

/// Every session on the tmux server, each with its own control mode client.
///
/// One connection per session rather than one shared connection that switches:
/// control mode only reports output for the session a client is attached to,
/// so a single connection would go blind to every session but the current one.
/// Six pipes is a cheap price for switching that is instant and for activity
/// dots that stay live while you are looking somewhere else — and the
/// throughput probe showed the wire is nowhere near saturated.
///
/// Pane surfaces are still built lazily, when a session is first shown. A
/// connection costs a pipe; a surface costs GPU memory.
@MainActor
final class TmuxServer {
    let tmuxPath: String

    private(set) var sessionNames = [String]()
    private(set) var connections = [String: TmuxSessionConnection]()

    /// Fires when the set of sessions changes, or when any session's window
    /// list changes in a way the sidebar shows.
    var onChange: (() -> Void)?

    init(tmuxPath: String) {
        self.tmuxPath = tmuxPath
    }

    func start() {
        refreshSessions()
    }

    func stop() {
        stopped = true
        TmuxLog.destructive(
            "stopping every connection: \(connections.keys.sorted().joined(separator: ", "))"
        )
        for connection in connections.values { connection.stop() }
        connections.removeAll()
    }

    func connection(for sessionName: String) -> TmuxSessionConnection? {
        connections[sessionName]
    }

    /// Reconcile the connection set with what tmux currently has.
    ///
    /// A one-shot `list-sessions` rather than asking an existing connection:
    /// this also runs at startup, before there is a connection to ask, and
    /// keeping one code path avoids the two drifting apart.
    func refreshSessions() {
        guard !stopped else { return }
        // An empty answer used to return here, and that was the one case the
        // vanished-session cleanup could not reach: `onChange` never fired, so
        // nothing dropped the connection, the controller, or the surfaces of a
        // session that no longer existed, and the app went on showing a session
        // the server had lost — with no route out of it, because every trigger
        // that would re-ask is carried by a connection. Now only "could not ask
        // tmux at all" returns early; an empty list reconciles like any other.
        guard let names = TmuxControlClient.listSessions(tmuxPath: tmuxPath) else { return }
        sessionNames = names

        for name in names where connections[name] == nil {
            let connection = TmuxSessionConnection(tmuxPath: tmuxPath, sessionName: name)
            connection.addModelObserver { [weak self] in self?.onChange?() }
            connection.onServerSessionsChanged = { [weak self] in
                // Coalesced onto the next runloop turn: every connection sees
                // this notification, so a six-session server would otherwise
                // relist six times for one `new-session`.
                self?.scheduleSessionRefresh()
            }
            connection.onExit = { [weak self] _ in self?.scheduleSessionRefresh() }
            connections[name] = connection
            connection.start()
        }

        let gone = Set(connections.keys).subtracting(names)
        if !gone.isEmpty {
            // The app did not necessarily do this — a session can be destroyed
            // from any terminal. Logged so that "the session vanished" can be
            // told apart from "this app dropped it".
            TmuxLog.destructive(
                "sessions no longer on the server, dropping connections: "
                    + gone.sorted().joined(separator: ", ")
            )
        }
        for name in gone {
            connections[name]?.stop()
            connections.removeValue(forKey: name)
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
    func newSession() {
        // Not sent through a control client, so it bypasses the logging choke
        // point in `TmuxControlClient.enqueue` and has to record itself.
        TmuxLog.command("new-session -d", session: "-")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["new-session", "-d"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        TmuxLog.lifecycle("new-session -d finished, status \(process.terminationStatus)")
        refreshSessions()
    }

    private var refreshScheduled = false
    private var reaskScheduled = false
    /// Set by `stop()`. Control clients report their exit *after* teardown
    /// finishes — 1ms after, in the log — and each of those exits schedules a
    /// re-ask. Today the process dies before the main queue turns again; the
    /// re-ask below waits a second, which is long enough to matter.
    private var stopped = false

    private func askAgainWhileServerIsGone() {
        guard !reaskScheduled, !stopped else { return }
        reaskScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.reaskScheduled = false
            guard self.connections.isEmpty else { return }
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
