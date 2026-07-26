//
//  TmuxControlClient.swift
//  TmuxGUI
//

import Foundation

/// A tmux control mode client: one `tmux -C attach` child process, its output
/// parsed into `TmuxNotification`s.
///
/// Runs over plain pipes rather than a pty. Verified against tmux 3.6a — the
/// client never touches termios in control mode, so there is nothing to gain
/// from allocating a pty and a lot of buffering behaviour to lose.
///
/// Requires the app sandbox to be OFF: a sandboxed process can neither spawn
/// tmux nor reach its socket under `/private/tmp/tmux-<uid>/`.
final class TmuxControlClient {
    /// Notifications other than `%output`, delivered on `callbackQueue`.
    var onNotification: ((TmuxNotification) -> Void)?
    /// Pane output, delivered on the reader queue so it never queues behind
    /// main-thread work. This is the hot path — everything else is bookkeeping.
    var onPaneOutput: ((String, Data) -> Void)?
    /// Called when the child exits, on `callbackQueue`.
    var onExit: ((String?) -> Void)?

    private let tmuxPath: String
    private let sessionName: String
    private let callbackQueue: DispatchQueue
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()

    /// Buffer for bytes that arrived without a terminating newline yet.
    private var pending = [UInt8]()

    // Command replies. tmux answers each command with a `%begin`/`%end` pair,
    // and promises notifications never appear inside a block.
    private var replyLines: [String]?
    private var completions = [([String], Bool) -> Void]()
    private let stateLock = NSLock()

    /// tmux emits one unsolicited `%begin`/`%end` block during the attach
    /// handshake, before `%session-changed`. Sending anything before that lands
    /// would let our first command's reply be matched against tmux's own block,
    /// so commands are held until the handshake completes.
    private var handshakeComplete = false
    private var queuedCommands = [(String, (([String], Bool) -> Void)?)]()

    init(tmuxPath: String, sessionName: String, callbackQueue: DispatchQueue = .main) {
        self.tmuxPath = tmuxPath
        self.sessionName = sessionName
        self.callbackQueue = callbackQueue
    }

    // MARK: - Lifecycle

    func start() throws {
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        // `=name` is tmux's exact-match target syntax. Without it a session
        // named "7" can resolve by prefix to something else entirely.
        process.arguments = ["-C", "attach", "-t", "=\(sessionName)"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            TmuxLog.lifecycle(
                "control client exited — status \(process.terminationStatus)"
                    + " reason \(process.terminationReason.rawValue)",
                session: self.sessionName
            )
            self.callbackQueue.async { self.onExit?(nil) }
        }

        try process.run()
        TmuxLog.lifecycle(
            "spawned \(tmuxPath) -C attach -t '=\(sessionName)' (pid \(process.processIdentifier))",
            session: sessionName
        )
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else {
            TmuxLog.lifecycle("stop() — control client already gone", session: sessionName)
            return
        }
        // `detach-client` lets tmux tear the client down cleanly; the pane
        // processes keep running, which is the whole point of the design. It
        // is still logged as destructive: it is the one command in this class
        // that ends something, and after an incident the question is always
        // whether teardown ran and in what order.
        TmuxLog.destructive("tearing down control client — sending detach-client, then SIGTERM",
                            session: sessionName)
        write(command: "detach-client")
        process.terminate()
    }

    // MARK: - Sending

    /// Send a command and ignore its reply.
    ///
    /// `caller` is captured by the compiler at the call site and carried into
    /// the log. It is the difference between knowing a `kill-window` went out
    /// and knowing whether the tab strip or the throughput probe sent it.
    func send(_ command: String, caller: StaticString = #function) {
        enqueue(command, caller: caller, completion: nil)
    }

    /// Send a command and receive its reply block. `failed` mirrors `%error`.
    func run(
        _ command: String,
        caller: StaticString = #function,
        completion: @escaping (_ lines: [String], _ failed: Bool) -> Void
    ) {
        enqueue(command, caller: caller, completion: completion)
    }

    /// Forward keystrokes to a pane. tmux takes one hex byte per argument.
    func sendKeys(pane: String, data: Data) {
        guard !data.isEmpty else { return }
        send("send-keys -t \(pane) -H \(TmuxOctal.hexArguments(for: data))")
    }

    /// Tell tmux how big this client is. tmux sizes the session's windows from
    /// its clients, so skipping this leaves every window at `default-size`.
    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        send("refresh-client -C \(columns)x\(rows)")
    }

    /// The one gate every command passes through, which is why the log lives
    /// here: a command that reaches tmux without a line in the file would have
    /// to bypass this function, and nothing does.
    ///
    /// Logged before the write, not after. If the write is the last thing this
    /// process ever does, the record still exists.
    private func enqueue(_ command: String, caller: StaticString, completion: (([String], Bool) -> Void)?) {
        TmuxLog.command(command, session: sessionName, caller: caller)

        stateLock.lock()
        if !handshakeComplete {
            queuedCommands.append((command, completion))
            stateLock.unlock()
            return
        }
        if let completion { completions.append(completion) }
        stateLock.unlock()
        write(command: command)
    }

    private func write(command: String) {
        guard let data = (command + "\n").data(using: .utf8) else { return }
        // A dead child turns the write into SIGPIPE, which would kill the app.
        guard process.isRunning else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    // MARK: - Reading

    private func consume(_ data: Data) {
        pending.append(contentsOf: data)

        var lineStart = 0
        var index = 0
        while index < pending.count {
            guard pending[index] == UInt8(ascii: "\n") else {
                index += 1
                continue
            }
            var end = index
            // tmux writes bare \n, but tolerate \r\n so a future transport
            // (ssh, a pty) does not silently append \r to every payload.
            if end > lineStart, pending[end - 1] == UInt8(ascii: "\r") { end -= 1 }
            handle(line: Array(pending[lineStart ..< end]))
            index += 1
            lineStart = index
        }
        if lineStart > 0 { pending.removeFirst(lineStart) }
    }

    private func handle(line: [UInt8]) {
        // Inside a reply block every line is command output, not a
        // notification — tmux guarantees notifications never interleave.
        stateLock.lock()
        let insideBlock = replyLines != nil
        stateLock.unlock()

        if insideBlock, !isBlockTerminator(line) {
            stateLock.lock()
            replyLines?.append(String(decoding: line, as: UTF8.self))
            stateLock.unlock()
            return
        }

        guard let notification = TmuxNotification.parse(line: line) else { return }

        switch notification {
        case .output(let pane, let data):
            onPaneOutput?(pane, data)

        case .begin:
            stateLock.lock()
            replyLines = []
            stateLock.unlock()

        case .end(_, let failed):
            stateLock.lock()
            let lines = replyLines ?? []
            replyLines = nil
            let completion = completions.isEmpty ? nil : completions.removeFirst()
            stateLock.unlock()
            if let completion {
                callbackQueue.async { completion(lines, failed) }
            }

        case .sessionChanged:
            flushHandshakeQueue()
            callbackQueue.async { [weak self] in self?.onNotification?(notification) }

        case .exited(let reason):
            callbackQueue.async { [weak self] in self?.onExit?(reason) }

        default:
            callbackQueue.async { [weak self] in self?.onNotification?(notification) }
        }
    }

    private func isBlockTerminator(_ line: [UInt8]) -> Bool {
        line.starts(with: Array("%end ".utf8)) || line.starts(with: Array("%error ".utf8))
    }

    /// Release commands held during the attach handshake, in submission order.
    private func flushHandshakeQueue() {
        stateLock.lock()
        guard !handshakeComplete else { stateLock.unlock(); return }
        handshakeComplete = true
        let queued = queuedCommands
        queuedCommands.removeAll()
        for (_, completion) in queued where completion != nil {
            completions.append(completion!)
        }
        stateLock.unlock()

        TmuxLog.lifecycle(
            "attach handshake complete — releasing \(queued.count) held command(s)",
            session: sessionName
        )
        for (command, _) in queued { write(command: command) }
    }

    // A `-L <socket>` override was added here and deliberately removed. It
    // would have let a debug build be pointed at a scratch tmux server so that
    // testing a font change did not reflow the user's real windows — which is
    // a genuine cost, since the app tells tmux how many columns it has. The
    // owner of this project declined it anyway, and the reasoning is worth
    // keeping: an app tested only against a server made for testing is tested
    // against the easy case. The bugs that have actually hurt here — a pane
    // reporting mouse positions into a live shell, a column count drifting by
    // one — all needed a real session with real programs in it to show up.
    // Test against the real thing and accept the reflow.

    // MARK: - Discovery

    /// Session names on the running server, in tmux's own order.
    ///
    /// A one-shot `tmux list-sessions` rather than a control mode command:
    /// picking which session to attach to has to happen before there is a
    /// control mode client to ask.
    static func listSessions(tmuxPath: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_name}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    /// Locate tmux. `Process` does not consult PATH, and a GUI app launched
    /// from Finder inherits a PATH without Homebrew on it, so the usual
    /// install locations are checked directly before falling back to a login
    /// shell that will have sourced the user's profile.
    static func locateTmux() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/sh")
        which.arguments = ["-lc", "command -v tmux"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        guard (try? which.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        which.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
