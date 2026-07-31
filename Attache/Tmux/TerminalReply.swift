//
//  TerminalReply.swift
//  Attache
//

import Foundation

/// Tells a terminal's *answers* apart from a user's *keystrokes*.
///
/// libghostty renders a pane, and everything it wants to send to the program
/// comes back on one channel, which this app forwards to `send-keys` — the
/// pane's keyboard. Most of that is the user typing. Some of it is not: a
/// terminal also speaks on its own behalf, answering `CSI c` with its device
/// attributes, `CSI 6n` with the cursor position, and — once a program turns
/// on mouse tracking — reporting the pointer on every screen refresh.
///
/// Those answers are wrong here twice over. tmux is the pane's terminal and
/// already answers for it, so the program gets a second reply it never asked
/// for; and this app has no mouse plumbing at all, so the pointer position it
/// reports is whatever stale coordinate the surface last saw, re-sent at the
/// display's refresh rate. Against a TUI they are noise. Against a shell
/// prompt they are command-line text.
///
/// **Why this is decided on the bytes and not on where they came from.**
/// The obvious fix is provenance — mark the keyboard entry points and forward
/// only what they produce. It does not work: libghostty hands key events to
/// its own thread, and the write callback for a keystroke arrives
/// asynchronously on `com.apple.root.default-qos.overcommit`, the same queue
/// and the same way a mouse report does. Measured against libghostty-spm at
/// the pinned commit on 2026-07-26 — a flag held across `keyDown` or across an
/// AppKit mouse call catches neither. The call stack carries no provenance, so
/// the grammar is what is left.
///
/// **Why it is safe.** A payload is dropped only when *every* byte of it
/// parses as one of these answers, and no key encoding produces any of them:
/// keys are text, control bytes, `SS3` letters, `CSI` finals in `A`-`H`/`P`-`S`
/// /`~`, or a bare `CSI …u` for the kitty protocol. Anything this file does
/// not fully recognise is forwarded untouched, so the failure mode is a report
/// that leaks — never a keystroke that vanishes.
///
/// **What deliberately still leaks**, because closing these would mean
/// guessing at bytes that a key can also produce, or holding state across
/// callbacks:
/// - `CSI row;col R`, the plain cursor-position report. xterm encodes modified
///   F3 as `CSI 1;2R`, byte for byte the same thing. The private form
///   `CSI ? row;col R` has no such twin and is withheld.
/// - Mode 1005 mouse reports, which UTF-8-encode the three bytes after
///   `CSI M`. Reading them would mean deciding how many bytes to consume
///   without knowing which mode is on, and consuming too many is how a
///   keystroke disappears.
/// - Any reply split across two write callbacks. Nothing here carries state
///   between calls; a half-parsed sequence is forwarded rather than buffered.
enum TerminalReply {
    /// Whether `data` is nothing but answers, and so must not reach the pane.
    static func isEntirelyReplies(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return false }

        var index = 0
        while index < bytes.count {
            guard let length = replyLength(bytes, at: index) else { return false }
            index += length
        }
        return true
    }

    /// Length of the answer starting at `start`, or `nil` if what is there is
    /// not one — including the case where it is one but has been cut short.
    private static func replyLength(_ bytes: [UInt8], at start: Int) -> Int? {
        guard start + 1 < bytes.count, bytes[start] == 0x1b else { return nil }

        switch bytes[start + 1] {
        case 0x5b: return csiReplyLength(bytes, at: start)                    // ESC [
        case 0x50: return stringReplyLength(bytes, at: start, allowsBEL: false) // ESC P — DCS
        case 0x5d: return stringReplyLength(bytes, at: start, allowsBEL: true)  // ESC ] — OSC
        default: return nil
        }
    }

    private static func csiReplyLength(_ bytes: [UInt8], at start: Int) -> Int? {
        var index = start + 2

        var privateMarker: UInt8?
        if index < bytes.count, (0x3c ... 0x3f).contains(bytes[index]) {
            privateMarker = bytes[index]
            index += 1
        }

        // X10 mouse reporting: `CSI M` and then three bytes that are a button
        // and a position, not parameters. They can be anything, including
        // bytes that would otherwise end a sequence, so this has to be taken
        // before the parameter scan.
        if privateMarker == nil, index < bytes.count, bytes[index] == 0x4d {
            let end = index + 4
            guard end <= bytes.count else { return nil }
            // The button byte is biased by 32 in X10.
            return isBareMotion(Int(bytes[index + 1]) - 32) ? end - start : nil
        }

        let parameterStart = index
        while index < bytes.count, (0x30 ... 0x3b).contains(bytes[index]) { index += 1 }
        let hasParameters = index > parameterStart
        let firstParameter = Self.firstParameter(bytes[parameterStart ..< index])

        while index < bytes.count, (0x20 ... 0x2f).contains(bytes[index]) { index += 1 }

        guard index < bytes.count, (0x40 ... 0x7e).contains(bytes[index]) else { return nil }
        let final = bytes[index]

        let isReply: Bool = switch privateMarker {
        case UInt8(0x3c):
            // SGR mouse (1006) and SGR-pixel mouse (1016): press/motion `M`,
            // release `m`.
            //
            // Only *bare motion* is withheld — see `isBareMotion`. Withholding
            // every mouse report was the first attempt and it broke scrolling
            // in every full-screen program: a wheel turn is a mouse report too,
            // and dropping it means the program is never told the user
            // scrolled.
            (final == 0x4d || final == 0x6d) && isBareMotion(firstParameter)
        case UInt8(0x3f), UInt8(0x3e), UInt8(0x3d):
            // Private answers: device attributes (`c`), mode report (`$y`),
            // kitty keyboard flags (`u`), status (`n`), extended cursor
            // position (`R`). A key never carries a private marker, which is
            // what makes these unambiguous — a kitty *key* is `CSI …u` with no
            // marker and stays forwarded.
            final == 0x63 || final == 0x79 || final == 0x75 || final == 0x6e
                || final == 0x52
        default:
            // Device status (`n`), urxvt mouse (1015, `M` with parameters),
            // and focus in/out (`I`/`O`, which carry no parameters).
            //
            // The plain cursor-position report `CSI row;col R` is deliberately
            // *not* here: xterm encodes modified F3 as `CSI 1;2R` — the same
            // bytes — so filtering it would eat Shift-F3. A leaked report is
            // recoverable; a key that never arrives is the failure this file
            // exists to avoid. Only the private form above can be told apart.
            final == 0x6e
                || (final == 0x4d && hasParameters && isBareMotion(firstParameter - 32))
                || ((final == 0x49 || final == 0x4f) && !hasParameters)
        }

        return isReply ? index + 1 - start : nil
    }

    /// Whether a mouse button code describes the pointer merely *passing over*
    /// the surface, with no button down and no wheel.
    ///
    /// This is the whole of the distinction the filter rests on. A terminal
    /// reports the pointer for three different reasons and only one of them is
    /// noise here:
    ///
    /// - **Bare motion** (bit 5 set, buttons reading 3 = none): sent because
    ///   the pointer is somewhere, not because the user did anything. tmux does
    ///   not give a control-mode client a mouse, so the coordinate is whatever
    ///   the surface last saw, re-sent. Nobody asked for it and nothing wants
    ///   it. Withheld.
    /// - **The wheel** (bit 6): a deliberate act. Withholding it is how the
    ///   first version of this filter silently broke scrolling in every
    ///   full-screen program — the pane simply never learned the user scrolled.
    /// - **Buttons and drags** (buttons reading 0/1/2, with or without bit 5):
    ///   also deliberate. Forwarded.
    ///
    /// Anything that does not parse is treated as *not* bare motion, so it is
    /// forwarded. Same direction as the rest of this file: leak rather than eat.
    private static func isBareMotion(_ buttonCode: Int) -> Bool {
        guard buttonCode >= 0 else { return false }
        let isMotion = buttonCode & 0b10_0000 != 0
        let isWheel = buttonCode & 0b100_0000 != 0
        let noButtonHeld = buttonCode & 0b11 == 0b11
        return isMotion && !isWheel && noButtonHeld
    }

    /// First semicolon-separated parameter, or -1 when there is not one.
    ///
    /// Digits are capped, and the cap is not tidiness. Swift traps on integer
    /// overflow in release builds as well as debug, so accumulating an
    /// unbounded digit run kills the process: `ESC [` followed by nineteen
    /// nines was enough, and it did not even need a final byte, because the
    /// parameter scan runs before the guard that checks for one. Pasting a log
    /// line into a pane whose program has not turned on bracketed paste is a
    /// realistic way to send exactly that.
    ///
    /// Nine digits covers every parameter this file reads — a mouse button
    /// code, a row, a column. Anything longer is not one of those, so -1 (the
    /// same value as "no parameter here") is the honest answer, and it makes
    /// `isBareMotion` false, so the payload is forwarded. Leak rather than eat,
    /// and above all do not die.
    private static func firstParameter(_ bytes: ArraySlice<UInt8>) -> Int {
        var value = -1
        var digits = 0
        for byte in bytes {
            guard (0x30 ... 0x39).contains(byte) else { break }
            digits += 1
            guard digits <= 9 else { return -1 }
            value = max(value, 0) * 10 + Int(byte - 0x30)
        }
        return value
    }

    /// `DCS`/`OSC` reply, up to its terminator.
    ///
    /// A terminal only ever *sends* these as answers — `XTGETTCAP` and
    /// `XTVERSION` come back as `DCS`, a colour query as `OSC`. No keystroke
    /// encodes to either, so the contents do not need inspecting; finding the
    /// end is enough.
    ///
    /// `OSC` accepts `BEL` as a terminator and `DCS` does not, which is not
    /// pedantry: sharing one scanner would let `ESC P … BEL` — a string that
    /// is not a complete reply at all — be recognised as one and withheld.
    private static func stringReplyLength(
        _ bytes: [UInt8],
        at start: Int,
        allowsBEL: Bool
    ) -> Int? {
        var index = start + 2
        while index < bytes.count {
            if allowsBEL, bytes[index] == 0x07 { return index + 1 - start }  // BEL
            if bytes[index] == 0x9c { return index + 1 - start }             // ST
            if bytes[index] == 0x1b, index + 1 < bytes.count, bytes[index + 1] == 0x5c {
                return index + 2 - start                                      // ESC \
            }
            index += 1
        }
        return nil
    }
}
