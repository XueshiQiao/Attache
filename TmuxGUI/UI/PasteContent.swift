//
//  PasteContent.swift
//  TmuxGUI
//

import Cocoa

/// What a macOS pasteboard means to a terminal pane.
///
/// A paste is not always text, and this app assumed it always was: ⌘V read
/// `.string` and stopped. A file copied in Finder and a screenshot taken with
/// ⇧⌘4 both arrived as *nothing at all*, with no error anywhere, because
/// neither of them puts a string on the pasteboard.
///
/// One reading serves ⌘V and a drop, which is the point of the type: a drag
/// carries its own pasteboard and otherwise poses exactly the same question.
///
/// The order is Ghostty's, and it is not arbitrary. A file reference wins over
/// any text describing it, because a path is the only form a program running in
/// the pane can act on.
enum PasteContent {
    /// Send these bytes to the pane.
    case text(String)

    /// Pixels, and no file anywhere to point at.
    ///
    /// Nothing can be sent, and no amount of work here changes that: a terminal
    /// carries bytes, and an image on the pasteboard is not bytes the pane can
    /// be given. What the image-aware TUIs do — Claude Code, Grok, OpenCode —
    /// is read the system pasteboard themselves when they see **Ctrl-V**, which
    /// is why that key does something in those programs and ⌘V does not. So the
    /// only useful answer is to send Ctrl-V and let the program fetch what it
    /// can already see.
    ///
    /// libghostty's own `paste(_:)` does exactly this; this app cannot use it
    /// (a pane's paste has to go through tmux) so it makes the same decision.
    case imageWithoutFile

    case nothing

    static func read(from pasteboard: NSPasteboard) -> PasteContent {
        // `urlReadingFileURLsOnly`, because a URL dragged out of a browser is
        // an http one and belongs in the pane as the text it is.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return .text(urls.map { shellToken(for: $0.path) }.joined(separator: " "))
        }

        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return .text(string)
        }

        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
            return .imageWithoutFile
        }

        return .nothing
    }

    /// A path as one shell argument.
    ///
    /// Quoted only when it has to be, because a bare path is what the person
    /// dragging the file expects to see land in their prompt, and single quotes
    /// around it are noise they then have to delete. Anything outside the safe
    /// set gets single quotes — which cannot themselves appear inside them, so
    /// an embedded quote closes, escapes and reopens. A path is arbitrary user
    /// text: this is the one place in the app where real text is interpolated
    /// into something a shell will read, and it is the same reasoning as
    /// `TmuxCommand.quote`.
    static func shellToken(for path: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/")
        if !path.isEmpty, path.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
