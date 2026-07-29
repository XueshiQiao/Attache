//
//  StatusLineRecovery.swift
//  TmuxGUI
//

import Foundation

/// The two decisions that stand between the status line wrapper and somebody
/// losing their status line: **is this command ours**, and **what do we put
/// back**.
///
/// Split out of `AgentStatusLineInstaller` so it can be run against a table of
/// cases without a `~/.claude/settings.json` to write to. That is the same
/// reason `TmuxRenameString` and `TerminalReply` are their own files: this is
/// the half whose failures are silent and unrecoverable, and the file with that
/// property gets a cross-check.
///
/// Every function here is pure. Nothing reads the disk, nothing reads the
/// environment; the paths come in as arguments.
enum StatusLineRecovery {
    /// What `statusLine.command` currently is, as far as this app is concerned.
    enum Ownership: Equatable {
        /// Exactly a command this app writes.
        case ours
        /// Somebody else's status line, or none at all.
        case foreign(String?)
        /// Names our script, but is not a command this app would have written.
        case unrecognised(String)
    }

    /// What to put back when the wrapper is removed.
    ///
    /// **`none` and `unavailable` are different answers.** A single optional
    /// cannot tell "there was no status line, so remove the key" from "the
    /// record is gone, so I do not know" — and treating the second as the
    /// first deletes the user's whole `statusLine` object, `refreshInterval`
    /// and any future key with it, on nothing more than a missing file.
    enum Recovery: Equatable {
        case none
        case command(String)
        case unavailable
    }

    /// Which shells a command we wrote could plausibly be spelled with. The
    /// empty one is the bare path.
    private static let shells = ["", "sh ", "bash ", "/bin/sh ", "/bin/bash "]

    /// **Not a substring test, and that distinction is the point.**
    ///
    /// Matching on the file name alone means a command that merely *mentions*
    /// our wrapper — most obviously another tool composing around it — reads as
    /// ours, and then installing discards that tool's command while
    /// uninstalling replaces it with a record older than it is. The forms below
    /// are exactly the ones this app could have written, plus the shells a
    /// person plausibly retypes it with; anything else that names the script is
    /// `unrecognised`, and the caller refuses rather than overwrites.
    static func classify(_ raw: String?, scriptPath: String, home: String) -> Ownership {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return .foreign(nil) }

        var targets = [scriptPath]
        if !home.isEmpty, scriptPath.hasPrefix(home + "/") {
            targets.append("~" + scriptPath.dropFirst(home.count))
        }
        for shell in shells {
            for target in targets where trimmed == shell + target { return .ours }
        }

        let name = (scriptPath as NSString).lastPathComponent
        if !name.isEmpty, trimmed.contains(name) { return .unrecognised(trimmed) }
        return .foreign(trimmed)
    }

    /// Parse the recovery record. Nil text means the file was not readable,
    /// which is `unavailable` and emphatically not `none`.
    static func recovery(from text: String?) -> Recovery {
        guard let text else { return .unavailable }
        var wrapped: String?
        var inner: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("TMUXGUI_WRAPPED=") {
                wrapped = String(line.dropFirst("TMUXGUI_WRAPPED=".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("INNER="), inner == nil {
                // The rest of the line, verbatim and untrimmed: a command's own
                // leading or trailing spaces are its business. First one wins,
                // so a hand-added second line cannot quietly take over.
                inner = String(line.dropFirst("INNER=".count))
            }
        }
        switch wrapped {
        case "none":
            return .none
        case "command":
            guard let inner, !inner.isEmpty else { return .unavailable }
            return .command(inner)
        default:
            // Includes a file with no marker at all — an older version's
            // format, or one somebody truncated.
            return .unavailable
        }
    }

    /// The recovery record, written.
    ///
    /// **Read by the wrapper, never executed by it.** It used to be `sh` that
    /// the wrapper sourced, which is the natural thing to reach for and is
    /// wrong twice: a stray `exit` or an unbalanced quote in a file this app
    /// tells people is safe to edit would take the wrapper down before it ran
    /// their status line, and the quoting needed to survive sourcing is exactly
    /// what mangled a command carrying a quote of its own. The value is the
    /// rest of the line, with no quoting to get wrong on either side.
    static func config(_ recovery: Recovery) -> String {
        let header = """
        # Written by TmuxGUI. This is the record of which status line to put
        # back when the wrapper is removed. It is *read*, never run — the value
        # of INNER is the rest of its line exactly as written, with no quoting.
        #
        # TMUXGUI_WRAPPED=none      there was no status line before
        # TMUXGUI_WRAPPED=command   INNER below is the one to run, and restore
        #
        # Safe to edit. If this file goes missing, TmuxGUI refuses to remove the
        # wrapper rather than guess — the backups beside ~/.claude/settings.json
        # have the original.

        """
        switch recovery {
        case .none, .unavailable:
            return header + "TMUXGUI_WRAPPED=none\nINNER=\n"
        case .command(let inner):
            return header + "TMUXGUI_WRAPPED=command\nINNER=\(inner)\n"
        }
    }

    /// Whether a command can survive being written to the record and read back.
    ///
    /// The record is line-based, so a command carrying a newline would be
    /// restored truncated — which is worse than refusing, because a truncated
    /// shell command can still run and do something else.
    static func canRoundTrip(_ command: String) -> Bool {
        !command.contains(where: \.isNewline)
    }
}
