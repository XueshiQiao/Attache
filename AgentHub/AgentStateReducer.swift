//
//  AgentStateReducer.swift
//  Attache
//

import Foundation

/// Synchronous `stdout` contract each agent's hook runner expects before
/// letting its turn proceed.
nonisolated enum AgentHookReply {
    /// Exact bytes `attache-agent-hub` must write to `stdout` for the invoking
    /// agent, or `nil` when empty `stdout` + exit `0` is passive allow.
    static func stdout(declaredAgent: String, rawEvent: String) -> String? {
        let baseEvent = rawEvent.split(separator: ":", maxSplits: 1).first.map(String.init) ?? rawEvent
        switch declaredAgent {
        case ManagedAgentKind.agy.rawValue, "antigravity":
            // Antigravity (`agy`) parses stdout synchronously with protojson on
            // every hook call (`docs/hooks.md` L139-143, L199, L397):
            // - `PreToolUse` requires `"decision"` (`"allow"` passes through).
            // - `Stop` requires `"decision"` (anything != `"continue"` stops).
            // - All other lifecycle hooks expect a valid JSON object `{}`.
            switch baseEvent {
            case "PreToolUse":
                return "{\"decision\":\"allow\"}\n"
            case "Stop":
                return "{\"decision\":\"stop\"}\n"
            default:
                return "{}\n"
            }
        default:
            return nil
        }
    }
}

/// Translates agent-specific hook arguments, stdin JSON, and environment
/// variables into a provider-neutral `NormalizedAgentEvent`.
nonisolated enum AgentEventNormalizer {
    static func normalize(
        declaredAgent: String,
        rawEvent: String,
        stdinData: Data,
        environment: [String: String],
        now: Int64 = Int64(Date().timeIntervalSince1970),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> NormalizedAgentEvent {
        let parts = rawEvent.split(separator: ":", maxSplits: 1).map(String.init)
        let cliEvent = parts.first ?? rawEvent
        let cliHint = parts.count > 1 ? parts[1] : nil

        let payload: [String: Any]
        if !stdinData.isEmpty,
           let parsed = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any]
        {
            payload = parsed
        } else {
            payload = [:]
        }

        // Grok's Claude-compatibility layer loads `~/.claude/settings.json` by
        // default (`~/.grok/docs/user-guide/10-hooks.md` L69) and exports
        // `GROK_HOOK_EVENT` / `GROK_SESSION_ID` (`10-hooks.md` L184). When our
        // native `~/.grok/hooks/attache-status.json` is also present, drop the
        // compatibility call so hooks never fire twice; when absent, reclassify
        // as `grok` so a Grok pane is never stamped `@agent_kind=claude`.
        var agentKind = declaredAgent == "antigravity" ? "agy" : declaredAgent
        var isGrokCompatDuplicate = false
        let isGrokCaller = nonEmpty(environment["GROK_HOOK_EVENT"]) != nil
            || nonEmpty(environment["GROK_SESSION_ID"]) != nil
        if agentKind == ManagedAgentKind.claude.rawValue, isGrokCaller {
            let grokHookPath = resolveGrokHookPath(environment: environment)
            if let grokHookPath, fileExists(grokHookPath) {
                isGrokCompatDuplicate = true
            } else {
                agentKind = ManagedAgentKind.grok.rawValue
            }
        }

        let payloadEvent = nonEmpty(payload["hook_event_name"] as? String)
            ?? nonEmpty(payload["hookEventName"] as? String)
        let eventName = canonicalEventName(cliEvent: cliEvent, payloadEvent: payloadEvent)

        // Payload `notification_type` takes precedence over the CLI `:blocked`
        // / `:idle` matcher hint so an agent build that ever ignores matchers
        // cannot misreport `idle_prompt` as `needs-input`.
        var notificationType = nonEmpty(payload["notification_type"] as? String)
            ?? nonEmpty(payload["notificationType"] as? String)
        if notificationType == nil, let cliHint {
            switch cliHint {
            case "idle": notificationType = "idle_prompt"
            case "blocked": notificationType = "permission_prompt"
            default: notificationType = cliHint
            }
        }

        let toolName = nonEmpty(payload["tool_name"] as? String)
            ?? nonEmpty(payload["toolName"] as? String)
            ?? nonEmpty((payload["toolCall"] as? [String: Any])?["name"] as? String)

        let source = nonEmpty(payload["source"] as? String)

        let hasSubagentID = nonEmpty(payload["agent_id"] as? String) != nil
            || nonEmpty(payload["agentId"] as? String) != nil
            || nonEmpty(payload["subagentType"] as? String) != nil
            || nonEmpty(payload["subagent_type"] as? String) != nil
        let isSubagentEvent = eventName == "SubagentStart"
            || eventName == "SubagentStop"
            || eventName == "SubagentEnd"

        let isBackgroundWorker = nonEmpty(environment["CLAUDE_JOB_DIR"]) != nil

        let sessionID = nonEmpty(payload["session_id"] as? String)
            ?? nonEmpty(payload["sessionId"] as? String)
            ?? nonEmpty(payload["conversationId"] as? String)
            ?? nonEmpty(environment["GROK_SESSION_ID"])

        let cwd = nonEmpty(payload["cwd"] as? String)
            ?? nonEmpty(payload["workspaceRoot"] as? String)
            ?? (payload["workspacePaths"] as? [String])?.compactMap(nonEmpty).first
            ?? nonEmpty(environment["GROK_WORKSPACE_ROOT"])

        return NormalizedAgentEvent(
            agentKind: agentKind,
            eventName: eventName,
            notificationType: notificationType,
            toolName: toolName,
            source: source,
            isSubagent: hasSubagentID || isSubagentEvent,
            isBackgroundWorker: isBackgroundWorker,
            isGrokCompatDuplicate: isGrokCompatDuplicate,
            sessionID: sessionID,
            cwd: cwd,
            timestamp: now
        )
    }

    static func resolveGrokHookPath(environment: [String: String]) -> String? {
        if let grokHome = nonEmpty(environment["GROK_HOME"]) {
            return (grokHome as NSString).appendingPathComponent("hooks/attache-status.json")
        }
        if let home = nonEmpty(environment["HOME"]) {
            return (home as NSString).appendingPathComponent(".grok/hooks/attache-status.json")
        }
        return nil
    }

    private static func canonicalEventName(cliEvent: String, payloadEvent: String?) -> String {
        if !cliEvent.isEmpty { return cliEvent }
        guard let payloadEvent else { return "" }
        switch payloadEvent {
        case "session_start": return "SessionStart"
        case "user_prompt_submit": return "UserPromptSubmit"
        case "pre_tool_use": return "PreToolUse"
        case "post_tool_use": return "PostToolUse"
        case "post_tool_use_failure": return "PostToolUseFailure"
        case "permission_request": return "PermissionRequest"
        case "notification": return "Notification"
        case "stop": return "Stop"
        case "stop_failure": return "StopFailure"
        case "stop_cancelled", "stop_canceled": return "StopCancelled"
        case "session_end": return "SessionEnd"
        case "subagent_start": return "SubagentStart"
        case "subagent_stop", "subagent_end": return "SubagentStop"
        case "pre_compact": return "PreCompact"
        case "post_compact": return "PostCompact"
        default: return payloadEvent
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// Centralized, client-agnostic state machine deciding the authoritative agent
/// state from any normalised event.
nonisolated enum AgentStateReducer {
    /// Tool names that block on explicit user answers rather than doing
    /// autonomous work (`AskUserQuestion` / `ExitPlanMode` in Claude & Grok,
    /// `ask_question` in Antigravity).
    private static let interactiveQuestionTools: Set<String> = [
        "askuserquestion",
        "askquestion",
        "ask_user_question",
        "ask_question",
        "exitplanmode",
        "exit_plan_mode",
    ]

    private static let blockingNotifications: Set<String> = [
        "permission_prompt",
        "elicitation_dialog",
        "agent_needs_input",
    ]

    static func reduce(_ event: NormalizedAgentEvent) -> AgentStateAction {
        if event.isGrokCompatDuplicate {
            return .ignore(reason: "grok-compat-duplicate")
        }
        if event.isSubagent {
            return .ignore(reason: "subagent")
        }
        if event.isBackgroundWorker {
            return .ignore(reason: "background-worker")
        }

        switch event.eventName {
        case "PreCompact", "PostCompact":
            return .ignore(reason: "compact")

        case "SessionStart":
            if event.source == "compact" {
                return .ignore(reason: "compact")
            }
            // Register presence and clear stale `@agent_state` from any earlier
            // session in this pane, without falsely claiming `working` before
            // the user submits a prompt (aligned with cmux & workmux).
            return .register(
                kind: event.agentKind,
                reason: "SessionStart",
                timestamp: event.timestamp,
                sessionID: event.sessionID,
                cwd: event.cwd
            )

        case "UserPromptSubmit", "PreInvocation":
            return transition(event, to: .working, reason: event.eventName)

        case "PreToolUse":
            if let tool = event.toolName,
               interactiveQuestionTools.contains(tool.lowercased())
            {
                return transition(event, to: .needsInput, reason: "PreToolUse:\(tool)")
            }
            let reason = event.toolName.map { "PreToolUse:\($0)" } ?? "PreToolUse"
            return transition(event, to: .working, reason: reason)

        case "PostToolUse", "PostToolUseFailure", "PostInvocation":
            return transition(event, to: .working, reason: event.eventName)

        case "PermissionRequest":
            return transition(event, to: .needsInput, reason: "PermissionRequest")

        case "Notification":
            guard let kind = event.notificationType else {
                return .ignore(reason: "untyped-notification")
            }
            if kind == "idle_prompt" {
                return transition(event, to: .done, reason: "Notification:idle_prompt")
            }
            if blockingNotifications.contains(kind) {
                return transition(event, to: .needsInput, reason: "Notification:\(kind)")
            }
            // Passive notifications (`task_complete`, etc.) must not overwrite
            // `done` with `needs-input`.
            return .ignore(reason: "passive-notification:\(kind)")

        case "Stop", "StopFailure", "StopCancelled", "turn-completion":
            return transition(event, to: .done, reason: event.eventName)

        case "SessionEnd":
            return .clear(
                kind: event.agentKind,
                reason: "SessionEnd",
                timestamp: event.timestamp
            )

        default:
            return .ignore(reason: "unhandled:\(event.eventName)")
        }
    }

    private static func transition(
        _ event: NormalizedAgentEvent,
        to state: CanonicalAgentState,
        reason: String
    ) -> AgentStateAction {
        .transition(AgentStateSnapshot(
            kind: event.agentKind,
            state: state,
            reason: reason,
            timestamp: event.timestamp,
            sessionID: event.sessionID,
            cwd: event.cwd
        ))
    }
}
