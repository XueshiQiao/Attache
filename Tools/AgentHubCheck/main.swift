//
//  main.swift
//  AgentHubCheck
//
//  Exercises `attache-agent-hub` end-to-end across all three architectural
//  layers defined in `docs/agent-hub-design.md`:
//
//    1. Synchronous `stdout` replies (`AgentHookReply`) — critical for `agy`.
//    2. Event normalisation & `AgentStateReducer` — subagents, compaction,
//       Grok's Claude-compatibility duplicate/reclassify handling, interactive
//       question tools (`AskUserQuestion`, `ExitPlanMode`, `ask_question`),
//       `StopFailure`, and `StopCancelled`.
//    3. Downstream sinks (`TmuxAgentStateSink` single-call batching,
//       `UnixSocketAgentStateSink` live `AF_UNIX` JSONL delivery) and an
//       isolated `tmux -L` end-to-end verification of both the native binary
//       runner and `AgentHubPortableScript`.
//
//  swiftc -O -o /tmp/agenthubcheck AgentHub/*.swift Tools/AgentHubCheck/main.swift \
//      && /tmp/agenthubcheck
//

import Darwin
import Foundation

private var failures = 0
private var total = 0

private func check(_ name: String, _ problem: @autoclosure () -> String?) {
    total += 1
    if let problem = problem() {
        failures += 1
        print("FAIL  \(name)\n      \(problem)")
    } else {
        print("ok    \(name)")
    }
}

private func expect<T: Equatable>(_ actual: T, _ wanted: T) -> String? {
    actual == wanted ? nil : "got \(actual), wanted \(wanted)"
}

private func reduce(
    agent: String,
    event: String,
    json: String = "",
    env: [String: String] = ["HOME": "/Users/test"],
    now: Int64 = 1_793_540_000,
    grokNativeHookInstalled: Bool = false
) -> AgentStateAction {
    let normalized = AgentEventNormalizer.normalize(
        declaredAgent: agent,
        rawEvent: event,
        stdinData: Data(json.utf8),
        environment: env,
        now: now,
        fileExists: { path in
            grokNativeHookInstalled && path.hasSuffix("hooks/attache-status.json")
        }
    )
    return AgentStateReducer.reduce(normalized)
}

// MARK: - 1. Synchronous stdout contracts

print("— synchronous stdout replies —")

check("claude and grok emit no stdout", {
    expect(AgentHookReply.stdout(declaredAgent: "claude", rawEvent: "PreToolUse"), nil)
        ?? expect(AgentHookReply.stdout(declaredAgent: "claude", rawEvent: "Stop"), nil)
        ?? expect(AgentHookReply.stdout(declaredAgent: "grok", rawEvent: "PreToolUse"), nil)
        ?? expect(AgentHookReply.stdout(declaredAgent: "grok", rawEvent: "StopCancelled"), nil)
}())

check("agy PreToolUse replies with allow decision JSON", {
    expect(
        AgentHookReply.stdout(declaredAgent: "agy", rawEvent: "PreToolUse"),
        "{\"decision\":\"allow\"}\n"
    )
}())

check("agy Stop replies with stop decision JSON", {
    expect(
        AgentHookReply.stdout(declaredAgent: "agy", rawEvent: "Stop"),
        "{\"decision\":\"stop\"}\n"
    )
}())

check("agy lifecycle events reply with empty JSON object", {
    for ev in ["SessionStart", "PreInvocation", "PostToolUse", "PostInvocation"] {
        if let err = expect(AgentHookReply.stdout(declaredAgent: "agy", rawEvent: ev), "{}\n") {
            return "\(ev): \(err)"
        }
    }
    return nil
}())

check("agy still emits valid JSON stdout even when running outside tmux", {
    var captured = ""
    let rc = AgentHubRunner.main(
        arguments: ["attache-agent-hub", "--agent", "agy", "--event", "PreToolUse"],
        environment: [:],
        stdinProvider: { Data(#"{"toolName":"ask_question"}"#.utf8) },
        stdoutWriter: { captured += $0 },
        paneResolver: { _ in nil },
        sinksProvider: { _ in [] }
    )
    return expect(rc, 0) ?? expect(captured, "{\"decision\":\"allow\"}\n")
}())

// MARK: - 2. Normalisation & Reducer Transitions

print("\n— centralized state reducer —")

check("SessionStart registers presence and clears stale working state", {
    let action = reduce(
        agent: "claude",
        event: "SessionStart",
        json: #"{"session_id":"s1","cwd":"/repo","source":"startup"}"#
    )
    return expect(
        action,
        .register(kind: "claude", reason: "SessionStart", timestamp: 1_793_540_000, sessionID: "s1", cwd: "/repo")
    )
}())

check("SessionStart during context compaction is ignored", {
    let action = reduce(
        agent: "claude",
        event: "SessionStart",
        json: #"{"source":"compact"}"#
    )
    return expect(action, .ignore(reason: "compact"))
}())

check("UserPromptSubmit (Claude/Grok) and PreInvocation (Antigravity) transition to working", {
    let claude = reduce(agent: "claude", event: "UserPromptSubmit")
    let grok = reduce(agent: "grok", event: "UserPromptSubmit")
    let agy = reduce(
        agent: "agy",
        event: "PreInvocation",
        json: #"{"conversationId":"c-42","workspacePaths":["/Users/test/Code/Attache"]}"#
    )
    return expect(
        claude,
        .transition(.init(kind: "claude", state: .working, reason: "UserPromptSubmit", timestamp: 1_793_540_000, sessionID: nil, cwd: nil))
    )
        ?? expect(
            grok,
            .transition(.init(kind: "grok", state: .working, reason: "UserPromptSubmit", timestamp: 1_793_540_000, sessionID: nil, cwd: nil))
        )
        ?? expect(
            agy,
            .transition(.init(kind: "agy", state: .working, reason: "PreInvocation", timestamp: 1_793_540_000, sessionID: "c-42", cwd: "/Users/test/Code/Attache"))
        )
}())

check("interactive question tools transition directly to needs-input across all agents", {
    let cases: [(String, String, String)] = [
        ("claude", #"{"tool_name":"AskUserQuestion"}"#, "PreToolUse:AskUserQuestion"),
        ("claude", #"{"tool_name":"ExitPlanMode"}"#, "PreToolUse:ExitPlanMode"),
        ("agy", #"{"toolName":"ask_question"}"#, "PreToolUse:ask_question"),
        ("grok", #"{"toolCall":{"name":"AskUserQuestion"}}"#, "PreToolUse:AskUserQuestion"),
    ]
    for (agent, payload, wantedReason) in cases {
        let action = reduce(agent: agent, event: "PreToolUse", json: payload)
        guard case .transition(let snap) = action else {
            return "\(agent) \(payload) did not transition: \(action)"
        }
        if let err = expect(snap.state, .needsInput) ?? expect(snap.reason, wantedReason) {
            return "\(agent): \(err)"
        }
    }
    return nil
}())

check("ordinary tool calls and PostToolUse transition to working", {
    let pre = reduce(agent: "claude", event: "PreToolUse", json: #"{"tool_name":"Bash"}"#)
    let post = reduce(agent: "agy", event: "PostToolUse", json: #"{"toolName":"ask_question"}"#)
    let fail = reduce(agent: "claude", event: "PostToolUseFailure")
    guard case .transition(let s1) = pre,
          case .transition(let s2) = post,
          case .transition(let s3) = fail
    else { return "expected transitions" }
    return expect(s1.state, .working)
        ?? expect(s1.reason, "PreToolUse:Bash")
        ?? expect(s2.state, .working)
        ?? expect(s3.state, .working)
}())

check("PermissionRequest and blocking notifications transition to needs-input", {
    let perm = reduce(agent: "claude", event: "PermissionRequest")
    let notif = reduce(
        agent: "claude",
        event: "Notification:blocked",
        json: #"{"notification_type":"elicitation_dialog"}"#
    )
    guard case .transition(let s1) = perm, case .transition(let s2) = notif else {
        return "expected transitions"
    }
    return expect(s1.state, .needsInput)
        ?? expect(s2.state, .needsInput)
        ?? expect(s2.reason, "Notification:elicitation_dialog")
}())

check("payload notification_type overrides CLI hint and ignores passive task_complete", {
    // Regression guard: if a runner ever invokes Notification:blocked with an
    // `idle_prompt` payload, payload truth wins (`done`, never `needs-input`).
    let idle = reduce(
        agent: "grok",
        event: "Notification:blocked",
        json: #"{"notification_type":"idle_prompt"}"#
    )
    let passive = reduce(
        agent: "grok",
        event: "Notification",
        json: #"{"notification_type":"task_complete"}"#
    )
    guard case .transition(let snap) = idle else { return "idle_prompt did not transition" }
    return expect(snap.state, .done)
        ?? expect(passive, .ignore(reason: "passive-notification:task_complete"))
}())

check("Stop, StopFailure, and StopCancelled all transition to done", {
    for (agent, ev) in [("claude", "Stop"), ("claude", "StopFailure"), ("agy", "Stop"), ("grok", "StopCancelled"), ("grok", "StopFailure")] {
        let action = reduce(agent: agent, event: ev)
        guard case .transition(let snap) = action else { return "\(agent) \(ev) failed" }
        if let err = expect(snap.state, .done) ?? expect(snap.reason, ev) {
            return "\(agent) \(ev): \(err)"
        }
    }
    return nil
}())

check("SessionEnd clears pane options", {
    expect(
        reduce(agent: "claude", event: "SessionEnd"),
        .clear(kind: "claude", reason: "SessionEnd", timestamp: 1_793_540_000)
    )
}())

check("subagents and background workers are filtered out", {
    let sub1 = reduce(agent: "claude", event: "Stop", json: #"{"agent_id":"sub-9"}"#)
    let sub2 = reduce(agent: "agy", event: "PreToolUse", json: #"{"subagentType":"research","toolName":"ask_question"}"#)
    let sub3 = reduce(agent: "grok", event: "SubagentStop")
    let bg = reduce(agent: "claude", event: "PreToolUse", env: ["HOME": "/Users/test", "CLAUDE_JOB_DIR": "/tmp/job1"])
    return expect(sub1, .ignore(reason: "subagent"))
        ?? expect(sub2, .ignore(reason: "subagent"))
        ?? expect(sub3, .ignore(reason: "subagent"))
        ?? expect(bg, .ignore(reason: "background-worker"))
}())

check("Grok Claude-compat call is dropped when native Grok hook exists, reclassified when absent", {
    let grokEnv = [
        "HOME": "/Users/test",
        "GROK_HOOK_EVENT": "SessionStart",
        "GROK_SESSION_ID": "grok-s1",
    ]
    let dropped = reduce(
        agent: "claude",
        event: "SessionStart",
        env: grokEnv,
        grokNativeHookInstalled: true
    )
    let reclassified = reduce(
        agent: "claude",
        event: "UserPromptSubmit",
        env: grokEnv,
        grokNativeHookInstalled: false
    )
    guard case .transition(let snap) = reclassified else {
        return "reclassified call did not transition: \(reclassified)"
    }
    return expect(dropped, .ignore(reason: "grok-compat-duplicate"))
        ?? expect(snap.kind, "grok")
        ?? expect(snap.sessionID, "grok-s1")
}())

// MARK: - 3. Pane Resolution & Sinks

print("\n— pane resolution & downstream sinks —")

check("ancestry walk finds owning pane across intermediate subshells and stops on cycles", {
    let panes: [Int32: String] = [100: "%7", 200: "%19"]
    let tree: [Int32: Int32] = [503: 502, 502: 501, 501: 200, 200: 1]
    let matched = AgentPaneResolver.matchAncestry(
        startPID: 503,
        paneByPID: panes,
        parentOf: { tree[$0] }
    )
    let cycle: [Int32: Int32] = [800: 801, 801: 800]
    let cyclic = AgentPaneResolver.matchAncestry(
        startPID: 800,
        paneByPID: panes,
        parentOf: { cycle[$0] }
    )
    return expect(matched, "%19") ?? expect(cyclic, nil)
}())

check("pane foreground ownership blocks cross-agent child clobbering while failing open on shells", {
    let cases: [(String, String, Bool)] = [
        // Matching interactive agents (including Claude semver p_comm & Grok truncated p_comm)
        ("claude", "2.1.308", true),
        ("claude", "claude", true),
        ("agy", "agy", true),
        ("antigravity", "agy", true),
        ("grok", "grok-1.0.52-mac", true),
        // Shells / wrappers / empty query failure fail open
        ("agy", "zsh", true),
        ("claude", "node", true),
        ("grok", "", true),
        // Cross-agent child subprocesses (`claude` -> `agy -p`, `agy` -> `grok`, `grok` -> `claude -p`)
        ("agy", "2.1.308", false),
        ("grok", "agy", false),
        ("claude", "grok-1.0.52-mac", false),
    ]
    for (actionKind, foregroundCmd, wanted) in cases {
        let actual = AgentPaneResolver.shouldPublishToPane(
            actionKind: actionKind,
            paneCurrentCommand: foregroundCmd
        )
        if let err = expect(actual, wanted) {
            return "\(actionKind) in `\(foregroundCmd)`: \(err)"
        }
    }
    return nil
}())

check("TmuxAgentStateSink batches all four pane options into one chained tmux command", {
    let target = AgentPaneTarget(paneID: "%42", tmuxSocketPath: "/tmp/tmux-test/sock")
    let args = TmuxAgentStateSink.tmuxArguments(
        for: .transition(.init(
            kind: "agy",
            state: .working,
            reason: "PreInvocation",
            timestamp: 1234,
            sessionID: nil,
            cwd: nil
        )),
        target: target
    )
    return expect(args, [
        "-S", "/tmp/tmux-test/sock",
        "set-option", "-p", "-t", "%42", "@agent_state", "working", ";",
        "set-option", "-p", "-t", "%42", "@agent_kind", "agy", ";",
        "set-option", "-p", "-t", "%42", "@agent_at", "1234", ";",
        "set-option", "-p", "-t", "%42", "@agent_why", "PreInvocation",
    ])
}())

check("TmuxAgentStateSink rejects malformed pane IDs", {
    let bad = AgentPaneTarget(paneID: "main:0.0", tmuxSocketPath: nil)
    return expect(
        TmuxAgentStateSink.tmuxArguments(
            for: .clear(kind: "claude", reason: "SessionEnd", timestamp: 1),
            target: bad
        ),
        nil
    )
}())

check("UnixSocketAgentStateSink delivers canonical JSONL envelope over AF_UNIX", {
    let sockPath = "/tmp/attache-hubcheck-\(getpid()).sock"
    unlink(sockPath)
    defer { unlink(sockPath) }

    let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenFD >= 0 else { return "socket() failed" }
    defer { close(listenFD) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(sockPath.utf8CString)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
        for (i, b) in bytes.enumerated() { raw[i] = b }
    }
    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0, listen(listenFD, 4) == 0 else {
        return "bind/listen failed on \(sockPath)"
    }

    let sink = UnixSocketAgentStateSink(socketPath: sockPath)
    let target = AgentPaneTarget(paneID: "%88", tmuxSocketPath: "/tmp/tmux-501/default")
    sink.publish(
        .transition(.init(
            kind: "agy",
            state: .needsInput,
            reason: "PreToolUse:ask_question",
            timestamp: 1_793_540_123,
            sessionID: "conv-1",
            cwd: "/Users/test/Code/Attache"
        )),
        target: target
    )

    let clientFD = accept(listenFD, nil, nil)
    guard clientFD >= 0 else { return "accept() failed" }
    defer { close(clientFD) }

    var buffer = [UInt8](repeating: 0, count: 2048)
    let n = read(clientFD, &buffer, buffer.count)
    guard n > 0 else { return "read() returned \(n)" }
    let text = String(decoding: buffer[..<n], as: UTF8.self)
    guard text.hasSuffix("\n"),
          let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { return "invalid JSONL: \(text)" }

    return expect(obj["v"] as? Int, AgentHubConstants.version)
        ?? expect(obj["pane"] as? String, "%88")
        ?? expect(obj["agent"] as? String, "agy")
        ?? expect(obj["action"] as? String, "transition")
        ?? expect(obj["state"] as? String, "needs-input")
        ?? expect(obj["reason"] as? String, "PreToolUse:ask_question")
        ?? expect(obj["sessionId"] as? String, "conv-1")
}())

// MARK: - 4. Isolated `tmux -L` End-to-End Check (Native + Portable Script)

print("\n— isolated tmux -L end-to-end —")

if let tmuxBin = TmuxBinaryLocator.locate(environment: ProcessInfo.processInfo.environment) {
    let label = "attache-hub-e2e-\(getpid())"

    func runTmux(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxBin)
        p.arguments = ["-L", label] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    defer {
        _ = runTmux(["kill-server"])
    }

    let (bootRC, bootInfo) = runTmux([
        "-f", "/dev/null", "new-session", "-d", "-P",
        "-F", "#{pane_id}\t#{socket_path}\t#{pane_pid}",
        "sleep 30",
    ])

    let cols = bootInfo.split(separator: "\t").map(String.init)
    if bootRC == 0, cols.count == 3, let panePID = Int32(cols[2]) {
        let paneID = cols[0]
        let socketPath = cols[1]
        let baseEnv: [String: String] = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/bin:/bin",
            "HOME": "/tmp/attache-fake-home-\(getpid())",
            "TMUX": "\(socketPath),99999,0",
            "TMUX_PANE": paneID,
        ]

        func readPaneOptions() -> String {
            runTmux([
                "display-message", "-p", "-t", paneID,
                "#{@agent_kind}|#{@agent_state}|#{@agent_why}",
            ]).1
        }

        check("e2e native hub: agy PreInvocation -> ask_question -> Stop writes options and JSON stdout", {
            var out1 = ""
            _ = AgentHubRunner.main(
                arguments: ["attache-agent-hub", "--agent", "agy", "--event", "PreInvocation"],
                environment: baseEnv,
                stdinProvider: { Data(#"{"conversationId":"c1"}"#.utf8) },
                stdoutWriter: { out1 += $0 }
            )
            if let err = expect(out1, "{}\n") ?? expect(readPaneOptions(), "agy|working|PreInvocation") {
                return err
            }

            var out2 = ""
            _ = AgentHubRunner.main(
                arguments: ["attache-agent-hub", "--agent", "agy", "--event", "PreToolUse"],
                environment: baseEnv,
                stdinProvider: { Data(#"{"toolName":"ask_question"}"#.utf8) },
                stdoutWriter: { out2 += $0 }
            )
            if let err = expect(out2, "{\"decision\":\"allow\"}\n")
                ?? expect(readPaneOptions(), "agy|needs-input|PreToolUse:ask_question")
            {
                return err
            }

            var out3 = ""
            _ = AgentHubRunner.main(
                arguments: ["attache-agent-hub", "--agent", "agy", "--event", "Stop"],
                environment: baseEnv,
                stdinProvider: { Data(#"{"stopReason":"USER_CANCELED"}"#.utf8) },
                stdoutWriter: { out3 += $0 }
            )
            return expect(out3, "{\"decision\":\"stop\"}\n")
                ?? expect(readPaneOptions(), "agy|done|Stop")
        }())

        check("e2e native hub: SessionStart clears leftover state without claiming working", {
            _ = AgentHubRunner.main(
                arguments: ["attache-agent-hub", "--agent", "claude", "--event", "SessionStart"],
                environment: baseEnv,
                stdinProvider: { Data(#"{"source":"startup"}"#.utf8) },
                stdoutWriter: { _ in }
            )
            return expect(readPaneOptions(), "claude||SessionStart")
        }())

        check("e2e native hub: $TMUX_PANE-stripped fallback resolves pane via kernel PID ancestry", {
            var strippedEnv = baseEnv
            strippedEnv.removeValue(forKey: "TMUX_PANE")
            let resolved = AgentPaneResolver.resolve(environment: strippedEnv, startPID: panePID)
            return expect(resolved, AgentPaneTarget(paneID: paneID, tmuxSocketPath: socketPath))
        }())

        check("e2e portable POSIX script: grok lifecycle & SessionEnd cleanup match native hub", {
            let scriptPath = "/tmp/attache-portable-hub-\(getpid()).sh"
            try! Data(AgentHubPortableScript.script.utf8).write(to: URL(fileURLWithPath: scriptPath))
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            defer { try? FileManager.default.removeItem(atPath: scriptPath) }

            func runPortable(_ args: [String], stdin: String = "") -> String {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = [scriptPath] + args
                p.environment = baseEnv
                let inPipe = Pipe()
                let outPipe = Pipe()
                p.standardInput = inPipe
                p.standardOutput = outPipe
                p.standardError = FileHandle.nullDevice
                try! p.run()
                inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                try? inPipe.fileHandleForWriting.close()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(decoding: data, as: UTF8.self)
            }

            let ver = runPortable(["--version"])
            if let err = expect(ver, "attache-hook-version: \(AgentHubConstants.version)\n") {
                return err
            }
            _ = runPortable(["--agent", "grok", "--event", "UserPromptSubmit"])
            if let err = expect(readPaneOptions(), "grok|working|UserPromptSubmit") {
                return err
            }
            _ = runPortable(["--agent", "grok", "--event", "StopCancelled"])
            if let err = expect(readPaneOptions(), "grok|done|StopCancelled") {
                return err
            }
            _ = runPortable(["--agent", "grok", "--event", "SessionEnd"])
            return expect(readPaneOptions(), "||")
        }())

        check("e2e child-agent guard: headless agy/grok inside a Claude pane never clobbers @agent_*", {
            let fakeBinDir = "/tmp/attache-fake-claude-\(getpid())"
            try? FileManager.default.removeItem(atPath: fakeBinDir)
            try! FileManager.default.createDirectory(atPath: fakeBinDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: fakeBinDir) }

            // Compile a tiny sleeper binary named `2.1.308` on disk: Darwin sets
            // `pbi_comm` (which tmux reads for `#{pane_current_command}`) from
            // the Mach-O vnode's resolved filename rather than symlink argv[0].
            let fakeClaudeBin = "\(fakeBinDir)/2.1.308"
            let cc = Process()
            cc.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            cc.arguments = ["-x", "c", "-", "-o", fakeClaudeBin]
            let ccIn = Pipe()
            cc.standardInput = ccIn
            cc.standardOutput = FileHandle.nullDevice
            cc.standardError = FileHandle.nullDevice
            try! cc.run()
            ccIn.fileHandleForWriting.write(Data("#include <unistd.h>\nint main(void){sleep(30);return 0;}\n".utf8))
            try? ccIn.fileHandleForWriting.close()
            cc.waitUntilExit()
            guard cc.terminationStatus == 0 else {
                return "clang failed to build dummy 2.1.308 sleeper"
            }

            let (wRC, claudePaneID) = runTmux([
                "new-window", "-d", "-P", "-F", "#{pane_id}",
                "\(fakeClaudeBin) 30",
            ])
            guard wRC == 0, AgentPaneTarget.isValidPaneID(claudePaneID) else {
                return "failed to spawn fake claude window: rc=\(wRC) out=\(claudePaneID)"
            }

            // Wait briefly for `exec` so tmux sees `2.1.308` as `pane_current_command`.
            var observedCmd = ""
            for _ in 0 ..< 30 {
                observedCmd = runTmux([
                    "display-message", "-p", "-t", claudePaneID, "#{pane_current_command}",
                ]).1
                if observedCmd == "2.1.308" { break }
                usleep(10_000)
            }
            if let err = expect(observedCmd, "2.1.308") {
                return "pane_current_command did not settle: \(err)"
            }

            var claudeEnv = baseEnv
            claudeEnv["TMUX_PANE"] = claudePaneID

            func readClaudePane() -> String {
                runTmux([
                    "display-message", "-p", "-t", claudePaneID,
                    "#{@agent_kind}|#{@agent_state}|#{@agent_why}",
                ]).1
            }

            // 1. Parent Claude session enters `working`.
            _ = AgentHubRunner.main(
                arguments: ["attache-agent-hub", "--agent", "claude", "--event", "UserPromptSubmit"],
                environment: claudeEnv,
                stdinProvider: { Data() },
                stdoutWriter: { _ in }
            )
            if let err = expect(readClaudePane(), "claude|working|UserPromptSubmit") {
                return err
            }

            // 2. Child `agy -p` fires PreInvocation, PreToolUse, and Stop with
            //    inherited `TMUX_PANE`: stdout replies must still be valid JSON,
            //    while `%claudePaneID`'s `@agent_*` stays untouched.
            var agyOut = ""
            for (ev, payload) in [
                ("PreInvocation", #"{"conversationId":"sub-c1"}"#),
                ("PreToolUse", #"{"toolName":"ask_question"}"#),
                ("Stop", #"{"stopReason":"DONE"}"#),
            ] {
                _ = AgentHubRunner.main(
                    arguments: ["attache-agent-hub", "--agent", "agy", "--event", ev],
                    environment: claudeEnv,
                    stdinProvider: { Data(payload.utf8) },
                    stdoutWriter: { agyOut += $0 }
                )
            }
            if let err = expect(agyOut, "{}\n{\"decision\":\"allow\"}\n{\"decision\":\"stop\"}\n")
                ?? expect(readClaudePane(), "claude|working|UserPromptSubmit")
            {
                return err
            }

            // 3. Portable POSIX script invoked by a child `grok` (including
            //    `SessionEnd`) also leaves the parent Claude pane untouched.
            let scriptPath = "/tmp/attache-portable-guard-\(getpid()).sh"
            try! Data(AgentHubPortableScript.script.utf8).write(to: URL(fileURLWithPath: scriptPath))
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            defer { try? FileManager.default.removeItem(atPath: scriptPath) }

            for ev in ["UserPromptSubmit", "Stop", "SessionEnd"] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = [scriptPath, "--agent", "grok", "--event", ev]
                p.environment = claudeEnv
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try! p.run()
                p.waitUntilExit()
            }
            return expect(readClaudePane(), "claude|working|UserPromptSubmit")
        }())
    } else {
        check("isolated tmux server boot", "failed with rc=\(bootRC) info=\(bootInfo)")
    }
}

print("")
if failures == 0 {
    print("\(total) cases, all passed")
} else {
    print("\(failures) of \(total) cases FAILED")
    exit(1)
}
