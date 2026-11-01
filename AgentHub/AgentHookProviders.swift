//
//  AgentHookProviders.swift
//  Attache
//

import Foundation

/// Structural JSON equality independent of dictionary key ordering.
nonisolated enum AgentJSONStructural {
    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            true
        case let (x as [String: Any], y as [String: Any]):
            Set(x.keys) == Set(y.keys) && x.keys.allSatisfy { same(x[$0], y[$0]) }
        case let (x as [Any], y as [Any]):
            x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
        case let (x as String, y as String):
            x == y
        case let (x as NSNumber, y as NSNumber):
            // Distinguish Bool (`CFBoolean`) from numeric 0/1 (`CFNumber`).
            CFGetTypeID(x) == CFGetTypeID(y) && x == y
        default:
            false
        }
    }

    /// Quotes a filesystem path for POSIX `sh -c` only when it contains
    /// characters outside `[A-Za-z0-9/_.-]`, keeping standard home paths
    /// directly readable in the user's config files.
    static func shellPath(_ path: String) -> String {
        guard !path.isEmpty else { return "''" }
        let safe = path.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
                 UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "/"), UInt8(ascii: "_"),
                 UInt8(ascii: "."), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
        if safe { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Errors produced when inspecting or transforming an agent's hook config file.
nonisolated enum AgentHookConfigFailure: LocalizedError, Equatable {
    case unreadable(path: String, detail: String)
    case unexpectedShape(path: String, detail: String)
    case writeFailed(path: String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(path, detail):
            "Could not read \(path) — \(detail). Nothing was changed."
        case let .unexpectedShape(path, detail):
            "\(path) is not shaped the way Attaché expects — \(detail). Nothing was changed."
        case let .writeFailed(path, detail):
            "Could not write \(path) — \(detail)."
        }
    }
}

/// Layer 1 adapter: describes one coding agent's hook config location,
/// detection rule, and pure non-destructive JSON `merge` / `unmerge` /
/// `validateShape` transforms.
nonisolated protocol AgentHookProvider: Sendable {
    var kind: ManagedAgentKind { get }
    /// Whether this agent's config file can be deleted when `unmerge` leaves
    /// an empty root object (`true` only for files Attaché owns outright, such
    /// as `~/.grok/hooks/attache-status.json`; `false` for shared settings).
    var removeFileWhenEmpty: Bool { get }

    func configURL(home: URL, environment: [String: String]) -> URL
    func isAgentPresent(home: URL, environment: [String: String]) -> Bool

    func validateShape(_ root: [String: Any], path: String) throws
    func merge(into root: [String: Any], hubPath: String) -> [String: Any]
    func unmerge(from root: [String: Any], hubPath: String) -> [String: Any]
    func hasAnyInstalledEntry(in root: [String: Any], hubPath: String) -> Bool
    func previewDiff(from root: [String: Any], hubPath: String, displayPath: String) throws -> String
}

nonisolated extension AgentHookProvider {
    func isUpToDate(in root: [String: Any], hubPath: String) -> Bool {
        hasAnyInstalledEntry(in: root, hubPath: hubPath)
            && AgentJSONStructural.same(merge(into: root, hubPath: hubPath), root)
    }

    fileprivate static func executableOnPath(_ name: String, environment: [String: String]) -> Bool {
        let searchPaths = (environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return searchPaths.contains { dir in
            guard !dir.isEmpty else { return false }
            let candidate = (dir as NSString).appendingPathComponent(name)
            return FileManager.default.isExecutableFile(atPath: candidate)
        }
    }
}

// MARK: - Matcher-Group Shared Helpers (Claude Code & Grok)

/// Shared transform for agents using `{ "hooks": { "<Event>": [ { "matcher"?, "hooks": [Handler] } ] } }`.
nonisolated enum MatcherGroupHookTransform {
    struct EventSpec: Sendable {
        let event: String
        let matcher: String?
        let eventArg: String
    }

    static func command(hubPath: String, agent: ManagedAgentKind, eventArg: String) -> String {
        "\(AgentJSONStructural.shellPath(hubPath)) --agent \(agent.rawValue) --event \(eventArg) 2>/dev/null || true"
    }

    static func hookGroup(
        hubPath: String,
        agent: ManagedAgentKind,
        spec: EventSpec
    ) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": command(hubPath: hubPath, agent: agent, eventArg: spec.eventArg),
            ]],
        ]
        if let matcher = spec.matcher {
            group["matcher"] = matcher
        }
        return group
    }

    static func isOurs(
        _ entry: [String: Any],
        hubPath: String,
        agent: ManagedAgentKind,
        recognisesLegacyClaudeScript: Bool
    ) -> Bool {
        guard let cmd = entry["command"] as? String else { return false }
        if cmd.contains(hubPath) || cmd.contains(AgentJSONStructural.shellPath(hubPath)) {
            return true
        }
        if cmd.contains("\(AgentHubConstants.executableName) --agent \(agent.rawValue)") {
            return true
        }
        if recognisesLegacyClaudeScript, cmd.contains(AgentHubConstants.legacyClaudeScriptSuffix) {
            return true
        }
        return false
    }

    static func validateShape(_ root: [String: Any], path: String) throws {
        guard let hooksValue = root["hooks"] else { return }
        guard let hooks = hooksValue as? [String: Any] else {
            throw AgentHookConfigFailure.unexpectedShape(
                path: path, detail: "`hooks` is not an object"
            )
        }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else {
                throw AgentHookConfigFailure.unexpectedShape(
                    path: path, detail: "`hooks.\(event)` is not a list"
                )
            }
            for item in groups {
                guard let group = item as? [String: Any] else {
                    throw AgentHookConfigFailure.unexpectedShape(
                        path: path, detail: "`hooks.\(event)` holds something that is not an object"
                    )
                }
                if let inner = group["hooks"] {
                    guard let entries = inner as? [Any],
                          entries.allSatisfy({ $0 is [String: Any] })
                    else {
                        throw AgentHookConfigFailure.unexpectedShape(
                            path: path,
                            detail: "`hooks.\(event)` has a `hooks` field that is not a list of objects"
                        )
                    }
                }
            }
        }
    }

    static func hasAnyInstalledEntry(
        in root: [String: Any],
        hubPath: String,
        agent: ManagedAgentKind,
        recognisesLegacyClaudeScript: Bool
    ) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else { continue }
                if entries.contains(where: {
                    isOurs($0, hubPath: hubPath, agent: agent,
                           recognisesLegacyClaudeScript: recognisesLegacyClaudeScript)
                }) {
                    return true
                }
            }
        }
        return false
    }

    static func merge(
        into root: [String: Any],
        hubPath: String,
        agent: ManagedAgentKind,
        specs: [EventSpec],
        recognisesLegacyClaudeScript: Bool
    ) -> [String: Any] {
        var cleaned = unmerge(
            from: root,
            hubPath: hubPath,
            agent: agent,
            recognisesLegacyClaudeScript: recognisesLegacyClaudeScript
        )
        var hooks = (cleaned["hooks"] as? [String: Any]) ?? [:]
        for spec in specs {
            var groups = (hooks[spec.event] as? [[String: Any]]) ?? []
            groups.append(hookGroup(hubPath: hubPath, agent: agent, spec: spec))
            hooks[spec.event] = groups
        }
        cleaned["hooks"] = hooks
        return cleaned
    }

    static func unmerge(
        from root: [String: Any],
        hubPath: String,
        agent: ManagedAgentKind,
        recognisesLegacyClaudeScript: Bool
    ) -> [String: Any] {
        var result = root
        guard var hooks = result["hooks"] as? [String: Any] else { return result }
        // Iterate every event key present in the file rather than only current
        // `specs`, so an event retired in a future version is still cleaned up.
        for event in Array(hooks.keys) {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                guard var entries = group["hooks"] as? [[String: Any]] else { return group }
                entries.removeAll {
                    isOurs($0, hubPath: hubPath, agent: agent,
                           recognisesLegacyClaudeScript: recognisesLegacyClaudeScript)
                }
                guard !entries.isEmpty else { return nil }
                var kept = group
                kept["hooks"] = entries
                return kept
            }
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }
        if hooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = hooks
        }
        return result
    }

    static func previewDiff(
        from root: [String: Any],
        hubPath: String,
        agent: ManagedAgentKind,
        specs: [EventSpec],
        recognisesLegacyClaudeScript: Bool,
        displayPath: String
    ) throws -> String {
        guard !AgentJSONStructural.same(
            merge(
                into: root, hubPath: hubPath, agent: agent,
                specs: specs, recognisesLegacyClaudeScript: recognisesLegacyClaudeScript
            ),
            root
        ) else { return "" }

        var removals = [String]()
        if let hooks = root["hooks"] as? [String: Any] {
            for (event, value) in hooks.sorted(by: { $0.key < $1.key }) {
                guard let groups = value as? [[String: Any]] else { continue }
                for group in groups {
                    guard let entries = group["hooks"] as? [[String: Any]] else { continue }
                    for entry in entries where isOurs(
                        entry, hubPath: hubPath, agent: agent,
                        recognisesLegacyClaudeScript: recognisesLegacyClaudeScript
                    ) {
                        let matcher = (group["matcher"] as? String).map { " [\($0)]" } ?? ""
                        removals.append("  \(event)\(matcher)")
                    }
                }
            }
        }

        var additions = [String: Any]()
        for spec in specs {
            var groups = (additions[spec.event] as? [[String: Any]]) ?? []
            groups.append(hookGroup(hubPath: hubPath, agent: agent, spec: spec))
            additions[spec.event] = groups
        }

        var lines = "[\(agent.displayName) — \(displayPath)]\n"
        if !removals.isEmpty {
            lines += "Removed first (previous Attaché hook entries):\n"
            lines += removals.joined(separator: "\n") + "\n\nThen added:\n"
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["hooks": additions],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        lines += String(decoding: data, as: UTF8.self)
        return lines
    }
}

// MARK: - 1. Claude Code Provider (`~/.claude/settings.json`)

nonisolated struct ClaudeHookProvider: AgentHookProvider {
    let kind: ManagedAgentKind = .claude
    let removeFileWhenEmpty = false

    static let specs: [MatcherGroupHookTransform.EventSpec] = [
        .init(event: "SessionStart", matcher: nil, eventArg: "SessionStart"),
        .init(event: "UserPromptSubmit", matcher: nil, eventArg: "UserPromptSubmit"),
        .init(event: "PreToolUse", matcher: nil, eventArg: "PreToolUse"),
        .init(event: "PostToolUse", matcher: nil, eventArg: "PostToolUse"),
        .init(event: "PostToolUseFailure", matcher: nil, eventArg: "PostToolUseFailure"),
        .init(
            event: "Notification",
            matcher: "permission_prompt|elicitation_dialog|agent_needs_input",
            eventArg: "Notification:blocked"
        ),
        .init(event: "Notification", matcher: "idle_prompt", eventArg: "Notification:idle"),
        .init(event: "PermissionRequest", matcher: nil, eventArg: "PermissionRequest"),
        .init(event: "Stop", matcher: nil, eventArg: "Stop"),
        // Fired instead of `Stop` when a Claude turn terminates on an API error,
        // rate limit, or dropped connection (aligned with cmux).
        .init(event: "StopFailure", matcher: nil, eventArg: "StopFailure"),
        .init(event: "SessionEnd", matcher: nil, eventArg: "SessionEnd"),
    ]

    func configURL(home: URL, environment: [String: String] = [:]) -> URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    func isAgentPresent(home: URL, environment: [String: String]) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
            || Self.executableOnPath("claude", environment: environment)
    }

    func validateShape(_ root: [String: Any], path: String) throws {
        try MatcherGroupHookTransform.validateShape(root, path: path)
    }

    func merge(into root: [String: Any], hubPath: String) -> [String: Any] {
        MatcherGroupHookTransform.merge(
            into: root,
            hubPath: hubPath,
            agent: .claude,
            specs: Self.specs,
            recognisesLegacyClaudeScript: true
        )
    }

    func unmerge(from root: [String: Any], hubPath: String) -> [String: Any] {
        MatcherGroupHookTransform.unmerge(
            from: root,
            hubPath: hubPath,
            agent: .claude,
            recognisesLegacyClaudeScript: true
        )
    }

    func hasAnyInstalledEntry(in root: [String: Any], hubPath: String) -> Bool {
        MatcherGroupHookTransform.hasAnyInstalledEntry(
            in: root,
            hubPath: hubPath,
            agent: .claude,
            recognisesLegacyClaudeScript: true
        )
    }

    func previewDiff(from root: [String: Any], hubPath: String, displayPath: String) throws -> String {
        try MatcherGroupHookTransform.previewDiff(
            from: root,
            hubPath: hubPath,
            agent: .claude,
            specs: Self.specs,
            recognisesLegacyClaudeScript: true,
            displayPath: displayPath
        )
    }
}

// MARK: - 2. Antigravity Provider (`~/.gemini/config/hooks.json`)

/// Installs Attaché's lifecycle hooks into Antigravity CLI's
/// `~/.gemini/config/hooks.json` under the dedicated `"attache-status"` group.
///
/// Antigravity's schema (`docs/hooks.md` L15-107) differs from Claude's in two
/// load-bearing ways:
/// 1. Top-level keys are **named hook groups** (`"attache-status": { ... }`),
///    merged additively across groups. Owning one group key means user groups
///    (`"lint-checker"`, etc.) are never even traversed during `merge`/`unmerge`.
/// 2. Lifecycle events (`SessionStart`, `PreInvocation`, `Stop`) take flat
///    `[Handler]` arrays, while tool events (`PreToolUse`, `PostToolUse`) take
///    `[{ "matcher": "...", "hooks": [Handler] }]`, and every handler's `stdout`
///    is parsed synchronously as JSON.
nonisolated struct AntigravityHookProvider: AgentHookProvider {
    static let groupName = "attache-status"

    let kind: ManagedAgentKind = .agy
    let removeFileWhenEmpty = false

    func configURL(home: URL, environment: [String: String] = [:]) -> URL {
        home.appendingPathComponent(".gemini/config/hooks.json")
    }

    func isAgentPresent(home: URL, environment: [String: String]) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity-cli").path)
            || fm.fileExists(atPath: home.appendingPathComponent(".gemini/config").path)
            || Self.executableOnPath("agy", environment: environment)
    }

    func validateShape(_ root: [String: Any], path: String) throws {
        for (groupKey, value) in root {
            guard let group = value as? [String: Any] else {
                throw AgentHookConfigFailure.unexpectedShape(
                    path: path, detail: "hook group `\(groupKey)` is not an object"
                )
            }
            for (event, eventValue) in group {
                guard let entries = eventValue as? [Any],
                      entries.allSatisfy({ $0 is [String: Any] })
                else {
                    throw AgentHookConfigFailure.unexpectedShape(
                        path: path,
                        detail: "`\(groupKey).\(event)` is not a list of objects"
                    )
                }
            }
        }
    }

    static func command(hubPath: String, eventArg: String, fallbackJSON: String) -> String {
        let exe = AgentJSONStructural.shellPath(hubPath)
        return "\(exe) --agent agy --event \(eventArg) 2>/dev/null || printf '\(fallbackJSON)\\n'"
    }

    static func hookGroupObject(hubPath: String) -> [String: Any] {
        [
            "SessionStart": [[
                "type": "command",
                "command": command(hubPath: hubPath, eventArg: "SessionStart", fallbackJSON: "{}"),
            ]],
            "PreInvocation": [[
                "type": "command",
                "command": command(hubPath: hubPath, eventArg: "PreInvocation", fallbackJSON: "{}"),
            ]],
            "PreToolUse": [[
                "matcher": "ask_question",
                "hooks": [[
                    "type": "command",
                    "command": command(
                        hubPath: hubPath,
                        eventArg: "PreToolUse",
                        fallbackJSON: "{\"decision\":\"allow\"}"
                    ),
                ]],
            ]],
            "PostToolUse": [[
                "matcher": "ask_question",
                "hooks": [[
                    "type": "command",
                    "command": command(hubPath: hubPath, eventArg: "PostToolUse", fallbackJSON: "{}"),
                ]],
            ]],
            "Stop": [[
                "type": "command",
                "command": command(
                    hubPath: hubPath,
                    eventArg: "Stop",
                    fallbackJSON: "{\"decision\":\"stop\"}"
                ),
            ]],
        ]
    }

    func merge(into root: [String: Any], hubPath: String) -> [String: Any] {
        var next = root
        next[Self.groupName] = Self.hookGroupObject(hubPath: hubPath)
        return next
    }

    func unmerge(from root: [String: Any], hubPath: String) -> [String: Any] {
        var next = root
        next.removeValue(forKey: Self.groupName)
        return next
    }

    func hasAnyInstalledEntry(in root: [String: Any], hubPath: String) -> Bool {
        root[Self.groupName] != nil
    }

    func previewDiff(from root: [String: Any], hubPath: String, displayPath: String) throws -> String {
        let merged = merge(into: root, hubPath: hubPath)
        guard !AgentJSONStructural.same(merged, root) else { return "" }
        var lines = "[\(kind.displayName) — \(displayPath)]\n"
        if root[Self.groupName] != nil {
            lines += "Replaced first: `\(Self.groupName)` group\n\nThen written:\n"
        }
        let data = try JSONSerialization.data(
            withJSONObject: [Self.groupName: Self.hookGroupObject(hubPath: hubPath)],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        lines += String(decoding: data, as: UTF8.self)
        return lines
    }
}

// MARK: - 3. Grok Provider (`~/.grok/hooks/attache-status.json`)

/// Installs Attaché's lifecycle hooks into `~/.grok/hooks/attache-status.json`
/// (or `$GROK_HOME/hooks/attache-status.json`). Grok auto-discovers every
/// `*.json` file in that directory (`~/.grok/docs/user-guide/10-hooks.md` L68).
nonisolated struct GrokHookProvider: AgentHookProvider {
    let kind: ManagedAgentKind = .grok
    let removeFileWhenEmpty = true

    static let specs: [MatcherGroupHookTransform.EventSpec] = [
        .init(event: "SessionStart", matcher: nil, eventArg: "SessionStart"),
        .init(event: "UserPromptSubmit", matcher: nil, eventArg: "UserPromptSubmit"),
        .init(event: "PreToolUse", matcher: nil, eventArg: "PreToolUse"),
        .init(event: "PostToolUse", matcher: nil, eventArg: "PostToolUse"),
        .init(event: "PostToolUseFailure", matcher: nil, eventArg: "PostToolUseFailure"),
        .init(
            event: "Notification",
            matcher: "permission_prompt|elicitation_dialog|agent_needs_input",
            eventArg: "Notification:blocked"
        ),
        .init(event: "Notification", matcher: "idle_prompt", eventArg: "Notification:idle"),
        .init(event: "Stop", matcher: nil, eventArg: "Stop"),
        .init(event: "StopFailure", matcher: nil, eventArg: "StopFailure"),
        // Fired instead of `Stop` when a Grok turn is interrupted (Ctrl+C / Esc)
        // or a permission prompt is rejected (`10-hooks.md` L104).
        .init(event: "StopCancelled", matcher: nil, eventArg: "StopCancelled"),
        .init(event: "SessionEnd", matcher: nil, eventArg: "SessionEnd"),
    ]

    func configURL(home: URL, environment: [String: String] = [:]) -> URL {
        if let raw = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("hooks/attache-status.json")
        }
        return home.appendingPathComponent(".grok/hooks/attache-status.json")
    }

    func isAgentPresent(home: URL, environment: [String: String]) -> Bool {
        let grokRoot: URL
        if let raw = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            grokRoot = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            grokRoot = home.appendingPathComponent(".grok")
        }
        return FileManager.default.fileExists(atPath: grokRoot.path)
            || Self.executableOnPath("grok", environment: environment)
    }

    func validateShape(_ root: [String: Any], path: String) throws {
        try MatcherGroupHookTransform.validateShape(root, path: path)
    }

    func merge(into root: [String: Any], hubPath: String) -> [String: Any] {
        MatcherGroupHookTransform.merge(
            into: root,
            hubPath: hubPath,
            agent: .grok,
            specs: Self.specs,
            recognisesLegacyClaudeScript: false
        )
    }

    func unmerge(from root: [String: Any], hubPath: String) -> [String: Any] {
        MatcherGroupHookTransform.unmerge(
            from: root,
            hubPath: hubPath,
            agent: .grok,
            recognisesLegacyClaudeScript: false
        )
    }

    func hasAnyInstalledEntry(in root: [String: Any], hubPath: String) -> Bool {
        MatcherGroupHookTransform.hasAnyInstalledEntry(
            in: root,
            hubPath: hubPath,
            agent: .grok,
            recognisesLegacyClaudeScript: false
        )
    }

    func previewDiff(from root: [String: Any], hubPath: String, displayPath: String) throws -> String {
        try MatcherGroupHookTransform.previewDiff(
            from: root,
            hubPath: hubPath,
            agent: .grok,
            specs: Self.specs,
            recognisesLegacyClaudeScript: false,
            displayPath: displayPath
        )
    }
}

// MARK: - Provider Catalog & Portable Remote Script

nonisolated enum AgentHookCatalog {
    static let providers: [any AgentHookProvider] = [
        ClaudeHookProvider(),
        AntigravityHookProvider(),
        GrokHookProvider(),
    ]

    static func provider(for kind: ManagedAgentKind) -> any AgentHookProvider {
        switch kind {
        case .claude: ClaudeHookProvider()
        case .agy: AntigravityHookProvider()
        case .grok: GrokHookProvider()
        }
    }
}

/// Portable POSIX `/bin/sh` implementation of `attache-agent-hub` deployed to
/// remote SSH hosts (`RemoteAgentSetup`), where the remote machine may be Linux
/// or a different CPU architecture from the local macOS bundle.
///
/// Accepts the exact same `--agent <claude|agy|grok> --event <event>` CLI flags
/// as the compiled local `attache-agent-hub` binary.
nonisolated enum AgentHubPortableScript {
    static let version = AgentHubConstants.version

    static let script = #"""
    #!/bin/sh
    # attache-hook-version: 2
    # Attaché Agent Hub (portable POSIX sh receiver for remote SSH hosts).
    # Normalises Claude Code, Antigravity (agy), and Grok lifecycle hooks into
    # tmux pane options (@agent_state, @agent_kind, @agent_at, @agent_why).

    if [ "$1" = "--version" ] || [ "$1" = "-v" ]; then
        printf 'attache-hook-version: 2\n'
        exit 0
    fi

    agent=""
    raw_event=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --agent) agent="$2"; shift 2 ;;
            --event) raw_event="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    [ -n "$agent" ] && [ -n "$raw_event" ] || exit 0
    [ "$agent" = "antigravity" ] && agent="agy"

    base_event="${raw_event%%:*}"
    hint=""
    case "$raw_event" in *:*) hint="${raw_event#*:}" ;; esac

    emit_reply() {
        if [ "$agent" = "agy" ]; then
            case "$base_event" in
                PreToolUse) printf '{"decision":"allow"}\n' ;;
                Stop)       printf '{"decision":"stop"}\n' ;;
                *)          printf '{}\n' ;;
            esac
        fi
    }

    input=$(cat 2>/dev/null || true)

    PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

    if [ -z "$TMUX_PANE" ]; then
        emit_reply
        exit 0
    fi

    # Grok's Claude-compatibility loader also runs ~/.claude/settings.json.
    if [ "$agent" = "claude" ] && { [ -n "$GROK_HOOK_EVENT" ] || [ -n "$GROK_SESSION_ID" ]; }; then
        grok_hook="${GROK_HOME:-$HOME/.grok}/hooks/attache-status.json"
        if [ -f "$grok_hook" ]; then
            emit_reply
            exit 0
        fi
        agent="grok"
    fi

    [ -n "$CLAUDE_JOB_DIR" ] && { emit_reply; exit 0; }

    # Guard against a child agent spawned inside another agent's tool call
    # (`claude` running `agy -p`, or `agy` invoking `grok`) overwriting the
    # interactive parent agent's pane options via an inherited $TMUX_PANE.
    pane_cmd=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_current_command}' 2>/dev/null || true)
    pane_kind=""
    case "$pane_cmd" in
        claude) pane_kind="claude" ;;
        agy|antigravity) pane_kind="agy" ;;
        grok|grok-*) pane_kind="grok" ;;
        codex|aider|gemini|opencode) pane_kind="$pane_cmd" ;;
        [0-9]*.[0-9]*)
            if printf '%s' "$pane_cmd" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
                pane_kind="claude"
            fi ;;
    esac
    if [ -n "$pane_kind" ] && [ "$pane_kind" != "$agent" ]; then
        emit_reply
        exit 0
    fi

    compact=$(printf '%s' "$input" | tr -d ' \t\r\n')
    case "$compact" in
        *'"agent_id":"'*|*'"agentId":"'*|*'"subagentType":"'*|*'"subagent_type":"'*)
            case "$compact" in
                *'"agent_id":""'*|*'"agentId":""'*|*'"subagentType":""'*|*'"subagent_type":""'*) ;;
                *) emit_reply; exit 0 ;;
            esac ;;
    esac

    case "$base_event" in
        SubagentStart|SubagentStop|SubagentEnd|PreCompact|PostCompact)
            emit_reply; exit 0 ;;
    esac

    tool=$(printf '%s' "$input" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p; s/.*"toolName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    if [ -z "$tool" ]; then
        tool=$(printf '%s' "$input" | sed -n 's/.*"toolCall"[[:space:]]*:[[:space:]]*{[^}]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    fi
    notif=$(printf '%s' "$input" | sed -n 's/.*"notification_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p; s/.*"notificationType"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    if [ -z "$notif" ] && [ -n "$hint" ]; then
        case "$hint" in
            idle) notif="idle_prompt" ;;
            blocked) notif="permission_prompt" ;;
            *) notif="$hint" ;;
        esac
    fi

    now=$(date +%s)
    case "$base_event" in
        SessionStart)
            case "$compact" in *'"source":"compact"'*) emit_reply; exit 0 ;; esac
            tmux set-option -pu -t "$TMUX_PANE" @agent_state \; \
                 set-option -p  -t "$TMUX_PANE" @agent_kind "$agent" \; \
                 set-option -p  -t "$TMUX_PANE" @agent_at "$now" \; \
                 set-option -p  -t "$TMUX_PANE" @agent_why "SessionStart" 2>/dev/null
            emit_reply; exit 0 ;;
        SessionEnd)
            tmux set-option -pu -t "$TMUX_PANE" @agent_state \; \
                 set-option -pu -t "$TMUX_PANE" @agent_kind \; \
                 set-option -pu -t "$TMUX_PANE" @agent_at \; \
                 set-option -pu -t "$TMUX_PANE" @agent_why 2>/dev/null
            emit_reply; exit 0 ;;
        UserPromptSubmit|PreInvocation|PostToolUse|PostToolUseFailure|PostInvocation)
            state="working"; why="$base_event" ;;
        PreToolUse)
            tool_lc=$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')
            case "$tool_lc" in
                askuserquestion|askquestion|ask_user_question|ask_question|exitplanmode|exit_plan_mode)
                    state="needs-input" ;;
                *) state="working" ;;
            esac
            if [ -n "$tool" ]; then why="PreToolUse:$tool"; else why="PreToolUse"; fi ;;
        PermissionRequest)
            state="needs-input"; why="PermissionRequest" ;;
        Notification)
            case "$notif" in
                idle_prompt) state="done"; why="Notification:idle_prompt" ;;
                permission_prompt|elicitation_dialog|agent_needs_input)
                    state="needs-input"; why="Notification:$notif" ;;
                *) emit_reply; exit 0 ;;
            esac ;;
        Stop|StopFailure|StopCancelled|turn-completion)
            state="done"; why="$base_event" ;;
        *)
            emit_reply; exit 0 ;;
    esac

    tmux set-option -p -t "$TMUX_PANE" @agent_state "$state" \; \
         set-option -p -t "$TMUX_PANE" @agent_kind  "$agent" \; \
         set-option -p -t "$TMUX_PANE" @agent_at    "$now" \; \
         set-option -p -t "$TMUX_PANE" @agent_why   "$why" 2>/dev/null

    emit_reply
    exit 0
    """#
}
