//
//  RemoteHelper.swift
//  Attache
//

import Foundation

/// What one helper request came back as. The three cases are the contract
/// every remote feature is built on: `absent` is the file system answering
/// "not there", `unavailable` is the question never reaching it — and the
/// two must never collapse, because "no data" drawn where "could not ask"
/// happened is the silent-blank dishonesty issue #5's risk list names.
nonisolated enum HelperOutcome<T> {
    case answered(T)
    case absent
    case unavailable(String)
}

/// One line of a `CLASSIFY` answer.
nonisolated enum RemoteFileKind {
    case file, directory, missing
}

/// A `STATTAIL` answer: identity, size, and the bytes from `start` to `size`.
nonisolated struct RemoteStatTail {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    /// Where `bytes` begins — the requested offset backed up by up to 64
    /// bytes, so `TranscriptTail.isContinuous` has its fingerprint window.
    let start: UInt64
    let bytes: Data
}

/// A `GITSTATUS` answer: every input path resolved, deduplicated to roots,
/// one hardened `git status --porcelain=v2` per root.
nonisolated struct RemoteGitStatusBatch {
    struct Root {
        /// As git reports it — a realpath, which may differ from any input
        /// path through a symlink. Canonical; never string-compare it back.
        let path: String
        /// FETCH_HEAD's mtime, epoch seconds, or nil when it has none.
        let fetchedEpoch: Int?
        /// nil when `git status` itself failed for this root — a state the
        /// caller must treat as could-not-ask, never as a clean repository.
        let porcelain: Data?
    }

    /// Index into `roots` per input path, nil where the path is not in a
    /// repository.
    let rootIndexByPath: [Int?]
    /// Input paths git could not answer for at all — a permission or
    /// safe.directory refusal, not a confirmed non-repository. Must never be
    /// cached as either real answer.
    let failedPathIndexes: Set<Int>
    let roots: [Root]
}

/// The client half of `RemoteHelperScript`: owns the channel process, frames
/// requests, verifies tags, and turns the wire's two statuses plus its own
/// channel state into `HelperOutcome`s.
///
/// One instance per host, restarted internally with backoff for as long as
/// `start()` has been called and `stop()` has not — the callers hold one
/// stable object and only ever learn "up" or "down". All completions arrive
/// on the main queue.
nonisolated final class RemoteHelper {
    /// Fires on the main queue whenever the channel comes up or goes down;
    /// the Bool is "up". Deduplicated — one call per actual change.
    var onStateChange: ((Bool) -> Void)?

    private let makeArgv: () -> [String]
    private let label: String
    private let queue: DispatchQueue

    // Everything below is confined to `queue`.
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var stderrTail = Data()
    private var helloSeen = false
    private var up = false
    private var shouldRun = false
    private var restartDelay: TimeInterval = 1
    private var tagCounter = 0
    private var pending: [PendingRequest] = []
    /// Set when the far side answered a HELLO this build does not speak;
    /// restarting cannot fix that, so the channel stays down with the reason.
    private var wedgedReason: String?

    private struct PendingRequest {
        let tag: String
        let completion: (Reply?) -> Void
        var headers: [String] = []
        var blobs: [Data] = []
    }

    private struct Reply {
        let status: Int
        let headers: [String]
        let blobs: [Data]
    }

    private enum Phase {
        case idle
        case collecting
        case bytes(remaining: Int)
        case byteTerminator
    }

    private var phase = Phase.idle

    /// `makeArgv` rather than an argv, so a restart re-renders the command —
    /// the script is passed as an argv word and never installed remotely.
    init(label: String, makeArgv: @escaping () -> [String]) {
        self.label = label
        self.makeArgv = makeArgv
        queue = DispatchQueue(label: "attache.helper.\(label)")
    }

    func start() {
        queue.async {
            guard !self.shouldRun else { return }
            self.shouldRun = true
            self.restartDelay = 1
            self.spawn()
        }
    }

    func stop() {
        queue.async {
            self.shouldRun = false
            self.tearDown(reason: "helper stopped")
        }
    }

    // MARK: - Requests

    func read(path: String, maxBytes: Int, completion: @escaping (HelperOutcome<Data>) -> Void) {
        request(verb: "READ \(maxBytes)", paths: [path]) { reply in
            guard let reply else { return .unavailable("channel down") }
            if let failure = Self.executionFailure(reply) { return .unavailable(failure) }
            guard reply.status == 0, let data = reply.blobs.first else { return .absent }
            return .answered(data)
        } deliver: { completion($0) }
    }

    /// Status 3: the far side could not *execute* the question — unreadable
    /// file, missing git. The one header line is its reason. Collapsing this
    /// into `absent` is how a permission failure draws as "no data".
    private static func executionFailure(_ reply: Reply) -> String? {
        guard reply.status == 3 else { return nil }
        return reply.headers.first ?? "remote execution failed"
    }

    func statTail(
        path: String, fromOffset offset: UInt64,
        completion: @escaping (HelperOutcome<RemoteStatTail>) -> Void
    ) {
        request(verb: "STATTAIL \(offset)", paths: [path]) { reply in
            guard let reply else { return .unavailable("channel down") }
            if let failure = Self.executionFailure(reply) { return .unavailable(failure) }
            guard reply.status == 0,
                  let stat = reply.headers.first(where: { $0.hasPrefix("STAT ") }),
                  let data = reply.blobs.first
            else { return .absent }
            let fields = stat.split(separator: " ").dropFirst().compactMap { UInt64($0) }
            guard fields.count == 4 else { return .unavailable("malformed STAT: \(stat)") }
            return .answered(RemoteStatTail(
                device: fields[0], inode: fields[1], size: fields[2], start: fields[3],
                bytes: data
            ))
        } deliver: { completion($0) }
    }

    func classify(
        paths: [String], completion: @escaping (HelperOutcome<[RemoteFileKind]>) -> Void
    ) {
        guard !paths.isEmpty else { return DispatchQueue.main.async { completion(.answered([])) } }
        request(verb: "CLASSIFY \(paths.count)", paths: paths) { reply in
            guard let reply else { return .unavailable("channel down") }
            let kinds = reply.headers.compactMap { line -> RemoteFileKind? in
                switch line {
                case "f": .file
                case "d": .directory
                case "-": .missing
                default: nil
                }
            }
            guard kinds.count == paths.count else {
                return .unavailable("classify answered \(kinds.count) of \(paths.count)")
            }
            return .answered(kinds)
        } deliver: { completion($0) }
    }

    /// The host's `$HOME` — the anchor every `~`-relative remote file the
    /// agent setup touches resolves against. Asked, never assumed: the local
    /// home's text on another machine is exactly the wrong-path hazard.
    func home(completion: @escaping (HelperOutcome<String>) -> Void) {
        request(verb: "HOME", paths: []) { reply in
            guard let reply else { return .unavailable("channel down") }
            guard reply.status == 0, let data = reply.blobs.first else { return .absent }
            let home = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard home.hasPrefix("/") else { return .unavailable("HOME answered \(home)") }
            return .answered(home)
        } deliver: { completion($0) }
    }

    func probe(program: String, completion: @escaping (HelperOutcome<String>) -> Void) {
        request(verb: "PROBE", paths: [program]) { reply in
            guard let reply else { return .unavailable("channel down") }
            guard reply.status == 0, let data = reply.blobs.first else { return .absent }
            return .answered(
                String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } deliver: { completion($0) }
    }

    /// One fingerprint line per root: the stat triple of `.git/HEAD`, `index`
    /// and `FETCH_HEAD` mushed into a token that changes when any of them
    /// does, or `-` for "not a repository here (any more)". Compared by the
    /// caller — the helper is stateless so a reconnect costs nothing. A `!`
    /// line means git could not answer for that root this round: skip it —
    /// do not compare, store or fire.
    func gitCheck(roots: [String], completion: @escaping (HelperOutcome<[String]>) -> Void) {
        guard !roots.isEmpty else { return DispatchQueue.main.async { completion(.answered([])) } }
        request(verb: "GITCHECK \(roots.count)", paths: roots) { reply in
            guard let reply else { return .unavailable("channel down") }
            if let failure = Self.executionFailure(reply) { return .unavailable(failure) }
            guard reply.headers.count == roots.count else {
                return .unavailable("gitcheck answered \(reply.headers.count) of \(roots.count)")
            }
            return .answered(reply.headers)
        } deliver: { completion($0) }
    }

    func gitStatus(
        paths: [String], completion: @escaping (HelperOutcome<RemoteGitStatusBatch>) -> Void
    ) {
        guard !paths.isEmpty else {
            return DispatchQueue.main.async {
                completion(.answered(RemoteGitStatusBatch(
                    rootIndexByPath: [], failedPathIndexes: [], roots: []
                )))
            }
        }
        request(verb: "GITSTATUS \(paths.count)", paths: paths) { reply in
            guard let reply else { return .unavailable("channel down") }
            if let failure = Self.executionFailure(reply) { return .unavailable(failure) }
            var indexByPath = [Int?](repeating: nil, count: paths.count)
            var failed = Set<Int>()
            var roots: [RemoteGitStatusBatch.Root] = []
            // Walked in order rather than by blob arithmetic: a root whose
            // `git status` failed contributes one blob (its path), a healthy
            // one contributes two, and only the header sequence says which.
            var blobIndex = 0
            var pendingRoot: (path: String, fetched: Int?)?
            func closeRoot(porcelain: Data?) {
                guard let open = pendingRoot else { return }
                roots.append(RemoteGitStatusBatch.Root(
                    path: open.path, fetchedEpoch: open.fetched, porcelain: porcelain
                ))
                pendingRoot = nil
            }
            for header in reply.headers {
                let words = header.split(separator: " ")
                if words.count == 3, words[0] == "PATH",
                   let position = Int(words[1]), let root = Int(words[2]),
                   position >= 0, position < paths.count
                {
                    if root == -2 { failed.insert(position) }
                    indexByPath[position] = root >= 0 ? root : nil
                } else if header == "ROOT", blobIndex < reply.blobs.count {
                    closeRoot(porcelain: nil)
                    pendingRoot = (
                        String(decoding: reply.blobs[blobIndex], as: UTF8.self), nil
                    )
                    blobIndex += 1
                } else if words.count == 2, words[0] == "FETCHED" {
                    pendingRoot?.fetched = Int(words[1])
                } else if header == "STATUS", blobIndex < reply.blobs.count {
                    closeRoot(porcelain: reply.blobs[blobIndex])
                    blobIndex += 1
                } else if header == "STATUSFAIL" {
                    closeRoot(porcelain: nil)
                }
            }
            closeRoot(porcelain: nil)
            return .answered(RemoteGitStatusBatch(
                rootIndexByPath: indexByPath, failedPathIndexes: failed, roots: roots
            ))
        } deliver: { completion($0) }
    }

    func gitFetch(root: String, completion: @escaping (HelperOutcome<Void>) -> Void) {
        request(verb: "GITFETCH", paths: [root], timeout: 120) { reply in
            guard let reply else { return .unavailable("channel down") }
            if let failure = Self.executionFailure(reply) { return .unavailable(failure) }
            return reply.status == 0 ? .answered(()) : .absent
        } deliver: { completion($0) }
    }

    // MARK: - Channel

    private func spawn() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard shouldRun, process == nil, wedgedReason == nil else { return }

        let argv = makeArgv()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: argv[0])
        child.arguments = Array(argv.dropFirst())
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr

        child.terminationHandler = { [weak self] child in
            guard let self else { return }
            self.queue.async {
                guard self.process === child else { return }
                let tail = String(decoding: self.stderrTail, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.channelFailed(
                    tail.isEmpty
                        ? "helper exited (status \(child.terminationStatus))"
                        : tail
                )
            }
        }

        do {
            try child.run()
        } catch {
            // Nothing is attached to the pipes yet, and that ordering is the
            // whole point — see the readers below.
            channelFailed("helper would not start: \(error.localizedDescription)")
            return
        }
        process = child
        stdinHandle = stdin.fileHandleForWriting

        // The readers go in *after* the launch succeeded, and `child` is held
        // weakly. Both halves are load-bearing and neither is obvious.
        //
        // `readUntilEOF` rather than `readabilityHandler` because a channel
        // that dies is the ordinary case here — the helper is stateless and
        // `channelFailed` replaces it — so a reader that kept firing after its
        // child exited accumulated one saturated core per dead channel, for the
        // life of the app. See `PipeRead.swift`.
        //
        // But that self-repair runs on EOF, and **there is no EOF when the
        // launch itself fails**: no child ever existed to close the write ends,
        // which this process is holding open through the `Pipe`s. A reader
        // installed before `run()` therefore never fires and never clears, and
        // the stdout closure strongly capturing `child` closed the loop —
        // `child` → `Pipe` → `FileHandle` → handler → `child` — with nothing
        // left to break it, because `process` is still nil on that path and so
        // `tearDown`'s `process = nil` clears nothing. `channelFailed` then
        // schedules another attempt, so a helper whose command cannot be
        // executed leaks a `Process` and six descriptors every retry, forever,
        // at a floor of one attempt per thirty seconds. It also accelerates:
        // descriptor exhaustion is itself a reason `posix_spawn` fails.
        // Found by an independent review 2026-08-23; the leak predates
        // `readUntilEOF` and was reachable through the old code the same way.
        //
        // Installing after the launch removes the window; the weak capture
        // removes the cycle even if a future edit reintroduces one. Nothing
        // is lost by reading late — bytes the child wrote in between sit in
        // the pipe buffer and the source fires on them as soon as it exists.
        // The capture may be weak because `child` is only ever used for the
        // identity test in `consume`, and a deallocated `Process` is by
        // definition not the current channel.
        stdout.fileHandleForReading.readUntilEOF { [weak self, weak child] data in
            guard let self, let child else { return }
            self.queue.async { self.consume(data, from: child) }
        }
        stderr.fileHandleForReading.readUntilEOF { [weak self] data in
            guard let self else { return }
            self.queue.async {
                self.stderrTail.append(data)
                if self.stderrTail.count > 4096 {
                    self.stderrTail.removeFirst(self.stderrTail.count - 4096)
                }
            }
        }
        buffer.removeAll()
        stderrTail.removeAll()
        helloSeen = false
        phase = .idle
        // The script itself is 4KB of the argv; log the transport half only.
        let shown = argv.prefix { !$0.contains("PROTO=") }.joined(separator: " ")
        TmuxLog.lifecycle("helper channel spawning: \(shown) <script>", session: label)
    }

    /// Every failure funnels here: fail everything in flight, tell the owner,
    /// and try again later — the helper is stateless, so a fresh channel is a
    /// full recovery.
    private func channelFailed(_ reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        tearDown(reason: reason)
        guard shouldRun, wedgedReason == nil else { return }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.spawn()
        }
    }

    private func tearDown(reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        if process != nil {
            TmuxLog.lifecycle("helper channel down: \(reason)", session: label)
        }
        let failed = pending
        pending.removeAll()
        for request in failed {
            DispatchQueue.main.async { request.completion(nil) }
        }
        if let child = process, child.isRunning { child.terminate() }
        process = nil
        stdinHandle = nil
        phase = .idle
        buffer.removeAll()
        setUp(false)
    }

    private func setUp(_ nowUp: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard up != nowUp else { return }
        up = nowUp
        let callback = onStateChange
        DispatchQueue.main.async { callback?(nowUp) }
    }

    /// True while the channel has a live, HELLO-verified process. Answered on
    /// the helper's own queue, so cheap enough to ask per request.
    var isUp: Bool {
        queue.sync { up }
    }

    /// Why the channel will not come back, when it will not. `nil` while
    /// restarting is still worth trying.
    var wedged: String? {
        queue.sync { wedgedReason }
    }

    // MARK: - Request plumbing

    private func request<T>(
        verb: String,
        paths: [String],
        timeout: TimeInterval = 15,
        parse: @escaping (Reply?) -> HelperOutcome<T>,
        deliver: @escaping (HelperOutcome<T>) -> Void
    ) {
        // A path with a newline in it would desync the whole line-oriented
        // protocol — every later request would read one path short. tmux
        // itself would have mangled such a path upstream; refusing it here
        // keeps the failure at the one request instead of the channel.
        if let bad = paths.first(where: { $0.contains("\n") }) {
            return DispatchQueue.main.async {
                deliver(.unavailable("path contains a newline: \(bad.debugDescription)"))
            }
        }
        queue.async {
            guard self.process != nil, self.stdinHandle != nil else {
                let reason = self.wedgedReason ?? "helper channel down"
                return DispatchQueue.main.async { deliver(.unavailable(reason)) }
            }
            self.tagCounter += 1
            let tag = "t\(self.tagCounter)"
            let line = "\(tag) \(verb)\n" + paths.map { $0 + "\n" }.joined()
            self.pending.append(PendingRequest(tag: tag) { reply in
                deliver(parse(reply))
            })
            do {
                try self.stdinHandle?.write(contentsOf: Data(line.utf8))
            } catch {
                self.channelFailed("helper stdin write failed: \(error.localizedDescription)")
                return
            }
            self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.pending.contains(where: { $0.tag == tag }) else { return }
                // A stuck request means a stuck *channel* — replies are FIFO,
                // so everything behind it is stuck too. Tear it all down.
                self.channelFailed("request \(tag) \(verb) timed out after \(Int(timeout))s")
            }
        }
    }

    // MARK: - Frame parsing

    private func consume(_ data: Data, from child: Process) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard process === child else { return }
        buffer.append(data)
        parseBuffer()
    }

    private func parseBuffer() {
        // `process` goes nil the moment anything fails; whatever is left in
        // the buffer then belongs to a channel that no longer exists.
        while process != nil {
            switch phase {
            case .bytes(let remaining):
                guard !buffer.isEmpty else { return }
                let take = min(remaining, buffer.count)
                if var current = pending.first {
                    current.blobs[current.blobs.count - 1].append(buffer.prefix(take))
                    pending[0] = current
                }
                buffer.removeFirst(take)
                phase = take == remaining ? .byteTerminator : .bytes(remaining: remaining - take)

            case .byteTerminator:
                guard !buffer.isEmpty else { return }
                guard buffer.first == UInt8(ascii: "\n") else {
                    channelFailed("protocol error: payload not newline-terminated")
                    return
                }
                buffer.removeFirst()
                phase = .collecting

            case .idle, .collecting:
                guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return }
                let lineData = buffer.prefix(upTo: newline)
                buffer.removeFirst(buffer.distance(from: buffer.startIndex, to: newline) + 1)
                var line = String(decoding: lineData, as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                handleLine(line)
            }
        }
    }

    private func handleLine(_ line: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard helloSeen else {
            // Anything before HELLO is banner noise from the remote shell —
            // the same tolerance the control-mode parser has for MOTD text.
            guard line.hasPrefix("HELLO ") else { return }
            let version = Int(line.dropFirst("HELLO ".count)) ?? -1
            guard version == RemoteHelperScript.protocolVersion else {
                wedgedReason = "helper protocol \(version), this build speaks"
                    + " \(RemoteHelperScript.protocolVersion) — is another build of this"
                    + " app sharing the host?"
                tearDown(reason: wedgedReason!)
                return
            }
            helloSeen = true
            restartDelay = 1
            setUp(true)
            return
        }

        switch phase {
        case .idle:
            guard let first = pending.first, line == "BEGIN \(first.tag)" else {
                channelFailed("protocol error: expected BEGIN, got \(line.debugDescription)")
                return
            }
            phase = .collecting

        case .collecting:
            guard var current = pending.first else {
                channelFailed("protocol error: frame with nothing pending")
                return
            }
            if line.hasPrefix("END \(current.tag) ") {
                let status = Int(line.split(separator: " ").last ?? "") ?? -1
                pending.removeFirst()
                phase = .idle
                let reply = Reply(status: status, headers: current.headers, blobs: current.blobs)
                DispatchQueue.main.async { current.completion(reply) }
            } else if line.hasPrefix("BYTES ") {
                guard let count = Int(line.dropFirst("BYTES ".count)), count >= 0 else {
                    channelFailed("protocol error: \(line.debugDescription)")
                    return
                }
                current.blobs.append(Data())
                pending[0] = current
                phase = count == 0 ? .byteTerminator : .bytes(remaining: count)
            } else {
                current.headers.append(line)
                pending[0] = current
            }

        case .bytes, .byteTerminator:
            // Unreachable: those phases consume raw bytes, not lines.
            channelFailed("protocol error: line in byte phase")
        }
    }
}
