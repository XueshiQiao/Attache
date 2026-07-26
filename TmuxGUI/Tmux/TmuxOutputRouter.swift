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

    /// How many `%output` chunks each pane has produced, counted whether or
    /// not there was a surface to hand them to.
    ///
    /// Exists to answer one question for the repaint pass: has this pane
    /// written anything since its geometry changed? A pane that has is one
    /// whose program already redrew itself at the new size, and painting a
    /// `capture-pane` snapshot over it is then all risk and no benefit. Kept
    /// here rather than on the surface because this is the only place that
    /// sees every chunk, and it already holds the lock that makes the count
    /// safe to read from the main thread.
    private var deliveryCounts = [String: UInt64]()

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
        defer { lock.unlock() }
        sessions[paneID] = session
        guard let pending = backlog.removeValue(forKey: paneID), !pending.isEmpty else { return false }
        // Handed over while the lock is still held. Releasing it first leaves a
        // window in which the reader queue delivers a live chunk to the session
        // that was just registered, and the backlog then arrives behind output
        // that came after it.
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
    ///
    /// The hand-off happens under the lock. That is what lets `deliverSnapshot`
    /// mean anything: counting a chunk and enqueuing it have to be one step, or
    /// a snapshot can be enqueued between them and land on top of output it was
    /// supposed to defer to.
    ///
    /// What that costs, stated exactly rather than as "nothing", because
    /// CLAUDE.md's rule about not slowing this path deserves a real answer.
    /// `InMemoryTerminalSession.receive` reaches `enqueueWrite`, which is a
    /// `DispatchQueue.async` onto the surface's own serial queue — so the lock
    /// never covers a parse. But `enqueueWrite` first reads `currentGeneration`,
    /// and that takes libghostty's surface-access lock. Attaching or detaching
    /// a surface — showing a pane, hiding one, switching windows — holds that
    /// same lock while it drains in-flight work, so a reader thread here can
    /// wait behind one chunk's parse, and now holds this lock while it does.
    ///
    /// Bounded and not a deadlock: the work on that queue writes into the
    /// surface and never calls back into this router, and a terminal's own
    /// output takes the `TmuxControlClient` path instead. So the worst case is
    /// one session's delivery pausing for one chunk during a pane
    /// show/hide — not the sustained stall the rule is about.
    @discardableResult
    func deliver(paneID: String, data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        deliveryCounts[paneID, default: 0] &+= 1
        if let session = sessions[paneID] {
            session.receive(data)
            return true
        }
        var pending = backlog[paneID] ?? Data()
        if pending.count < backlogLimitPerPane {
            pending.append(data)
            backlog[paneID] = pending
        }
        return false
    }

    /// Paint a `capture-pane` snapshot over a pane, but only if the pane has
    /// produced nothing since `count`.
    ///
    /// The comparison and the enqueue are one step, under the same lock
    /// `deliver` takes. Doing it as two — read the count, then hand the bytes
    /// to the session — leaves exactly the window this whole mechanism exists
    /// to close: the reader queue enqueues a live chunk in between, and the
    /// stale snapshot is queued behind it and wins.
    ///
    /// Returns false when the pane spoke, so the caller can decide whether to
    /// wait for it to fall quiet.
    func deliverSnapshot(paneID: String, data: Data, ifDeliveryCountIs count: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard deliveryCounts[paneID] ?? 0 == count, let session = sessions[paneID] else { return false }
        session.receive(data)
        return true
    }

    func isRegistered(paneID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions[paneID] != nil
    }

    /// Chunks delivered for a pane so far. Only ever compared against an
    /// earlier reading of itself — the absolute value means nothing, and it is
    /// deliberately not reset by `unregister`, so a reading taken before a
    /// surface was released still compares as "changed" afterwards rather than
    /// as "quiet".
    func deliveryCount(paneID: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return deliveryCounts[paneID] ?? 0
    }
}
