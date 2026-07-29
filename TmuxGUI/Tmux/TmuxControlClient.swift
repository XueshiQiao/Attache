//
//  TmuxControlClient.swift
//  TmuxGUI
//

import Foundation

/// One session as `list-sessions` reports it, before there is a connection.
struct TmuxSessionListing {
    let id: String
    let name: String
}

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
    /// What this client attaches to and what every log line names it by.
    /// An id rather than a name because a name is not an identity: it can be
    /// changed from any terminal at any moment, including between the
    /// `list-sessions` that found this session and the attach below.
    private let sessionID: String
    /// The session's current name, for the log only. Kept up to date by
    /// `TmuxSessionConnection` so a line written after a rename says what the
    /// user would now call the session.
    ///
    /// Locked, and not out of tidiness. It is written on the callback queue
    /// when tmux announces a rename and read from `Process.terminationHandler`,
    /// which runs on a queue of the system's choosing — so a session renamed at
    /// the moment its client exits is two threads on one `String`, which is not
    /// a stale log line but undefined behaviour.
    var sessionLabel: String {
        get { labelLock.lock(); defer { labelLock.unlock() }; return storedLabel }
        set { labelLock.lock(); storedLabel = newValue; labelLock.unlock() }
    }

    private var storedLabel: String
    private let labelLock = NSLock()
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
    /// One entry per command written, in order, whether or not anybody wants
    /// the reply.
    ///
    /// The optional is the whole point and it is load-bearing. tmux answers
    /// **every** command with a `%begin`/`%end` block — a fire-and-forget
    /// `send` is not exempt — so a queue that only held the commands with
    /// completions went one out of step for each one of them, permanently, and
    /// from then on every `run` received an earlier command's reply. That is
    /// the same corruption `isBlockTerminator` documents, arrived at from the
    /// other direction, and it was reachable without any unusual pane content
    /// at all: `subscribeToActivity` alone was enough to make the first
    /// `list-windows` parse a `refresh-client` block, which is empty, and
    /// answer "this session has no windows".
    ///
    /// Found 2026-07-28 by adding two more subscriptions and watching the rail
    /// go blank — with one offset the next refresh happened to look right, and
    /// with three it never recovered.
    /// Serialises the actual pipe writes, so their order on the wire is the
    /// order they were appended to `completions` under the lock. See `enqueue`.
    private let writeQueue = DispatchQueue(label: "tmuxgui.control.write")

    private var completions = [(([Data], Bool) -> Void)?]()
    private let stateLock = NSLock()

    /// tmux emits one unsolicited `%begin`/`%end` block during the attach
    /// handshake, before `%session-changed`. Sending anything before that lands
    /// would let our first command's reply be matched against tmux's own block,
    /// so commands are held until the handshake completes.
    private var handshakeComplete = false
    private var queuedCommands = [(String, (([Data], Bool) -> Void)?)]()

    init(tmuxPath: String, sessionID: String, sessionName: String,
         callbackQueue: DispatchQueue = .main)
    {
        self.tmuxPath = tmuxPath
        self.sessionID = sessionID
        storedLabel = sessionName
        self.callbackQueue = callbackQueue
    }

    // MARK: - Lifecycle

    func start() throws {
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        // `$3`, not `=name`. Exact-match on the name was already needed to stop
        // a session called "7" resolving by prefix to something else; the id
        // removes the question. It also closes the window between listing the
        // sessions and attaching to one of them, in which any terminal on the
        // machine is free to rename it — verified on tmux 3.6a that a session
        // id is accepted wherever a session target is.
        process.arguments = ["-C", "attach", "-t", sessionID]
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
                session: self.sessionLabel
            )
            self.callbackQueue.async { self.onExit?(nil) }
        }

        try process.run()
        TmuxLog.lifecycle(
            "spawned \(tmuxPath) -C attach -t \(sessionID) (\(sessionLabel),"
                + " pid \(process.processIdentifier))",
            session: sessionLabel
        )
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else {
            TmuxLog.lifecycle("stop() — control client already gone", session: sessionLabel)
            return
        }
        // `detach-client` lets tmux tear the client down cleanly; the pane
        // processes keep running, which is the whole point of the design. It
        // is still logged as destructive: it is the one command in this class
        // that ends something, and after an incident the question is always
        // whether teardown ran and in what order.
        TmuxLog.destructive("tearing down control client — sending detach-client, then SIGTERM",
                            session: sessionLabel)
        // Through the FIFO like everything else, not straight to `write`.
        // tmux answers `detach-client` with a block too, and a command that
        // reaches the wire without a matching slot in `completions` shifts the
        // queue by one for whatever is still outstanding — the same corruption
        // `completions` exists to prevent. Teardown is the least likely place
        // for it to matter and the easiest place to leave an exception behind.
        stateLock.lock()
        completions.append(nil)
        stateLock.unlock()
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
        TmuxLog.command(command, session: sessionLabel, caller: caller)

        stateLock.lock()
        if !handshakeComplete {
            queuedCommands.append((command, completion))
            stateLock.unlock()
            return
        }
        // Always, including the nil. See `completions`.
        //
        // The write is submitted while the lock is still held, and that is what
        // makes the order an invariant rather than a likelihood: two threads
        // enqueueing at once could otherwise append in one order and reach the
        // pipe in the other, which desynchronises every reply after them.
        // `async` on a serial queue does not block, so holding the lock across
        // it costs nothing.
        //
        // Deliberately *not* writing inside the lock. That would order things
        // too, and it can deadlock: `write` blocks when tmux's stdin buffer is
        // full, tmux fills it when it is blocked writing its own output, and it
        // is blocked writing output when the read thread is waiting for this
        // very lock. A serial queue gives the ordering without the coupling.
        completions.append(completion)
        writeQueue.async { [weak self] in self?.write(command: command) }
        stateLock.unlock()
    }

    /// Put a command on the wire, and say so when it does not go.
    ///
    /// **Every path out of here that is not a write has to be recorded.** The
    /// command's completion is already in `completions` by the time this runs —
    /// `enqueue` appends it under the lock — so a command that silently fails
    /// to leave leaves an entry nothing will ever pop, and from then on every
    /// reply on this connection goes to the wrong caller. That is the same
    /// corruption the `%end` handler guards against from the other side, and it
    /// used to be spelled `try?`, which is indistinguishable from success.
    private func write(command: String) {
        guard let data = (command + "\n").data(using: .utf8) else {
            TmuxLog.lifecycle("command was not encodable and never went out: \(command)", session: sessionLabel)
            return
        }
        // A dead child turns the write into SIGPIPE, which would kill the app.
        guard process.isRunning else {
            TmuxLog.lifecycle("tmux is gone; command never went out: \(command)", session: sessionLabel)
            return
        }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            TmuxLog.lifecycle("write to tmux failed (\(error)); command never went out: \(command)", session: sessionLabel)
        }
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

        case .begin(let number, _):
            stateLock.lock()
            replyLines = []
            openBlockNumber = number
            stateLock.unlock()

        case .end(_, let failed, let isCommandReply):
            stateLock.lock()
            let lines = replyLines ?? []
            replyLines = nil
            openBlockNumber = nil
            // **Only a block tmux attributes to a command of ours takes a
            // completion.** tmux answers this client with blocks nobody here
            // asked for — the attach handshake, and every command it runs on
            // its own behalf. A `set-hook -g after-select-pane 'run-shell …'`
            // in the user's config makes that one extra block for every
            // `select-pane` the app sends, and popping a completion for it
            // hands the *next* command its predecessor's reply from then on.
            //
            // Observed 2026-07-29 in the user's own log, with that hook
            // installed by an unrelated tool: one `select-pane -t %606` out,
            // two blocks back. The victim was the `list-windows` that follows
            // `%window-pane-changed`, which received an empty block, returned
            // early on `parsed.isEmpty`, and left the model naming a pane tmux
            // had already moved off — after which every sync pulled the
            // keyboard back to the stale pane. See `TmuxNotification.parse`
            // for the flags this reads and what was measured.
            //
            // Typed rather than inferred: the element is already optional, and
            // letting the ternary work it out yields a double optional whose
            // `if let` unwraps one layer and silently never fires.
            // Read before the pop, or removing the last entry would report
            // itself as a starved queue.
            let starved = isCommandReply && completions.isEmpty
            let completion: (([Data], Bool) -> Void)? =
                starved ? nil : (isCommandReply ? completions.removeFirst() : nil)
            stateLock.unlock()
            // The other direction of the same fault, and it has no local fix:
            // a reply arriving for a command nothing is waiting on means the
            // queue is already short. Silence is what made this class of bug
            // cost a day, so it is recorded rather than tolerated.
            if starved {
                TmuxLog.lifecycle(
                    "command reply arrived with no command waiting — reply queue is out of step",
                    session: sessionLabel
                )
            }
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
              case .end(let number, _, _)? = TmuxNotification.parse(line: line)
        else { return false }
        guard number == openBlock else {
            // Either a pane is displaying a transcript — the case above, now
            // handled — or a future tmux stopped matching the numbers, which
            // would strand this block and every reply after it. Logged so the
            // second one is diagnosable instead of looking like a hang.
            TmuxLog.lifecycle(
                "ignoring a line inside reply block \(openBlock) that looks like its terminator"
                    + " but is numbered \(number) — treating it as content",
                session: sessionLabel
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
        // Every held command, nil completions included — tmux answers each of
        // them with a block. Filtering here is the same off-by-one `enqueue`
        // had, and it hit the whole handshake queue at once.
        //
        // Appended *and* submitted under the one lock, in step, for the reason
        // written at `enqueue`: releasing the lock between the two let a fresh
        // command overtake the held ones on the wire while sitting after them
        // in `completions`. The log line below used to sit in that gap and
        // widen it.
        for (command, completion) in queued {
            completions.append(completion)
            writeQueue.async { [weak self] in self?.write(command: command) }
        }
        stateLock.unlock()

        TmuxLog.lifecycle(
            "attach handshake complete — releasing \(queued.count) held command(s)",
            session: sessionLabel
        )
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

    /// Every session on the running server, in tmux's own order.
    ///
    /// The id comes back with the name because the id is the identity: a name
    /// is user text that any terminal can change at any moment, and keying
    /// anything by it makes a rename indistinguishable from "that session was
    /// destroyed and a different one appeared".
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
    static func listSessions(tmuxPath: String) -> [TmuxSessionListing]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_id} #{session_name}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                // One split, so a name containing spaces arrives whole. A row
                // with no id is not a session this app can address and is
                // dropped rather than guessed at.
                let parts = line.split(separator: " ", maxSplits: 1)
                guard let id = parts.first, id.hasPrefix("$") else { return nil }
                return TmuxSessionListing(
                    id: String(id), name: parts.count > 1 ? String(parts[1]) : ""
                )
            }
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
