//
//  ConversationFileMonitor.swift
//  Attache
//

import Foundation

/// Watches one file and says when it changed.
///
/// Shared by every file-backed provider, which today is all of them, and
/// deliberately *not* part of `AgentConversationSource`: watching a file is
/// meaningless for a source that would arrive over a socket, and putting it in
/// the protocol would make every future implementation pretend to have a path.
///
/// **Both mechanisms are needed and neither is redundant.** The kqueue source
/// is what makes an ordinary append show up immediately. The poll is what
/// covers the cases kqueue reports as the end of the world: a file replaced by
/// `rename(2)` — which is how an editor and several tools write — leaves the
/// descriptor pointing at an unlinked inode that will never change again, and
/// the watcher goes quiet forever with no error anywhere. The poll notices the
/// path is a different file and re-arms. A 2-second cadence for a backstop is
/// the same interval `GitStatusService` settled on for the same kind of job.
final class ConversationFileMonitor {
    private let path: String
    private let queue: DispatchQueue
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var poll: DispatchSourceTimer?
    private var coalescing = false
    /// What the file looked like when it was last reported, so the poll can
    /// tell "nothing happened" from "replaced by a different file of the same
    /// size".
    private var stamp: FileStamp?

    private struct FileStamp: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: TimeInterval
    }

    init(path: String, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.path = path
        self.queue = queue
        self.onChange = onChange
    }

    deinit { tearDown() }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stamp = Self.stamp(ofPath: self.path)
            self.arm()
            self.startPolling()
            self.onChange()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.tearDown() }
    }

    // MARK: - kqueue

    private func arm() {
        guard source == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        descriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = self.source?.data ?? []
            // The file this descriptor names is gone as far as we are
            // concerned. Re-open by *path* — for an atomic replace that is a
            // different inode, and the descriptor we hold would never speak
            // again.
            if !mask.intersection([.delete, .rename, .revoke]).isEmpty {
                self.disarm()
                self.arm()
            }
            self.reportChange()
        }
        source.setCancelHandler { [fd] in close(fd) }
        self.source = source
        source.resume()
    }

    private func disarm() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func tearDown() {
        disarm()
        poll?.cancel()
        poll = nil
    }

    // MARK: - The backstop

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(400))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // **Re-arm on "there is no watcher", before comparing anything.**
            // `arm` fails silently when the path is momentarily absent — which
            // is exactly what a rename-away/create-back replacement looks
            // like — and the coalesced callback that follows records the *new*
            // file's stamp. The comparison below then sees nothing changed,
            // returns, and the watcher is never rebuilt: updates degrade to
            // this two-second poll for the rest of the monitor's life, with
            // nothing anywhere saying so. Found by review 2026-08-01.
            if self.source == nil { self.arm() }

            let current = Self.stamp(ofPath: self.path)
            guard current != self.stamp else { return }
            // A different inode means the path now names another file and the
            // watcher is attached to a corpse.
            if current?.inode != self.stamp?.inode {
                self.disarm()
                self.arm()
            }
            self.stamp = current
            self.reportChange()
        }
        poll = timer
        timer.resume()
    }

    /// Collapse a burst into one report.
    ///
    /// An agent writing a turn produces many appends in a few hundred
    /// milliseconds, and re-reading a 40 MB transcript once per append would
    /// spend the whole turn parsing. 150 ms is below the point a person reads
    /// as lag and above the gap between consecutive writes.
    private func reportChange() {
        guard !coalescing else { return }
        coalescing = true
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            guard let self else { return }
            self.coalescing = false
            self.stamp = Self.stamp(ofPath: self.path)
            self.onChange()
        }
    }

    private static func stamp(ofPath path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileStamp(
            inode: UInt64(info.st_ino),
            size: UInt64(info.st_size),
            modified: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }
}
