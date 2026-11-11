//
//  WorkspaceForm.swift
//  Attache
//

import AppKit

/// The three fields of a saved workspace, asked for in a sheet-sized alert.
///
/// Saving and killing are offered together because that is the reason to
/// save: the window was only being kept so it could be found again. The
/// button that kills says so in its own title and is marked destructive, and
/// it is never the default — Return saves and leaves the window alone.
@MainActor
enum WorkspaceForm {
    enum Outcome: Equatable {
        case cancel
        case save(WorkspaceDraft)
        case saveAndKill(WorkspaceDraft)
    }

    /// `killing` names the window the third button would kill; nil when there
    /// is no window to kill (editing a saved workspace).
    ///
    /// A panel of its own rather than an `NSAlert`: an alert with three
    /// buttons stacks them full-width under an app icon, which put a kill
    /// one row below the default button and at the same size. Here the two
    /// ordinary answers sit bottom right where a dialog's always do, and
    /// the kill is alone on the left, away from both.
    static func run(title: String, draft: WorkspaceDraft, killing window: String?) -> Outcome {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        panel.title = title

        let name = field(draft.name, placeholder: "PastePaw")
        let path = field(draft.path, placeholder: "~/Code/PastePawX")
        let command = field(draft.command, placeholder: "claude")
        let grid = NSGridView(views: [
            [label("Name"), name],
            [label("Folder"), path],
            [label("Command"), command],
            [NSGridCell.emptyContentView, note("Runs in your shell, so an alias works. Leave empty for a plain shell.")],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.row(at: 3).topPadding = -4

        let choice = Choice()
        func button(_ title: String, _ response: NSApplication.ModalResponse, key: String = "") -> NSButton {
            let button = NSButton(title: title, target: choice, action: #selector(Choice.choose(_:)))
            button.tag = response.rawValue
            button.keyEquivalent = key
            return button
        }
        let save = button("Save", .alertFirstButtonReturn, key: "\r")
        let cancel = button("Cancel", .alertSecondButtonReturn, key: "\u{1b}")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var row: [NSView] = [spacer, cancel, save]
        var rows: [NSView] = [grid]
        if let window {
            let kill = button("Save and Kill Window", .alertThirdButtonReturn)
            kill.hasDestructiveAction = true
            kill.toolTip = "Saves, then kills \(window): every process in it ends, including any AI agent mid-run."
            row.insert(kill, at: 0)
            rows.append(note(
                "“Save and Kill Window” also kills \(window): every process in it ends,"
                    + " including any AI agent mid-run."
            ))
        }
        let buttons = NSStackView(views: row)
        buttons.orientation = .horizontal
        buttons.spacing = 10
        rows.append(buttons)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: grid.widthAnchor),
        ])
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        panel.center()
        panel.initialFirstResponder = draft.command.isEmpty ? command : name

        let answer = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        let result = WorkspaceDraft(name: name.stringValue, path: path.stringValue, command: command.stringValue)
        switch answer {
        case .alertFirstButtonReturn: return .save(result)
        case .alertThirdButtonReturn: return .saveAndKill(result)
        default: return .cancel
        }
    }

    /// The buttons' target: ends the modal session with the button's own tag.
    private final class Choice: NSObject {
        @objc func choose(_ sender: NSButton) {
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: sender.tag))
        }
    }

    private static func note(_ text: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 380
        return note
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// A command is code, not prose: one curled quote from a substitution and
    /// the shell reads a different command. `Plain` turns every substitution
    /// off in the field editor, where they live.
    private static func field(_ text: String, placeholder: String) -> NSTextField {
        let field = PlainTextField(string: text)
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.isAutomaticTextCompletionEnabled = false
        field.widthAnchor.constraint(equalToConstant: 380).isActive = true
        return field
    }

    private final class PlainTextField: NSTextField {
        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if let editor = currentEditor() as? NSTextView {
                editor.isAutomaticTextReplacementEnabled = false
                editor.isAutomaticSpellingCorrectionEnabled = false
                editor.isContinuousSpellCheckingEnabled = false
                editor.isAutomaticQuoteSubstitutionEnabled = false
                editor.isAutomaticDashSubstitutionEnabled = false
            }
            return became
        }
    }
}
