//
//  TmuxOctal.swift
//  TmuxGUI
//

import Foundation

/// Byte-level codec for the two places tmux control mode encodes payloads.
///
/// Everything here works on bytes, never on `String`. Verified against tmux
/// 3.6a: `%output` escapes control characters and backslash as three octal
/// digits, but passes bytes above 0x7f through raw — so a single `%output`
/// line can carry the tail of a UTF-8 sequence, or a byte that is not valid
/// UTF-8 at all (a partial write from the pane's program). Decoding via
/// `String(data:encoding:.utf8)` would replace each of those with U+FFFD and
/// silently corrupt the stream before Ghostty ever parses it.
enum TmuxOctal {
    /// Undo tmux's `\ooo` escaping. Bytes that are not a well-formed escape
    /// are copied through, which is what tmux's own encoder guarantees.
    static func decode(_ bytes: [UInt8]) -> Data {
        // Fast path: most output lines from a normal program contain no
        // backslash at all, so skip building a new buffer byte by byte.
        guard bytes.contains(UInt8(ascii: "\\")) else { return Data(bytes) }

        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            guard byte == UInt8(ascii: "\\"), i + 3 < bytes.count else {
                out.append(byte)
                i += 1
                continue
            }
            let d0 = bytes[i + 1], d1 = bytes[i + 2], d2 = bytes[i + 3]
            guard isOctalDigit(d0), isOctalDigit(d1), isOctalDigit(d2) else {
                out.append(byte)
                i += 1
                continue
            }
            let value = (Int(d0 - 0x30) << 6) | (Int(d1 - 0x30) << 3) | Int(d2 - 0x30)
            out.append(UInt8(truncatingIfNeeded: value))
            i += 4
        }
        return Data(out)
    }

    /// Encode keystrokes for `send-keys -H`, which takes one hex number per
    /// byte. The man page calls them "ASCII characters", but tmux 3.6a accepts
    /// arbitrary byte values — verified by sending `e4 b8 ad` and reading 中
    /// back out of the pane — so multi-byte UTF-8 input needs no special case.
    static func hexArguments(for data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func isOctalDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "7")
    }
}
