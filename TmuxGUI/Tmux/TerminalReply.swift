//
//  TerminalReply.swift
//  TmuxGUI
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
        case 0x5b: return csiReplyLength(bytes, at: start)          // ESC [
        case 0x50: return stringReplyLength(bytes, at: start)       // ESC P — DCS
        case 0x5d: return stringReplyLength(bytes, at: start)       // ESC ] — OSC
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
            return end <= bytes.count ? end - start : nil
        }

        let parameterStart = index
        while index < bytes.count, (0x30 ... 0x3b).contains(bytes[index]) { index += 1 }
        let hasParameters = index > parameterStart

        while index < bytes.count, (0x20 ... 0x2f).contains(bytes[index]) { index += 1 }

        guard index < bytes.count, (0x40 ... 0x7e).contains(bytes[index]) else { return nil }
        let final = bytes[index]

        let isReply: Bool = switch privateMarker {
        case UInt8(0x3c):
            // SGR mouse (1006) and SGR-pixel mouse (1016): press/motion `M`,
            // release `m`. This is the encoding every modern program asks for
            // and it was 100% of the traffic this fix was written for.
            final == 0x4d || final == 0x6d
        case UInt8(0x3f), UInt8(0x3e), UInt8(0x3d):
            // Private answers: device attributes (`c`), mode report (`$y`),
            // kitty keyboard flags (`u`), status (`n`). A key never carries a
            // private marker, which is what makes these unambiguous — a kitty
            // *key* is `CSI …u` with no marker and stays forwarded.
            final == 0x63 || final == 0x79 || final == 0x75 || final == 0x6e
        default:
            // Cursor position (`R`), device status (`n`), urxvt mouse (1015,
            // `M` with parameters), and focus in/out (`I`/`O`, which carry no
            // parameters).
            final == 0x52 || final == 0x6e
                || (final == 0x4d && hasParameters)
                || ((final == 0x49 || final == 0x4f) && !hasParameters)
        }

        return isReply ? index + 1 - start : nil
    }

    /// `DCS`/`OSC` reply, up to its terminator.
    ///
    /// A terminal only ever *sends* these as answers — `XTGETTCAP` and
    /// `XTVERSION` come back as `DCS`, a colour query as `OSC`. No keystroke
    /// encodes to either, so the contents do not need inspecting; finding the
    /// end is enough.
    private static func stringReplyLength(_ bytes: [UInt8], at start: Int) -> Int? {
        var index = start + 2
        while index < bytes.count {
            if bytes[index] == 0x07 { return index + 1 - start }        // BEL
            if bytes[index] == 0x9c { return index + 1 - start }        // ST
            if bytes[index] == 0x1b, index + 1 < bytes.count, bytes[index + 1] == 0x5c {
                return index + 2 - start                                 // ESC \
            }
            index += 1
        }
        return nil
    }
}
