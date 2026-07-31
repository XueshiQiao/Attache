//
//  TerminalLinkTarget.swift
//  TmuxGUI
//

import Foundation

/// What a clicked link in the terminal turns out to be.
///
/// libghostty matches the link and hands over a string; deciding what that
/// string *is* happens here, with no view and no file system of its own, so
/// `Tools/LinkTargetCheck` can drive every case without a screen or a disk.
enum TerminalLinkTarget: Equatable {
    /// Something with a scheme the system opener understands — a web page, a
    /// mail address. Goes to the default handler.
    case url(URL)
    /// An existing directory. Finder opens it.
    case directory(String)
    /// An existing file. Finder opens its parent and selects it.
    case file(String)
    /// It parsed as a path and nothing is there. Worth saying so: the
    /// underline is drawn by libghostty, which matches on shape alone and
    /// never checks the disk, so a link can highlight and still lead nowhere.
    case missing(String)
    /// Not a link this app acts on.
    case unsupported
}

extension TerminalLinkTarget {
    /// What the file system says about a path, injected so the decision table
    /// can be tested against a fixture instead of the machine it runs on.
    enum Existence: Equatable {
        case file
        case directory
        case absent
    }

    /// Schemes handed to the system opener untouched.
    ///
    /// Deliberately a list rather than "anything with a scheme": libghostty's
    /// matcher also produces `file:`, which is a local path wearing a scheme
    /// and belongs on the Finder path, and refusing everything else keeps a
    /// click from launching a handler this app never considered.
    private static let openableSchemes: Set<String> = [
        "http", "https", "mailto", "ftp", "ssh", "git", "tel",
        "magnet", "ipfs", "ipns", "gemini", "gopher", "news",
    ]

    /// Decide what a matched link string refers to.
    ///
    /// `cwd` is the working directory of the pane the click landed in, and is
    /// the only thing that can resolve a relative match — libghostty's matcher
    /// happily produces `src/main.swift`, which means nothing on its own.
    /// A nil `cwd` therefore leaves a relative path unsupported rather than
    /// guessing against the app's own working directory, which is never the
    /// one the user was looking at.
    static func resolve(
        _ raw: String,
        cwd: String?,
        home: String = NSHomeDirectory(),
        existence: (String) -> Existence
    ) -> TerminalLinkTarget {
        // The matcher's last branch may take trailing spaces when they run to
        // the end of the line, and a path is often read out of prose that put
        // a comma or a closing bracket against it.
        let text = trimmed(raw)
        guard !text.isEmpty else { return .unsupported }

        if let scheme = scheme(of: text) {
            if openableSchemes.contains(scheme) {
                // `URL(string:)` and not a hand-built one: the string came off
                // a terminal screen and may hold anything, and a URL that will
                // not parse must not be handed to the opener.
                guard let url = URL(string: text) else { return .unsupported }
                return .url(url)
            }
            if scheme == "file" {
                guard let url = URL(string: text), url.isFileURL else { return .unsupported }
                return classify(url.path, existence: existence)
            }
            return .unsupported
        }

        return classify(absolutePath(for: text, cwd: cwd, home: home), existence: existence)
    }

    private static func classify(
        _ path: String?,
        existence: (String) -> Existence
    ) -> TerminalLinkTarget {
        guard let path, !path.isEmpty else { return .unsupported }
        switch existence(path) {
        case .file: return .file(path)
        case .directory: return .directory(path)
        case .absent: return .missing(path)
        }
    }

    /// Expand `~`, and resolve a relative match against the pane's directory.
    ///
    /// Returns nil when the path is relative and there is no directory to
    /// resolve it against — the one case where the app genuinely does not know
    /// what was clicked.
    private static func absolutePath(for text: String, cwd: String?, home: String) -> String? {
        if text == "~" { return home }
        if text.hasPrefix("~/") {
            return home + String(text.dropFirst(1))
        }
        // A leading `~` that is not `~/` is another user's home on Unix, which
        // this app has no business guessing at.
        if text.hasPrefix("~") { return nil }
        if text.hasPrefix("/") { return normalised(text) }
        guard let cwd, !cwd.isEmpty else { return nil }
        return normalised(cwd.hasSuffix("/") ? cwd + text : cwd + "/" + text)
    }

    /// Collapse `.` and `..` without touching the disk.
    ///
    /// `URL.standardized` would resolve symlinks against the running machine,
    /// which is the wrong answer for a path that came off another machine's
    /// screen over ssh; this only rewrites the text.
    private static func normalised(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = text[text.startIndex ..< colon]
        guard !candidate.isEmpty else { return nil }
        // A scheme is letters, digits, `+`, `-`, `.`, starting with a letter.
        // Checking this rather than splitting on the first colon is what keeps
        // `/tmp/notes:2` — a grep result — from reading as scheme `/tmp/notes`.
        guard let first = candidate.first, first.isLetter else { return nil }
        for character in candidate {
            guard character.isLetter || character.isNumber
                || character == "+" || character == "-" || character == "."
            else { return nil }
        }
        return candidate.lowercased()
    }

    /// Strip what prose put around a path, and nothing a path can contain.
    ///
    /// A bracket comes off in two situations and no others: the text is
    /// wrapped in a matching pair, or it ends with a closer whose opener is
    /// nowhere in the text. So `(/tmp/a.txt)` loses its parens while
    /// `/tmp/a(1).txt` keeps them.
    private static func trimmed(_ raw: String) -> String {
        let brackets = [("(", ")"), ("[", "]"), ("{", "}"), ("<", ">")]
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed, !text.isEmpty {
            changed = false
            if let last = text.last, ",;:".contains(last) {
                text.removeLast()
                changed = true
                continue
            }
            for (open, close) in brackets where text.hasPrefix(open) && text.hasSuffix(close) {
                text = String(text.dropFirst().dropLast())
                changed = true
                break
            }
            if changed { continue }
            for (open, close) in brackets {
                guard text.hasSuffix(close), !text.contains(open) else { continue }
                text.removeLast()
                changed = true
                break
            }
            if text.hasSuffix("."), !text.hasSuffix(".."), text != "." {
                // A trailing period ends a sentence far more often than it ends
                // a filename, and libghostty's own matcher drops one too.
                text.removeLast()
                changed = true
            }
        }
        return text
    }
}
