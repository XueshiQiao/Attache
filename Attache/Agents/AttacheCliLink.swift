//
//  AttacheCliLink.swift
//  Attache
//

import Foundation

/// How this app runs attache-cli on the machine a tmux server runs on.
///
/// The one place that differs from the phone, and only underneath: the phone
/// has a single SSH connection, so it sends short commands through tmux's
/// `run-shell` and a buffer, and opens an exec channel for the long ones.
/// This app can start a process — directly on this Mac, or as an `ssh` exec
/// riding the host's ControlMaster — so every command is just a process. The
/// commands, their arguments and what they print are the phone's exactly.
///
/// attache-cli lives at `~/.local/bin/attache-cli` on every host, the same
/// path the phone installs it to, so whichever client connects first puts it
/// there and neither depends on the other. The remote `$HOME` is expanded by
/// the remote `sh`, never by this app: the remote home is not this one.
nonisolated struct AttacheCliLink: Equatable {
    let transport: TmuxTransport

    static let relativePath = ".local/bin/attache-cli"

    /// The argv that runs `attache-cli <args>` there.
    func argv(_ args: [String]) -> [String] {
        switch transport.kind {
        case .local:
            // No shell on the local path: the words are the argv.
            [NSHomeDirectory() + "/" + Self.relativePath] + args
        case .ssh:
            transport.execArgv(["/bin/sh", "-c", "exec \"$HOME/\(Self.relativePath)\" \"$@\"", "attache-cli"] + args)
        }
    }

    /// Runs one short command and hands back its stdout lines (nil when it
    /// could not be started or ran past `timeout`). Every attache-cli
    /// command but `follow` and `agents --watch` ends by itself in well under
    /// a second; the timeout is for a host that stopped answering.
    func run(_ args: [String], timeout: TimeInterval = 15,
             completion: @escaping @MainActor ([String]?) -> Void) {
        let argv = argv(args)
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            // Read to EOF before waiting: a reply larger than the pipe buffer
            // would otherwise block the child and the wait forever.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            let timedOut = process.terminationReason == .uncaughtSignal
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            DispatchQueue.main.async { completion(timedOut ? nil : lines) }
        }
    }

    /// Starts a long command (`follow`, `agents --watch`) and calls `onEvent`
    /// with every JSON object it prints, on the main queue, until the stream
    /// ends (`onEnd`) or is cancelled. attache-cli stops when its stdin ends,
    /// so cancelling closes stdin first and terminates as a backstop.
    @MainActor
    func stream(_ args: [String],
                onEvent: @escaping @MainActor ([String: Any]) -> Void,
                onEnd: @escaping @MainActor () -> Void) -> AttacheCliStream {
        let stream = AttacheCliStream()
        stream.start(argv: argv(args), onEvent: onEvent, onEnd: onEnd)
        return stream
    }
}

/// One running `follow` or `agents --watch`.
nonisolated final class AttacheCliStream: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var cancelled = false

    // On the main actor because `readUntilEOF` is: it is how every pipe in
    // this app is read (CLAUDE.md, "A `readabilityHandler` that ignores
    // empty data never stops running").
    @MainActor
    fileprivate func start(argv: [String],
                           onEvent: @escaping @MainActor ([String: Any]) -> Void,
                           onEnd: @escaping @MainActor () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            DispatchQueue.main.async { onEnd() }
        }
        do {
            try process.run()
        } catch {
            DispatchQueue.main.async { onEnd() }
            return
        }
        lock.lock()
        self.process = process
        self.stdin = input.fileHandleForWriting
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled {
            cancel()
            return
        }
        // After `run()`, never before: a launch that fails produces no EOF,
        // and a reader installed ahead of it would never clear itself (see
        // CLAUDE.md, "A reader installed before `run()`").
        var lines = JSONLines()
        output.fileHandleForReading.readUntilEOF { data in
            let objects = lines.feed(data).compactMap(AttacheCliProtocol.object)
            guard !objects.isEmpty else { return }
            DispatchQueue.main.async { objects.forEach(onEvent) }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process, stdin = self.stdin
        self.stdin = nil
        lock.unlock()
        try? stdin?.close()
        guard let process else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
    }

    deinit { cancel() }
}

/// Bytes in, complete lines out. The unfinished tail stays bytes and is never
/// decoded on its own: a read can end inside a multi-byte character, and
/// decoding half of one makes a replacement character no later read repairs.
nonisolated struct JSONLines {
    private var pending = Data()

    mutating func feed(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            let text = String(decoding: line, as: UTF8.self)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(text) }
        }
        return lines
    }
}
