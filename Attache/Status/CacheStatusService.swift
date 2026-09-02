//
//  CacheStatusService.swift
//  Attache
//

import Foundation

/// One machine's prompt-cache estimates: reads transcript tails, remembers
/// what they said, and tells the rail when a chip would draw differently.
///
/// Reads are off the main thread and memoised by (path, file size), the way
/// the reference tooling does it — transcripts reach 112 MB and the tail
/// window is all that is ever needed. A minute tick fires `onChange` so a
/// warm countdown crosses its minute buckets and flips to cold on time even
/// when the file itself is idle — which is exactly when it matters, because
/// an idle transcript is a cache quietly running out.
@MainActor
final class CacheStatusService {
    var onChange: (() -> Void)?

    /// nil reads the local disk; a helper reads the remote one over the
    /// channel every other remote feature already uses.
    private let helper: RemoteHelper?
    /// How long a memo answers before the file is looked at again. Remote
    /// looks are a round trip, so they run at half the cadence.
    private let refreshInterval: TimeInterval

    private struct Entry {
        var size: UInt64
        var estimate: PromptCacheEstimate
        var fetchedAt: Date
    }

    private var entries = [String: Entry]()
    private var inFlight = Set<String>()

    /// The wrapper-less fallback's answers, per working directory. `path`
    /// nil is a real answer — "no unambiguous session there" — and is cached
    /// like any other so an ambiguous directory is not re-scanned on every
    /// rail rebuild.
    private struct Discovery {
        var path: String?
        var scannedAt: Date
    }

    private var discoveries = [String: Discovery]()
    private var scanning = Set<String>()

    private var tick: Timer?
    private var paused = false

    init() {
        helper = nil
        refreshInterval = 20
    }

    init(helper: RemoteHelper) {
        self.helper = helper
        refreshInterval = 45
    }

    func stop() {
        tick?.invalidate()
        tick = nil
        onChange = nil
    }

    /// Same contract as the git service's pause: a hidden window keeps its
    /// numbers, it just stops paying for them.
    func setPaused(_ value: Bool) {
        paused = value
    }

    /// The memoised estimate, refreshing behind the answer when it is stale.
    func estimate(forTranscript path: String) -> PromptCacheEstimate? {
        refreshIfStale(path)
        startTickIfNeeded()
        return entries[path]?.estimate
    }

    /// The transcript a pane's working directory points at when nothing
    /// publishes the real path — local machines only, because it walks
    /// `~/.claude/projects` on this machine's disk. nil while unknown, and
    /// nil for a directory whose sessions are ambiguous: two agents in one
    /// repository with nothing installed cannot be told apart from out
    /// here, and a wrong attribution would hang another session's dollars
    /// on this row.
    func transcriptPath(forWorkingDirectory cwd: String) -> String? {
        guard helper == nil, !cwd.isEmpty else { return nil }
        scanIfStale(cwd)
        return discoveries[cwd]?.path
    }

    // MARK: - Refresh

    private func refreshIfStale(_ path: String) {
        guard !paused, !inFlight.contains(path) else { return }
        if let entry = entries[path], Date().timeIntervalSince(entry.fetchedAt) < refreshInterval {
            return
        }
        inFlight.insert(path)
        if let helper {
            refreshRemote(path, helper: helper)
        } else {
            refreshLocal(path)
        }
    }

    private func refreshLocal(_ path: String) {
        let known = entries[path]?.size
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let read = Self.readLocalTail(path: path, knownSize: known)
            DispatchQueue.main.async { self?.finish(path: path, read: read) }
        }
    }

    /// (size, estimate?) — estimate nil means "unchanged, keep what you
    /// have" when the size matches, or "nothing usable" when it does not.
    private nonisolated static func readLocalTail(
        path: String, knownSize: UInt64?
    ) -> (size: UInt64, estimate: PromptCacheEstimate?, unchanged: Bool) {
        guard let handle = FileHandle(forReadingAtPath: path),
              let size = try? handle.seekToEnd()
        else { return (0, nil, false) }
        defer { try? handle.close() }
        if let knownSize, knownSize == size { return (size, nil, true) }
        let window = UInt64(PromptCacheEstimator.tailWindowBytes)
        let offset = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let tail = try? handle.read(upToCount: Int(size - offset))
        else { return (size, nil, false) }
        return (size, PromptCacheEstimator.estimate(tail: tail, startsMidFile: offset > 0), false)
    }

    /// Two `STATTAIL`s: one from an offset far past any real file, which the
    /// helper answers with the stat line and zero bytes — the cheap size
    /// probe — and one from `size - window` for the tail itself. The helper
    /// rewinds 64 bytes on its own; `startsMidFile` drops the partial line
    /// either way.
    private func refreshRemote(_ path: String, helper: RemoteHelper) {
        let probe: UInt64 = 1 << 50
        helper.statTail(path: path, fromOffset: probe) { [weak self] outcome in
            guard let self else { return }
            guard case .answered(let stat) = outcome else {
                self.finish(path: path, read: (0, nil, false))
                return
            }
            if let entry = self.entries[path], entry.size == stat.size {
                self.finish(path: path, read: (stat.size, nil, true))
                return
            }
            let window = UInt64(PromptCacheEstimator.tailWindowBytes)
            let offset = stat.size > window ? stat.size - window : 0
            helper.statTail(path: path, fromOffset: offset) { [weak self] outcome in
                guard let self else { return }
                guard case .answered(let answer) = outcome else {
                    self.finish(path: path, read: (0, nil, false))
                    return
                }
                let estimate = PromptCacheEstimator.estimate(
                    tail: answer.bytes, startsMidFile: answer.start > 0
                )
                self.finish(path: path, read: (answer.size, estimate, false))
            }
        }
    }

    private func finish(
        path: String, read: (size: UInt64, estimate: PromptCacheEstimate?, unchanged: Bool)
    ) {
        inFlight.remove(path)
        let now = Date()
        if read.unchanged, var entry = entries[path] {
            entry.fetchedAt = now
            entries[path] = entry
            return
        }
        guard let estimate = read.estimate else {
            // Unreadable, gone, or nothing usable in it: forget rather than
            // keep showing numbers about a file that stopped answering.
            if entries.removeValue(forKey: path) != nil { onChange?() }
            return
        }
        let previous = entries[path]?.estimate
        entries[path] = Entry(size: read.size, estimate: estimate, fetchedAt: now)
        if previous != estimate { onChange?() }
    }

    // MARK: - Discovery (local, nothing installed)

    private func scanIfStale(_ cwd: String) {
        guard !paused, !scanning.contains(cwd) else { return }
        if let known = discoveries[cwd], Date().timeIntervalSince(known.scannedAt) < 60 {
            return
        }
        scanning.insert(cwd)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.scanProjectDirectory(forCwd: cwd)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning.remove(cwd)
                let previous = self.discoveries[cwd]?.path
                self.discoveries[cwd] = Discovery(path: result.chosen, scannedAt: Date())
                // The estimates were read to choose; keep them so the chip
                // can draw without a second pass over the same bytes.
                for (path, size, estimate) in result.estimates {
                    self.entries[path] = Entry(size: size, estimate: estimate, fetchedAt: Date())
                }
                if previous != result.chosen { self.onChange?() }
            }
        }
    }

    private nonisolated static func scanProjectDirectory(
        forCwd cwd: String
    ) -> (chosen: String?, estimates: [(String, UInt64, PromptCacheEstimate)]) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(
                TranscriptLocator.projectDirectoryName(forWorkingDirectory: cwd),
                isDirectory: true
            )
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return (nil, []) }

        // mtime is untrusted as evidence of a *request* — Claude Code
        // rewrites these files while idle — but it is fine as a shortlist;
        // the real recency below comes from each file's own last request.
        // The same rough-then-refine the reference tool uses.
        let shortlist = names
            .filter { $0.hasSuffix(".jsonl") }
            .map { directory.appendingPathComponent($0).path }
            .sorted {
                (mtime($0) ?? .distantPast) > (mtime($1) ?? .distantPast)
            }
            .prefix(8)

        var estimates = [(String, UInt64, PromptCacheEstimate)]()
        for path in shortlist {
            let read = readLocalTail(path: path, knownSize: nil)
            if let estimate = read.estimate {
                estimates.append((path, read.size, estimate))
            }
        }
        let chosen = TranscriptLocator.chooseCandidate(
            estimates.map { (path: $0.0, lastRequestAt: $0.2.lastRequestAt) },
            now: Date()
        )
        return (chosen, estimates)
    }

    private nonisolated static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: - The minute tick

    /// Fires `onChange` once a minute while anything is memoised, so the
    /// countdown's minute buckets and the warm→cold flip repaint without a
    /// file changing. The rail's rebuild signature carries the bucket, so a
    /// tick that changes nothing is a signature compare and a return.
    private func startTickIfNeeded() {
        guard tick == nil, !entries.isEmpty || !inFlight.isEmpty else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.paused else { return }
                self.onChange?()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }
}
