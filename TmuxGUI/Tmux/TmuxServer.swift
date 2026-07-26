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
        let names = TmuxControlClient.listSessions(tmuxPath: tmuxPath)
        guard !names.isEmpty else { return }
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
        for name in gone {
            connections[name]?.stop()
            connections.removeValue(forKey: name)
        }

        onChange?()
    }

    /// Create a detached session. Detached so the GUI decides when to show
    /// it, rather than tmux yanking every attached client over to it.
    func newSession() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["new-session", "-d"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        refreshSessions()
    }

    private var refreshScheduled = false

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
