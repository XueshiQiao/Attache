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

    struct Entry {
        let name: String
        let windowCount: Int
        let hasActivity: Bool
    }

    private let header = NSTextField(labelWithString: "SESSIONS")
    private let newButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    /// Clearance for the traffic lights. The window has no title bar, so the
    /// content starts at the very top and the buttons float over this rail.
    ///
    /// Read from the buttons themselves rather than pinned to a number: their
    /// size and inset are the system's to choose, and they have changed across
    /// macOS releases. The fallback only applies before the view has a window.
    private var trafficLightInset: CGFloat {
        guard let button = window?.standardWindowButton(.closeButton),
              let frame = button.superview?.convert(button.frame, to: nil),
              let height = window?.frame.height
        else { return 38 }
        // Button frame is in window coordinates measured from the bottom.
        return height - frame.minY + 6
    }
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
        addSubview(header)

        newButton.title = "+  New session"
        newButton.font = .systemFont(ofSize: 11.5)
        newButton.isBordered = false
        newButton.bezelStyle = .inline
        newButton.alignment = .left
        newButton.target = self
        newButton.action = #selector(newClicked)
        addSubview(newButton)

        // Status lives here rather than in a title bar, since there is no
        // title bar. Two lines: what the app is showing, and how fast bytes
        // are arriving.
        for label in [statusLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 2
            addSubview(label)
        }
        statusLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)

        applyChromeTheme()
    }

    /// Re-read the chrome colours. The rows resolve theirs at construction, so
    /// they are rebuilt — a theme change is not a tmux notification and they
    /// would otherwise keep the old colours until one arrived.
    func applyChromeTheme() {
        let theme = ChromeTheme.current
        header.textColor = theme.faintText
        newButton.contentTintColor = theme.faintText
        statusLabel.textColor = theme.mutedText
        detailLabel.textColor = theme.faintText
        rebuild()
        needsDisplay = true
    }

    func showStatus(_ status: String, detail: String) {
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
        needsLayout = true
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
        header.frame = CGRect(
            x: inset + 2, y: trafficLightInset,
            width: bounds.width - inset * 2, height: 14
        )

        var y = trafficLightInset + 22
        for row in itemViews {
            row.frame = CGRect(x: 6, y: y, width: bounds.width - 12, height: rowHeight)
            y += rowHeight + gap
        }

        newButton.frame = CGRect(x: 10, y: y + 6, width: bounds.width - 20, height: 26)

        let width = bounds.width - inset * 2
        detailLabel.frame = CGRect(x: inset, y: bounds.maxY - 26, width: width, height: 14)
        statusLabel.frame = CGRect(x: inset, y: bounds.maxY - 62, width: width, height: 32)
    }

    /// Empty space in the rail drags the window, since there is no title bar
    /// to grab. Rows and buttons handle their own clicks and opt out.
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_: NSRect) {
        ChromeTheme.current.separator.setFill()
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
    private var pressed = false

    init(entry: SessionSidebarView.Entry, isSelected: Bool) {
        sessionName = entry.name
        self.isSelected = isSelected
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        applyColors()

        label.stringValue = entry.name
        label.font = .systemFont(ofSize: 12.5, weight: isSelected ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)

        countLabel.stringValue = "\(entry.windowCount)"
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        countLabel.alignment = .right
        addSubview(countLabel)

        activityDot.wantsLayer = true
        activityDot.layer?.cornerRadius = 3
        // Left as the system orange on purpose. This is a status signal, not
        // decoration — "something happened in a session you are not looking
        // at" has to mean the same thing under every scheme.
        activityDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        activityDot.isHidden = !(entry.hasActivity && !isSelected)
        addSubview(activityDot)

        toolTip = "\(entry.name) · \(entry.windowCount) window\(entry.windowCount == 1 ? "" : "s")"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func applyColors() {
        let theme = ChromeTheme.current
        if isSelected {
            layer?.backgroundColor = theme.accent.cgColor
        } else if isHovering {
            layer?.backgroundColor = theme.hover.cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        // The text over the accent used to be hardcoded white, which is
        // unreadable as soon as a scheme's accent is a light colour.
        label.textColor = isSelected ? theme.onAccent : (isHovering ? theme.text : theme.mutedText)
        countLabel.textColor = isSelected
            ? theme.onAccent.withAlphaComponent(0.75)
            : theme.faintText
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
        pressed = true
    }

    /// Select on mouse up, for the same reason the window strip does:
    /// selecting rebuilds this view, and doing that from mouseDown kills the
    /// gesture. The trigger is "a press started here", not `clickCount == 1` —
    /// synthesised events carry a clickCount of 0 and a guard on the exact
    /// value silently ignores them.
    override func mouseUp(with _: NSEvent) {
        guard pressed else { return }
        pressed = false
        onClick?()
    }
}
