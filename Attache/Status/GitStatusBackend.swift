//
//  GitStatusBackend.swift
//  Attache
//

import Foundation

/// How a path answered "which repository, if any".
enum GitRootAnswer {
    /// The canonical root — git's realpath, which through a symlink may not
    /// be a prefix of the asked path. Callers key by this and never compare
    /// it back to what they asked.
    case root(String, GitSummary?)
    case notARepository
    /// The question never reached a file system. Must not be cached as
    /// anything — least of all as "not a repository", which is the silent
    /// wrong answer issue #5's risk list names.
    case unavailable
}

/// How a known root answered a read.
enum GitReadAnswer {
    case summary(GitSummary)
    /// Was a repository, is not any more — deleted, or a worktree removed.
    /// The stale summary comes down.
    case gone
    /// Could not ask. The last summary stays up; wrong-but-recent beats
    /// blank-and-lying.
    case unavailable
}

/// The half of the Git service that touches a machine: resolving roots,
/// reading status, fetching, and noticing change. `GitStatusService` keeps
/// every scheduling decision — debounce, quiet windows, backstop, the
/// visible set — and asks one of these to actually look.
@MainActor
protocol GitStatusBackend: AnyObject {
    /// Whether a read's wall-clock says anything about the repository. The
    /// local spawn does; over ssh the time is mostly the link, and marking a
    /// remote repository "slow" for a high-RTT hop would be blaming the
    /// repository for the network.
    var measuresReadCost: Bool { get }

    func resolve(path: String, completion: @escaping @MainActor (GitRootAnswer) -> Void)
    func read(root: String, completion: @escaping @MainActor (GitReadAnswer) -> Void)
    /// False = refused. The caller stops asking for the rest of the run.
    func fetch(root: String, completion: @escaping @MainActor (Bool) -> Void)

    /// Raw change signals for one root; the service debounces them.
    func startWatching(root: String, onChange: @escaping @MainActor () -> Void)
    func stopWatching(root: String)
    func setPaused(_ paused: Bool)
}

// MARK: - Local

/// The backend this app always had: spawn `git`, watch `.git` with kqueue.
@MainActor
final class LocalGitStatusBackend: GitStatusBackend {
    let measuresReadCost = true

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        // Concurrent because the cost is spawn latency, not CPU — see the
        // measurements at the top of `GitStatusService`.
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        return queue
    }()

    private var watchers = [String: DispatchSourceFileSystemObject]()

    func resolve(path: String, completion: @escaping @MainActor (GitRootAnswer) -> Void) {
        queue.addOperation {
            let root = GitStatus.repositoryRoot(containing: path)
            Task { @MainActor in
                completion(root.map { .root($0, nil) } ?? .notARepository)
            }
        }
    }

    func read(root: String, completion: @escaping @MainActor (GitReadAnswer) -> Void) {
        queue.addOperation {
            let result = Result { try GitStatus.read(root: root) }
            Task { @MainActor in
                switch result {
                case .success(let summary): completion(.summary(summary))
                case .failure: completion(.gone)
                }
            }
        }
    }

    func fetch(root: String, completion: @escaping @MainActor (Bool) -> Void) {
        queue.addOperation {
            let result = Result { try GitStatus.fetch(root: root) }
            Task { @MainActor in
                if case .success = result { completion(true) } else { completion(false) }
            }
        }
    }

    /// Watch a repository's `.git` for the changes that do not touch the
    /// working tree: commit, branch switch, stage, fetch, rebase.
    ///
    /// `.git` and not the work tree. Watching the root recursively would mean
    /// an event for every file a build writes — `node_modules`, `DerivedData` —
    /// and at 82ms a read that is a fan the user can hear. The cost of the
    /// narrower watch is that a plain edit is seen by the backstop rather than
    /// immediately, which is the right trade.
    func startWatching(root: String, onChange: @escaping @MainActor () -> Void) {
        guard watchers[root] == nil else { return }
        let path = URL(fileURLWithPath: root).appendingPathComponent(".git").path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { Task { @MainActor in onChange() } }
        // The descriptor belongs to the source, and closing it anywhere else
        // is a use-after-close the moment an event is already in flight.
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers[root] = source
    }

    func stopWatching(root: String) {
        watchers.removeValue(forKey: root)?.cancel()
    }

    /// The kqueue sources are cheap to leave armed; the service already
    /// refuses to schedule work while paused.
    func setPaused(_: Bool) {}
}

// MARK: - Remote

/// The same questions asked of another machine, over the helper channel.
///
/// The kqueue watcher has no remote analogue, so change detection is the
/// stat triple: `.git/HEAD`, `index` and `FETCH_HEAD` fingerprinted by one
/// `GITCHECK` per second covering *every* watched root in a single round
/// trip — one stat over 45 files measured under 10ms, so this reproduces
/// kqueue's feel instead of degrading to a 30-second poll. Fingerprints are
/// compared here, not remotely: the helper is stateless so a reconnect
/// costs nothing.
@MainActor
final class RemoteGitStatusBackend: GitStatusBackend {
    let measuresReadCost = false

    private let helper: RemoteHelper
    private var onChangeByRoot = [String: @MainActor () -> Void]()
    private var fingerprints = [String: String]()
    private var pollTimer: Timer?
    private var isPaused = false
    private var checkInFlight = false

    init(helper: RemoteHelper) {
        self.helper = helper
    }

    func resolve(path: String, completion: @escaping @MainActor (GitRootAnswer) -> Void) {
        helper.gitStatus(paths: [path]) { outcome in
            switch outcome {
            case .answered(let batch):
                // git failing to answer for the path is not "not a
                // repository" — caching it as one is the silent blank the
                // three-outcomes rule forbids.
                guard !batch.failedPathIndexes.contains(0) else {
                    return completion(.unavailable)
                }
                guard let index = batch.rootIndexByPath.first ?? nil,
                      index < batch.roots.count
                else { return completion(.notARepository) }
                let root = batch.roots[index]
                completion(.root(root.path, Self.summary(from: root)))
            case .absent:
                completion(.notARepository)
            case .unavailable:
                completion(.unavailable)
            }
        }
    }

    func read(root: String, completion: @escaping @MainActor (GitReadAnswer) -> Void) {
        helper.gitStatus(paths: [root]) { outcome in
            switch outcome {
            case .answered(let batch):
                guard !batch.failedPathIndexes.contains(0) else {
                    return completion(.unavailable)
                }
                guard let index = batch.rootIndexByPath.first ?? nil,
                      index < batch.roots.count
                else { return completion(.gone) }
                guard let summary = Self.summary(from: batch.roots[index]) else {
                    // The root answered but its `git status` did not: the
                    // last summary stays up rather than a clean lie.
                    return completion(.unavailable)
                }
                completion(.summary(summary))
            case .absent:
                completion(.gone)
            case .unavailable:
                completion(.unavailable)
            }
        }
    }

    func fetch(root: String, completion: @escaping @MainActor (Bool) -> Void) {
        helper.gitFetch(root: root) { outcome in
            if case .answered = outcome { completion(true) } else { completion(false) }
        }
    }

    private static func summary(from root: RemoteGitStatusBatch.Root) -> GitSummary? {
        guard let porcelain = root.porcelain else { return nil }
        return GitStatus.parse(
            porcelainV2: String(decoding: porcelain, as: UTF8.self),
            readAt: Date(),
            lastFetch: root.fetchedEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    func startWatching(root: String, onChange: @escaping @MainActor () -> Void) {
        onChangeByRoot[root] = onChange
        ensurePolling()
    }

    func stopWatching(root: String) {
        onChangeByRoot.removeValue(forKey: root)
        fingerprints.removeValue(forKey: root)
        if onChangeByRoot.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            pollTimer?.invalidate()
            pollTimer = nil
        } else {
            ensurePolling()
        }
    }

    private func ensurePolling() {
        guard !isPaused, !onChangeByRoot.isEmpty, pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard !isPaused, !checkInFlight, !onChangeByRoot.isEmpty else { return }
        let roots = onChangeByRoot.keys.sorted()
        checkInFlight = true
        helper.gitCheck(roots: roots) { [weak self] outcome in
            guard let self else { return }
            self.checkInFlight = false
            // A down channel is not "nothing changed" — it is "cannot see".
            // The fingerprints keep their last values so recovery diffs
            // against reality, and nothing fires meanwhile.
            guard case .answered(let prints) = outcome, prints.count == roots.count
            else { return }
            for (root, print) in zip(roots, prints) {
                // `!` is git failing to answer this round — not a change, not
                // a value worth storing. Comparing against it would fire a
                // refresh on recovery for repositories that never moved.
                guard print != "!" else { continue }
                let previous = self.fingerprints[root]
                self.fingerprints[root] = print
                if let previous, previous != print {
                    self.onChangeByRoot[root]?()
                }
            }
        }
    }
}
