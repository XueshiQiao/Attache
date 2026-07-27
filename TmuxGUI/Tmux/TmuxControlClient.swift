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
    //
    // Held as bytes for the same reason `%output` is — see `TmuxOctal` — but
    // arriving at it from the opposite direction. Verified on tmux 3.6a by
    // driving `tmux -C attach` over a pipe and reading the raw stream: tmux
    // escapes nothing inside a reply block, so a `capture-pane -e` reply
    // carries ESC as the byte 0x1b, not as `\033`. A reply line is therefore
    // an arbitrary byte string with only the newline reserved, and decoding it
    // to `String` on the way past is a lossy step no later code can undo.
    private var replyLines: [Data]?
    /// The command number tmux gave the block currently open. What tells a real
    /// terminator from a pane displaying one — see `isBlockTerminator`.
    private var openBlockNumber: Int?
    private var completions = [([Data], Bool) -> Void]()
    private let stateLock = NSLock()

    /// tmux emits one unsolicited `%begin`/`%end` block during the attach
    /// handshake, before `%session-changed`. Sending anything before that lands
    /// would let our first command's reply be matched against tmux's own block,
    /// so commands are held until the handshake completes.
    private var handshakeComplete = false
    private var queuedCommands = [(String, (([Data], Bool) -> Void)?)]()

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
    /// the log. It resolves to the *immediate* caller, so it distinguishes
    /// `killWindow(id:)` from `runThroughputProbe` — two very different reasons
    /// for a `kill-window` to go out. It does not distinguish which UI reached
    /// `killWindow`, because the tab strip and the menu both route through it.
    func send(_ command: String, caller: StaticString = #function) {
        enqueue(command, caller: caller, completion: nil)
    }

    /// Send a command and receive its reply block as text. `failed` mirrors
    /// `%error`.
    ///
    /// Lossy, and only safe because of what the callers ask for. `String
    /// (decoding:as:)` substitutes U+FFFD for anything that is not valid
    /// UTF-8, which is fine for tmux's own format output: verified on 3.6a
    /// that `list-windows -F` renders a byte above 0x7f in a window name as
    /// the four ASCII characters `\351`, so that reply is ASCII whatever the
    /// user called the window. Anything carrying a pane's own bytes wants
    /// `runBytes` instead.
    func run(
        _ command: String,
        caller: StaticString = #function,
        completion: @escaping (_ lines: [String], _ failed: Bool) -> Void
    ) {
        runBytes(command, caller: caller) { lines, failed in
            completion(lines.map { String(decoding: $0, as: UTF8.self) }, failed)
        }
    }

    /// Send a command and receive its reply block as raw bytes, exactly as
    /// tmux wrote them.
    ///
    /// The path a `capture-pane` snapshot takes. It is the reply-block
    /// counterpart of the rule `%output` already follows: what comes back is a
    /// pane's screen, and a pane's screen is bytes.
    func runBytes(
        _ command: String,
        caller: StaticString = #function,
        completion: @escaping (_ lines: [Data], _ failed: Bool) -> Void
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

    /// The gate every command from the UI passes through, which is why the log
    /// lives here.
    ///
    /// Three things reach tmux without coming through it, and they are listed
    /// because an earlier version of this comment said nothing did, which is
    /// the kind of claim someone later relies on:
    ///
    /// - `stop()` writes `detach-client` straight to the pipe. It logs, but as
    ///   a DESTRUCTIVE line rather than in the command format.
    /// - `TmuxControlClient.listSessions` spawns its own `tmux list-sessions`,
    ///   and logs nothing at all. Read-only, so nothing it does can be the
    ///   cause of a disappearance.
    /// - `TmuxServer.newSession` spawns `tmux new-session -d`, and logs itself.
    ///
    /// Logged before the write, not after. If the write is the last thing this
    /// process ever does, the record still exists.
    private func enqueue(_ command: String, caller: StaticString, completion: (([Data], Bool) -> Void)?) {
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
        let openBlock = openBlockNumber
        let insideBlock = replyLines != nil
        stateLock.unlock()

        if insideBlock, !isBlockTerminator(line, closing: openBlock) {
            stateLock.lock()
            replyLines?.append(Data(line))
            stateLock.unlock()
            return
        }

        guard let notification = TmuxNotification.parse(line: line) else { return }

        switch notification {
        case .output(let pane, let data):
            onPaneOutput?(pane, data)

        case .begin(let number):
            stateLock.lock()
            replyLines = []
            openBlockNumber = number
            stateLock.unlock()

        case .end(_, let failed):
            stateLock.lock()
            let lines = replyLines ?? []
            replyLines = nil
            openBlockNumber = nil
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

    /// Whether this line ends the open reply block, as opposed to being a line
    /// of that block's content that merely looks like one.
    ///
    /// Matching on the `%end `/`%error ` prefix alone is not enough, and the
    /// counter-example is not hostile input — it is this project's own subject
    /// matter. A reply block carries a pane's screen verbatim, and a pane
    /// showing a captured control mode transcript has lines beginning `%end `
    /// on it. Closing the block there truncates that reply, fires the wrong
    /// completion, and leaves the FIFO in `completions` shifted by one, so
    /// from then on every command receives the *previous* command's reply —
    /// `list-windows` answered with a pane's screen, layouts parsed from the
    /// wrong bytes. It is silent and it is permanent for that connection.
    ///
    /// tmux stamps `%begin` and its matching `%end`/`%error` with the same
    /// command number. Verified on 3.6a by reading the raw stream over a pipe,
    /// across four consecutive blocks: 303/303, 308/308, 309/309, 311/311,
    /// including an `%error`, which carries the number the same way. That
    /// number is a per-server command counter the pane's content has no way to
    /// know, so requiring it to match is what tells the terminator apart from
    /// a pane that happens to be displaying one.
    private func isBlockTerminator(_ line: [UInt8], closing openBlock: Int?) -> Bool {
        guard line.starts(with: Array("%end ".utf8)) || line.starts(with: Array("%error ".utf8)) else {
            return false
        }
        guard let openBlock,
              case .end(let number, _)? = TmuxNotification.parse(line: line)
        else { return false }
        guard number == openBlock else {
            // Either a pane is displaying a transcript — the case above, now
            // handled — or a future tmux stopped matching the numbers, which
            // would strand this block and every reply after it. Logged so the
            // second one is diagnosable instead of looking like a hang.
            TmuxLog.lifecycle(
                "ignoring a line inside reply block \(openBlock) that looks like its terminator"
                    + " but is numbered \(number) — treating it as content",
                session: sessionName
            )
            return false
        }
        return true
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
    ///
    /// `nil` means the question could not be *asked*: `tmux` would not spawn.
    /// An empty array is an answer, and a different one — tmux ran and listed
    /// nothing, which here is the same event as the server being gone, because
    /// a tmux server whose last session is killed exits. `TmuxServer`
    /// reconciles its connections against this, so the two cannot share a
    /// return value: one of them must drop every connection and the other must
    /// change nothing.
    static func listSessions(tmuxPath: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_name}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
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
