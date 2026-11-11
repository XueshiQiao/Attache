//
//  ProjectForm.swift
//  Attache
//

import AppKit

/// The three fields of a saved project, asked for in a sheet-sized alert.
///
/// Saving and killing are offered together because that is the reason to
/// save: the window was only being kept so it could be found again. The
/// button that kills says so in its own title and is marked destructive, and
/// it is never the default — Return saves and leaves the window alone.
@MainActor
enum ProjectForm {
    enum Outcome: Equatable {
        case cancel
        case save(ProjectDraft)
        case saveAndKill(ProjectDraft)
    }

    /// `killing` names the window the third button would kill; nil when there
    /// is no window to kill (editing a saved project).
    ///
    /// A panel of its own rather than an `NSAlert`: an alert with three
    /// buttons stacks them full-width under an app icon, which put a kill
    /// one row below the default button and at the same size. Here the two
    /// ordinary answers sit bottom right where a dialog's always do, and
    /// the kill is alone on the left, away from both.
    ///
    /// The command is a combo box over `suggestions` — the person's own list
    /// of often-used commands — because the same three or four commands are
    /// saved again and again and a picked one cannot be mistyped. Anything
    /// else can still be typed.
    static func run(title: String, draft: ProjectDraft, suggestions: [String],
                    killing window: String?) -> Outcome {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        panel.title = title

        let name = field(draft.name, placeholder: "PastePaw")
        let path = field(draft.path, placeholder: "~/Code/PastePawX")
        let command = PlainComboBox(string: draft.command)
        configure(command, placeholder: "claude")
        command.addItems(withObjectValues: suggestions)
        command.numberOfVisibleItems = min(max(suggestions.count, 1), 12)
        command.completes = false
        let grid = NSGridView(views: [
            [label("Name"), name],
            [label("Folder"), path],
            [label("Command"), command],
            [NSGridCell.emptyContentView, note(
                "Runs in your shell, so an alias works. Leave empty for a plain shell."
                    + " The list is yours: Projects ▸ Edit Commands…"
            )],
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
        let result = ProjectDraft(name: name.stringValue, path: path.stringValue, command: command.stringValue)
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
        configure(field, placeholder: placeholder)
        return field
    }

    private static func configure(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.isAutomaticTextCompletionEnabled = false
        field.widthAnchor.constraint(equalToConstant: 380).isActive = true
    }

    /// The often-used commands as a list: a field each, edited in place,
    /// with buttons on the row to move it or take it out, and a plus under
    /// the list. Returns the edited list, or nil when cancelled. Blank rows
    /// and repeats are attache-cli's to drop; what is typed here goes to it
    /// as typed.
    ///
    /// AppKit, after two SwiftUI versions that could not put the caret where
    /// it belonged — both measured on 2026-11-11 by asking the panel for its
    /// first responder. In a `List`, a row's field is the table's to open
    /// and `@FocusState` did nothing: the responder stayed the list after
    /// "Add Command". As plain fields in a scroll view, the responder after
    /// "Add Command" was still the *first* field, and nothing asked of the
    /// panel stopped that field taking the caret on opening. Here the caret
    /// goes where `makeFirstResponder` says, when it says.
    static func editCommands(_ commands: [String]) -> [String]? {
        let editor = CommandsEditor(commands)
        // Up, and then nothing focused: opening the panel is not the start
        // of editing the first command. Left alone AppKit gives the first
        // field the caret with its text selected, one keystroke from
        // replacing a command nobody meant to touch.
        editor.panel.makeKeyAndOrderFront(nil)
        editor.panel.makeFirstResponder(nil)
        let answer = NSApp.runModal(for: editor.panel)
        editor.panel.orderOut(nil)
        guard answer == .alertFirstButtonReturn else { return nil }
        return editor.commands
    }

    @MainActor
    private final class CommandsEditor: NSObject {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        private let rows = NSStackView()
        private let scroll = NSScrollView()

        var commands: [String] {
            rows.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.first as? NSTextField }
                .map(\.stringValue)
        }

        init(_ commands: [String]) {
            super.init()
            panel.title = "Commands"

            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 6
            rows.translatesAutoresizingMaskIntoConstraints = false
            let document = FlippedView()
            document.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(rows)
            scroll.documentView = document
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false

            let add = NSButton(title: "Add Command", target: self, action: #selector(addCommand))
            add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            add.imagePosition = .imageLeading
            let save = NSButton(title: "Save", target: self, action: #selector(finish(_:)))
            save.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            save.keyEquivalent = "\r"
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(finish(_:)))
            cancel.tag = NSApplication.ModalResponse.alertSecondButtonReturn.rawValue
            cancel.keyEquivalent = "\u{1b}"
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let buttons = NSStackView(views: [add, spacer, cancel, save])
            buttons.orientation = .horizontal
            buttons.spacing = 10

            let stack = NSStackView(views: [
                note("Offered when you save a project, so a command you use often is picked instead of"
                    + " typed. An alias works. Projects already saved keep the command they were saved with."),
                scroll, buttons,
            ])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            stack.translatesAutoresizingMaskIntoConstraints = false
            let content = NSView()
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                scroll.widthAnchor.constraint(equalToConstant: 420),
                scroll.heightAnchor.constraint(equalToConstant: 220),
                buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
                document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
                rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
                rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
                rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            ])
            commands.forEach { _ = addRow($0) }
            panel.contentView = content
            panel.setContentSize(content.fittingSize)
            panel.center()
        }

        private func addRow(_ text: String) -> NSTextField {
            let field = PlainTextField(string: text)
            field.placeholderString = "command"
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.cell?.isScrollable = true
            field.cell?.usesSingleLineMode = true
            field.isAutomaticTextCompletionEnabled = false
            func button(_ symbol: String, _ help: String, _ action: Selector) -> NSButton {
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage()
                let button = NSButton(image: image, target: self, action: action)
                button.isBordered = false
                button.toolTip = help
                // Out of the Tab order: Tab goes from one command to the next.
                button.refusesFirstResponder = true
                return button
            }
            let row = NSStackView(views: [
                field,
                button("chevron.up", "Move up", #selector(moveUp(_:))),
                button("chevron.down", "Move down", #selector(moveDown(_:))),
                button("minus.circle", "Remove this command from the list", #selector(removeRow(_:))),
            ])
            row.orientation = .horizontal
            row.spacing = 8
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            return field
        }

        @objc private func addCommand() {
            let field = addRow("")
            // Laid out first, so there is a frame to scroll to and a field
            // on screen to take the caret.
            panel.contentView?.layoutSubtreeIfNeeded()
            field.scrollToVisible(field.bounds)
            panel.makeFirstResponder(field)
        }

        private func row(of sender: NSButton) -> (view: NSView, index: Int)? {
            guard let view = sender.superview, let index = rows.arrangedSubviews.firstIndex(of: view) else { return nil }
            return (view, index)
        }

        @objc private func moveUp(_ sender: NSButton) { move(sender, by: -1) }
        @objc private func moveDown(_ sender: NSButton) { move(sender, by: 1) }

        private func move(_ sender: NSButton, by offset: Int) {
            guard let (view, index) = row(of: sender),
                  rows.arrangedSubviews.indices.contains(index + offset) else { return }
            rows.removeArrangedSubview(view)
            rows.insertArrangedSubview(view, at: index + offset)
        }

        @objc private func removeRow(_ sender: NSButton) {
            guard let (view, _) = row(of: sender) else { return }
            // The caret may be in the row that is going.
            panel.makeFirstResponder(nil)
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        @objc private func finish(_ sender: NSButton) {
            // Ends any edit in progress, so the field holds what was typed.
            panel.makeFirstResponder(nil)
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: sender.tag))
        }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class PlainComboBox: NSComboBox {
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
