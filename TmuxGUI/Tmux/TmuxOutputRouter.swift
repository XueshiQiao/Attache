//
//  TmuxOutputRouter.swift
//  TmuxGUI
//

import Foundation
import GhosttyTerminal

/// Thread-safe map from tmux pane id to the surface that renders it.
///
/// Exists to keep the hot path off the main thread. `%output` arrives on the
/// pipe reader queue at whatever rate the panes produce — measured at 19 MB/s
/// with room to spare — and `InMemoryTerminalSession.receive` already
/// serialises onto its own queue. Hopping to main just to look up a dictionary
/// would put every byte behind whatever the UI happens to be doing.
///
/// Only the registration side touches the main thread, and that happens once
/// per pane.
final class TmuxOutputRouter {
    private let lock = NSLock()
    private var sessions = [String: InMemoryTerminalSession]()

    /// Panes whose output arrived before their surface existed. tmux starts
    /// streaming as soon as the client attaches, so a busy pane can produce
    /// several kilobytes before the UI has built a view for it; dropping that
    /// would leave a visible hole in the scrollback.
    private var backlog = [String: Data]()
    private let backlogLimitPerPane = 256 * 1024

    /// Attach a surface to a pane and hand it whatever arrived first.
    ///
    /// Returns true if there was buffered output. The caller uses that to
    /// decide whether the pane also needs a `capture-pane` snapshot: a pane
    /// that has been quiet since the client attached would otherwise render
    /// blank, because tmux does not replay a pane's screen on attach. A pane
    /// that was already streaming does not need one — and painting a snapshot
    /// over live output would only rewind it.
    @discardableResult
    func register(paneID: String, session: InMemoryTerminalSession) -> Bool {
        lock.lock()
        sessions[paneID] = session
        let pending = backlog.removeValue(forKey: paneID)
        lock.unlock()

        guard let pending, !pending.isEmpty else { return false }
        session.receive(pending)
        return true
    }

    func unregister(paneID: String) {
        lock.lock()
        sessions.removeValue(forKey: paneID)
        backlog.removeValue(forKey: paneID)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        sessions.removeAll()
        backlog.removeAll()
        lock.unlock()
    }

    /// True if the pane had somewhere to go — used by metrics to tell whether
    /// bytes belong to a visible pane or one we are only counting.
    @discardableResult
    func deliver(paneID: String, data: Data) -> Bool {
        lock.lock()
        if let session = sessions[paneID] {
            lock.unlock()
            session.receive(data)
            return true
        }
        var pending = backlog[paneID] ?? Data()
        if pending.count < backlogLimitPerPane {
            pending.append(data)
            backlog[paneID] = pending
        }
        lock.unlock()
        return false
    }

    func isRegistered(paneID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions[paneID] != nil
    }
}
