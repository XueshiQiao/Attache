//
//  TerminalLinkGesture.swift
//  TmuxGUI
//

import Cocoa

/// Which modifier turns the path or URL under the pointer into a link.
///
/// **Why this is a translation and not a setting handed to libghostty.**
/// libghostty already matches URLs *and* file paths — its default matcher has
/// three branches, one of them absolute and dot-relative paths — and already
/// draws the underline and the pointing-hand cursor. Two things about it
/// cannot be configured, both verified in Ghostty's source at the pinned
/// commit:
///
/// 1. The modifier is hard-coded to ⌘ (`hover_mods = ctrlOrSuper`) in
///    `Config.default`, and the `link` key that would let a caller state its
///    own has a parser that returns `error.NotImplemented` outright — the
///    comment above it in Ghostty's source says it cannot be set yet.
/// 2. Link detection is skipped *entirely* while the program in the terminal
///    has mouse reporting on, which for this app is always: tmux runs with
///    `mouse on`. The one exception Ghostty allows is ⇧, meaning "this gesture
///    is the terminal's, not the program's".
///
/// So the only gesture that works out of the box is ⇧⌘, and the way to offer
/// any other one is to rewrite the modifiers on the event before libghostty
/// sees it. ⇧ gets it past the mouse-reporting gate, and Ghostty then strips
/// ⇧ back off itself (`mouseModsWithCapture`) before comparing against ⌘ — so
/// adding ⇧ is exactly equivalent to the user holding it, which is the path
/// measured to work on 2026-07-31.
///
/// What that gate guards is real, and the rewrite does take it away for the
/// length of the gesture. Mouse input reaches tmux here: clicking a window's
/// name in tmux's own status line switches windows in this app, measured
/// 2026-07-31. So a rewritten press is a press tmux never sees — an acceptable
/// trade for a gesture the user made in order to click a link, and the reason
/// the whole press-drag-release sequence is rewritten as one thing rather than
/// event by event, since a half-rewritten sequence hands tmux motion with no
/// press underneath it.
///
/// `TerminalReply` is not a safety net for any of this. It lost its call sites
/// when the pane renderer was deleted and filters nothing today, whatever
/// CLAUDE.md's older paragraph about it says.
/// Only ⌘ and ⇧⌘ are offered, and that is a decision rather than an oversight.
/// The rewrite happens on the way *in*, before Ghostty knows whether the
/// pointer is over a link, so every event carrying the gesture is rewritten —
/// not only the ones that turn out to be links. A modifier the terminal
/// already owns therefore loses its own meaning everywhere: ⌥ is Ghostty's
/// rectangular selection, and ⌃-click is a right-click on macOS. Both were
/// offered here at first and both would have been broken across the whole
/// surface, not merely on links.
enum TerminalLinkGesture: String, CaseIterable {
    // Written out in the settings file, so the spelling is the one a person
    // would type: `link_modifier = "shift-command"`.
    case command = "command"
    case shiftCommand = "shift-command"

    /// The modifiers libghostty has to see. Always the same pair, whatever the
    /// user picked: ⌘ is what its matcher compares against and ⇧ is the key to
    /// the gate.
    static let ghosttyEquivalent: NSEvent.ModifierFlags = [.command, .shift]

    /// Modifiers this app cares about. Caps lock and the function key are not
    /// part of any gesture and must not stop one from matching.
    static let considered: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .command: [.command]
        case .shiftCommand: [.command, .shift]
        }
    }

    var label: String {
        switch self {
        case .command: "⌘"
        case .shiftCommand: "⇧⌘"
        }
    }

    /// What to put on the event, or nil to pass it through untouched.
    ///
    /// The comparison is exact rather than "contains": a gesture of ⌘ must not
    /// fire while the user is holding ⌥⌘ to do something else, and the
    /// replacement *drops* whatever the user held, because Ghostty compares
    /// the surviving modifiers for equality — leaving ⌥ on would make the
    /// comparison ⌥⌘ against ⌘ and match nothing.
    func ghosttyFlags(for incoming: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags? {
        guard incoming.intersection(Self.considered) == flags else { return nil }
        return Self.ghosttyEquivalent
    }
}
