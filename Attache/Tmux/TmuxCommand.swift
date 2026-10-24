//
//  TmuxCommand.swift
//  Attache
//

import Foundation

enum TmuxCommand {
    /// Quote a string for tmux's command parser.
    ///
    /// Only needed for genuine user text such as a new window name — every
    /// other target in this app is an id. tmux treats a single-quoted string
    /// as literal with no escapes available inside it, so an embedded quote
    /// has to close, escape, and reopen, the same trick sh uses.
    static func quote(_ text: String) -> String {
        // Control characters have no business in a window name and would let
        // a newline split the command line in two.
        let cleaned = text.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7f }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        return "'" + cleaned.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
