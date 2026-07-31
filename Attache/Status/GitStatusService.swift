//
//  GitStatusService.swift
//  Attache
//

import Foundation

/// Keeps a `GitSummary` for every repository the rail is currently showing,
/// and decides when to go and look again.
///
/// The scheduling is the whole file, and it exists because of one measurement:
/// a `git status` read costs **~82ms**, of which only ~15ms is git. The rest is
/// spawning a process. Fifteen repositories read in a row took **1.29s**
/// (measured 2026-07-28). So a rail that refreshed everything on a short timer
/// would spend a visible fraction of a core doing nothing anyone asked for, on
/// a laptop, forever.
///
/// Four rules follow from that number:
///
/// - **Only what is on screen.** `setVisibleRoots` is the whole work list.
///   A session whose list is collapsed contributes nothing.
/// - **Change-driven, not clock-driven.** One `DispatchSource` per repository
///   watching its `.git`, so a commit, a branch switch, a stage or a fetch
///   reports itself. The clock is only a backstop for working-tree edits,
///   which `.git` does not see.
/// - **Concurrent, because the cost is spawn latency and not CPU.** Four at a
///   time turns 1.29s of wall clock into roughly a third of that. Serial was
///   the first design and it is wrong for work that is almost entirely waiting.
/// - **Slow repositories punish themselves, not the rail.** A read over 250ms
///   gets its backstop interval multiplied, once, with a line in the log.
///
/// Nothing here ever touches the main thread except `onChange`, which is
/// delivered on it because its only caller is the rail.
@MainActor
final class GitStatusService {
    /// Called when any visible repository's summary changed. The rail rebuilds
    /// from `summary(forPath:)`; nothing is handed over, because a rebuild
    /// reads every row anyway.
    var onChange: (() -> Void)?

    /// How long after a filesystem event to actually look. Long enough that a
    /// `git checkout` writing hundreds of files is one read rather than
    /// hundreds, short enough that it still feels immediate.
    private static let debounce: TimeInterval = 0.75
    /// The backstop, for working-tree edits that never touch `.git`.
    private static let backstop: TimeInterval = 30
    /// Past this, a repository is treated as expensive and backed off.
    private static let slowRead: TimeInterval = 0.25
    private static let concurrency = 4

    /// Cached `pane_current_path` → repository root. The mapping never changes
    /// for a given path, and resolving it costs its own `git` process — 76ms
    /// measured — so it is asked exactly once. `nil` means "asked, and this
    /// path is not in a repository", which is a real answer worth caching:
    /// a home directory would otherwise be re-tested forever.
    private var rootByPath = [String: String?]()
    /// Paths whose root is being looked up right now.
    ///
    /// A dictionary of optionals has two states per key and this needs three:
    /// unknown, being asked, and answered-with-nothing. Without the third, a
    /// path shows its directory ("not a repository") for the ~76ms the lookup
    /// takes and then flips to a branch name — a visible flicker on every row
    /// of the rail at launch.
    private var resolving = Set<String>()

    private var summaryByRoot = [String: GitSummary]()
    /// Roots whose read is in flight, so a burst of events is one read.
    private var reading = Set<String>()
    /// Roots asked to refresh while a read was in flight.
    private var againAfter = Set<String>()
    /// When each root's last read finished, so the events that read caused can
    /// be told from somebody else's.
    ///
    /// Running `git status` inside a repository writes inside its own `.git`,
    /// and this service watches exactly that directory — so every read wakes
    /// its own watcher, which schedules another read. Measured: 5 plain runs
    /// produced 14 filesystem events, and 4 even with `--no-optional-locks`.
    /// The git flags reduce it; only this closes it.
    ///
    /// The cost is a blind spot: a real change landing inside the quiet window
    /// is not seen until the backstop comes round. That is the right way to be
    /// wrong — late by up to `backstop`, rather than spinning `git` forever.
    private var lastReadFinished = [String: Date]()
    private static let quietAfterRead: TimeInterval = 1.5

    private var watchers = [String: DispatchSourceFileSystemObject]()
    private var debounceWork = [String: DispatchWorkItem]()
    /// Backstop multiplier for repositories that read slowly. 1 for everything
    /// until proven otherwise.
    private var slowFactor = [String: Int]()

    private var visibleRoots = Set<String>()
    private var backstopTimer: Timer?
    private var fetchTimer: Timer?
    /// Roots whose last fetch failed. Not retried for the rest of the run.
    ///
    /// The common cause is credentials: a private remote over HTTPS with
    /// nothing cached, or an SSH key behind a passphrase. `GitStatus.run`
    /// forces every prompt off so the attempt fails instead of hanging, and
    /// retrying it every ten minutes would be a connection to a host that has
    /// already said no, forever, for a `↓` nobody is looking at.
    private var fetchRefused = Set<String>()
    private var fetching = Set<String>()
    /// Suspended while nobody can see the rail. There is no point reading a
    /// repository to draw it into a window that is not on screen.
    private var isPaused = false

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = GitStatusService.concurrency
        queue.qualityOfService = .utility
        return queue
    }()

    // MARK: - What the rail asks

    /// The summary to draw for a pane sitting in `path`, if one has been read.
    ///
    /// Never blocks and never starts a read: a row draws what is known and the
    /// scheduler decides when that changes. A path whose root has not been
    /// resolved yet returns nil, and the row's second line stays blank rather
    /// than showing a placeholder that would flicker on every rebuild.
    func summary(forPath path: String) -> GitSummary? {
        guard let root = rootByPath[path] ?? nil else { return nil }
        return summaryByRoot[root]
    }

    /// Whether this repository's `behind` count is actually being kept current.
    ///
    /// Not the same question as "is the setting on". A repository whose fetch
    /// was refused — a private remote with no cached credentials is the usual
    /// way — is exactly as stale as one with the setting off, and a tooltip
    /// that read the setting alone would say "nothing to pull" about a remote
    /// it has never once reached. That is a worse answer than the honest
    /// "unknown" it would otherwise have given.
    func fetchIsLive(forPath path: String) -> Bool {
        guard AppSettings.gitAutoFetch, let root = rootByPath[path] ?? nil else { return false }
        return !fetchRefused.contains(root)
    }

    /// True once a path has been looked at and found not to be in a repository,
    /// so the row can say so instead of staying blank forever.
    func isKnownNotARepository(path: String) -> Bool {
        guard !resolving.contains(path), let cached = rootByPath[path] else { return false }
        return cached == nil
    }

    /// The paths the rail is currently drawing, in any session.
    ///
    /// Idempotent and cheap to call on every rebuild, which is what the rail
    /// does: it diffs internally and only reacts to what actually changed.
    func setVisiblePaths(_ paths: Set<String>) {
        var unresolved = [String]()
        for path in paths where !rootByPath.keys.contains(path) {
            unresolved.append(path)
        }
        if !unresolved.isEmpty { resolveRoots(for: unresolved) }

        let roots = Set(paths.compactMap { rootByPath[$0] ?? nil })
        guard roots != visibleRoots else { return }

        for gone in visibleRoots.subtracting(roots) { stopWatching(gone) }
        for fresh in roots.subtracting(visibleRoots) {
            startWatching(fresh)
            refresh(root: fresh)
        }
        visibleRoots = roots
        ensureBackstop()
    }

    /// Stop everything while the window is not visible, and pick straight back
    /// up when it is. Called from the window's occlusion state.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            backstopTimer?.invalidate()
            backstopTimer = nil
        } else {
            ensureBackstop()
            // Everything on screen is now of unknown age, so read it once
            // rather than waiting out a backstop interval.
            for root in visibleRoots { refresh(root: root) }
        }
    }

    // MARK: - Resolving

    /// Turn paths into repository roots, off the main thread.
    ///
    /// Batched because the answer for one path says nothing about another, and
    /// each costs a process. The results land back on the main actor, which is
    /// the only place `rootByPath` is touched.
    private func resolveRoots(for paths: [String]) {
        for path in paths {
            // `updateValue`, never `rootByPath[path] = nil`. The value type is
            // itself optional, and assigning nil through the subscript *removes
            // the key* rather than storing a nil against it — so the claim
            // below would not stick, every rebuild would queue the same lookup
            // again, and "asked, and this is not a repository" could never be
            // recorded at all.
            rootByPath.updateValue(nil, forKey: path)
            resolving.insert(path)
            queue.addOperation { [weak self] in
                let root = GitStatus.repositoryRoot(containing: path)
                Task { @MainActor in
                    guard let self else { return }
                    self.rootByPath.updateValue(root, forKey: path)
                    self.resolving.remove(path)
                    guard let root else {
                        // Now answerable, and the answer changes what the row
                        // draws — from blank to the directory it is sitting in.
                        self.onChange?()
                        return
                    }
                    if self.visibleRoots.insert(root).inserted {
                        self.startWatching(root)
                    }
                    self.refresh(root: root)
                }
            }
        }
    }

    // MARK: - Reading

    /// Read a repository, unless one is already in flight for it.
    private func refresh(root: String) {
        guard !isPaused else { return }
        guard !reading.contains(root) else {
            // Something changed while we were reading, so the read now
            // finishing describes a state that is already stale. Remember to go
            // again rather than dropping it.
            againAfter.insert(root)
            return
        }
        reading.insert(root)

        queue.addOperation { [weak self] in
            let started = Date()
            let result = Result { try GitStatus.read(root: root) }
            let elapsed = Date().timeIntervalSince(started)

            Task { @MainActor in
                guard let self else { return }
                self.reading.remove(root)
                self.lastReadFinished[root] = Date()
                self.noteReadCost(elapsed, root: root)

                switch result {
                case .success(let summary):
                    if self.summaryByRoot[root] != summary {
                        // Once per repository per run, on the read that first
                        // produces an answer. Not tidiness: a row drawing
                        // nothing looks the same whether the repository is
                        // clean, the read failed, or the path never resolved,
                        // and this is the only place those come apart.
                        if self.summaryByRoot[root] == nil {
                            TmuxLog.lifecycle(
                                "git: \(root) — \(summary.displayRef),"
                                    + " +\(summary.staged) ~\(summary.modified)"
                                    + " ?\(summary.untracked)"
                                    + (summary.hasUpstream
                                        ? " ↑\(summary.ahead) ↓\(summary.behind)"
                                        : " (no upstream)")
                                    + " in \(Int(elapsed * 1000))ms"
                            )
                        }
                        self.summaryByRoot[root] = summary
                        self.onChange?()
                    }
                case .failure:
                    // A repository that stopped being one — deleted, or a
                    // worktree removed. Drop it rather than keeping the last
                    // good answer on screen, which would be a row describing
                    // something that no longer exists.
                    if self.summaryByRoot.removeValue(forKey: root) != nil {
                        self.onChange?()
                    }
                }

                if self.againAfter.remove(root) != nil { self.refresh(root: root) }
            }
        }
    }

    private func noteReadCost(_ elapsed: TimeInterval, root: String) {
        guard elapsed > Self.slowRead, slowFactor[root] == nil else { return }
        // Logged once per repository per run. A monorepo is not a defect and
        // this is not a warning — it is the reason its row updates less often,
        // recorded where someone wondering can find it.
        slowFactor[root] = 4
        TmuxLog.lifecycle(
            "git status took \(Int(elapsed * 1000))ms in \(root) —"
                + " backing its refresh off to \(Int(Self.backstop) * 4)s"
        )
    }

    // MARK: - Watching

    /// Watch a repository's `.git` for the changes that do not touch the
    /// working tree: commit, branch switch, stage, fetch, rebase.
    ///
    /// `.git` and not the work tree. Watching the root recursively would mean
    /// an event for every file a build writes — `node_modules`, `DerivedData`,
    /// a webpack rebuild — and at 82ms a read that is a fan the user can hear.
    /// The cost of the narrower watch is that a plain edit to a tracked file is
    /// seen by the backstop rather than immediately, which is the right trade:
    /// the numbers that change on an edit are the least urgent thing on the row.
    private func startWatching(_ root: String) {
        guard watchers[root] == nil else { return }
        let path = URL(fileURLWithPath: root).appendingPathComponent(".git").path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleDebounced(root) }
        }
        // The descriptor belongs to the source, and closing it anywhere else is
        // a use-after-close the moment an event is already in flight.
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers[root] = source
    }

    private func stopWatching(_ root: String) {
        watchers.removeValue(forKey: root)?.cancel()
        debounceWork.removeValue(forKey: root)?.cancel()
    }

    private func scheduleDebounced(_ root: String) {
        // Ours, almost certainly. See `lastReadFinished`.
        if reading.contains(root) { return }
        if let finished = lastReadFinished[root],
           Date().timeIntervalSince(finished) < Self.quietAfterRead { return }

        debounceWork[root]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.debounceWork[root] = nil
                self?.refresh(root: root)
            }
        }
        debounceWork[root] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    // MARK: - Backstop

    private func ensureBackstop() {
        guard !isPaused, !visibleRoots.isEmpty else { return }
        guard backstopTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.backstop, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.runBackstop() }
        }
        // The rail keeps updating while a menu is open or a divider is being
        // dragged; a timer in the default mode alone stops dead during both.
        RunLoop.main.add(timer, forMode: .common)
        backstopTimer = timer
    }

    // MARK: - Fetching

    /// Start, stop, or re-time the background fetch to match the settings.
    /// Called on launch and whenever the settings change, so turning the switch
    /// off stops the next connection rather than the one after it.
    func applySettings() {
        fetchTimer?.invalidate()
        fetchTimer = nil
        guard AppSettings.gitAutoFetch else { return }
        let interval = TimeInterval(AppSettings.gitAutoFetchMinutes * 60)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.runFetch() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fetchTimer = timer
        // Once now as well: a user who just turned this on is asking about the
        // repositories in front of them, not about the ones in ten minutes.
        runFetch()
    }

    private func runFetch() {
        guard !isPaused, AppSettings.gitAutoFetch else { return }
        for root in visibleRoots
            where !fetchRefused.contains(root) && !fetching.contains(root)
        {
            fetching.insert(root)
            queue.addOperation { [weak self] in
                let result = Result { try GitStatus.fetch(root: root) }
                Task { @MainActor in
                    guard let self else { return }
                    self.fetching.remove(root)
                    switch result {
                    case .success:
                        // The refs moved, so the ahead/behind pair did too.
                        self.refresh(root: root)
                    case .failure:
                        self.fetchRefused.insert(root)
                        TmuxLog.lifecycle(
                            "git fetch refused in \(root) — not asking again this run"
                        )
                    }
                }
            }
        }
    }

    private var backstopTicks = 0

    private func runBackstop() {
        backstopTicks += 1
        for root in visibleRoots {
            // A repository marked slow is read every fourth tick instead of
            // every one. Everything else has a factor of 1 and is read always.
            let factor = slowFactor[root] ?? 1
            guard backstopTicks % factor == 0 else { continue }
            refresh(root: root)
        }
    }

    deinit {
        // `watchers` cannot be touched from a non-isolated deinit, and the
        // sources hold the only reference to their descriptors — so they are
        // cancelled by the process ending, which is the only way this object
        // ever goes away. Recorded rather than left as an apparent leak.
    }
}
