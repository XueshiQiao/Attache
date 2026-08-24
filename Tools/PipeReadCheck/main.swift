//
//  main.swift
//  PipeReadCheck
//
//  Cross-check for `FileHandle.readUntilEOF`, in the same spirit as
//  `Tools/RenameStringCheck`.
//
//      swiftc -O -o /tmp/pipereadcheck \
//          Attache/Tmux/PipeRead.swift Tools/PipeReadCheck/main.swift
//      /tmp/pipereadcheck
//
//  What this file protects is not a parse. It is the one line that stops a
//  pipe reader spinning after the child exits — see `PipeRead.swift` for the
//  measurement that made it necessary, and for what leaving it out cost.
//
//  So the important case here is `unfixed`, and it is deliberately not a test
//  of app code: it builds the *wrong* shape by hand and asserts that the same
//  measurement catches it. A check that only ever exercises the fixed path
//  cannot tell "the bug is gone" from "the instrument is broken", and this
//  particular bug is invisible in every other way — no error, no log line,
//  nothing on screen, just a machine that is warm.
//
//  Counting deliveries is not enough, and the first version of this file made
//  exactly that mistake: `readUntilEOF` filters the empty EOF callbacks before
//  `onData`, so "no deliveries after the child exited" stayed true even with
//  the self-clear deleted. Verified by mutation on 2026-08-23 — the line
//  removed, this check still answered "all pass". Two observations replace it,
//  and both are of the invariant rather than a proxy for it:
//
//    * the handler is read back after EOF and must be nil, which is the
//      cancellation itself — and which a handler deadlocked before the
//      assignment also fails, since it never gets there;
//    * the process's own CPU time across the settle window, which is the
//      production symptom in the units it was reported in.
//
//  Both are asserted in *both* directions: the unfixed shape must leave the
//  handler installed and must burn a core, or the instrument is broken rather
//  than the app repaired.
//
//  Unlike the pure-function checks in this directory, this one spawns real
//  children and watches a real clock. The margins are orders of magnitude
//  wide rather than tight, so scheduler noise cannot move either number near
//  the other.
//

import Foundation

var failures = 0
var cases = 0

func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    if passed { return }
    failures += 1
    let extra = detail()
    print("FAIL  \(name)\(extra.isEmpty ? "" : " — \(extra)")")
}

/// Counters a reader writes from the pipe's own queue and the checks read
/// from the main thread once the child is long gone.
final class Tally {
    private let lock = NSLock()
    private var calls = 0
    private var empties = 0
    private var bytes = Data()

    func record(_ data: Data) {
        lock.lock()
        calls += 1
        if data.isEmpty { empties += 1 }
        bytes.append(data)
        lock.unlock()
    }

    var snapshot: (calls: Int, empties: Int, bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        return (calls, empties, bytes)
    }
}

/// This process's own CPU seconds, user plus system. A spinning read source
/// runs on a dispatch worker inside *this* process, so the settle window's
/// delta is the burn — measured in the same unit the incident was reported in.
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func secs(_ tv: timeval) -> Double { Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000 }
    return secs(usage.ru_utime) + secs(usage.ru_stime)
}

/// Run `/bin/sh -c body`, read its stdout with `install`, wait for it to exit,
/// then keep watching for `settle` seconds. Everything counted in that window
/// arrived *after* the writer was gone.
struct Outcome {
    /// Deliveries to `onData` after the child exited.
    let calls: Int
    /// How many of those carried no bytes. Always 0 for `readUntilEOF`.
    let empties: Int
    /// Everything the child wrote, in order.
    let bytes: Data
    /// Whether the read source was cancelled — the invariant itself, read
    /// back off the handle after the settle window and before any cleanup.
    let cancelled: Bool
    /// CPU seconds this process burned during the settle window.
    let cpu: Double
}

/// Run `/bin/sh -c body`, read its stdout with `install`, wait for it to exit,
/// then keep watching for `settle` seconds. Everything measured in that window
/// happened *after* the writer was gone.
func afterEOF(
    body: String,
    settle: TimeInterval,
    install: (FileHandle, Tally) -> Void
) -> Outcome {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", body]
    let pipe = Pipe()
    child.standardOutput = pipe
    let tally = Tally()
    install(pipe.fileHandleForReading, tally)
    try! child.run()
    child.waitUntilExit()
    let before = tally.snapshot
    let cpuBefore = cpuSeconds()
    Thread.sleep(forTimeInterval: settle)
    let cpuAfter = cpuSeconds()
    let after = tally.snapshot
    // Read the invariant BEFORE cleaning up, or the cleanup answers the
    // question instead of the code under test.
    let cancelled = pipe.fileHandleForReading.readabilityHandler == nil
    // Keep the handler from outliving the case when it is the unfixed shape.
    pipe.fileHandleForReading.readabilityHandler = nil
    return Outcome(
        calls: after.calls - before.calls,
        empties: after.empties - before.empties,
        bytes: after.bytes,
        cancelled: cancelled,
        cpu: cpuAfter - cpuBefore
    )
}

/// Every reader that reaches EOF must end in the same state, whatever it was
/// reading. Asserted per case rather than once, because the ways to fail are
/// per case: a reader can cancel correctly on a short child and not on a
/// multi-chunk one.
func checkQuietAfterEOF(_ name: String, _ o: Outcome) {
    check("\(name): the read source is cancelled", o.cancelled,
          "handler still installed after EOF — the self-clear did not run,"
              + " or it deadlocked before the assignment")
    check("\(name): nothing is burning CPU", o.cpu < 0.05,
          "burned \(String(format: "%.3f", o.cpu))s of CPU after the child exited")
    check("\(name): no deliveries after EOF", o.calls == 0,
          "\(o.calls) deliveries")
}

// MARK: - The shape this file exists to keep out

// Written out by hand rather than imported: this is what `readUntilEOF`
// replaced, and the point of running it is to prove the measurement below can
// see the difference. Kept short — one third of a second is already four
// orders of magnitude past the threshold.
let unfixed = afterEOF(body: "printf 'hello'", settle: 0.3) { handle, tally in
    handle.readabilityHandler = { handle in
        let data = handle.availableData
        tally.record(data)
        guard !data.isEmpty else { return }
    }
}

check(
    "the unfixed shape spins after EOF, and this check can see it",
    unfixed.calls > 1_000,
    "only \(unfixed.calls) calls in 0.3s after the child exited — the instrument,"
        + " not the app, is what failed here"
)
check(
    "and every one of those calls is empty",
    unfixed.empties == unfixed.calls,
    "\(unfixed.calls - unfixed.empties) of \(unfixed.calls) carried bytes"
)
// The two observations the fixed cases turn on, asserted here in their failing
// direction. Without this pair, a `cancelled` that is always true or a CPU
// reading that is always zero would pass every case below and mean nothing.
check(
    "an uncancelled source reads back as uncancelled",
    !unfixed.cancelled,
    "the handle reported itself cancelled while the handler was still spinning"
        + " — the invariant check is not measuring anything"
)
check(
    "and a spinning source shows up as burned CPU",
    unfixed.cpu > 0.10,
    "only \(String(format: "%.3f", unfixed.cpu))s burned in a 0.3s spin —"
        + " the CPU reading is not measuring anything"
)

// MARK: - The shape in the app

let fixed = afterEOF(body: "printf 'hello'", settle: 0.3) { handle, tally in
    handle.readUntilEOF { tally.record($0) }
}

checkQuietAfterEOF("readUntilEOF", fixed)
check(
    "readUntilEOF never hands the caller an empty Data",
    fixed.empties == 0,
    "\(fixed.empties) empty deliveries"
)
check(
    "and the bytes still arrive",
    fixed.bytes == Data("hello".utf8),
    "got \(fixed.bytes.count) bytes: \(String(decoding: fixed.bytes, as: UTF8.self).debugDescription)"
)

// A child that says nothing at all is the case a reader is most likely to get
// wrong, because its very first callback is the EOF one — the app reaches it
// on every ssh that dies before printing, which is most of them.
let silent = afterEOF(body: "exit 0", settle: 0.3) { handle, tally in
    handle.readUntilEOF { tally.record($0) }
}
checkQuietAfterEOF("a child that writes nothing", silent)
check(
    "and it delivers nothing",
    silent.bytes.isEmpty,
    "\(silent.bytes.count) bytes"
)

// Output larger than one pipe buffer, so the reader is genuinely re-entered
// while the child is alive: the EOF branch must not be reachable early.
let long = afterEOF(body: "for i in $(seq 1 4000); do printf '0123456789'; done", settle: 0.3) { handle, tally in
    handle.readUntilEOF { tally.record($0) }
}
check(
    "a multi-chunk child is read to the end",
    long.bytes.count == 40_000,
    "got \(long.bytes.count) of 40000 bytes"
)
checkQuietAfterEOF("a multi-chunk child", long)

// The one way this repair could be worse than the bug it replaces: if
// `availableData` could ever come back empty while the writer is still open,
// the reader would treat a lull as EOF and silently truncate the child. This
// child writes with a third of a second of silence between each byte, so the
// source goes quiet and comes back three times with the pipe still open — and
// the assertion is on the bytes, not on a count, because a truncation here
// would be invisible in every other way.
let gapped = afterEOF(
    body: "printf 'a'; sleep 0.3; printf 'b'; sleep 0.3; printf 'c'",
    settle: 0.3
) { handle, tally in
    handle.readUntilEOF { tally.record($0) }
}
check(
    "a lull with the writer still open is not mistaken for EOF",
    gapped.bytes == Data("abc".utf8),
    "got \(String(decoding: gapped.bytes, as: UTF8.self).debugDescription), wanted \"abc\""
)
checkQuietAfterEOF("a reader that saw lulls", gapped)

// The handler must clear *itself*: nothing in the app clears it on the way
// past, and a reader whose owner has been deallocated is exactly the case
// where nobody is left to.
let orphaned = afterEOF(body: "printf 'x'", settle: 0.3) { handle, tally in
    handle.readUntilEOF { [weak tally] data in tally?.record(data) }
}
checkQuietAfterEOF("an orphaned reader", orphaned)

// MARK: - Why an empty read may be treated as EOF at all

// `readUntilEOF` turns "no bytes" into "stop reading, forever". If a read can
// ever come back empty while the writer is still open, that is not a CPU bug
// traded for a smaller one — it is a pane losing the rest of its output with
// nothing said. So the premise gets measured rather than argued, in the two
// ways it could fail.
//
// First: POSIX only promises "0 means EOF" on a *blocking* descriptor. On a
// non-blocking one an empty read is EAGAIN and means nothing of the sort. So
// the descriptor is asked directly, at the three moments its state could
// differ — Foundation installs its monitor lazily, and a future version of it
// setting O_NONBLOCK would turn this file's whole premise false with no other
// symptom.
do {
    func isNonBlocking(_ fd: Int32) -> Bool { (fcntl(fd, F_GETFL) & O_NONBLOCK) != 0 }

    let pipe = Pipe()
    let fd = pipe.fileHandleForReading.fileDescriptor
    check("the pipe starts out blocking", !isNonBlocking(fd))

    pipe.fileHandleForReading.readUntilEOF { _ in }
    Thread.sleep(forTimeInterval: 0.15)
    check("installing a reader does not make it non-blocking", !isNonBlocking(fd))

    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", "printf 'x'; sleep 0.3; printf 'y'"]
    child.standardOutput = pipe
    try! child.run()
    Thread.sleep(forTimeInterval: 0.15)
    check("nor does a child writing to it", !isNonBlocking(fd))
    child.waitUntilExit()
    Thread.sleep(forTimeInterval: 0.15)
    pipe.fileHandleForReading.readabilityHandler = nil
}

// Second: a signal delivered while a read is blocked returns EINTR, and a
// layer that reported that as "no bytes" would hand `readUntilEOF` a false
// EOF partway through a child's output. The handler below is installed with
// `sigaction` and **no SA_RESTART**, because `signal(3)` on BSD sets it and
// the kernel would then restart the read for us — which is the thing under
// test, so it must not be left on.
// File scope, because a signal handler is a C function pointer and cannot be a
// closure that captures anything.
nonisolated(unsafe) var signalsCaught = 0
func countSignal(_ signal: Int32) { signalsCaught += 1 }

do {
    var action = sigaction()
    action.__sigaction_u.__sa_handler = countSignal
    action.sa_flags = 0
    sigemptyset(&action.sa_mask)
    sigaction(SIGUSR1, &action, nil)

    let expected = 20_000
    var short = 0
    for _ in 0..<2 {
        let pipe = Pipe()
        let got = NSMutableData()
        let lock = NSLock()
        let finished = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readUntilEOF { data in
            lock.lock(); got.append(data); lock.unlock()
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Slow and chunked on purpose: the reader has to spend real time
        // blocked for a signal to land in the middle of a read.
        child.arguments = ["-c",
            "for i in $(seq 1 20); do for j in $(seq 1 100); do printf '0123456789'; done; sleep 0.01; done"]
        child.standardOutput = pipe
        try! child.run()
        let storm = Thread {
            for _ in 0..<2000 { pthread_kill(pthread_self(), SIGUSR1); usleep(200) }
            finished.signal()
        }
        storm.start()
        child.waitUntilExit()
        _ = finished.wait(timeout: .now() + 10)
        Thread.sleep(forTimeInterval: 0.3)
        lock.lock(); let n = got.length; lock.unlock()
        if n != expected { short += 1 }
        pipe.fileHandleForReading.readabilityHandler = nil
    }
    check("signals do not interrupt a read into a false EOF", short == 0,
          "\(short) of 2 rounds came up short of \(expected) bytes"
              + " (\(signalsCaught) signals delivered)")
    check("and the signals really were delivered", signalsCaught > 100,
          "only \(signalsCaught) — the storm did not land, so this case proved nothing")
}

if failures == 0 {
    print("PipeReadCheck: \(cases) cases, all pass"
        + " (unfixed shape: \(unfixed.calls) calls and"
        + " \(String(format: "%.2f", unfixed.cpu))s CPU burned in 0.3s)")
} else {
    print("PipeReadCheck: \(failures) failed out of \(cases)")
    exit(1)
}
