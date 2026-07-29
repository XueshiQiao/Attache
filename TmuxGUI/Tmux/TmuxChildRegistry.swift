//
//  TmuxChildRegistry.swift
//  TmuxGUI
//

import Foundation

/// Keeps track of the `tmux -C attach` children this app has spawned, so a run
/// that dies badly does not leave them behind.
///
/// **This is a net under a fault that has been seen and cannot yet be
/// reproduced. Read the next two paragraphs together or the comment misleads.**
///
/// Seen, on 2026-07-30: an orphaned `tmux -C attach` that had been attached
/// since 11:56 that morning, its parent long dead and `ps` reporting `PPID 1`,
/// still listed by `tmux list-clients`. `detach-client` could not remove it —
/// nobody was draining its stdout, so tmux had nowhere to put the answer — and
/// it had to be killed by pid. The cost of one of these is not a stray process:
/// tmux goes on buffering output for a client that is still attached, so once
/// roughly 64KB has piled up the orphan blocks for ever and the server keeps
/// holding memory on its behalf.
///
/// Measured afterwards, and it does *not* explain the above: `tmux -C attach`
/// exits promptly when its stdin reaches EOF, and killing this app with
/// `SIGKILL` does collect all four of its children — the read end of each
/// child's stdout pipe goes with the app, and the write end of its stdin with
/// it, so the child either takes a `SIGPIPE` or sees EOF. So the ordinary
/// crash is already safe, and **why that orphan survived is unknown**. A
/// suspected route is an inherited pipe fd held open by some other process this
/// app spawned, which would keep the child from ever seeing EOF; an attempt to
/// reproduce that was inconclusive because the runtime used for the experiment
/// sets close-on-exec on its own pipes.
///
/// Hence a registry rather than a mechanism: this cannot wait on a
/// reproduction, because the failure is invisible until somebody happens to run
/// `ps`, and it costs the user's tmux server memory the whole time. What is
/// written down can be collected on the next launch whatever the cause turned
/// out to be.
///
/// The decision about *which* pid may be killed is `TmuxChildRecord`, kept
/// separate and pure so it can be checked against a table. Everything here is
/// the side effects: a file, `ps`, and a signal.
enum TmuxChildRegistry {
    /// `~/Library/Application Support/TmuxGUI/control-clients` — not under
    /// `Logs`, because this is live state rather than a record, and a log that
    /// rotates would take the pids with it.
    static let fileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TmuxGUI", isDirectory: true)
        .appendingPathComponent("control-clients")

    private static let lock = NSLock()

    /// Hold the file across a read-modify-write, against every other writer —
    /// including the ones in other processes.
    ///
    /// **`NSLock` is not enough here and that was found by review.** Two copies
    /// of this app share this file: one recording a child it has just spawned
    /// while another is sweeping is a read-modify-write race across processes,
    /// and the loser's change is not merely late — it is *erased*. An erased
    /// record is a future orphan that nothing will ever collect, which is the
    /// exact failure this file exists to prevent, so the cheap fix is worth it.
    ///
    /// `flock` on a sibling lock file rather than on the record file itself,
    /// because `write` replaces that file atomically — locking an inode that is
    /// about to be swapped out from under the lock protects nothing.
    private static func withFileLock(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let lockPath = fileURL.appendingPathExtension("lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            // Losing the lock is not a reason to skip the work: the race is
            // narrow and being unable to take a lock at all would otherwise mean
            // never recording anything.
            TmuxLog.lifecycle("could not open \(lockPath); proceeding unlocked", session: "-")
            body()
            return
        }
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        defer { flock(descriptor, LOCK_UN) }
        body()
    }

    /// Note a child immediately after `Process.run()` returns.
    ///
    /// Written synchronously, for the same reason `TmuxLog` is: the interesting
    /// case is always the run that never gets to flush anything.
    static func record(childPID: Int32, sessionID: String) {
        // The start time is read here rather than derived, because it has to be
        // the value a later `ps` will report for the same process — see
        // `TmuxChildRecord.startedAt`. If it cannot be read there is nothing
        // safe to write: a record without one can never be acted on.
        guard let started = startTime(of: childPID) else {
            TmuxLog.lifecycle(
                "could not read the start time of pid \(childPID); it will not be"
                    + " recorded, so a crash could leave it behind",
                session: sessionID
            )
            return
        }
        let record = TmuxChildRecord(
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            childPID: childPID, startedAt: started, sessionID: sessionID
        )
        withFileLock {
            var records = read()
            records.removeAll { $0.childPID == childPID }
            records.append(record)
            write(records)
        }
    }

    /// Drop a child that is gone. Nothing depends on this happening — the sweep
    /// is correct without it — but a file that stays short is a file somebody
    /// will still be willing to read in six months.
    static func forget(childPID: Int32) {
        withFileLock {
            var records = read()
            records.removeAll { $0.childPID == childPID }
            write(records)
        }
    }

    /// Collect the children of runs that are no longer here. Called once at
    /// launch, before any connection of this run exists.
    ///
    /// Returns how many were reclaimed so the caller can say so out loud: a
    /// non-zero count means a previous run died without tearing down, and that
    /// is worth knowing on its own.
    @discardableResult
    static func sweep() -> Int {
        let mine = ProcessInfo.processInfo.processIdentifier
        var reclaimed = 0
        withFileLock {
            let records = read()
            // This run's own records are kept untouched: `record` appends as
            // connections open, and a sweep must never erase what is running
            // here.
            var survivors = records.filter { $0.ownerPID == mine }

            for record in records where record.ownerPID != mine {
                let ownerAlive = isRunning(record.ownerPID)
                guard record.shouldReclaim(
                    ownerIsAlive: ownerAlive, child: facts(of: record.childPID)
                ) else {
                    // A live owner keeps its record; a dead pid, or a pid that
                    // now means something else, is simply dropped.
                    if ownerAlive { survivors.append(record) }
                    continue
                }
                TmuxLog.destructive(
                    "reclaiming orphaned control client pid \(record.childPID)"
                        + " for \(record.sessionID) — its run (pid \(record.ownerPID)) is gone",
                    session: record.sessionID
                )
                // Counted and dropped only when it is actually gone. Both
                // signals can fail — a pid that changed owner between the check
                // and the kill answers `EPERM` — and reporting a reclaim that
                // did not happen, or forgetting a process that is still there,
                // are both worse than keeping the record for the next launch.
                if terminate(record.childPID) {
                    reclaimed += 1
                } else {
                    TmuxLog.lifecycle(
                        "pid \(record.childPID) survived both signals; keeping its record",
                        session: record.sessionID
                    )
                    survivors.append(record)
                }
            }

            write(survivors)
        }
        return reclaimed
    }

    // MARK: - Process facts

    private static func isRunning(_ pid: Int32) -> Bool {
        // Signal 0 tests for existence without delivering anything. `EPERM`
        // means it exists and belongs to somebody else, which for this question
        // is still "alive".
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// SIGTERM, then SIGKILL if it is still there. Answers whether it is gone.
    ///
    /// The escalation is not belt-and-braces. The orphan that prompted this file
    /// could not be detached because its output was not being read; a process
    /// wedged that way may not get far enough through a graceful shutdown to
    /// exit, and leaving it alive is the whole failure being prevented.
    private static func terminate(_ pid: Int32) -> Bool {
        kill(pid, SIGTERM)
        usleep(200_000)
        guard isRunning(pid) else { return true }
        TmuxLog.destructive("pid \(pid) ignored SIGTERM — sending SIGKILL", session: "-")
        kill(pid, SIGKILL)
        usleep(100_000)
        return !isRunning(pid)
    }

    // MARK: - Reading a pid with `ps`

    /// `ps` rather than `sysctl(KERN_PROCARGS2)`: this runs a handful of times
    /// per launch, the argv unpacking that call needs is fiddly enough to be its
    /// own source of bugs, and "cannot read it" has to mean "do not kill it" —
    /// which nil already says to `shouldReclaim`.
    ///
    /// **Two calls rather than one, and that is not laziness.** Both `lstart`
    /// and `command` contain spaces, so a single `-o lstart=,command=` produces
    /// output that cannot be split back into fields without guessing. Asked
    /// separately, each answer is unambiguous: `lstart` alone is exactly five
    /// tokens, and `command` alone is the whole line.
    private static func facts(of pid: Int32) -> TmuxChildRecord.ChildFacts? {
        guard let command = ps(["-o", "command=", "-p", "\(pid)"]),
              let parentAndStart = ps(["-o", "ppid=,lstart=", "-p", "\(pid)"])
        else { return nil }
        let tokens = parentAndStart.split(whereSeparator: \.isWhitespace)
        guard let parent = tokens.first.flatMap({ Int32($0) }), tokens.count > 1
        else { return nil }
        return TmuxChildRecord.ChildFacts(
            commandLine: command,
            startedAt: TmuxChildRecord.normalizeStart(
                tokens.dropFirst().joined(separator: " ")
            ),
            parentPID: parent
        )
    }

    /// The start time of a pid in the form `TmuxChildRecord` stores, or nil.
    private static func startTime(of pid: Int32) -> String? {
        guard let raw = ps(["-o", "lstart=", "-p", "\(pid)"]) else { return nil }
        let normalized = TmuxChildRecord.normalizeStart(raw)
        return normalized.isEmpty ? nil : normalized
    }

    private static func ps(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Storage

    /// Caller holds `lock`.
    private static func read() -> [TmuxChildRecord] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { TmuxChildRecord.parse(line: String($0)) }
    }

    /// Caller holds `lock`.
    private static func write(_ records: [TmuxChildRecord]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let text = records.map(\.line).joined(separator: "\n")
            + (records.isEmpty ? "" : "\n")
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
