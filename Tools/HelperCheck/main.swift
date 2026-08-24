//
//  main.swift
//  HelperCheck
//
//  Cross-check for the remote helper — both halves at once. The script under
//  test is the exact `RemoteHelperScript.script` string the app ships, run
//  through a local `/bin/sh` over pipes; the client under test is the exact
//  `RemoteHelper` frame parser the app uses. sh is sh — ssh is only the pipe
//  between them, and `TransportCheck` proves the pipe delivers bytes intact.
//
//      swiftc -O -o /tmp/helpercheck \
//          Attache/Tmux/TmuxLog.swift Attache/Remote/RemoteHelperScript.swift \
//          Attache/Remote/RemoteHelper.swift Attache/Remote/PosixChecksum.swift \
//          Attache/Status/GitStatus.swift Tools/HelperCheck/main.swift
//      /tmp/helpercheck
//
//  What the cases guard, in order of what a miss costs:
//  - Byte-exactness. A transcript byte lost or invented here becomes a
//    spliced conversation; a git status byte becomes a wrong branch line.
//    Payloads are length-prefixed for exactly this, so the cases feed the
//    frames' own vocabulary (BEGIN/END/BYTES lines, NULs, invalid UTF-8)
//    through as file *content*.
//  - The STATTAIL contract `TranscriptTail` depends on: identity that
//    changes with the inode, a 64-byte overlap window, bytes never past the
//    size the STAT line named.
//  - The GITSTATUS batch shape: dedup to one root, realpath answers,
//    porcelain that `GitStatus.parse` accepts — measured here against a real
//    `git init` repository, skipped loudly when git is not installed.
//  - The third outcome. A stopped channel answers `unavailable`, never
//    `absent` — the difference between "no data" and "could not ask" is the
//    honesty rule the whole remote design hangs on.
//  - The launch that fails. `spawn` retries forever, so anything it holds on
//    to on the way out is held once per attempt, at a floor of one attempt
//    per thirty seconds. Counted in descriptors, because descriptors are what
//    ran out.
//

import Foundation

nonisolated(unsafe) var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("  ok \(name)")
    } else {
        failures += 1
        print("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

/// Pump the main queue until `body`'s completion fires. The helper delivers
/// on the main queue; a command-line check has to turn the crank itself.
func wait<T>(_ body: (@escaping (T) -> Void) -> Void) -> T {
    nonisolated(unsafe) var result: T?
    body { value in result = value }
    let deadline = Date(timeIntervalSinceNow: 20)
    while result == nil, Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
    guard let result else {
        print("FAIL timed out waiting for a helper answer")
        exit(1)
    }
    return result
}

let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("helpercheck-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: workDir)
try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

// MARK: - The script's own promises

check("script carries no single quote", !RemoteHelperScript.script.contains("'"))
check("script survives Swift's indent stripping where sh needs column zero",
      RemoteHelperScript.script.contains("roots=\"$roots\n$r\"")
          && RemoteHelperScript.script.contains("IFS=\"\n\""))

// MARK: - Channel up, ping, pipelining

let helper = RemoteHelper(label: "check") { ["/bin/sh", "-c", RemoteHelperScript.script] }
helper.start()

do {
    // Three reads issued back to back before any answer: the FIFO tags have
    // to keep them straight.
    let trap = workDir.appendingPathComponent("trap.bin")
    let evil = Data("END t9 0\nBEGIN t9\nBYTES 3\n".utf8) + Data([0, 255, 128]) + Data("fin\n".utf8)
    try! evil.write(to: trap)
    let first: HelperOutcome<Data> = wait { done in
        helper.read(path: trap.path, maxBytes: 999_999) { done($0) }
    }
    let capped: HelperOutcome<Data> = wait { done in
        helper.read(path: trap.path, maxBytes: 10) { done($0) }
    }
    let missing: HelperOutcome<Data> = wait { done in
        helper.read(path: trap.path + ".missing", maxBytes: 10) { done($0) }
    }
    if case .answered(let data) = first {
        check("read returns exact bytes through frame-shaped content", data == evil)
    } else { check("read returns exact bytes through frame-shaped content", false) }
    if case .answered(let data) = capped {
        check("read caps at maxBytes", data == evil.prefix(10))
    } else { check("read caps at maxBytes", false) }
    if case .absent = missing {
        check("read of a missing file is absent, status told apart from bytes", true)
    } else { check("read of a missing file is absent, status told apart from bytes", false) }
    check("channel reports up after HELLO", helper.isUp)
}

// MARK: - STATTAIL: the TranscriptTail contract

do {
    let log = workDir.appendingPathComponent("transcript.jsonl")
    try! Data(repeating: UInt8(ascii: "A"), count: 100).write(to: log)

    let full: HelperOutcome<RemoteStatTail> = wait { done in
        helper.statTail(path: log.path, fromOffset: 0) { done($0) }
    }
    guard case .answered(let stat0) = full else {
        check("stattail answers", false); exit(1)
    }
    check("stattail full read", stat0.size == 100 && stat0.start == 0
          && stat0.bytes == Data(repeating: UInt8(ascii: "A"), count: 100))

    // Multi-byte UTF-8 appended across the offset: the overlap window must
    // come back byte-exact, no text decoding anywhere in the path.
    let appended = "汉字tail".data(using: .utf8)!
    let handle = try! FileHandle(forWritingTo: log)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: appended)
    try! handle.close()

    let tail: HelperOutcome<RemoteStatTail> = wait { done in
        helper.statTail(path: log.path, fromOffset: 100) { done($0) }
    }
    guard case .answered(let stat1) = tail else {
        check("stattail overlap answers", false); exit(1)
    }
    check("stattail backs up 64 bytes for the fingerprint window",
          stat1.start == 36
              && stat1.bytes == Data(repeating: UInt8(ascii: "A"), count: 64) + appended)
    check("stattail identity is stable while the file is the same one",
          stat1.device == stat0.device && stat1.inode == stat0.inode)

    // Atomic replace — the `mv` over the file that `tail -F` streams through
    // with no marker at all. The inode is the only witness.
    let replacement = workDir.appendingPathComponent("replacement")
    try! Data("rewritten".utf8).write(to: replacement)
    rename(replacement.path, log.path)
    let replaced: HelperOutcome<RemoteStatTail> = wait { done in
        helper.statTail(path: log.path, fromOffset: 0) { done($0) }
    }
    if case .answered(let stat2) = replaced {
        check("stattail sees the inode change on atomic replace", stat2.inode != stat1.inode)
    } else { check("stattail sees the inode change on atomic replace", false) }

    let gone: HelperOutcome<RemoteStatTail> = wait { done in
        helper.statTail(path: log.path + ".gone", fromOffset: 0) { done($0) }
    }
    if case .absent = gone {
        check("stattail of a missing file is absent", true)
    } else { check("stattail of a missing file is absent", false) }
}

// MARK: - CLASSIFY

do {
    let spaced = workDir.appendingPathComponent("re po")
    try! FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
    let file = spaced.appendingPathComponent("a.txt")
    try! Data("x".utf8).write(to: file)

    let kinds: HelperOutcome<[RemoteFileKind]> = wait { done in
        helper.classify(paths: [
            spaced.path,
            file.path,
            spaced.path + " && xcodebuild -project",
            "/definitely/not/there",
        ]) { done($0) }
    }
    if case .answered(let answer) = kinds {
        check("classify answers in order through spaces and shell metatext",
              answer == [.directory, .file, .missing, .missing])
    } else { check("classify answers in order through spaces and shell metatext", false) }
}

// MARK: - PROBE

do {
    let hit: HelperOutcome<String> = wait { done in helper.probe(program: "sh") { done($0) } }
    if case .answered(let path) = hit {
        check("probe finds sh", path.hasSuffix("/sh"))
    } else { check("probe finds sh", false) }
    let miss: HelperOutcome<String> = wait { done in
        helper.probe(program: "definitely-not-a-command-xyz") { done($0) }
    }
    if case .absent = miss {
        check("probe miss is absent", true)
    } else { check("probe miss is absent", false) }
}

// MARK: - HOME

do {
    let home: HelperOutcome<String> = wait { done in helper.home { done($0) } }
    if case .answered(let path) = home {
        check("home answers this machine's HOME", path == NSHomeDirectory())
    } else { check("home answers this machine's HOME", false) }
}

// MARK: - Git: batch status, dedup, fingerprints — against a real repository

let git = ["/usr/bin/git", "/opt/homebrew/bin/git"].first {
    FileManager.default.isExecutableFile(atPath: $0)
}
if let git {
    func run(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try! process.run()
        process.waitUntilExit()
    }
    let repo = workDir.appendingPathComponent("repo dir")
    let sub = repo.appendingPathComponent("sub")
    try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    run(["init", "-q", repo.path])
    try! Data("x".utf8).write(to: repo.appendingPathComponent("a.txt"))
    run(["-C", repo.path, "add", "a.txt"])

    let batch: HelperOutcome<RemoteGitStatusBatch> = wait { done in
        helper.gitStatus(paths: [repo.path, sub.path, repo.path, workDir.path]) { done($0) }
    }
    if case .answered(let answer) = batch {
        check("gitstatus dedups three paths in one repo to one root",
              answer.rootIndexByPath == [0, 0, 0, nil] && answer.roots.count == 1)
        // Compared with both sides canonicalised the same way, because the
        // two canonical forms disagree on purpose: git answers realpath(3)
        // (`/private/var/…`) while Foundation's resolvingSymlinksInPath
        // strips `/private` back off. What matters is that they name the
        // same file — and that callers treat the helper's form as the key.
        let rootURL = URL(fileURLWithPath: answer.roots.first?.path ?? "/")
            .resolvingSymlinksInPath()
        check("gitstatus root is git's realpath answer",
              rootURL == URL(fileURLWithPath: repo.path).resolvingSymlinksInPath(),
              "got \(answer.roots.first?.path ?? "nil")")
        check("gitstatus FETCH_HEAD absent reads as no epoch",
              answer.roots.first?.fetchedEpoch == nil)
        if let porcelain = answer.roots.first?.porcelain {
            let summary = GitStatus.parse(
                porcelainV2: String(decoding: porcelain, as: UTF8.self),
                readAt: Date(), lastFetch: nil
            )
            check("helper porcelain parses through the same GitStatus.parse the rail uses",
                  summary.staged == 1, "staged \(summary.staged)")
        }
    } else {
        check("gitstatus answers", false)
    }

    // FETCH_HEAD with a real mtime → an epoch in the reply.
    let fetchHead = repo.appendingPathComponent(".git/FETCH_HEAD")
    try! Data().write(to: fetchHead)
    let refreshed: HelperOutcome<RemoteGitStatusBatch> = wait { done in
        helper.gitStatus(paths: [repo.path]) { done($0) }
    }
    if case .answered(let answer) = refreshed {
        check("gitstatus reports FETCH_HEAD's epoch once one exists",
              answer.roots.first?.fetchedEpoch ?? 0 > 1_500_000_000)
    } else { check("gitstatus reports FETCH_HEAD's epoch once one exists", false) }

    // Fingerprints: same until the index moves, different after.
    let first: HelperOutcome<[String]> = wait { done in
        helper.gitCheck(roots: [repo.path, workDir.path]) { done($0) }
    }
    guard case .answered(let prints) = first, prints.count == 2 else {
        print("FAIL gitcheck shape"); exit(1)
    }
    check("gitcheck answers a fingerprint and a dash", prints[0] != "-" && prints[1] == "-")
    try! Data("y".utf8).write(to: repo.appendingPathComponent("b.txt"))
    run(["-C", repo.path, "add", "b.txt"])
    let second: HelperOutcome<[String]> = wait { done in
        helper.gitCheck(roots: [repo.path]) { done($0) }
    }
    if case .answered(let after) = second {
        check("gitcheck fingerprint moves when the index does", after[0] != prints[0])
    } else { check("gitcheck fingerprint moves when the index does", false) }

    // Measured on git 2.50.1: no remote at all is a clean nothing-to-do
    // (exit 0); a remote that cannot be reached is a refusal (exit 128).
    // Both must come back as a status — never a hang, never a prompt — and
    // the environment guards are what keep a credentialed remote from
    // prompting, which over a control channel would corrupt the protocol.
    let idle: HelperOutcome<Void> = wait { done in
        helper.gitFetch(root: repo.path) { done($0) }
    }
    if case .answered = idle {
        check("gitfetch with no remote is a clean nothing-to-do", true)
    } else { check("gitfetch with no remote is a clean nothing-to-do", false) }
    run(["-C", repo.path, "remote", "add", "origin", "/nonexistent/repo"])
    let refused: HelperOutcome<Void> = wait { done in
        helper.gitFetch(root: repo.path) { done($0) }
    }
    if case .absent = refused {
        check("gitfetch against an unreachable remote refuses cleanly", true)
    } else { check("gitfetch against an unreachable remote refuses cleanly", false) }
} else {
    print("  -- git not installed; the GITSTATUS/GITCHECK/GITFETCH cases were NOT run --")
    failures += 1
}

// MARK: - Status 3: could not execute is not could not find

do {
    let locked = workDir.appendingPathComponent("locked.bin")
    try! Data("secret".utf8).write(to: locked)
    try! FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    let read: HelperOutcome<Data> = wait { done in
        helper.read(path: locked.path, maxBytes: 100) { done($0) }
    }
    if case .unavailable = read {
        check("an unreadable file reads as could-not-ask, never absent", true)
    } else {
        check("an unreadable file reads as could-not-ask, never absent", false,
              "got \(read)")
    }
    let tail: HelperOutcome<RemoteStatTail> = wait { done in
        helper.statTail(path: locked.path, fromOffset: 0) { done($0) }
    }
    if case .unavailable = tail {
        check("an unreadable stattail is could-not-ask too", true)
    } else {
        check("an unreadable stattail is could-not-ask too", false)
    }
    try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path)
}

do {
    // A helper whose PATH holds no git at all: the git verbs must answer
    // "could not execute here", never "not a repository" — which the service
    // would cache and stop asking about.
    let gitless = RemoteHelper(label: "gitless") {
        ["/usr/bin/env", "PATH=/var/empty", "/bin/sh", "-c", RemoteHelperScript.script]
    }
    gitless.start()
    let batch: HelperOutcome<RemoteGitStatusBatch> = wait { done in
        gitless.gitStatus(paths: [workDir.path]) { done($0) }
    }
    if case .unavailable = batch {
        check("gitstatus with no git is could-not-ask, never not-a-repository", true)
    } else {
        check("gitstatus with no git is could-not-ask, never not-a-repository", false,
              "got \(batch)")
    }
    gitless.stop()
}

// MARK: - The checksum both sides of the settings write compare

do {
    // The remote write exec recomputes `cksum` over the target and compares
    // it with the token this side computed from the read bytes — legal only
    // if the two implementations agree byte for byte, which POSIX promises
    // and this measures, against the system binary, on data with every
    // byte value in it.
    var bytes = Data((0 ..< 4096).map { _ in UInt8.random(in: 0 ... 255) })
    bytes.append(Data("edge\u{01}case".utf8))
    for sample in [Data(), Data("x".utf8), bytes] {
        let mine = PosixChecksum.token(for: sample)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/cksum")
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try! process.run()
        stdin.fileHandleForWriting.write(sample)
        try! stdin.fileHandleForWriting.close()
        let out = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
        process.waitUntilExit()
        check("cksum token matches the system binary for \(sample.count) bytes",
              mine == out, "mine \(mine) theirs \(out)")
    }
}

// MARK: - The third outcome

helper.stop()
do {
    let down: HelperOutcome<Data> = wait { done in
        helper.read(path: "/etc/hosts", maxBytes: 10) { done($0) }
    }
    if case .unavailable = down {
        check("a stopped channel answers unavailable, never absent", true)
    } else {
        check("a stopped channel answers unavailable, never absent", false)
    }
}

// MARK: - A launch that fails must not hold anything

// The path this guards has no EOF in it, which is what made it survive the
// repair that gave every reader a self-clear: when `run()` throws, no child
// ever existed to close the write ends, so a reader installed before the
// launch never fires and never clears itself. The stdout closure captured
// `child` strongly, and `process` is still nil on that path, so nothing was
// left to break `child` -> `Pipe` -> `FileHandle` -> handler -> `child`.
// Every retry then leaked a `Process` and six descriptors.
//
// Counted rather than reasoned about: descriptor exhaustion is the failure,
// so the assertion is on the descriptor count. It is also the one measurement
// that stays true if the retain graph is rearranged again.

func openDescriptors() -> Int {
    var count = 0
    for fd in 0..<Int32(getdtablesize()) where fcntl(fd, F_GETFD) != -1 {
        count += 1
    }
    return count
}

do {
    let doomed = RemoteHelper(label: "nolaunch") {
        ["/nonexistent/attache-helper-check-should-not-exist", "-x"]
    }

    // One cycle first, uncounted: the queue, the log and Foundation's own
    // lazy state all allocate once, and that is not the leak under test.
    doomed.start()
    doomed.stop()
    _ = doomed.isUp                       // `queue.sync` — drains the queue

    let before = openDescriptors()
    let rounds = 20
    for _ in 0..<rounds {
        doomed.start()                    // start() spawns immediately
        doomed.stop()                     // and stop() tears the attempt down
    }
    _ = doomed.isUp
    let after = openDescriptors()
    let leaked = after - before

    // Six per attempt is what the defect cost — three pipes, two ends each.
    // The margin is deliberately loose: a couple of descriptors of ordinary
    // churn is not this bug, and 120 is not ordinary churn.
    check(
        "a launch that fails leaks no descriptors",
        leaked < rounds,
        "\(leaked) descriptors held after \(rounds) failed launches"
            + " (\(String(format: "%.1f", Double(leaked) / Double(rounds))) per attempt;"
            + " the defect this guards cost 6)"
    )
    check(
        "and the channel still reports itself down, not up",
        !doomed.isUp
    )
}

// MARK: - Verdict

if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("all helper checks passed")
