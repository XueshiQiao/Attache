//
//  TmuxLog.swift
//  TmuxGUI
//

import Foundation

/// Every command this app sends to tmux, written to disk *before* it is sent.
///
/// tmux is shared, live state with no undo. A window this app closes takes an
/// agent's run with it; a session it destroys takes the user's context. When
/// something disappears the only question that matters is **which command went
/// out, and who asked for it** — and the process that could answer is usually
/// the one that just died.
///
/// So: written synchronously, one `write(2)` per line, no buffering, and to a
/// file rather than only stdout. The interesting case is always the one where
/// the app never gets to flush.
///
/// Keystrokes are never recorded. `send-keys` carries whatever the user typed,
/// a password prompt included; only its size is logged.
///
/// That is the only redaction, and it is worth being exact about the limit:
/// `rename-window` and `rename-session` carry text the user typed and it is
/// logged verbatim. A window name is not a secret — it is in every `tmux ls`
/// and drawn on the tab — and a rename is a write operation, which is what
/// this file exists to record. But "keystrokes are never recorded" would be
/// too strong a reading, so: keystrokes *sent to a pane* are never recorded.
enum TmuxLog {
    /// How much damage a command can do.
    ///
    /// After an incident the first thing anyone does is grep. `DESTRUCTIVE` is
    /// the short list of lines that can lose work, and it is worth being able
    /// to find them without knowing tmux's whole command vocabulary.
    enum Kind: String {
        case destructive = "DESTRUCTIVE"
        case write = "WRITE"
        case query = "QUERY"
        case lifecycle = "LIFECYCLE"
    }

    /// `~/Library/Logs/TmuxGUI/tmux-commands.log` — where macOS keeps app logs,
    /// and outside the app bundle so it survives a rebuild as well as a crash.
    static let fileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TmuxGUI", isDirectory: true)
        .appendingPathComponent("tmux-commands.log")

    // MARK: - Entry points

    /// Record a command on its way to tmux.
    ///
    /// `caller` defaults to the calling function, which is the whole point: it
    /// turns "a kill-window went out" into "`killWindow(id:)` sent it" or
    /// "`runThroughputProbe` sent it", and those are different bugs.
    static func command(
        _ command: String,
        session: String,
        caller: StaticString = #function
    ) {
        let text = redacted(command)
        emit(kind(of: command), session: session, caller: "\(caller)", text: text)
        // The diagnostics tap, and this gate is *why* it works: every command
        // passes through here, so expectations derived from the text cover
        // call sites that do not exist yet. The redacted form on purpose —
        // diagnostics keeps a ring of recent commands in its snapshots, and a
        // snapshot must not hold what this file just refused to log.
        DiagnosticsCenter.shared.commandSent(text, session: session)
    }

    /// Record something that is not a tmux command — a process spawning or
    /// exiting, a connection being torn down, the app terminating.
    static func lifecycle(
        _ message: String,
        session: String = "-",
        caller: StaticString = #function
    ) {
        emit(.lifecycle, session: session, caller: "\(caller)", text: message)
    }

    /// Record a destructive act that is not itself a tmux command, or one whose
    /// severity the command text does not convey. Always logged as
    /// `DESTRUCTIVE` regardless of what it looks like.
    static func destructive(
        _ message: String,
        session: String = "-",
        caller: StaticString = #function
    ) {
        emit(.destructive, session: session, caller: "\(caller)", text: message)
    }

    // MARK: - Classification

    /// Bucket a tmux command by what it can do.
    ///
    /// Unknown commands are treated as writes rather than queries: a command
    /// this app does not recognise is more likely to be a new mutation than a
    /// new question, and over-logging costs a line while under-logging costs
    /// the answer.
    static func kind(of command: String) -> Kind {
        let verb = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command

        if verb.hasPrefix("kill-") || verb == "detach-client" || verb.hasPrefix("respawn-") {
            return .destructive
        }
        if verb.hasPrefix("list-") || verb.hasPrefix("show-")
            || verb == "capture-pane" || verb == "display-message"
        {
            return .query
        }
        return .write
    }

    /// Strip the payload out of `send-keys`.
    ///
    /// The command is `send-keys -t %42 -H 68 65 6c 6c 6f` — hex of exactly
    /// what the user typed. Logging it would turn this file into a keylogger,
    /// so only the byte count survives.
    ///
    /// Every `send-keys` is redacted, not only the hex form this app sends
    /// today. The alternative is a privacy guarantee that holds until someone
    /// adds a call site and does not know this function exists, which is not a
    /// guarantee at all.
    static func redacted(_ command: String) -> String {
        guard command.hasPrefix("send-keys") else { return command }

        if let marker = command.range(of: " -H ") {
            let byteCount = command[marker.upperBound...].split(separator: " ").count
            return command[..<marker.lowerBound] + " -H <\(byteCount) bytes withheld>"
        }

        // Some other form of send-keys: keep the target, which is all that is
        // useful here anyway, and drop everything else unread.
        let tokens = command.split(separator: " ")
        if let flag = tokens.firstIndex(of: "-t"), flag + 1 < tokens.count {
            return "send-keys -t \(tokens[flag + 1]) <withheld>"
        }
        return "send-keys <withheld>"
    }

    // MARK: - Writing

    private static let lock = NSLock()
    private static var handle: FileHandle?
    private static var bytesWritten: UInt64 = 0

    /// Stop a closed stdout from killing the process.
    ///
    /// Process-wide, which is why it is spelled out rather than buried: with
    /// the default disposition, writing to a pipe whose reader has gone raises
    /// SIGPIPE and the default action for SIGPIPE is termination. Nothing in
    /// this app wants that. `TmuxControlClient.write` guards its pipe write
    /// with `process.isRunning` for the same hazard, and that guard is a race
    /// it cannot win; ignoring the signal turns both cases into an ordinary
    /// `EPIPE` that the `try?` at each call site drops.
    ///
    /// `dispatch_once` semantics via `let`, so the handler is installed once
    /// however many threads arrive together.
    private static let brokenPipesIgnored: Bool = {
        signal(SIGPIPE, SIG_IGN)
        return true
    }()

    private static func ignoreBrokenPipes() {
        _ = brokenPipesIgnored
    }

    /// Keep one generation of history and cap it. A day of heavy use is a few
    /// megabytes; an unbounded log on someone's boot volume is its own bug.
    private static let sizeLimit: UInt64 = 8 * 1024 * 1024

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static func emit(_ kind: Kind, session: String, caller: String, text: String) {
        let line = "[\(stamp.string(from: Date()))] [\(kind.rawValue)] "
            + "[\(session)] \(caller) — \(text)\n"

        // stdout too: CLAUDE.md's documented way to run this app is the binary
        // directly, with stdout attached, and that is where anyone watching a
        // live repro is already looking.
        //
        // `try?` and not the older `write(_:)`, which raises. And the raise was
        // not even the dangerous half: a closed reader delivers SIGPIPE, which
        // kills the process before any error can be returned, so
        // `TmuxGUI | head -1` — a completely ordinary thing to type — took the
        // whole app down at the second log line. `ignoreBrokenPipes` is what
        // actually fixes that; this call just stops the leftover EPIPE from
        // becoming an exception.
        Self.ignoreBrokenPipes()
        try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))

        lock.lock()
        defer { lock.unlock() }
        guard let handle = openedHandle() else { return }
        let data = Data(line.utf8)
        // Logging must never be the reason the app fails.
        try? handle.write(contentsOf: data)
        bytesWritten += UInt64(data.count)
        if bytesWritten > sizeLimit { rotate() }
    }

    /// Caller holds `lock`.
    private static func openedHandle() -> FileHandle? {
        if let handle { return handle }

        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: fileURL) else { return nil }
        bytesWritten = (try? opened.seekToEnd()) ?? 0
        handle = opened

        let banner = "\n=== TmuxGUI \(ProcessInfo.processInfo.processIdentifier) "
            + "started \(stamp.string(from: Date())) ===\n"
        try? opened.write(contentsOf: Data(banner.utf8))
        return opened
    }

    /// Caller holds `lock`.
    private static func rotate() {
        try? handle?.close()
        handle = nil
        bytesWritten = 0
        let previous = fileURL.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
    }
}
