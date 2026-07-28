//
//  TmuxPaneSnapshot.swift
//  TmuxGUI
//

import Foundation

/// Where tmux says a pane's cursor is, zero-based from the top-left of the
/// visible screen.
///
/// Absolute, and that is not obvious: measured on tmux 3.6a with a scroll
/// region of rows 4-9 and origin mode on, putting the cursor at region-relative
/// row 2 makes tmux report row 4 — the screen row, not the region row. Anything
/// replaying this after turning origin mode on has to convert.
struct TmuxPaneCursor {
    let column: Int
    let row: Int
}

/// The terminal modes a pane is in, as tmux has them.
///
/// A screen is more than its text, and this app attaches to sessions whose
/// programs set their modes long before it was running. Every field here is a
/// tmux format variable that exists on 3.6a and rides along in the
/// `display-message` round trip the capture already makes — no extra command.
struct TmuxPaneModes {
    /// `alternate_on`. Whether the program is on the alternate screen.
    let alternateScreen: Bool
    /// `cursor_flag` — DECTCEM.
    let cursorVisible: Bool
    /// `wrap_flag` — DECAWM.
    let wrap: Bool
    /// `insert_flag` — IRM.
    let insert: Bool
    /// `origin_flag` — DECOM. Changes what a cursor position *means*, which is
    /// why it is emitted before the cursor is placed and why the row is
    /// converted when it is on.
    let origin: Bool
    /// `keypad_cursor_flag` — DECCKM. Decides what the arrow keys send.
    let applicationCursorKeys: Bool
    /// `keypad_flag` — DECKPAM/DECKPNM. Same, for the keypad.
    let applicationKeypad: Bool

    /// `mouse_standard_flag` — DECSET 1000.
    let mouseStandard: Bool
    /// `mouse_button_flag` — DECSET 1002.
    let mouseButton: Bool
    /// `mouse_all_flag` — DECSET 1003.
    let mouseAll: Bool
    /// `mouse_sgr_flag` — DECSET 1006.
    let mouseSGR: Bool
    /// `mouse_utf8_flag` — DECSET 1005.
    let mouseUTF8: Bool

    /// `scroll_region_upper`/`scroll_region_lower` — DECSTBM, zero-based.
    let scrollRegionUpper: Int
    let scrollRegionLower: Int

    /// `cursor_shape`, one of tmux's four words, and `cursor_blinking`.
    ///
    /// Measured on 3.6a: DECSCUSR 0 gives `default`, 1 and 2 `block`, 3 and 4
    /// `underline`, 5 and 6 `bar`, with the odd values also setting
    /// `cursor_blinking`. `CSI ?12h` sets `cursor_blinking` on its own and
    /// leaves the shape at `default`, which is why blink is carried separately
    /// rather than folded into the shape.
    let cursorShape: String
    let cursorBlinking: Bool
}

/// Everything needed to redraw a pane exactly as tmux has it.
///
/// A type of its own, rather than nested in the connection that fetches it,
/// so that `TmuxScreenReplay` — and the checker that runs a case table over
/// it — can be compiled without dragging in a control mode client.
struct TmuxPaneSnapshot {
    /// Rows above the visible screen, oldest first — the pane's scrollback.
    /// Empty unless it was asked for.
    let history: [Data]
    /// The visible screen. One row per pane row, blanks included — unless
    /// `cursor` is nil, in which case the trailing blank rows have been
    /// dropped; see the note in `TmuxSessionConnection.capturePane`.
    let screen: [Data]
    /// Nil when tmux would not answer. `modes` is nil in exactly the same
    /// case: both come out of one reply, so either both are known or neither
    /// is.
    let cursor: TmuxPaneCursor?
    let modes: TmuxPaneModes?
}
