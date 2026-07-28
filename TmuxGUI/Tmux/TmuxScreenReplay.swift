//
//  TmuxScreenReplay.swift
//  TmuxGUI
//

import Foundation

/// Turns tmux's picture of a pane into the bytes a terminal surface has to be
/// fed to end up looking like it.
///
/// Kept away from the views, and from anything that needs a screen, because
/// this is the one part of the repaint that can be *checked*: it is a pure
/// function from a `capture-pane` reply to a byte string, and
/// `Tools/ScreenReplayCheck` runs a table of cases over it. Everything else
/// about a repaint needs a running app, a GPU surface and someone to look at
/// the result — which on a machine whose displays are asleep is not available
/// at all.
enum TmuxScreenReplay {
    /// - Parameter isFirstPaint: whether this is the first thing a pane's
    ///   surface has ever been shown. It decides two things that must not
    ///   happen on a repaint: erasing the scrollback, and writing history into
    ///   it.
    static func payload(
        for snapshot: TmuxPaneSnapshot, isFirstPaint: Bool
    ) -> Data {
        // Home and erase. A repaint is replacing the screen, not adding to it.
        var payload = Data(Array("\u{1b}[H\u{1b}[2J".utf8))

        if isFirstPaint {
            // `CSI 3 J` — erase saved lines. Asked for rather than relied on:
            // if this build of libghostty does not implement it the sequence is
            // ignored, and the residue is that output the router had already
            // handed over, and which had already scrolled off the top, appears
            // once more in the scrollback below the copy tmux is about to
            // supply. The visible screen is right either way, because the erase
            // above is not optional.
            //
            // Never on a repaint. A repaint supplies the visible screen only,
            // so erasing the scrollback there would throw away history nothing
            // is about to replace — the pane's own, going back to before the
            // app was running.
            payload.append(contentsOf: Array("\u{1b}[3J".utf8))
            append(snapshot.history, to: &payload)
            // Separator, so the first row of the screen starts a line of its
            // own rather than continuing the last line of the history.
            if !snapshot.history.isEmpty { payload.append(contentsOf: [0x0d, 0x0a]) }
        }

        append(snapshot.screen, to: &payload)

        // Put the cursor back where tmux has it. Writing the rows leaves it
        // after the last byte of the last one — the end of the bottom-most line
        // with anything on it, which for a full-screen program is its status
        // bar. It corrected itself the moment the program next drew anything,
        // which is why it only ever looked wrong on arriving somewhere.
        //
        // This used to be skipped for a first paint, on the stated grounds that
        // replaying scrollback leaves tmux's row number nothing to be relative
        // to. True of one combined capture; not true here. The history and the
        // screen arrive as ranges that meet exactly, and every row of the
        // screen is written, so once the history has scrolled through the
        // viewport, viewport row 0 is screen row 0. See
        // `TmuxSessionConnection.capturePane`.
        if let cursor = snapshot.cursor {
            payload.append(contentsOf: Array("\u{1b}[\(cursor.row + 1);\(cursor.column + 1)H".utf8))
        }
        return payload
    }

    /// Rows joined by CR LF, with none after the last — a trailing newline
    /// would scroll the screen by one and leave every row a line higher than
    /// tmux has it, which is the same off-by-one the cursor is counted in.
    ///
    /// CR LF rather than LF because the surface is a terminal: a bare LF steps
    /// down a row without returning to column one.
    private static func append(_ rows: [Data], to payload: inout Data) {
        for (index, row) in rows.enumerated() {
            if index > 0 { payload.append(contentsOf: [0x0d, 0x0a]) }
            payload.append(row)
        }
    }
}
