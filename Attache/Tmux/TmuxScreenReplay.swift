//
//  TmuxScreenReplay.swift
//  Attache
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
///
/// ## Why the order is what it is
///
/// Almost every sequence here has a side effect on the cursor or on which
/// buffer is being written to, so this is a sequence of steps rather than a
/// bag of settings:
///
/// 1. **The primary screen, on a first paint.** History belongs in the primary
///    buffer's scrollback — that is where a real terminal put it — so the
///    replay starts there whatever the pane is doing now.
/// 2. **A neutral terminal**, before a single row is written. The surface is in
///    whatever modes the *previous* program left it in, and two of them decide
///    what writing a row even does: a scroll region makes the CR LFs between
///    rows scroll inside that region instead of the screen, so a 24-row
///    snapshot written into a pane left on rows 1-10 by a vim shuffles itself
///    inside those ten and overwrites the rest; and origin mode makes the home
///    that follows land at the top of that region rather than of the screen.
///    Insert mode and autowrap are reset with them for the same reason —
///    cheaper to state than to reason about. The pane's *real* modes go on at
///    step 7, once there is nothing left to write.
/// 3. **Erase.** A repaint replaces the screen rather than adding to it, and a
///    first paint has to replace whatever `TmuxOutputRouter.register` handed
///    over a moment earlier, or the snapshot is a second copy of it.
/// 4. **History, on a first paint only.** A repaint's scrollback is real and
///    nothing here replaces it.
/// 5. **The alternate screen, if the pane is on it.** After the history, so
///    vim's screen does not land in the scrollback, and before the rows, so
///    they land on the buffer they belong to. Emitted either way on a repaint,
///    because a program that has *exited* since the last paint needs the
///    switch back as much as one that just started needs the switch in. Each
///    buffer keeps its own scroll region, so the neutral reset is repeated
///    after the switch rather than assumed to have carried across.
/// 6. **The rows.**
/// 7. **The scroll region**, which homes the cursor, so it cannot come after
///    the cursor is placed.
/// 8. **Origin mode**, which also homes the cursor *and* changes what a cursor
///    position means.
/// 9. **Everything else**, none of which moves the cursor.
/// 10. **The cursor.**
enum TmuxScreenReplay {
    /// - Parameter isFirstPaint: whether this is the first thing a pane's
    ///   surface has ever been shown. It decides two things that must not
    ///   happen on a repaint: erasing the scrollback, and writing history into
    ///   it.
    static func payload(
        for snapshot: TmuxPaneSnapshot, isFirstPaint: Bool
    ) -> Data {
        var payload = Data()
        let alternate = snapshot.modes?.alternateScreen ?? false

        if isFirstPaint {
            payload += esc("[?1049l")
            payload += neutral
            payload += esc("[H") + esc("[2J")
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
            payload += esc("[3J")
            append(snapshot.history, to: &payload)
            // Separator, so the first row of the screen starts a line of its
            // own rather than continuing the last line of the history.
            if !snapshot.history.isEmpty { payload += crlf }

            // Deliberately no second erase when the pane is *not* on the
            // alternate screen: the last rows of the history are still in the
            // viewport, mid-scroll, and clearing here would punch a hole
            // between the scrollback and the screen.
            if alternate { payload += esc("[?1049h") + neutral + esc("[H") + esc("[2J") }
        } else {
            payload += esc(alternate ? "[?1049h" : "[?1049l")
            payload += neutral
            payload += esc("[H") + esc("[2J")
        }

        append(snapshot.screen, to: &payload)
        if let modes = snapshot.modes { payload += modeSequences(modes) }

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
            payload += esc("[\(cursorRow(cursor, snapshot.modes));\(cursor.column + 1)H")
        }
        return payload
    }

    /// The row for `CUP`, one-based, in whatever coordinate system origin mode
    /// has just put the terminal in.
    ///
    /// tmux reports the cursor's *screen* row even when origin mode is on —
    /// measured on 3.6a — and `CUP` under origin mode counts from the top of
    /// the scroll region. Sending tmux's number straight through would put the
    /// cursor `scroll_region_upper` rows too far down, silently, on exactly the
    /// programs that use a scroll region.
    private static func cursorRow(_ cursor: TmuxPaneCursor, _ modes: TmuxPaneModes?) -> Int {
        guard let modes, modes.origin else { return cursor.row + 1 }
        return max(1, cursor.row - modes.scrollRegionUpper + 1)
    }

    /// Every mode, in an order chosen so that nothing later undoes something
    /// earlier. See the type's own note.
    private static func modeSequences(_ modes: TmuxPaneModes) -> Data {
        var payload = Data()

        // DECSTBM first: it homes the cursor. One-based on the wire, zero-based
        // from tmux.
        payload += esc("[\(modes.scrollRegionUpper + 1);\(modes.scrollRegionLower + 1)r")
        // DECOM second, for the same reason and one more: it decides what the
        // cursor position at the end of this means.
        payload += esc(modes.origin ? "[?6h" : "[?6l")

        payload += esc(modes.cursorVisible ? "[?25h" : "[?25l")
        payload += esc(modes.wrap ? "[?7h" : "[?7l")
        payload += esc(modes.insert ? "[4h" : "[4l")
        payload += esc(modes.applicationCursorKeys ? "[?1h" : "[?1l")
        // Not a CSI: DECKPAM and DECKPNM are two-byte sequences.
        payload += esc(modes.applicationKeypad ? "=" : ">")

        // The mouse modes are why the wheel over a `less` or a vim pane
        // scrolled libghostty's own buffer instead of reaching the program.
        payload += esc(modes.mouseStandard ? "[?1000h" : "[?1000l")
        payload += esc(modes.mouseButton ? "[?1002h" : "[?1002l")
        payload += esc(modes.mouseAll ? "[?1003h" : "[?1003l")
        payload += esc(modes.mouseSGR ? "[?1006h" : "[?1006l")
        payload += esc(modes.mouseUTF8 ? "[?1005h" : "[?1005l")

        payload += esc("[\(decscusr(modes)) q")
        // Carried separately because tmux does: `CSI ?12h` sets
        // `cursor_blinking` while leaving the shape at `default`, which
        // DECSCUSR 0 cannot express.
        payload += esc(modes.cursorBlinking ? "[?12h" : "[?12l")
        return payload
    }

    /// tmux's shape word and blink flag back into one DECSCUSR parameter.
    /// The mapping was measured rather than assumed; see `TmuxPaneModes`.
    private static func decscusr(_ modes: TmuxPaneModes) -> Int {
        switch modes.cursorShape {
        case "block": modes.cursorBlinking ? 1 : 2
        case "underline": modes.cursorBlinking ? 3 : 4
        case "bar": modes.cursorBlinking ? 5 : 6
        // Including any word a future tmux invents: "leave it alone" is the
        // one answer that cannot be wrong about a shape this does not know.
        default: 0
        }
    }

    /// A terminal that will do what writing a row looks like it does.
    ///
    /// `ESC[r` is DECSTBM with no parameters: the scroll region becomes the
    /// whole screen. Without it the CR LFs between rows scroll inside whatever
    /// region the previous program left behind. The other three are here
    /// because reasoning about whether they matter costs more than sending
    /// them, and every one of them is set to its real value a few bytes later.
    private static let neutral =
        esc("[r") + esc("[?6l") + esc("[?7h") + esc("[4l")

    private static let crlf = Data([0x0d, 0x0a])

    private static func esc(_ tail: String) -> Data {
        Data(Array("\u{1b}\(tail)".utf8))
    }

    /// Rows joined by CR LF, with none after the last — a trailing newline
    /// would scroll the screen by one and leave every row a line higher than
    /// tmux has it, which is the same off-by-one the cursor is counted in.
    ///
    /// CR LF rather than LF because the surface is a terminal: a bare LF steps
    /// down a row without returning to column one.
    private static func append(_ rows: [Data], to payload: inout Data) {
        for (index, row) in rows.enumerated() {
            if index > 0 { payload += crlf }
            payload += row
        }
    }
}
