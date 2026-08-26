//
//  SessionNames.swift
//  Attache
//

import Foundation

/// What a fresh session gets called. tmux's own default is the next free
/// number, and a rail with sessions named 0, 1 and 2 reads like something
/// failed to load — a city reads like a place to work, and its capital
/// first letter sits well beside the hand-named sessions in the rail.
///
/// The atlas is plain ASCII, one word per city, with nothing tmux treats
/// specially (`:` and `.` address windows and panes) and nothing the shell
/// layers could trip on — which is what makes passing one to
/// `new-session -s` safe without leaning on the quoting that guards *user*
/// text. Creating with a name is authoring, like renaming; the
/// target-by-id rule is about addressing what already exists.
nonisolated enum SessionNames {
    static let words = [
        "Lisbon", "Porto", "Madrid", "Seville", "Turin", "Milan", "Naples",
        "Vienna", "Prague", "Krakow", "Oslo", "Bergen", "Helsinki", "Riga",
        "Dublin", "Lyon", "Geneva", "Kyoto", "Osaka", "Nara", "Seoul",
        "Busan", "Taipei", "Hanoi", "Bangkok", "Jakarta", "Perth",
        "Auckland", "Havana", "Lima", "Quito", "Cusco", "Denver", "Austin",
        "Portland", "Nairobi", "Dakar", "Cairo", "Marrakesh", "Valparaiso",
        "Chengdu", "Hangzhou", "Suzhou", "Guilin", "Harbin", "Kunming",
        // Not an omission: 西安 romanises as Xi'an, and the apostrophe is
        // the one character this whole file exists to keep out of a shell.
    ]

    /// A name no current session is using. When the whole bowl is taken,
    /// a numbered one; the caller still handles the cross-client race by
    /// falling back to tmux's own numbering on "duplicate session".
    static func pick(avoiding used: Set<String>) -> String {
        if let name = words.filter({ !used.contains($0) }).randomElement() {
            return name
        }
        for suffix in 2 ... 99 {
            let name = "\(words.randomElement() ?? "session")-\(suffix)"
            if !used.contains(name) { return name }
        }
        return "session-\(Int.random(in: 100 ... 9999))"
    }
}
