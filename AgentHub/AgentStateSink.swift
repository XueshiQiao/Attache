//
//  AgentStateSink.swift
//  Attache
//

import Darwin
import Foundation

/// Downstream consumer of authoritative `AgentStateAction` decisions.
///
/// Layer 2 (`AgentStateReducer`) knows nothing about tmux, sockets, or push
/// gateways; adding a new client transport (e.g. a resident `attache-daemon`
/// for Android / iOS WebSocket or FCM/APNs delivery) is adding a sink here.
nonisolated protocol AgentStateSink: Sendable {
    var id: String { get }
    func publish(_ action: AgentStateAction, target: AgentPaneTarget)
}

/// Locates the `tmux` binary even when an agent's hook runner strips Homebrew
/// directories from `PATH`.
nonisolated enum TmuxBinaryLocator {
    private static let fallbackPaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    static func locate(environment: [String: String]) -> String? {
        if let rawPath = environment["PATH"] {
            for entry in rawPath.split(separator: ":") where !entry.isEmpty {
                let candidate = (String(entry) as NSString).appendingPathComponent("tmux")
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return fallbackPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Resolves which tmux pane owns the current hook invocation.
nonisolated enum AgentPaneResolver {
    static func resolve(
        environment: [String: String],
        startPID: Int32 = getppid()
    ) -> AgentPaneTarget? {
        let socketPath = extractSocketPath(from: environment["TMUX"])

        // Primary path: tmux exports `TMUX_PANE` (`%N`) into every pane and
        // normal hook subprocesses inherit it.
        if let rawPane = environment["TMUX_PANE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           AgentPaneTarget.isValidPaneID(rawPane)
        {
            return AgentPaneTarget(paneID: rawPane, tmuxSocketPath: socketPath)
        }

        // Fallback path: if a hook runner sanitised `TMUX_PANE`, walk kernel
        // process ancestry from our parent PID up to a live tmux pane's root
        // PID (`list-panes -a -F "#{pane_pid}\t#{pane_id}"`).
        guard let tmux = TmuxBinaryLocator.locate(environment: environment) else { return nil }
        let panes = queryLivePanePIDs(tmuxExecutable: tmux, socketPath: socketPath)
        guard !panes.isEmpty,
              let matchedPane = matchAncestry(
                  startPID: startPID,
                  paneByPID: panes,
                  parentOf: kernelParentPID(of:)
              )
        else { return nil }
        return AgentPaneTarget(paneID: matchedPane, tmuxSocketPath: socketPath)
    }

    static func extractSocketPath(from tmuxEnv: String?) -> String? {
        guard let tmuxEnv else { return nil }
        let socket = tmuxEnv.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let socket, !socket.isEmpty else { return nil }
        return socket
    }

    /// Pure ancestry walk, separated so check tools can exercise multi-hop and
    /// cycle cases deterministically without spawning processes.
    static func matchAncestry(
        startPID: Int32,
        paneByPID: [Int32: String],
        parentOf: (Int32) -> Int32?
    ) -> String? {
        var current = startPID
        var visited = Set<Int32>()
        for _ in 0 ..< 32 {
            guard current > 1, visited.insert(current).inserted else { return nil }
            if let pane = paneByPID[current], AgentPaneTarget.isValidPaneID(pane) {
                return pane
            }
            guard let parent = parentOf(current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    static func kernelParentPID(of pid: Int32) -> Int32? {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    private static func queryLivePanePIDs(
        tmuxExecutable: String,
        socketPath: String?
    ) -> [Int32: String] {
        var args = [String]()
        if let socketPath { args += ["-S", socketPath] }
        args += ["list-panes", "-a", "-F", "#{pane_pid}\t#{pane_id}"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxExecutable)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return [:]
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }

        var result = [Int32: String]()
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 1)
            guard cols.count == 2,
                  let pid = Int32(cols[0]),
                  AgentPaneTarget.isValidPaneID(String(cols[1]))
            else { continue }
            result[pid] = String(cols[1])
        }
        return result
    }

    /// Guards against a child agent spawned inside another agent's tool call
    /// (`claude` running `agy -p`, or `agy` invoking `grok`) clobbering the
    /// interactive parent agent's pane state via an inherited `TMUX_PANE`.
    ///
    /// On Darwin/Linux tmux resolves `#{pane_current_command}` from the pty's
    /// foreground process group (`TIOCGPGRP`), which stays on the interactive
    /// parent TUI while tool subprocesses run. When that foreground command is
    /// a known agent *different* from `actionKind`, the pane belongs to the
    /// parent agent. Shells, wrappers (`zsh`, `node`), or empty answers fail
    /// open (`true`).
    static func shouldPublishToPane(
        actionKind: String,
        paneCurrentCommand: String
    ) -> Bool {
        let trimmed = paneCurrentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAction = (actionKind == "antigravity") ? "agy" : actionKind
        guard let foregroundKind = AgentProcessCatalog.kind(ofCommand: trimmed) else {
            return true
        }
        return foregroundKind == normalizedAction
    }

    static func paneAllowsAction(
        _ action: AgentStateAction,
        target: AgentPaneTarget,
        environment: [String: String]
    ) -> Bool {
        guard let actionKind = action.agentKind,
              AgentPaneTarget.isValidPaneID(target.paneID),
              let tmux = TmuxBinaryLocator.locate(environment: environment),
              let currentCommand = queryPaneCurrentCommand(
                  tmuxExecutable: tmux,
                  target: target
              )
        else {
            return true
        }
        return shouldPublishToPane(actionKind: actionKind, paneCurrentCommand: currentCommand)
    }

    private static func queryPaneCurrentCommand(
        tmuxExecutable: String,
        target: AgentPaneTarget
    ) -> String? {
        var args = [String]()
        if let socket = target.tmuxSocketPath, !socket.isEmpty {
            args += ["-S", socket]
        }
        args += ["display-message", "-p", "-t", target.paneID, "#{pane_current_command}"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxExecutable)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Scheme A Sink: tmux Pane User Options

/// Publishes authoritative agent state into tmux pane options (`@agent_state`,
/// `@agent_kind`, `@agent_at`, `@agent_why`) in a single chained `tmux` call.
nonisolated struct TmuxAgentStateSink: AgentStateSink {
    let id = "tmux"
    let environment: [String: String]

    /// Pure argument builder, exposed for byte-exact assertion in `AgentHubCheck`.
    static func tmuxArguments(
        for action: AgentStateAction,
        target: AgentPaneTarget
    ) -> [String]? {
        guard AgentPaneTarget.isValidPaneID(target.paneID) else { return nil }
        let pane = target.paneID
        var prefix = [String]()
        if let socket = target.tmuxSocketPath, !socket.isEmpty {
            prefix += ["-S", socket]
        }

        switch action {
        case .ignore:
            return nil

        case let .register(kind, reason, timestamp, _, _):
            return prefix + [
                "set-option", "-pu", "-t", pane, "@agent_state", ";",
                "set-option", "-p", "-t", pane, "@agent_kind", kind, ";",
                "set-option", "-p", "-t", pane, "@agent_at", String(timestamp), ";",
                "set-option", "-p", "-t", pane, "@agent_why", reason,
            ]

        case .transition(let snap):
            return prefix + [
                "set-option", "-p", "-t", pane, "@agent_state", snap.state.rawValue, ";",
                "set-option", "-p", "-t", pane, "@agent_kind", snap.kind, ";",
                "set-option", "-p", "-t", pane, "@agent_at", String(snap.timestamp), ";",
                "set-option", "-p", "-t", pane, "@agent_why", snap.reason,
            ]

        case .clear:
            return prefix + [
                "set-option", "-pu", "-t", pane, "@agent_state", ";",
                "set-option", "-pu", "-t", pane, "@agent_kind", ";",
                "set-option", "-pu", "-t", pane, "@agent_at", ";",
                "set-option", "-pu", "-t", pane, "@agent_why",
            ]
        }
    }

    func publish(_ action: AgentStateAction, target: AgentPaneTarget) {
        guard let args = Self.tmuxArguments(for: action, target: target),
              let tmux = TmuxBinaryLocator.locate(environment: environment)
        else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Reporting must always fail open and never disturb the agent session.
        }
    }
}

// MARK: - Scheme B Extension Sink: Unix Domain Socket (Daemon / Mobile Bridge)

/// Forwards every canonical state action as a single-line JSON envelope to a
/// local Unix domain socket (`$ATTACHE_HUB_SOCKET` or
/// `~/.config/attache/agent-hub.sock`) whenever a listener is present.
///
/// Cost when no resident daemon is running: one `stat(2)` syscall.
nonisolated struct UnixSocketAgentStateSink: AgentStateSink {
    let id = "unix-socket"
    let socketPath: String

    init(environment: [String: String]) {
        if let override = environment["ATTACHE_HUB_SOCKET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            self.socketPath = override
        } else {
            let home = environment["HOME"] ?? NSHomeDirectory()
            self.socketPath = AgentHubConstants.defaultSocketPath(home: home)
        }
    }

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    static func encodeEnvelope(
        action: AgentStateAction,
        target: AgentPaneTarget
    ) -> Data? {
        var dict: [String: Any] = [
            "v": AgentHubConstants.version,
            "pane": target.paneID,
        ]
        if let socket = target.tmuxSocketPath {
            dict["tmuxSocket"] = socket
        }

        switch action {
        case .ignore:
            return nil
        case let .register(kind, reason, timestamp, sessionID, cwd):
            dict["action"] = "register"
            dict["agent"] = kind
            dict["reason"] = reason
            dict["at"] = timestamp
            if let sessionID { dict["sessionId"] = sessionID }
            if let cwd { dict["cwd"] = cwd }
        case .transition(let snap):
            dict["action"] = "transition"
            dict["agent"] = snap.kind
            dict["state"] = snap.state.rawValue
            dict["reason"] = snap.reason
            dict["at"] = snap.timestamp
            if let sessionID = snap.sessionID { dict["sessionId"] = sessionID }
            if let cwd = snap.cwd { dict["cwd"] = cwd }
        case let .clear(kind, reason, timestamp):
            dict["action"] = "clear"
            dict["agent"] = kind
            dict["reason"] = reason
            dict["at"] = timestamp
        }

        guard var json = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        json.append(0x0A) // '\n'
        return json
    }

    func publish(_ action: AgentStateAction, target: AgentPaneTarget) {
        var st = stat()
        guard stat(socketPath, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFSOCK,
              let line = Self.encodeEnvelope(action: action, target: target)
        else { return }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000) // 50ms ceiling
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(socketPath.utf8CString)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard utf8.count <= maxLen else { return }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            let raw = UnsafeMutableRawPointer(sunPathPtr).assumingMemoryBound(to: CChar.self)
            for (idx, ch) in utf8.enumerated() {
                raw[idx] = ch
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return }

        line.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            _ = send(fd, base, buf.count, 0)
        }
    }
}

// MARK: - CLI Entry Coordinator

/// Parses `attache-agent-hub` CLI invocations, guarantees synchronous `stdout`
/// replies, runs `AgentStateReducer`, and fans the decision out to all sinks.
nonisolated enum AgentHubRunner {
    struct Invocation: Equatable {
        enum Mode: Equatable {
            case version
            case hook(agent: String, event: String)
        }
        let mode: Mode
    }

    static func parseArguments(_ arguments: [String]) -> Invocation? {
        var idx = 1
        var agent: String?
        var event: String?
        while idx < arguments.count {
            let arg = arguments[idx]
            switch arg {
            case "--version", "-v":
                return Invocation(mode: .version)
            case "--agent":
                guard idx + 1 < arguments.count else { return nil }
                agent = arguments[idx + 1]
                idx += 2
            case "--event":
                guard idx + 1 < arguments.count else { return nil }
                event = arguments[idx + 1]
                idx += 2
            default:
                idx += 1
            }
        }
        guard let agent, !agent.isEmpty, let event, !event.isEmpty else { return nil }
        return Invocation(mode: .hook(agent: agent, event: event))
    }

    /// Runs one CLI invocation end-to-end and always returns `0` for hook calls
    /// so a status hook can never fail an agent turn.
    static func main(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdinProvider: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
        stdoutWriter: (String) -> Void = { text in
            if let data = text.data(using: .utf8) {
                try? FileHandle.standardOutput.write(contentsOf: data)
            }
        },
        paneResolver: ([String: String]) -> AgentPaneTarget? = { env in
            AgentPaneResolver.resolve(environment: env)
        },
        paneOwnershipCheck: (AgentStateAction, AgentPaneTarget, [String: String]) -> Bool = { action, target, env in
            AgentPaneResolver.paneAllowsAction(action, target: target, environment: env)
        },
        sinksProvider: ([String: String]) -> [any AgentStateSink] = { env in
            [TmuxAgentStateSink(environment: env), UnixSocketAgentStateSink(environment: env)]
        }
    ) -> Int32 {
        guard let invocation = parseArguments(arguments) else {
            return 0
        }

        switch invocation.mode {
        case .version:
            stdoutWriter("attache-hook-version: \(AgentHubConstants.version)\n")
            return 0

        case let .hook(declaredAgent, rawEvent):
            // Emit the agent's synchronous reply even when running outside tmux
            // (`target == nil`), because `agy` parses stdout unconditionally.
            defer {
                if let reply = AgentHookReply.stdout(
                    declaredAgent: declaredAgent,
                    rawEvent: rawEvent
                ) {
                    stdoutWriter(reply)
                }
            }

            let stdinData = stdinProvider()
            guard let target = paneResolver(environment) else {
                return 0
            }

            let normalized = AgentEventNormalizer.normalize(
                declaredAgent: declaredAgent,
                rawEvent: rawEvent,
                stdinData: stdinData,
                environment: environment
            )
            let action = AgentStateReducer.reduce(normalized)
            guard case .ignore = action else {
                guard paneOwnershipCheck(action, target, environment) else {
                    return 0
                }
                for sink in sinksProvider(environment) {
                    sink.publish(action, target: target)
                }
                return 0
            }
            return 0
        }
    }
}
