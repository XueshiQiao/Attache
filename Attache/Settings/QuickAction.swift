//
//  QuickAction.swift
//  Attache
//

import Foundation

/// A named tmux command the user put in the menu bar.
///
/// The whole type is two strings, and that is the point: this app already has
/// exactly one way to make something happen — send tmux a command — so a
/// "quick action" needs to be nothing more than a line the user would otherwise
/// type after `bind` in their `.tmux.conf`. Nothing here is interpreted, and no
/// app-side behaviour can be reached this way; an action that could toggle a
/// setting or open a window would be a second kind of thing wearing the same
/// name.
///
/// The command is sent verbatim to the connection of the session on screen, so
/// a relative target (`set status`, `next-window`) resolves against it exactly
/// as it would for a tmux key binding.
struct QuickAction: Codable, Hashable, Identifiable {
    var id: UUID
    var title: String
    var command: String

    init(id: UUID = UUID(), title: String, command: String) {
        self.id = id
        self.title = title
        self.command = command
    }

    /// What the menu ships with.
    ///
    /// One entry, and it is the one that prompted the feature: the rail already
    /// lists a session's windows, so tmux's own status line is a second copy of
    /// the same list along the bottom edge. `set` with no value toggles —
    /// measured on tmux 3.6a, three presses giving off, on, off — and turning
    /// the line off does not make tmux mute, because it still borrows the
    /// bottom row for messages and prompts when it has something to say
    /// (measured against a live client on 2026-07-30).
    static let installed = [
        QuickAction(title: "Toggle tmux Status Bar", command: "set status"),
    ]

    /// Whether this row is worth putting in the menu. A half-typed row in the
    /// settings table should not become a menu item that does nothing.
    var isRunnable: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
