//
//  OutboundShape.swift
//  Attache
//

#if DEBUG

    import Foundation

    /// Names the *shape* of a byte string the terminal wants to send to tmux,
    /// without ever recording what it says.
    ///
    /// The write path carries whatever the user typed, so it can never be
    /// logged — `TmuxLog.redacted` exists for exactly that reason. But when the
    /// app sends bytes nobody typed, "705 writes of 12 bytes each" is not
    /// enough to tell a cursor-position report from an SGR mouse event from a
    /// paste, and those are three different bugs with three different fixes.
    ///
    /// A sequence's grammar is not its content: the introducer, the private
    /// marker, how many parameters there are and which final byte terminates
    /// them identify `ESC [ < 35 ; 100 ; 20 M` as a mouse report without
    /// revealing where the pointer was. Parameter *values* are never emitted,
    /// and printable text is reduced to a count.
    enum OutboundShape {
        static func describe(_ data: Data) -> String {
            let bytes = [UInt8](data)
            guard !bytes.isEmpty else { return "empty" }

            let detail: String
            if bytes[0] == 0x1b, bytes.count >= 2 {
                switch bytes[1] {
                case 0x5b: detail = csi(bytes.dropFirst(2))          // ESC [
                case 0x4f: detail = ss3(bytes.dropFirst(2))          // ESC O
                case 0x5d: detail = "OSC"                            // ESC ]
                case 0x50: detail = "DCS"                            // ESC P
                case 0x5f: detail = "APC"                            // ESC _
                default: detail = "ESC + 1 byte"
                }
            } else if bytes[0] == 0x1b {
                detail = "bare ESC"
            } else {
                detail = plain(bytes)
            }

            return "\(detail), \(bytes.count) bytes"
        }

        /// `CSI [private] params… [intermediates] final`.
        ///
        /// The private marker is reported because it is what separates a mouse
        /// report (`CSI <`) from an ordinary cursor key, and it is grammar, not
        /// data. Parameters are counted, never printed.
        private static func csi(_ body: ArraySlice<UInt8>) -> String {
            var index = body.startIndex
            var privateMarker = ""
            if index < body.endIndex, (0x3c ... 0x3f).contains(body[index]) {
                privateMarker = " private '\(Character(UnicodeScalar(body[index])))'"
                index += 1
            }

            var parameters = 0
            var sawDigit = false
            while index < body.endIndex, (0x30 ... 0x3f).contains(body[index]) {
                if body[index] == 0x3b {
                    parameters += 1
                    sawDigit = false
                } else {
                    sawDigit = true
                }
                index += 1
            }
            if sawDigit || parameters > 0 { parameters += 1 }

            while index < body.endIndex, (0x20 ... 0x2f).contains(body[index]) { index += 1 }

            guard index < body.endIndex else {
                return "CSI\(privateMarker), unterminated, \(parameters) params"
            }
            return "CSI\(privateMarker), final '\(Character(UnicodeScalar(body[index])))', "
                + "\(parameters) params"
        }

        private static func ss3(_ body: ArraySlice<UInt8>) -> String {
            guard let final = body.first else { return "SS3, unterminated" }
            return "SS3, final '\(Character(UnicodeScalar(final)))'"
        }

        /// Plain input — the case that really is the user's keystrokes. Only a
        /// classification of the bytes survives, never the bytes.
        private static func plain(_ bytes: [UInt8]) -> String {
            if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) { return "printable text" }
            if bytes.allSatisfy({ $0 < 0x20 || $0 == 0x7f }) { return "control bytes" }
            return "mixed text"
        }
    }

#endif
