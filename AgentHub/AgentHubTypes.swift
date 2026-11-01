//
//  AgentHubTypes.swift
//  Attache
//

import Foundation

/// Constants shared between `attache-agent-hub` (the standalone host-side
/// receiver binary), `Attaché.app`, and `RemoteAgentSetup`.
nonisolated enum AgentHubConstants {
    /// Incremented whenever the hub's event table, reducer rules, or portable
    /// script changes in a way an already-installed host needs to pick up.
    static let version = 2

    static let executableName = "attache-agent-hub"

    /// Stable host path every installed hook invokes, independent of where
    /// `Attaché.app` was launched from (`/Applications`, `/tmp/dd`, etc.).
    static func installedExecutablePath(home: String) -> String {
        (home as NSString).appendingPathComponent(".config/attache/bin/\(executableName)")
    }

    static func installedExecutableURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".config/attache/bin/\(executableName)")
    }

    /// Optional Unix domain socket bound by a future resident `attache-daemon`
    /// (Scheme B — mobile push / WebSocket gateway). When absent on disk, the
    /// socket sink is a single `stat()` no-op.
    static func defaultSocketPath(home: String) -> String {
        (home as NSString).appendingPathComponent(".config/attache/agent-hub.sock")
    }

    /// Pre-v2 Claude-only hook script path, recognised during `unmerge` so an
    /// upgrade migrates `~/.claude/settings.json` cleanly without leaving the
    /// v1 entries firing alongside v2.
    static let legacyClaudeScriptSuffix = ".claude/hooks/tmuxgui-agent-state.sh"
}

/// First-class agents with declarative hook installation and hub normalisation.
nonisolated enum ManagedAgentKind: String, CaseIterable, Sendable, Equatable {
    case claude
    case agy
    case grok

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .agy: "Antigravity"
        case .grok: "Grok"
        }
    }
}

/// Canonical wire vocabulary written to `@agent_state` and emitted to
/// downstream sinks. Matches `AgentState` in the GUI client byte for byte.
nonisolated enum CanonicalAgentState: String, Sendable, Equatable {
    case working
    case needsInput = "needs-input"
    case done
}

/// Authoritative state produced by `AgentStateReducer` for a single transition.
nonisolated struct AgentStateSnapshot: Sendable, Equatable {
    let kind: String
    let state: CanonicalAgentState
    let reason: String
    let timestamp: Int64
    let sessionID: String?
    let cwd: String?
}

/// Decision emitted by `AgentStateReducer` after normalising one hook call.
nonisolated enum AgentStateAction: Sendable, Equatable {
    /// Session opened or reset: record `@agent_kind` and clear any leftover
    /// `@agent_state` without claiming `working` before a prompt is submitted.
    case register(kind: String, reason: String, timestamp: Int64, sessionID: String?, cwd: String?)
    /// Active lifecycle state transition (`working`, `needs-input`, `done`).
    case transition(AgentStateSnapshot)
    /// True session exit: remove `@agent_*` options from the pane.
    case clear(kind: String, reason: String, timestamp: Int64)
    /// Ignored noise (subagent tool calls, mid-turn compaction, duplicate).
    case ignore(reason: String)

    /// Canonical agent identifier associated with a state-mutating action.
    var agentKind: String? {
        switch self {
        case let .register(kind, _, _, _, _): kind
        case let .transition(snapshot): snapshot.kind
        case let .clear(kind, _, _): kind
        case .ignore: nil
        }
    }
}

/// Resolved tmux pane identity for a hook invocation.
nonisolated struct AgentPaneTarget: Sendable, Equatable {
    /// `%<digits>`, validated before passing to `tmux -t`.
    let paneID: String
    /// Socket path extracted from `$TMUX` (`<path>,<pid>,<idx>`), or nil when
    /// resolved via the default server's process-ancestry fallback.
    let tmuxSocketPath: String?

    static func isValidPaneID(_ candidate: String) -> Bool {
        guard candidate.first == "%", candidate.count >= 2 else { return false }
        return candidate.dropFirst().allSatisfy(\.isNumber)
    }
}

/// Provider-neutral representation of a raw hook invocation.
nonisolated struct NormalizedAgentEvent: Sendable, Equatable {
    var agentKind: String
    var eventName: String
    var notificationType: String?
    var toolName: String?
    var source: String?
    var isSubagent: Bool
    var isBackgroundWorker: Bool
    var isGrokCompatDuplicate: Bool
    var sessionID: String?
    var cwd: String?
    var timestamp: Int64
}

/// Maps `#{pane_current_command}` values and `@agent_kind` identifiers across
/// managed and passively-detected coding agents.
nonisolated enum AgentProcessCatalog {
    static let allKnownKinds: Set<String> = [
        "claude", "agy", "grok", "codex", "aider", "gemini", "opencode",
    ]

    private static let exactCommandToKind: [String: String] = [
        "claude": "claude",
        "agy": "agy",
        "antigravity": "agy",
        "grok": "grok",
        "codex": "codex",
        "aider": "aider",
        "gemini": "gemini",
        "opencode": "opencode",
    ]

    static func isAgentCommand(_ command: String) -> Bool {
        kind(ofCommand: command) != nil
    }

    static func kind(ofCommand command: String) -> String? {
        guard !command.isEmpty else { return nil }
        if let exact = exactCommandToKind[command] { return exact }
        // Measured on macOS (`p_comm` 15-byte cap): Grok's versioned binary
        // `grok-1.0.52-macos-arm64` reports `grok-1.0.52-mac`.
        if command.hasPrefix("grok-") { return "grok" }
        // Measured on Claude Code: `#{pane_current_command}` is its bare
        // semantic version (`2.1.308`), digits and dots only.
        if looksLikeVersion(command) { return "claude" }
        return nil
    }

    static func displayName(forKind kind: String) -> String {
        switch kind {
        case "claude": "Claude Code"
        case "agy", "antigravity": "Antigravity"
        case "grok": "Grok"
        case "codex": "Codex"
        case "aider": "Aider"
        case "gemini": "Gemini"
        case "opencode": "OpenCode"
        default: kind
        }
    }

    /// `N.N` or `N.N.N`, digits and dots only — tight so `python3.12` or `2.txt`
    /// never masquerades as Claude Code.
    static func looksLikeVersion(_ command: String) -> Bool {
        let parts = command.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }
}
