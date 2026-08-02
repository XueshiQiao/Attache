//
//  StartupTarget.swift
//  Attache
//

import Foundation

/// Which session and window the app should open on.
///
/// **The配置 holds names; everything that touches tmux still uses ids.** That
/// is not a loophole in CLAUDE.md's rule — it is what the rule is for. A name
/// is arbitrary user text and must never be interpolated into a command line,
/// so it is used here for one thing only: comparing against the names tmux has
/// already reported, to find the id that goes with it. The id is what gets
/// sent. A session called `"; kill-server #` is matched or not matched and
/// nothing else happens to it.
///
/// **Every failure falls back rather than stopping.** A preference that names
/// a session which is not running today has to leave the app on its ordinary
/// default, because the alternative is an app that opens on nothing after the
/// person renames a session.
enum StartupTarget {

    /// Find a session id by name, or nil.
    ///
    /// Matching is deliberately forgiving in two ways, both of them because
    /// the person is typing this into a text file from memory:
    ///
    /// - **Case-insensitive.** `dev` and `DEV` are the same session to a
    ///   person and there is no reason to make them different here.
    /// - **Diacritic-insensitive.** This app is called `Attaché` and its
    ///   window is called `Attache`; CLAUDE.md has a whole section on that
    ///   distinction being load-bearing elsewhere. Someone configuring a
    ///   window called `Attache` will very reasonably type `Attaché`, and
    ///   refusing that would be a puzzle with no upside.
    ///
    /// Exact matches win over folded ones, so a person with both `dev` and
    ///`Dev` gets the one they typed.
    static func id(
        matching wanted: String, in candidates: [(id: String, name: String)]
    ) -> String? {
        let target = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        // **An ambiguous name resolves to nothing, deliberately.** Taking the
        // first of several matches looks helpful and is not: tmux windows are
        // routinely called `zsh`, several at a time, so `startup_window =
        // "zsh"` would always land on whichever one happened to come first and
        // there would be no way to ask for any of the others. Worse, it would
        // look like it worked. Refusing sends the person back to the file to
        // give a name that identifies one thing.
        let exact = candidates.filter { $0.name == target }
        if exact.count == 1 { return exact[0].id }
        if exact.count > 1 { return nil }

        let folded = fold(target)
        guard !folded.isEmpty else { return nil }
        let loose = candidates.filter { fold($0.name) == folded }
        return loose.count == 1 ? loose[0].id : nil
    }

    /// Why a lookup came back empty, for the log. The two cases need different
    /// fixes from the person — one is a typo, the other is a name that is not
    /// unique — and a single "not found" cannot tell them apart.
    enum Miss: Equatable {
        case noMatch
        case ambiguous(count: Int)
    }

    static func miss(
        matching wanted: String, in candidates: [(id: String, name: String)]
    ) -> Miss {
        let target = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = candidates.filter { $0.name == target }
        if exact.count > 1 { return .ambiguous(count: exact.count) }
        let loose = candidates.filter { fold($0.name) == fold(target) }
        if loose.count > 1 { return .ambiguous(count: loose.count) }
        return .noMatch
    }

    /// Lower-cased and stripped of accents, for comparison only.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
