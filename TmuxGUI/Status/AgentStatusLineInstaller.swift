//
//  AgentStatusLineInstaller.swift
//  TmuxGUI
//

import Foundation

/// Installs the wrapper that feeds the rail what a Claude Code session knows
/// about itself.
///
/// Claude Code hands a JSON object on stdin to whatever `statusLine.command`
/// names, and that object is the **only** place it publishes cost, context and
/// rate limits — the hook payloads `AgentHookInstaller` registers for carry a
/// session id, a working directory and a tool name, and nothing else. So this
/// is not a convenient route to those numbers, it is the route.
///
/// Everything about the design follows from one thing: **the status line is the
/// user's, not ours.** They chose it, they look at it all day, and a great many
/// of them chose something this app has never heard of. So:
///
/// - It **wraps** rather than replaces. Whatever was configured runs with the
///   same stdin and its output is printed byte for byte, exit status preserved.
///   The line in the terminal does not change. Nothing here knows or cares
///   whether it is wrapping coralline, ccstatusline, or a Python script.
/// - The wrapper **parses nothing**. Extracting fields in shell needs `jq` or
///   `python3`, and whichever it needed would be a machine where this silently
///   does not work. The whole object crosses as text and `AgentStats` reads it.
/// - The command it wrapped is recorded in a **plain file beside the script**,
///   in a format that says the difference between "there was no status line"
///   and "the recovery record is gone".
/// - A user with **no** status line is not left with a blank row. Measured
///   2026-07-29 on Claude Code 2.1.220: a `statusLine.command` that prints
///   nothing still costs a row. So the wrapper renders a minimal line in that
///   case rather than reporting silently.
///
/// **Three things here exist because a review found them, and each one could
/// have cost somebody their status line.** They are called out at their sites:
/// the recovery record distinguishing absent from empty; ownership matched on
/// the exact command rather than on a substring; and the wrapper reading that
/// record rather than executing it.
enum AgentStatusLineInstaller {
    static var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hooks/tmuxgui-statusline.sh")
    }

    /// Where the wrapped command is recorded. Deliberately its own file: the
    /// one thing a person is likely to want to change by hand is which status
    /// line runs inside, and that should not mean editing a script.
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hooks/tmuxgui-statusline.conf")
    }

    static var minimalURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hooks/tmuxgui-statusline-minimal.sh")
    }

    /// The command this app writes into `statusLine.command`.
    static var installedCommand: String { "sh \(scriptURL.path)" }

    enum Failure: LocalizedError {
        case unsupportedType(String)
        case notASingleLine
        case externallyModified(String)
        case recoveryUnavailable

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let type):
                "Your status line is of type “\(type)”, which this does not know how to"
                    + " wrap — only “command” status lines can be. Nothing was changed."
            case .notASingleLine:
                "Your status line command runs across more than one line, and this can only"
                    + " wrap a single-line command — wrapping it could not put it back"
                    + " exactly. Nothing was changed. Move it into a script and point"
                    + " statusLine.command at that instead."
            case .externallyModified(let command):
                "Your status line mentions this app's wrapper but is not the command this app"
                    + " writes — something else has changed it since:\n\n\(command)\n\n"
                    + "Nothing was changed, because putting our own command back would throw"
                    + " that away. Edit statusLine.command yourself if you want it replaced."
            case .recoveryUnavailable:
                "The record of which status line to put back is missing or unreadable"
                    + " (~/.claude/hooks/tmuxgui-statusline.conf), so removing the wrapper"
                    + " now could not restore it. Nothing was changed. The settings backups"
                    + " beside ~/.claude/settings.json have the original command."
            }
        }
    }

    // MARK: - What is there now

    typealias Ownership = StatusLineRecovery.Ownership
    typealias Recovery = StatusLineRecovery.Recovery

    /// The two decisions that decide whether anybody loses a status line —
    /// "is this ours" and "what do we put back" — live in
    /// `StatusLineRecovery`, where a check tool can reach them. See the
    /// reasoning there; this file only supplies the paths and the disk.
    static func ownership() -> Ownership {
        guard let settings = try? AgentHookInstaller.loadSettings() else {
            return .foreign(nil)
        }
        return classify(command(in: settings))
    }

    static func classify(_ raw: String?) -> Ownership {
        StatusLineRecovery.classify(
            raw,
            scriptPath: scriptURL.path,
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    static func isInstalled() -> Bool { ownership() == .ours }

    /// The status line that would be wrapped, for showing before the button is
    /// pressed. Nil means there is none — the case that gets a minimal line.
    static func commandToWrap() -> String? {
        switch ownership() {
        case .ours: return recovery().command
        case .foreign(let command): return command
        case .unrecognised(let command): return command
        }
    }

    // MARK: - The recovery record

    static func recovery() -> Recovery {
        StatusLineRecovery.recovery(from: try? String(contentsOf: configURL, encoding: .utf8))
    }

    /// The whole `statusLine` object as compact JSON, or nil if there is none.
    ///
    /// Recorded verbatim so uninstall can put back what was there rather than
    /// what this app happened to look at. `refreshInterval`, `padding` and any
    /// key a future Claude Code adds all ride along without this file having to
    /// know they exist.
    private static func serialise(statusLine: Any?) -> String? {
        guard let object = statusLine as? [String: Any] else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func deserialise(_ text: String?) -> [String: Any]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Install and uninstall

    /// Returns the backup that was taken.
    @discardableResult
    static func install() throws -> URL {
        // Read and mtime together — see `loadSettingsVerifying`. Capturing the
        // stamp after the read makes an edit that lands in between look like
        // the baseline, and the write then overwrites it.
        var (settings, readAt) = try AgentHookInstaller.loadSettingsVerifying()

        // Every refusal below happens before a single byte is written, so a
        // configuration this cannot put back leaves the disk exactly as it was.
        if let statusLine = settings["statusLine"] as? [String: Any],
           let type = statusLine["type"] as? String,
           type != "command"
        {
            throw Failure.unsupportedType(type)
        }

        let current = command(in: settings)
        var record: Recovery
        switch classify(current) {
        case .ours:
            // Re-install. The record already holds the right answer; deriving
            // it again from a settings file that names our own script would
            // record the wrapper as its own inner command and nest forever.
            //
            // **An unreadable record is refused rather than degraded.** The
            // tempting shortcut is to treat it as "there was no status line",
            // since re-installing removes nothing — but it writes that claim
            // into the record, and the *next* uninstall then acts on it. A
            // silent loss one step removed from the action that caused it is
            // the worst kind.
            let recorded = recovery()
            guard !recorded.isUnavailable else { throw Failure.recoveryUnavailable }
            record = recorded
        case .unrecognised(let command):
            throw Failure.externallyModified(command)
        case .foreign(let command):
            // **Validated against the raw command**, before any trimming. A
            // newline cannot round-trip through a line-based record, and a
            // record written anyway restores something other than what was
            // there — which for a shell command means it still runs.
            if let command {
                guard StatusLineRecovery.canRoundTrip(command) else {
                    throw Failure.notASingleLine
                }
            }
            record = Recovery(command: command, original: nil)
        }

        // The object as it stands now, whatever else is in it. On a re-install
        // the recorded one is older and therefore the right one to keep.
        if record.original == nil {
            record.original = serialise(statusLine: settings["statusLine"])
        }
        if let original = record.original,
           !StatusLineRecovery.canRoundTrip(original)
        {
            throw Failure.notASingleLine
        }

        try writeScripts(recovery: record)
        let backup = try AgentHookInstaller.backUpSettings()

        // Only `command` and `type` are touched. `padding`, `refreshInterval`
        // and anything a future Claude Code adds are left exactly as found —
        // this file has four other tools' settings in it.
        var statusLine = (settings["statusLine"] as? [String: Any]) ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = installedCommand
        settings["statusLine"] = statusLine

        try AgentHookInstaller.writeSettings(settings, readAt: readAt)
        TmuxLog.destructive(
            "wrapped the Claude Code status line in \(scriptURL.path)"
                + " — backup at \(backup.lastPathComponent)"
        )
        return backup
    }

    /// Returns the backup that was taken.
    @discardableResult
    static func uninstall() throws -> URL {
        var (settings, readAt) = try AgentHookInstaller.loadSettingsVerifying()

        switch classify(command(in: settings)) {
        case .ours: break
        case .unrecognised(let command): throw Failure.externallyModified(command)
        case .foreign: return try AgentHookInstaller.backUpSettings()  // already not ours
        }

        // Decided before the backup, so a refusal writes nothing at all.
        let restore = recovery()
        guard !restore.isUnavailable else { throw Failure.recoveryUnavailable }

        let backup = try AgentHookInstaller.backUpSettings()

        // **The whole object goes back, not just the command.** A settings file
        // can hold a `statusLine` with `refreshInterval` and no command at all;
        // reading "there was no command" as "there was no object" deletes that,
        // and nothing says so. The recorded object is the shape that was there.
        if var original = deserialise(restore.original) {
            // An edit to INNER wins: the record is advertised as editable and
            // this is the field people will edit.
            // **Nothing is removed from the recorded object.** It is the
            // shape that was there before this app touched it, command
            // included, so putting it back unchanged is the restore. Stripping
            // `command` when the record does not name one throws away whatever
            // was in that field — and the field can hold something this app
            // declined to treat as a command without it stopping being the
            // user's text.
            if let command = restore.command {
                // A hand edit to INNER wins over the recorded object.
                original["command"] = command
                if original["type"] == nil { original["type"] = "command" }
            }
            settings["statusLine"] = original
        } else if let command = restore.command {
            // No object was recorded but a command was — a hand-edited record.
            // Honour it rather than throwing the command away.
            settings["statusLine"] = ["type": "command", "command": command]
        } else {
            // There was no object before, so there is none after.
            settings.removeValue(forKey: "statusLine")
        }

        try AgentHookInstaller.writeSettings(settings, readAt: readAt)
        // The scripts stay on disk, for the reason the hook script does: they
        // are inert once nothing points at them, they are short enough to read,
        // and deleting files out of another program's directory is not
        // something to do quietly.
        TmuxLog.destructive(
            "unwrapped the Claude Code status line — backup at \(backup.lastPathComponent)"
        )
        return backup
    }

    // MARK: - Shape

    private static func command(in settings: [String: Any]) -> String? {
        guard let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              // Newlines count as empty here, so `classify` never has to
              // decide whether a command made only of whitespace is a command.
              // The raw text is still what gets returned, and the recorded
              // object still carries the field verbatim either way.
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return command
    }

    // MARK: - The scripts

    private static func writeScripts(recovery: Recovery) throws {
        let directory = scriptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try write(script, to: scriptURL, executable: true)
        try write(minimalScript, to: minimalURL, executable: true)
        try write(config(recovery: recovery), to: configURL, executable: false)
    }

    private static func write(_ text: String, to url: URL, executable: Bool) throws {
        try Data(text.utf8).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path
        )
    }

    static func config(recovery: Recovery) -> String {
        StatusLineRecovery.config(recovery)
    }

    static let script = #"""
    #!/bin/sh
    # TmuxGUI — feeds the sidebar the numbers Claude Code publishes only here.
    #
    # This is a wrapper. Whatever status line was configured before is recorded
    # in tmuxgui-statusline.conf beside this file, runs with the same stdin, and
    # has its output printed unchanged — so the line in your terminal does not
    # change. Remove it in TmuxGUI (Settings -> Behaviour), or put the command
    # in that file back into ~/.claude/settings.json yourself.
    #
    # Nothing is parsed here. TmuxGUI reads this JSON in Swift, so this script
    # needs jq about as much as it needs awk, which is not at all.

    input=$(cat)
    here=$(dirname "$0")

    # **Reporting runs in the background, is never waited for, and never has
    # more than one instance per pane.**
    #
    # Backgrounding is what stops a wedged tmux server from stalling every
    # status line on the machine — a wrapper that can hang the status line it
    # wraps is worse than no wrapper. But backgrounding alone turns that hang
    # into a leak: a server that accepts connections and stops answering would
    # collect one more client every five seconds, per session, forever.
    #
    # `mkdir` is atomic, so it is the lock. If the previous update for this pane
    # has not finished, this render is skipped rather than starting a second
    # one. A pane whose numbers stop moving is a visible, bounded failure; a
    # thousand stuck tmux clients is not.
    if [ -n "$TMUX_PANE" ]; then
        lock="${TMPDIR:-/tmp}/tmuxgui-stat${TMUX_PANE}.lock"
        if mkdir "$lock" 2>/dev/null; then
            (
                # Newlines stripped: a control-mode notification is line-based,
                # and a raw newline in an option value would break TmuxGUI's
                # read loop. JSON carries newlines inside strings as \n escapes,
                # so this is lossless.
                printf '%s' "$input" | tr -d '\n\r' | {
                    read -r line
                    tmux set-option -p -t "$TMUX_PANE" @agent_stat "$line"
                }
                rmdir "$lock" 2>/dev/null
            ) </dev/null >/dev/null 2>&1 &
        else
            # A lock older than any real update means the process holding it was
            # killed rather than finishing — reap it so one bad update cannot
            # wedge a pane's numbers permanently.
            find "$lock" -maxdepth 0 -mmin +2 -exec rmdir {} \; 2>/dev/null
        fi
    fi

    # **Read, not sourced.** This file is advertised as safe to edit, so it must
    # not be able to run anything: sourcing it would let a stray `exit` or an
    # unbalanced quote kill the wrapper before your status line ever ran. `sed`
    # takes the rest of the line, verbatim.
    INNER=''
    if [ -f "$here/tmuxgui-statusline.conf" ]; then
        INNER=$(sed -n 's/^INNER=//p' "$here/tmuxgui-statusline.conf" | head -n 1)
    fi

    if [ -n "$INNER" ]; then
        printf '%s' "$input" | sh -c "$INNER"
    else
        # No status line to wrap. Drawing nothing is not free — a configured
        # status line that prints nothing still costs a row — so draw something
        # worth the row instead.
        printf '%s' "$input" | sh "$here/tmuxgui-statusline-minimal.sh"
    fi

    """#

    /// Used only when there was no status line to wrap.
    ///
    /// This is the one place in the feature that parses JSON in shell, and so
    /// the one place `jq` matters. Without it the line degrades to the
    /// directory and the branch — which needs no parser — rather than
    /// disappearing. Reporting to the sidebar never touches this file.
    static let minimalScript = #"""
    #!/bin/sh
    # TmuxGUI — a minimal Claude Code status line.
    #
    # Installed alongside tmuxgui-statusline.sh and used only when there was no
    # status line of your own to wrap. Replace it with anything you like: put
    # your command in tmuxgui-statusline.conf and this file stops being used.

    input=$(cat)

    dir=$PWD
    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    model=''
    ctx=''
    cost=''
    if command -v jq >/dev/null 2>&1; then
        us=$(printf '\037')
        IFS="$us" read -r dir_json model ctx cost <<EOF
    $(printf '%s' "$input" | jq -r --arg us "$us" '[
        (.workspace.current_dir // .cwd // ""),
        (.model.display_name // ""),
        (.context_window.used_percentage // "" | tostring),
        (.cost.total_cost_usd // "" | tostring)
      ] | join($us)' 2>/dev/null)
    EOF
        [ -n "$dir_json" ] && dir=$dir_json
        branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    fi

    out=${dir##*/}
    [ -n "$branch" ] && out="$out · $branch"
    [ -n "$model" ]  && out="$out · $model"
    case $ctx in ''|null) ;; *) out="$out · ctx ${ctx%%.*}%" ;; esac
    case $cost in ''|null|0) ;; *) out=$(printf '%s · $%.2f' "$out" "$cost") ;; esac

    printf '%s' "$out"

    """#
}
