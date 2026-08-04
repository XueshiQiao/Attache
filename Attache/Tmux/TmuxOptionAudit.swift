//
//  TmuxOptionAudit.swift
//  Attache
//

import Foundation

/// The one look this app takes at the user's tmux configuration, once per
/// run, right after the first attach.
///
/// The app is designed not to depend on that configuration — everything is
/// addressed by id and reply pairing reads tmux's own flags — but two kinds
/// of setting still hurt the user *through* the app, and both are invisible
/// until they fire:
///
/// - `destroy-unattached` / `exit-unattached`. A control-mode client counts
///   as an attached client (measured on tmux 3.6a: with `destroy-unattached
///   on`, a session holding only a control client survived while an
///   unattached one was destroyed instantly). For a user with either option
///   on, this app's connections are what keep the sessions alive — quitting
///   it destroys them, whatever was running inside included. That deserves a
///   warning while there is still time to change the option, not an
///   after-the-fact apology.
///
/// - `command-alias`. An alias is consulted before the built-in it shadows —
///   measured on 3.6a: with `list-windows` aliased, the plain word runs the
///   alias and `list-windows -F …` fails with "too many arguments" — so one
///   line of configuration can silently disable every feature built on that
///   command. The rail going permanently empty with no error anywhere reads
///   as this app being broken, and the cause is one `show-options` away.
///
/// Parsing lives here, pure and Foundation-only, so it can be exercised
/// without a server.
enum TmuxOptionAudit {
    /// Every command word this app sends at tmux, argv spawns included —
    /// aliases apply to those the same way, since one-shot commands are
    /// parsed by the same server. Grown by hand when a new command is
    /// introduced; a stale entry costs a spurious warning, a missing one
    /// costs a warning that should have fired, so err on the side of listing.
    static let commandsSent: Set<String> = [
        "attach",
        "capture-pane",
        "delete-buffer",
        "detach-client",
        "display-message",
        "kill-pane",
        "kill-window",
        "list-clients",
        "list-panes",
        "list-sessions",
        "list-windows",
        "load-buffer",
        "move-window",
        "new-session",
        "new-window",
        "paste-buffer",
        "refresh-client",
        "rename-session",
        "rename-window",
        "resize-pane",
        "select-pane",
        "select-window",
        "send-keys",
        "set-option",
        "show-options",
        "split-window",
        "switch-client",
    ]

    /// `show-options -g command-alias` output → the alias names that shadow a
    /// command this app sends, in the order tmux listed them.
    ///
    /// The format, measured on 3.6a: `command-alias[5] choose-session=choose-tree -s`,
    /// with the whole `name=value` pair double-quoted when the value carries a
    /// space. tmux ships six defaults (`split-pane`, `splitp`, `server-info`,
    /// `info`, `choose-window`, `choose-session`); none shadows anything in
    /// the list above, so a machine with no aliases of its own reports clean.
    static func shadowedCommands(inShowOptionsOutput lines: [String]) -> [String] {
        var hits = [String]()
        for line in lines {
            guard let bracket = line.range(of: "] ") else { continue }
            var entry = line[bracket.upperBound...]
            if entry.hasPrefix("\"") { entry = entry.dropFirst() }
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[..<equals])
            if commandsSent.contains(name), !hits.contains(name) { hits.append(name) }
        }
        return hits
    }

    /// Whether a lifecycle option value means "quitting this app can destroy
    /// something". `off` is tmux's default for both options this is asked
    /// about; everything else — `on`, and `destroy-unattached`'s `keep-last`
    /// and `keep-group` — destroys at least some sessions when their last
    /// client goes.
    static func isHostileLifecycleValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "off"
    }
}
