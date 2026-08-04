//
//  SSHPreflight.swift
//  Attache
//

import Foundation

/// The one ssh connection per host that authenticates: a `-N` ControlMaster
/// child every data connection then multiplexes over.
///
/// The rule it enforces is the issue's first risk: an auth prompt must never
/// reach a data pipe, because the control pipe is a protocol and a prompt
/// corrupts it in both directions. So auth happens here, once, and every
/// data connection carries `BatchMode=yes` + `ControlMaster=no` — they ride
/// this master's socket or they fail fast and loudly.
///
/// Readiness is asked of ssh itself (`ssh -O check`), not inferred from the
/// socket path existing: the path embeds `%C`, a hash only ssh expands.
///
/// A master that is already running under our ControlPath — a previous run
/// of this app that crashed, or a second copy — is *adopted*: `-O check`
/// answers before anything is spawned, and an adopted master is not
/// terminated on `stop()`, because it is not ours to kill.
@MainActor
final class SSHPreflight {
    enum State: Equatable {
        case idle
        case connecting
        case up
        /// The reason, in ssh's own words where possible.
        case down(String)
    }

    private(set) var state = State.idle {
        didSet { if state != oldValue { observers.forEach { $0(state) } } }
    }

    /// Observers rather than a single callback, because a pre-flight is
    /// shared: two `[[host]]` blocks can name one destination — the same
    /// machine, two tmux sockets is a legitimate setup — and two instances
    /// racing check-unlink-spawn over one ControlPath can unlink each
    /// other's *live* socket. One instance per ControlPath, handed out by
    /// `shared`, is what removes the race rather than narrowing it.
    private var observers: [(State) -> Void] = []

    func addObserver(_ observer: @escaping (State) -> Void) {
        observers.append(observer)
        observer(state)
    }

    private static var byControlPath = [String: SSHPreflight]()

    static func shared(target: SSHTarget, label: String) -> SSHPreflight {
        if let existing = byControlPath[target.controlPath] { return existing }
        let made = SSHPreflight(target: target, label: label)
        byControlPath[target.controlPath] = made
        return made
    }

    /// How many hosts currently want this master up. `stop()` from one host
    /// must not take the master out from under another — the adopted-master
    /// version of the same accident.
    private var retainCount = 0

    private let target: SSHTarget
    private let label: String
    private var master: Process?
    private var adopted = false
    private var shouldRun = false
    private var retryDelay: TimeInterval = 1
    private var checkTimer: Timer?
    /// Written from the pipe's own reader queue, read on the main actor when
    /// the master exits — the lock is the synchronisation, so these two step
    /// outside the class's isolation on purpose.
    nonisolated(unsafe) private var stderrTail = Data()
    private let stderrLock = NSLock()

    init(target: SSHTarget, label: String) {
        self.target = target
        self.label = label
    }

    func start() {
        retainCount += 1
        guard !shouldRun else { return }
        shouldRun = true
        retryDelay = 1
        connect()
    }

    func stop() {
        retainCount = max(0, retainCount - 1)
        guard retainCount == 0 else { return }
        shouldRun = false
        checkTimer?.invalidate()
        checkTimer = nil
        if let master, master.isRunning, !adopted {
            TmuxChildRegistry.forget(childPID: master.processIdentifier)
            master.terminate()
        }
        master = nil
        state = .idle
    }

    /// Ask ssh whether the master answers, off the main thread; `-O check`
    /// only touches the local socket, but a synchronous `Process` wait on the
    /// main thread is a habit this codebase does not want.
    private func check(_ completion: @escaping @MainActor (Bool) -> Void) {
        let argv = [
            target.sshPath,
            "-o", "ControlPath=\(target.controlPath)",
            "-O", "check", "--", target.destination,
        ]
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let alive = (try? process.run()) != nil && {
                process.waitUntilExit()
                return process.terminationStatus == 0
            }()
            DispatchQueue.main.async { completion(alive) }
        }
    }

    private func connect() {
        guard shouldRun else { return }
        // One master, full stop. Several retry chains can converge here — the
        // child's exit, the heartbeat, the ready-poll timeout — and before
        // this guard each spawned its own `ssh -N`, the reference overwrite
        // orphaned the previous child, and a killed master turned into five
        // live ones inside a minute (observed against the mini, 2026-08-05).
        if let master, master.isRunning { return pollUntilReady(deadline: Date(timeIntervalSinceNow: 15)) }
        state = .connecting
        check { [weak self] alreadyRunning in
            guard let self, self.shouldRun else { return }
            if alreadyRunning {
                self.adopted = true
                self.becameReady()
            } else {
                self.spawnMaster()
            }
        }
    }

    private func spawnMaster() {
        guard master?.isRunning != true else { return }
        adopted = false
        // A master killed uncleanly leaves its socket behind, and
        // `ControlMaster=yes` refuses to bind over the corpse. Reached only
        // after `-O check` answered nothing — a *live* master would have been
        // adopted above — so whatever file is at this path answers no one.
        unlink(target.controlPath)
        let argv = target.masterArgv
        let child = Process()
        child.executableURL = URL(fileURLWithPath: argv[0])
        child.arguments = Array(argv.dropFirst())
        child.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        child.standardError = stderr
        stderrLock.lock(); stderrTail.removeAll(); stderrLock.unlock()
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.stderrLock.lock()
            self.stderrTail.append(data)
            if self.stderrTail.count > 4096 {
                self.stderrTail.removeFirst(self.stderrTail.count - 4096)
            }
            self.stderrLock.unlock()
        }
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self, self.master === child else { return }
                self.masterExited(status: child.terminationStatus)
            }
        }
        do {
            try child.run()
        } catch {
            failed("ssh would not start: \(error.localizedDescription)")
            return
        }
        master = child
        // Recorded like a control client: an orphaned master holds a network
        // connection and the mux socket, and the sweep's exact-command match
        // is what lets a later run collect it. An *adopted* master is never
        // recorded — it is not ours to kill.
        TmuxChildRegistry.record(childPID: child.processIdentifier, sessionID: "ssh-master")
        TmuxLog.lifecycle(
            "ssh master spawned: \(argv.joined(separator: " ")) (pid \(child.processIdentifier))",
            session: label
        )
        pollUntilReady(deadline: Date(timeIntervalSinceNow: 15))
    }

    /// The master goes ready when `-O check` says so. Polled rather than
    /// signalled, because a `-N` master prints nothing on success — silence
    /// is its steady state.
    private func pollUntilReady(deadline: Date) {
        guard shouldRun, let master, master.isRunning else { return }
        check { [weak self] ready in
            guard let self, self.shouldRun else { return }
            if ready { return self.becameReady() }
            guard Date() < deadline else {
                self.master?.terminate()
                return self.failed("ssh master did not become ready in 15s")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.pollUntilReady(deadline: deadline)
            }
        }
    }

    private func becameReady() {
        retryDelay = 1
        state = .up
        TmuxLog.lifecycle(
            adopted ? "ssh master adopted (already running)" : "ssh master ready",
            session: label
        )
        // The master can die without its child-exit reaching us — an adopted
        // one is not our child at all. A slow heartbeat keeps the state
        // honest; 10s is far inside the keepalive window the master itself
        // uses to notice a dead peer.
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .up else { return }
                self.check { [weak self] alive in
                    guard let self, self.state == .up else { return }
                    if !alive { self.failed("ssh master stopped answering") }
                }
            }
        }
    }

    private func masterExited(status: Int32) {
        stderrLock.lock()
        let tail = String(decoding: stderrTail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        stderrLock.unlock()
        master = nil
        failed(tail.isEmpty ? "ssh master exited (status \(status))" : tail)
    }

    private var retryScheduled = false

    private func failed(_ reason: String) {
        checkTimer?.invalidate()
        checkTimer = nil
        state = .down(reason)
        TmuxLog.lifecycle("ssh master down: \(reason)", session: label)
        guard shouldRun, !retryScheduled else { return }
        retryScheduled = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            guard self.shouldRun, self.state != .up else { return }
            self.connect()
        }
    }

    /// One immediate retry, for the host row's click — the backoff can be at
    /// 30s and a person pointing at the row deserves an answer now.
    func retryNow() {
        guard shouldRun, case .down = state else { return }
        retryDelay = 1
        connect()
    }
}
