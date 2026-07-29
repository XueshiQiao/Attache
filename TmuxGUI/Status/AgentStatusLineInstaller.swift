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
        case .ours:
            if case .command(let inner) = recovery() { return inner }
            return nil
        case .foreign(let command):
            return command
        case .unrecognised(let command):
            return command
        }
    }

    // MARK: - The recovery record

    static func recovery() -> Recovery {
        StatusLineRecovery.recovery(from: try? String(contentsOf: configURL, encoding: .utf8))
    }

    // MARK: - Install and uninstall

    /// Returns the backup that was taken.
    @discardableResult
    static func install() throws -> URL {
        var settings = try AgentHookInstaller.loadSettings()

        // Every refusal below happens before a single byte is written, so a
        // configuration this cannot put back leaves the disk exactly as it was.
        if let statusLine = settings["statusLine"] as? [String: Any],
           let type = statusLine["type"] as? String,
           type != "command"
        {
            throw Failure.unsupportedType(type)
        }

        let current = command(in: settings)
        let inner: Recovery
        switch classify(current) {
        case .ours:
            // Re-install. The record already holds the right answer; deriving
            // it again from a settings file that names our own script would
            // record the wrapper as its own inner command and nest forever.
            //
            // **An unreadable record is refused rather than degraded.** The
            // tempting shortcut is to treat it as "there was no status line",
            // since re-installing removes nothing — but it writes that claim
            // into the record, and the *next* uninstall then deletes a
            // `statusLine` the user did have. A silent loss one step removed
            // from the action that caused it is the worst kind.
            let recorded = recovery()
            guard recorded != .unavailable else { throw Failure.recoveryUnavailable }
            inner = recorded
        case .unrecognised(let command):
            throw Failure.externallyModified(command)
        case .foreign(let command):
            guard let command else {
                inner = .none
                break
            }
            // A command with a newline in it cannot round-trip through a
            // line-based record, and writing it anyway would silently restore a
            // truncated command on uninstall.
            guard StatusLineRecovery.canRoundTrip(command) else { throw Failure.notASingleLine }
            inner = .command(command)
        }

        let readAt = AgentHookInstaller.settingsModified()
        try writeScripts(recovery: inner)
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
        var settings = try AgentHookInstaller.loadSettings()

        switch classify(command(in: settings)) {
        case .ours: break
        case .unrecognised(let command): throw Failure.externallyModified(command)
        case .foreign: return try AgentHookInstaller.backUpSettings()  // already not ours
        }

        // Decided before the backup, so a refusal writes nothing at all.
        let restore = recovery()
        guard restore != .unavailable else { throw Failure.recoveryUnavailable }

        let readAt = AgentHookInstaller.settingsModified()
        let backup = try AgentHookInstaller.backUpSettings()

        var statusLine = (settings["statusLine"] as? [String: Any]) ?? [:]
        switch restore {
        case .command(let inner):
            statusLine["command"] = inner
            settings["statusLine"] = statusLine
        case .none:
            // There was no status line before, so there is none after. Leaving
            // one that runs nothing is the blank row this feature exists to
            // avoid — and this branch is only reached when the record says so
            // in as many words.
            settings.removeValue(forKey: "statusLine")
        case .unavailable:
            preconditionFailure("refused above")
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
              !command.trimmingCharacters(in: .whitespaces).isEmpty
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

    # **Reporting runs in the background and is never waited for.** It is cheap
    # — one tmux call, measured at 6ms — but cheap is not the same as bounded,
    # and a wedged tmux server would otherwise stall every status line render on
    # the machine. A wrapper that can hang the status line it wraps is worse
    # than no wrapper.
    if [ -n "$TMUX_PANE" ]; then
        (
            # Newlines stripped: a control-mode notification is line-based, and
            # a raw newline in an option value would break TmuxGUI's read loop.
            # JSON carries newlines inside strings as \n escapes, so this is
            # lossless.
            printf '%s' "$input" | tr -d '\n\r' | {
                read -r line
                tmux set-option -p -t "$TMUX_PANE" @agent_stat "$line"
            }
        ) </dev/null >/dev/null 2>&1 &
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
