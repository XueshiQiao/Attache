//
//  SessionSidebarView.swift
//  TmuxGUI
//

import Cocoa

/// The first-level tab rail: one entry per tmux session, stacked vertically.
///
/// Same contract as the window strip — nothing here is authored locally.
/// Selecting switches which session the content area shows; renaming and
/// creating go to tmux and come back as notifications.
@MainActor
final class SessionSidebarView: NSView {
    var onSelect: ((String) -> Void)?
    var onRename: ((String, String) -> Void)?
    var onNew: (() -> Void)?

    static let preferredWidth: CGFloat = 168

    struct Entry {
        let name: String
        let windowCount: Int
        let hasActivity: Bool
    }

    private let header = NSTextField(labelWithString: "SESSIONS")
    private let newButton = NSButton()
    private var entries = [Entry]()
    private var selectedName: String?
    private var itemViews = [SessionRowView]()
    private var editor: NSTextField?
    private var pendingRebuild = false
    private weak var editingRow: SessionRowView?

    private let rowHeight: CGFloat = 34
    private let gap: CGFloat = 2

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setUp()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    private func setUp() {
        header.font = .systemFont(ofSize: 10, weight: .semibold)
        header.textColor = .tertiaryLabelColor
        addSubview(header)

        newButton.title = "＋  新建 session"
        newButton.font = .systemFont(ofSize: 11.5)
        newButton.isBordered = false
        newButton.bezelStyle = .inline
        newButton.contentTintColor = .tertiaryLabelColor
        newButton.alignment = .left
        newButton.target = self
        newButton.action = #selector(newClicked)
        addSubview(newButton)
    }

    func update(entries: [Entry], selected: String?) {
        self.entries = entries
        selectedName = selected
        rebuild()
    }

    private func rebuild() {
        // Same reason as the window strip: never tear down a field the user is
        // typing in just because tmux said something.
        guard editor == nil else {
            pendingRebuild = true
            return
        }
        for view in itemViews { view.removeFromSuperview() }
        itemViews.removeAll()

        for entry in entries {
            let row = SessionRowView(entry: entry, isSelected: entry.name == selectedName)
            row.onClick = { [weak self] in self?.onSelect?(entry.name) }
            row.onDoubleClick = { [weak self] in self?.beginRename(entry) }
            addSubview(row)
            itemViews.append(row)
        }

        needsLayout = true
        layoutSubtreeIfNeeded()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 10
        header.frame = CGRect(x: inset + 2, y: 10, width: bounds.width - inset * 2, height: 14)

        var y: CGFloat = 32
        for row in itemViews {
            row.frame = CGRect(x: 6, y: y, width: bounds.width - 12, height: rowHeight)
            y += rowHeight + gap
        }

        newButton.frame = CGRect(x: 10, y: y + 6, width: bounds.width - 20, height: 26)
    }

    override func draw(_: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        CGRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    @objc private func newClicked() { onNew?() }

    // MARK: - Rename

    private func beginRename(_ entry: Entry) {
        guard let row = itemViews.first(where: { $0.sessionName == entry.name }) else { return }
        finishEditing(commit: true)

        let field = NSTextField(frame: row.frame.insetBy(dx: 6, dy: 5))
        field.stringValue = entry.name
        field.font = .systemFont(ofSize: 12)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier(entry.name)
        field.isAutomaticTextCompletionEnabled = false
        addSubview(field)
        row.isHidden = true
        editingRow = row
        editor = field
        window?.makeFirstResponder(field)

        guard let fieldEditor = field.currentEditor() as? NSTextView else { return }
        fieldEditor.isAutomaticTextReplacementEnabled = false
        fieldEditor.isAutomaticSpellingCorrectionEnabled = false
        fieldEditor.isContinuousSpellCheckingEnabled = false
        fieldEditor.isAutomaticQuoteSubstitutionEnabled = false
        fieldEditor.isAutomaticDashSubstitutionEnabled = false
        fieldEditor.selectAll(nil)
    }

    fileprivate func finishEditing(commit: Bool) {
        guard let editor else { return }
        let old = editor.identifier?.rawValue
        let new = editor.stringValue.trimmingCharacters(in: .whitespaces)
        editor.removeFromSuperview()
        self.editor = nil
        editingRow?.isHidden = false
        editingRow = nil

        if commit, let old, !new.isEmpty, new != old { onRename?(old, new) }
        if pendingRebuild {
            pendingRebuild = false
            rebuild()
        }
    }

    override func cancelOperation(_: Any?) { finishEditing(commit: false) }
}

extension SessionSidebarView: NSTextFieldDelegate {
    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finishEditing(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_: Notification) {
        finishEditing(commit: true)
    }
}

/// One session row.
@MainActor
final class SessionRowView: NSView {
    let sessionName: String

    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private let isSelected: Bool
    private let label = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let activityDot = NSView()
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    init(entry: SessionSidebarView.Entry, isSelected: Bool) {
        sessionName = entry.name
        self.isSelected = isSelected
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        applyColors()

        label.stringValue = entry.name
        label.font = .systemFont(ofSize: 12.5, weight: isSelected ? .semibold : .regular)
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)

        countLabel.stringValue = "\(entry.windowCount)"
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        addSubview(countLabel)

        activityDot.wantsLayer = true
        activityDot.layer?.cornerRadius = 3
        activityDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        activityDot.isHidden = !(entry.hasActivity && !isSelected)
        addSubview(activityDot)

        toolTip = "\(entry.name) · \(entry.windowCount) 个窗口"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    private func applyColors() {
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        label.textColor = isSelected ? .white : (isHovering ? .labelColor : .secondaryLabelColor)
        countLabel.textColor = isSelected ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
    }

    override func layout() {
        super.layout()
        var left: CGFloat = 10
        if !activityDot.isHidden {
            activityDot.frame = CGRect(x: left, y: (bounds.height - 6) / 2, width: 6, height: 6)
            left += 11
        }
        countLabel.frame = CGRect(x: bounds.maxX - 30, y: (bounds.height - 14) / 2, width: 22, height: 14)
        label.frame = CGRect(
            x: left, y: (bounds.height - 16) / 2,
            width: max(0, countLabel.frame.minX - 6 - left), height: 16
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) { isHovering = true; applyColors() }
    override func mouseExited(with _: NSEvent) { isHovering = false; applyColors() }

    /// The whole row is one target; the labels must not swallow clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
    }

    // Select on mouse up, for the same reason the window strip does: selecting
    // rebuilds this view, and doing that from mouseDown kills the gesture.
    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        onClick?()
    }
}
