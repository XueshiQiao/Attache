//
//  AgentHookInstaller.swift
//  TmuxGUI
//

import Foundation

/// Installs the Claude Code hook that reports agent state into tmux.
///
/// This is the only thing in the app that writes a file belonging to another
/// program, and that file is shared: on this machine it already carries hooks
/// for four other tools, plus `statusLine`, `permissions`, `enabledPlugins` and
/// more. So the rules here are not stylistic.
///
/// - **Back up first**, to a timestamped copy beside the original.
/// - **Preserve every key it does not recognise.** The merge is done on
///   `[String: Any]` and only `hooks.<event>` arrays are touched, by appending.
///   Rewriting the file from a typed model would silently drop everything the
///   model has no field for.
/// - **Idempotent.** Matched on the script path, so pressing the button twice
///   installs once.
/// - **Reversible.** Uninstall removes only entries naming our script.
/// - **Atomic.** Written to a temporary file and renamed, so an interrupted
///   write cannot leave a truncated settings file behind.
///
/// One thing it cannot preserve: **key order and formatting**. `JSONSerialization`
/// has no way to keep them, so the file comes back sorted and pretty-printed.
/// Nothing is lost and the backup holds the original, but the diff is the whole
/// file and the user is told so before anything is written.
enum AgentHookInstaller {
    /// Where Claude Code keeps its settings, and where the script goes.
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hooks/tmuxgui-agent-state.sh")
    }

    /// Which Claude Code event means which state.
    ///
    /// `SessionStart` reports `working` rather than `done`: the session exists
    /// because something is starting, and a fresh pane showing "finished" is a
    /// claim about a turn that never happened.
    /// Which Claude Code event means which state, and for `Notification`, which
    /// *kind* of notification.
    ///
    /// `SessionStart` reports `working` rather than `done`: the session exists
    /// because something is starting, and a fresh pane showing "finished" is a
    /// claim about a turn that never happened.
    ///
    /// **`Notification` is split, and getting that wrong was a real defect.**
    /// It is documented as firing for eight different things, and only some of
    /// them mean the agent is blocked. `idle_prompt` fires merely because
    /// nobody has typed for a while — so mapping the whole event to
    /// "needs you" turned every finished, idle session amber. Observed on this
    /// machine: three panes all reading `needs-input`, one of them a session
    /// that had just answered normally and was sitting at an empty prompt.
    ///
    /// The matcher is the documented way to tell them apart. `idle_prompt` maps
    /// to `done` — it is Claude Code saying "your turn", which is what a
    /// finished turn already means — and the genuinely blocked kinds keep
    /// `needs-input`. The completion kinds are not registered at all.
    static let events: [(event: String, matcher: String?, state: String)] = [
        ("SessionStart", nil, "working"),
        ("UserPromptSubmit", nil, "working"),
        ("PreToolUse", nil, "working"),
        ("PostToolUse", nil, "working"),
        ("Notification", "permission_prompt|elicitation_dialog|agent_needs_input", "needs-input"),
        ("Notification", "idle_prompt", "done"),
        ("PermissionRequest", nil, "needs-input"),
        ("Stop", nil, "done"),
        ("SessionEnd", nil, "clear"),
    ]

    enum Failure: LocalizedError {
        case unreadableSettings(String)
        case unexpectedShape(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadableSettings(let detail):
                "Could not read ~/.claude/settings.json — \(detail). Nothing was changed."
            case .unexpectedShape(let detail):
                "~/.claude/settings.json is not shaped the way this expects — \(detail)."
                    + " Nothing was changed."
            case .writeFailed(let detail):
                "Could not write the changes — \(detail)."
            }
        }
    }

    // MARK: - The script

    /// Written to `~/.claude/hooks/` rather than run from inside the app
    /// bundle, and kept readable, because it runs on every hook event of every
    /// Claude Code session on this machine. Somebody should be able to read
    /// exactly what that is without unpacking an app.
    static let script = #"""
    #!/bin/sh
    # TmuxGUI — reports the agent's state into tmux, where the sidebar reads it.
    #
    # Installed by TmuxGUI (Settings -> Behaviour -> Agent status). Remove it
    # there, or delete this file and its entries in ~/.claude/settings.json.
    #
    # $1 = working | needs-input | done | clear
    #
    # The state is written as a tmux *pane option*, so it belongs to tmux rather
    # than to any one program: `tmux show-options -p -t %N` prints it, and any
    # client attached to that server can read it.

    [ -n "$TMUX_PANE" ] || exit 0   # not running inside tmux; nothing to report to

    state="$1"
    input=$(cat)                    # Claude Code passes the hook payload on stdin
    compact=$(printf '%s' "$input" | tr -d ' \t\n')

    # **Events fired by a subagent are not the main agent's state.**
    #
    # This is the whole reason the badge used to sit on "working" while the
    # agent was in fact idle and waiting for the user: a background subagent
    # keeps making tool calls, each one fires PreToolUse/PostToolUse in the same
    # pane, and every one of them was being reported as the main agent working.
    # The payload carries `agent_id` exactly when the hook was fired by a
    # subagent, so those are dropped. Another agent-aware multiplexer's Claude
    # integration does the same thing for the same reason.
    case "$compact" in
        *'"agent_id":"'*) exit 0 ;;
    esac

    # Belt and braces for the notification split. The matcher in settings.json
    # is the documented mechanism, but if a build ever ignores it, an idle nudge
    # arriving as "needs-input" would turn every finished session amber — the
    # exact defect this split exists to fix. The payload names its own kind.
    if [ "$state" = needs-input ]; then
        case "$compact" in
            *'"idle_prompt"'*) state=done ;;
        esac
    fi

    # A `SessionStart` fired by context compaction happens **mid-turn**, not at
    # the start of a session, so it must not be read as one.
    #
    # Gated on the state this app maps `SessionStart` to, and on the event name,
    # rather than applied to every payload. Unconditionally, the same bytes
    # appearing anywhere in anything — a tool argument, a file being read, a
    # display-mode flag — would drop that event; on a `Stop` that swallows the
    # "done" transition and the pane keeps whatever it last showed.
    if [ "$state" = working ]; then
        case "$compact" in
            *'"hook_event_name":"SessionStart"'*)
                case "$compact" in
                    *'"source":"compact"'*) exit 0 ;;
                esac ;;
        esac
    fi

    # `SubagentStop` is a completion event for a subagent, not for the turn.
    # **Not reachable today**: no `SubagentStop` hook is registered, and a
    # payload's `hook_event_name` is always the key its command was registered
    # under. Kept rather than deleted so that registering it later cannot
    # silently start reporting a subagent's completion as the turn's.
    case "$compact" in
        *'"hook_event_name":"SubagentStop"'*) exit 0 ;;
    esac

    if [ "$state" = clear ]; then
        tmux set-option -pu -t "$TMUX_PANE" @agent_state 2>/dev/null
        tmux set-option -pu -t "$TMUX_PANE" @agent_kind  2>/dev/null
        tmux set-option -pu -t "$TMUX_PANE" @agent_at    2>/dev/null
        tmux set-option -pu -t "$TMUX_PANE" @agent_why   2>/dev/null
        exit 0
    fi

    # Which event produced this state, so a transition log can say *why* rather
    # than only *what*. The app cannot work this out on its own — it sees a pane
    # option change and nothing about the event behind it — and a log of states
    # with no causes cannot be checked against an intended state machine, which
    # is the only reason to keep one.
    #
    # Extracted with `sed` rather than a JSON parser because this runs on every
    # hook event of every session and must stay a few milliseconds. A payload
    # that does not match leaves `why` empty, which is honest.
    why=$(printf '%s' "$input" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    kind=$(printf '%s' "$input" | sed -n 's/.*"notification_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$kind" ] && why="$why:$kind"

    tmux set-option -p -t "$TMUX_PANE" @agent_state "$state" 2>/dev/null
    tmux set-option -p -t "$TMUX_PANE" @agent_kind  claude   2>/dev/null
    tmux set-option -p -t "$TMUX_PANE" @agent_at    "$(date +%s)" 2>/dev/null
    tmux set-option -p -t "$TMUX_PANE" @agent_why   "$why"    2>/dev/null

    # Always 0, and every tmux call silenced: a reporting hook that fails must
    # never be able to break the Claude Code session it is reporting on.
    exit 0
    """#

    // MARK: - Reading the current state

    /// Whether our hook is already registered for at least one event.
    static func isInstalled() -> Bool {
        guard let settings = try? loadSettings() else { return false }
        return !ourCommands(in: settings).isEmpty
    }

    /// Whether what is installed matches *this* version's definition.
    ///
    /// Distinct from `isInstalled`, and the distinction has a UI consequence:
    /// the button showed "Remove" the moment any of our entries existed, so
    /// somebody carrying a previous version's shape had no way to reach the
    /// upgrade at all — they would have had to guess that Remove-then-Install
    /// was the fix. The event list changes between versions; this is what makes
    /// that visible.
    static func isUpToDate() -> Bool {
        guard let settings = try? loadSettings() else { return false }
        return same(merge(intoSettings: settings), settings)
    }

    /// Order-independent structural comparison. `JSONSerialization` hands back
    /// dictionaries, so `==` is unavailable and comparing encoded bytes would
    /// fail on key order alone.
    private nonisolated static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (x as [String: Any], y as [String: Any]):
            Set(x.keys) == Set(y.keys) && x.keys.allSatisfy { same(x[$0], y[$0]) }
        case let (x as [Any], y as [Any]):
            x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
        case let (x as String, y as String): x == y
        case let (x as NSNumber, y as NSNumber): x == y
        default: false
        }
    }

    /// The exact JSON that would be added, for showing before anything is
    /// written. Not a summary — the thing itself.
    ///
    /// On an upgrade it also names what will be **removed** first, because
    /// installing is a sync: our previous entries go before the new ones
    /// arrive. A preview that showed only additions would be describing half
    /// of what the button does, which is the half that cannot lose anything.
    static func plannedAdditions() throws -> String {
        let settings = try loadSettings()

        var removals = [String]()
        if let hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks.sorted(by: { $0.key < $1.key }) {
                guard let groups = value as? [[String: Any]] else { continue }
                for group in groups {
                    guard let entries = group["hooks"] as? [[String: Any]] else { continue }
                    for entry in entries where isOurs(entry) {
                        let matcher = (group["matcher"] as? String).map { " [\($0)]" } ?? ""
                        removals.append("  \(event)\(matcher)")
                    }
                }
            }
        }

        var additions = [String: Any]()
        let pristine = unmerge(fromSettings: settings)
        for (event, matcher, state) in events
            where !hasOurHook(for: event, matcher: matcher, in: pristine)
        {
            var groups = (additions[event] as? [[String: Any]]) ?? []
            groups.append(hookGroup(state: state, matcher: matcher))
            additions[event] = groups
        }
        guard !additions.isEmpty || !removals.isEmpty else { return "" }

        var text = ""
        if !removals.isEmpty {
            text += "Removed first (this app's own entries, from a previous version):\n"
            text += removals.joined(separator: "\n")
            text += "\n\nThen added:\n"
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["hooks": additions],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return text + String(decoding: data, as: UTF8.self)
    }

    // MARK: - Install and uninstall

    /// Returns the path of the backup that was taken.
    @discardableResult
    static func install() throws -> URL {
        var settings = try loadSettings()
        // Before the script is written and before the backup is taken: a shape
        // we refuse to touch should leave the disk exactly as it was.
        try validateShape(settings)
        let readAt = settingsModified()
        try writeScript()
        let backup = try backUpSettings()

        // One path for both a first install and an upgrade — see `merge`.
        settings = merge(intoSettings: settings)

        try writeSettings(settings, readAt: readAt)
        TmuxLog.destructive(
            "installed the agent hook into \(settingsURL.path) — backup at \(backup.lastPathComponent)"
        )
        return backup
    }

    /// Returns the path of the backup that was taken.
    @discardableResult
    static func uninstall() throws -> URL {
        var settings = try loadSettings()
        try validateShape(settings)
        let readAt = settingsModified()
        let backup = try backUpSettings()

        // Through `unmerge` rather than a second copy of the same loop. Two
        // copies of "which entries are ours" is the pair that drifts.
        settings = unmerge(fromSettings: settings)

        try writeSettings(settings, readAt: readAt)
        // The script is left on disk on purpose. It is inert without the
        // settings entries, it is three lines to inspect, and deleting a file
        // out of another program's directory is not something to do quietly.
        TmuxLog.destructive(
            "removed the agent hook from \(settingsURL.path) — backup at \(backup.lastPathComponent)"
        )
        return backup
    }

    // MARK: - Shape

    /// One entry, in the shape Claude Code's settings use: an event maps to a
    /// list of groups, each holding a list of commands.
    private static func hookGroup(state: String, matcher: String?) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [["type": "command", "command": "\(scriptURL.path) \(state)"]],
        ]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    private nonisolated static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(scriptURL.path) == true
    }

    /// The matcher is part of the identity. `Notification` legitimately carries
    /// two of ours — one for the kinds that mean "blocked", one for the idle
    /// nudge — so "is ours already here" has to ask about the specific one.
    private static func hasOurHook(
        for event: String, matcher: String?, in settings: [String: Any]
    ) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]] else { return false }
        return groups.contains { group in
            guard (group["hooks"] as? [[String: Any]])?.contains(where: isOurs) == true
            else { return false }
            return (group["matcher"] as? String) == matcher
        }
    }

    private static func ourCommands(in settings: [String: Any]) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        return hooks.values.flatMap { value -> [String] in
            guard let groups = value as? [[String: Any]] else { return [] }
            return groups.flatMap { group -> [String] in
                guard let entries = group["hooks"] as? [[String: Any]] else { return [] }
                return entries.filter(isOurs).compactMap { $0["command"] as? String }
            }
        }
    }

    // MARK: - Files

    /// Exposed so a check tool can exercise the merge against a copy of a real
    /// settings file without touching the real one.
    /// Bring the file to exactly this version's definition.
    ///
    /// Ours are removed first and then re-added, rather than appended to. The
    /// event list changes between versions — the `Notification` split added a
    /// matcher and turned one entry into two — and appending would leave the
    /// previous version's entry behind, still firing, still mapping every
    /// notification to "needs you". That is worse than not upgrading at all,
    /// because the stale entry is the one that was wrong.
    ///
    /// Only entries naming our script are touched, so this is still an append
    /// as far as every other tool in the file is concerned.
    static func merge(intoSettings settings: [String: Any]) -> [String: Any] {
        var settings = unmerge(fromSettings: settings)
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        // No `hasOurHook` check: `unmerge` above removed every one of ours, so
        // there is nothing left for it to find.
        for (event, matcher, state) in events {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups.append(hookGroup(state: state, matcher: matcher))
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// The inverse, for the same reason.
    static func unmerge(fromSettings settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, _, _) in events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                guard var entries = group["hooks"] as? [[String: Any]] else { return group }
                entries.removeAll { isOurs($0) }
                guard !entries.isEmpty else { return nil }
                var kept = group
                kept["hooks"] = entries
                return kept
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return settings
    }

    /// Refuse to touch a `hooks` section shaped in a way this does not
    /// understand, rather than replacing it.
    ///
    /// `merge` reads each event with `as? [[String: Any]] ?? []`, and a Swift
    /// array cast is all-or-nothing: one entry of an unexpected type fails the
    /// whole cast, the default takes over, and the assignment that follows
    /// replaces that event's real contents with only our own. A future schema,
    /// or a hand-edited file, is enough. `Failure.unexpectedShape` already
    /// existed for exactly this stance and was only being applied to the top
    /// level; the nested shape is where it was actually needed.
    static func validateShape(_ settings: [String: Any]) throws {
        guard let hooksValue = settings["hooks"] else { return }
        guard let hooks = hooksValue as? [String: Any] else {
            throw Failure.unexpectedShape("`hooks` is not an object")
        }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else {
                throw Failure.unexpectedShape("`hooks.\(event)` is not a list")
            }
            guard groups.allSatisfy({ $0 is [String: Any] }) else {
                throw Failure.unexpectedShape(
                    "`hooks.\(event)` holds something that is not an object"
                )
            }
        }
    }

    // The four below are `static` rather than `private static` because
    // `AgentStatusLineInstaller` edits the same file and must not grow its own
    // copy of any of this. A second implementation of "back up first, resolve
    // the symlink, write atomically, refuse if somebody else wrote meanwhile"
    // is how one of them quietly stops taking a backup.
    static func loadSettings() throws -> [String: Any] {
        // An absent file is not an error: Claude Code creates it on demand and
        // installing into a machine that has never had one is legitimate.
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: settingsURL) } catch {
            throw Failure.unreadableSettings(error.localizedDescription)
        }
        guard !data.isEmpty else { return [:] }
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: data) } catch {
            throw Failure.unreadableSettings("it is not valid JSON — \(error.localizedDescription)")
        }
        guard let object = parsed as? [String: Any] else {
            throw Failure.unexpectedShape("the top level is not an object")
        }
        return object
    }

    /// The file the settings path actually names, following any symlink.
    ///
    /// This matters more than it looks. `~/.claude/settings.json` is exactly the
    /// kind of file people keep in a dotfiles repository and symlink into
    /// place — chezmoi, stow, yadm — and both halves of this class get it wrong
    /// without resolving first. Demonstrated on this machine:
    ///
    /// - `Data.write(options: .atomic)` writes a temporary file and renames it
    ///   over the destination, which **replaces the symlink with a regular
    ///   file**. The dotfiles repository keeps the old content, is no longer
    ///   what Claude Code reads, and nothing says so.
    /// - `FileManager.copyItem` on a symlink copies the *link*, so the "backup"
    ///   is a second pointer at the live file. Editing the target afterwards
    ///   changed the backup's content too — it was never a snapshot, which is
    ///   the one thing a backup has to be.
    ///
    /// So everything below works on the resolved path, and the backup is taken
    /// by copying bytes rather than by copying the file.
    static func resolvedSettingsURL() -> URL {
        settingsURL.resolvingSymlinksInPath()
    }

    static func backUpSettings() throws -> URL {
        let source = resolvedSettingsURL()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")

        // Beside the real file, not beside the symlink: a backup that lands in
        // a different directory from the thing it protects is one nobody finds.
        let directory = source.deletingLastPathComponent()
        var backup = directory.appendingPathComponent("settings.json.tmuxgui-backup-\(stamp)")

        guard FileManager.default.fileExists(atPath: source.path) else { return backup }

        // Never overwrite an existing backup. The stamp is only accurate to the
        // second, and Install followed by Uninstall inside one second would
        // otherwise delete the pre-install original and replace it with a copy
        // of the post-install state — destroying the only artifact that could
        // undo the change. A double-click on the button is enough to get there.
        var suffix = 2
        while FileManager.default.fileExists(atPath: backup.path), suffix < 100 {
            backup = directory.appendingPathComponent(
                "settings.json.tmuxgui-backup-\(stamp)-\(suffix)"
            )
            suffix += 1
        }

        do {
            // Bytes, not `copyItem`. See `resolvedSettingsURL`.
            let contents = try Data(contentsOf: source)
            try contents.write(to: backup, options: [.atomic])
        } catch {
            throw Failure.writeFailed("the backup could not be made — \(error.localizedDescription)")
        }
        return backup
    }

    /// The settings file's modification date, for noticing a write that landed
    /// between our read and our write.
    static func settingsModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: resolvedSettingsURL().path))?[
            .modificationDate
        ] as? Date
    }

    /// Read the settings, and hand back a modification stamp that is known to
    /// belong to the bytes that were read.
    ///
    /// **Reading first and stamping afterwards is a real window, not a
    /// theoretical one.** An edit that lands between the two becomes the
    /// recorded baseline, so `writeSettings` sees nothing newer and overwrites
    /// that edit with a snapshot taken before it. Stamping on both sides and
    /// insisting they agree closes it; a disagreement just means going round
    /// again, because somebody genuinely was writing.
    static func loadSettingsVerifying() throws -> ([String: Any], Date?) {
        for _ in 0 ..< 3 {
            let before = settingsModified()
            let settings = try loadSettings()
            let after = settingsModified()
            if before == after { return (settings, after) }
        }
        throw Failure.writeFailed(
            "~/.claude/settings.json kept changing while it was being read —"
                + " nothing was written. Close whatever is editing it and try again."
        )
    }

    static func writeSettings(_ settings: [String: Any], readAt: Date?) throws {
        // Somebody else wrote the file while we were working on it. Last write
        // wins would silently discard their change, and this is a file four
        // other tools have entries in — refusing costs a retry and clobbering
        // costs somebody their setup.
        // Any transition counts, including a file that did not exist when it
        // was read and does now: `readAt == nil` with a stamp on disk means
        // somebody created it in between, and writing over that is the same
        // loss as writing over an edit.
        let now = settingsModified()
        if now != readAt {
            throw Failure.writeFailed(
                "the file changed while this was being prepared — nothing was written."
                    + " Close whatever edited it and try again."
            )
        }

        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw Failure.writeFailed("the merged settings could not be encoded — \(error.localizedDescription)")
        }
        do {
            // `.atomic` for the temp-file-and-rename — a settings file truncated
            // by an interrupted write would take out four other tools' hooks
            // along with ours — but aimed at the **resolved** path, so a
            // symlinked config is written through rather than replaced.
            try data.write(to: resolvedSettingsURL(), options: [.atomic])
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    private static func writeScript() throws {
        let directory = scriptURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
            )
        } catch {
            throw Failure.writeFailed("the hook script could not be written — \(error.localizedDescription)")
        }
    }
}
