//
//  StatusLineRecovery.swift
//  Attache
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
        /// Somebody else's status line, or none at all. **The command is
        /// carried raw**, exactly as it was in the settings file — see
        /// `classify`.
        case foreign(String?)
        /// Names our script, but is not a command this app would have written.
        case unrecognised(String)
    }

    /// What to put back when the wrapper is removed.
    ///
    /// **Two things are recorded, not one, and that is the finding this shape
    /// exists for.** The command alone cannot say whether the `statusLine`
    /// *object* was there — and a settings file can perfectly well hold
    /// `{"statusLine": {"refreshInterval": 500}}` with no command at all.
    /// Recording only "there was no command" and then deleting the whole object
    /// on uninstall throws that away, irreversibly except through the backup.
    ///
    /// So `original` carries the object verbatim, as compact JSON, and uninstall
    /// puts *that* back. `command` stays as well, because the record is
    /// advertised as editable and the one thing a person will want to change is
    /// which status line runs inside; when the two disagree, the edited command
    /// wins.
    struct Recovery: Equatable {
        /// The command to run inside the wrapper, and to restore. Nil means
        /// there was none.
        var command: String?
        /// The whole original `statusLine` object as compact JSON. Nil means
        /// there was no object at all, so uninstall removes the key.
        var original: String?
        /// The record could not be read or does not parse. Emphatically not the
        /// same as "there was nothing": this one refuses to act.
        var isUnavailable = false

        static let unavailable = Recovery(command: nil, original: nil, isUnavailable: true)
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
    ///
    /// **Trimming is for the comparison only; `foreign` carries the raw text.**
    /// Returning the trimmed value looks harmless and defeats the newline guard
    /// downstream: `canRoundTrip` would then be shown a command with its
    /// trailing newline already removed, pass it, and the record would restore
    /// something other than what was there. Normalising for a *test* is not the
    /// same as normalising the *value*.
    static func classify(_ raw: String?, scriptPath: String, home: String) -> Ownership {
        guard let raw else { return .foreign(nil) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .foreign(nil) }

        var targets = [scriptPath]
        if !home.isEmpty, scriptPath.hasPrefix(home + "/") {
            targets.append("~" + scriptPath.dropFirst(home.count))
        }
        for shell in shells {
            for target in targets where trimmed == shell + target { return .ours }
        }

        let name = (scriptPath as NSString).lastPathComponent
        if !name.isEmpty, trimmed.contains(name) { return .unrecognised(trimmed) }
        return .foreign(raw)
    }

    /// Parse the recovery record. Nil text means the file was not readable,
    /// which is `unavailable` and emphatically not "there was nothing".
    static func recovery(from text: String?) -> Recovery {
        guard let text else { return .unavailable }
        var wrapped: String?
        var inner: String?
        var original: String?
        var sawOriginal = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(Key.wrapped) {
                wrapped = String(line.dropFirst(Key.wrapped.count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix(Key.inner), inner == nil {
                // The rest of the line, verbatim and untrimmed: a command's own
                // leading or trailing spaces are its business. First one wins,
                // so a hand-added second line cannot quietly take over.
                inner = String(line.dropFirst(Key.inner.count))
            } else if line.hasPrefix(Key.original), !sawOriginal {
                sawOriginal = true
                let value = String(line.dropFirst(Key.original.count))
                    .trimmingCharacters(in: .whitespaces)
                original = value == Marker.absent ? nil : value
            }
        }

        // Written by a version that did not record the object. Refuse rather
        // than guess: guessing here is what deletes a `statusLine` somebody
        // still had.
        guard sawOriginal else { return .unavailable }

        switch wrapped {
        case Marker.none:
            return Recovery(command: nil, original: original)
        case Marker.command:
            guard let inner, !inner.isEmpty else { return .unavailable }
            return Recovery(command: inner, original: original)
        default:
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
        # Written by Attaché. This is the record of what to put back when the
        # wrapper is removed. It is *read*, never run — the value of a key is
        # the rest of its line exactly as written, with no quoting.
        #
        #   \(Key.wrapped)\(Marker.none)      there was no status line command
        #   \(Key.wrapped)\(Marker.command)   \(Key.inner) below is the one to run, and restore
        #   \(Key.inner)…            the command that runs inside the wrapper
        #   \(Key.original)…         the whole original statusLine object, or "\(Marker.absent)"
        #
        # \(Key.inner) is safe to edit — it is the one thing you are likely to want
        # to change, and an edit here wins over the command inside \(Key.original).
        # If this file goes missing, Attaché refuses to remove the wrapper
        # rather than guess; the backups beside ~/.claude/settings.json have the
        # original.

        """
        let originalLine = "\(Key.original)\(recovery.original ?? Marker.absent)\n"
        if recovery.isUnavailable {
            return header + "\(Key.wrapped)\(Marker.none)\n\(Key.inner)\n" + originalLine
        }
        guard let command = recovery.command, !command.isEmpty else {
            return header + "\(Key.wrapped)\(Marker.none)\n\(Key.inner)\n" + originalLine
        }
        return header + "\(Key.wrapped)\(Marker.command)\n\(Key.inner)\(command)\n" + originalLine
    }

    private enum Key {
        static let wrapped = "TMUXGUI_WRAPPED="
        static let inner = "INNER="
        static let original = "TMUXGUI_ORIGINAL="
    }

    private enum Marker {
        static let none = "none"
        static let command = "command"
        static let absent = "absent"
    }

    /// Whether a value can survive being written to the record and read back.
    ///
    /// The record is line-based, so anything carrying a newline would be
    /// restored truncated — which is worse than refusing, because a truncated
    /// shell command can still run and do something other than what was asked.
    /// Applied to the **raw** command and to the serialised object alike.
    static func canRoundTrip(_ value: String) -> Bool {
        !value.contains(where: \.isNewline)
    }
}
