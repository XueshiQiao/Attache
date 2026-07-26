//
//  TmuxText.swift
//  TmuxGUI
//

import Foundation

enum TmuxText {
    /// Strip terminal control sequences so tmux-sourced text is safe to put in
    /// a window title or a menu.
    ///
    /// tmux's `automatic-rename` names a window after whatever the pane last
    /// ran, so a window name routinely contains raw CSI sequences. Dropping
    /// just the ESC byte is not enough — that leaves the parameter bytes
    /// behind as literal text like `[31m`.
    static func plain(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)

        var scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]

            guard scalar == "\u{1b}" else {
                // Drop remaining C0 controls and DEL; keep everything else,
                // including CJK and emoji.
                if scalar.value >= 0x20, scalar.value != 0x7f {
                    out.unicodeScalars.append(scalar)
                }
                index += 1
                continue
            }

            index += 1
            guard index < scalars.count else { break }

            switch scalars[index] {
            case "[":
                // CSI: parameters and intermediates, then a final byte in
                // 0x40...0x7e.
                index += 1
                while index < scalars.count, !(0x40 ... 0x7e).contains(scalars[index].value) {
                    index += 1
                }
                index += 1
            case "]":
                // OSC: runs until BEL or ST (ESC \).
                index += 1
                while index < scalars.count {
                    if scalars[index] == "\u{07}" { index += 1; break }
                    if scalars[index] == "\u{1b}", index + 1 < scalars.count, scalars[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                // Two-character sequence such as ESC k … ESC \ (window title).
                index += 1
            }
        }

        return out.trimmingCharacters(in: .whitespaces)
    }
}
