//
//  TagForm.swift
//  Attache
//

import AppKit

/// The small modal forms that make and change a window tag: a name, and
/// for a new tag a colour too.
enum TagForm {
    /// A new tag's name and colour; nil when cancelled or left empty.
    @MainActor
    static func askNew() -> (name: String, color: String)? {
        let alert = NSAlert()
        alert.messageText = "New Tag"
        alert.informativeText = "Put a tag on windows you mean to come back to; a window without one is"
            + " easy to tell apart as one you can close when it is done."
        let name = field("", placeholder: "Follow up")
        let colors = NSPopUpButton(frame: .zero, pullsDown: false)
        for color in TagCommands.colors {
            colors.addItem(withTitle: color.capitalized)
            colors.lastItem?.attributedTitle = TagPalette.menuTitle(
                color.capitalized, color: color, font: colors.font ?? .menuFont(ofSize: 0)
            )
            colors.lastItem?.representedObject = color
        }
        // Gray is the fallback colour, so a new tag starts on the next one.
        colors.selectItem(at: 2)
        let stack = NSStackView(views: [name, colors])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        name.widthAnchor.constraint(equalToConstant: 180).isActive = true
        alert.accessoryView = stack
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = tidy(name.stringValue)
        guard !text.isEmpty else { return nil }
        let color = colors.selectedItem?.representedObject as? String ?? TagCommands.colors[2]
        return (text, color)
    }

    /// A tag's new name; nil when cancelled, left empty or unchanged.
    @MainActor
    static func askRename(_ current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename Tag"
        alert.informativeText = "Every window that carries “\(current)” shows the new name."
        let name = field(current, placeholder: current)
        name.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = name
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = tidy(name.stringValue)
        return text.isEmpty || text == current ? nil : text
    }

    private static func tidy(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    @MainActor
    private static func field(_ text: String, placeholder: String) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        // The completion popup takes the Return that was meant to press the
        // default button; see "Autocorrect eats Return" in AGENTS.md.
        field.isAutomaticTextCompletionEnabled = false
        return field
    }
}
