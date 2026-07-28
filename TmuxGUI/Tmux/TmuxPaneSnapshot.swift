//
//  TmuxPaneSnapshot.swift
//  TmuxGUI
//

import Foundation

/// Where tmux says a pane's cursor is, zero-based from the top-left of the
/// visible screen.
struct TmuxPaneCursor {
    let column: Int
    let row: Int
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
    /// Nil when tmux would not answer.
    let cursor: TmuxPaneCursor?
}
