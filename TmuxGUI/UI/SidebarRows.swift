//
//  SidebarRows.swift
//  TmuxGUI
//

import Cocoa

/// The three kinds of row the rail is built out of.
///
/// Split from `SessionSidebarView` because the rail now draws a two-level list
/// and "what a row looks like when the pointer is over it" is a different
/// concern from "where the rows go". Every one of them follows the same two
/// rules the window strip established: the whole rounded box is one click
/// target, and selection happens on mouse *up* — selecting sends a tmux
/// command, tmux replies, the rail rebuilds, and the view being clicked is
/// gone before a mouse-down handler could finish.

// MARK: - Session

/// A session, drawn as a group heading rather than a selectable pill.
///
/// The heading still has to be clickable, and that is the whole risk of this
/// layout: static heading styling says "label", and a label that switches
/// sessions is a trap. So the affordance is built on hover instead — the row
/// fills with the same rounded wash a window row uses, the text brightens, and
/// the window count is replaced by the **+** that makes a new window. By the
/// time the pointer is anywhere near it, it reads as a row.
@MainActor
final class SidebarSessionRow: NSView {
    let sessionID: String
    let sessionName: String
    /// Survives a rebuild, unlike the view itself. See
    /// `SessionSidebarView.isDoubleClick(on:clickCount:)`. Built from the id
    /// rather than the name so that renaming a session mid-double-click cannot
    /// make the second half land on what looks like a different row.
    var rowIdentity: String { "session:\(sessionID)" }

    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onNewWindow: (() -> Void)?
    /// The disclosure triangle, which opens the list without switching to it.
    /// Deliberately not the same gesture as clicking the heading: one is a look
    /// at another session, the other is a move to it.
    var onToggle: (() -> Void)?
    /// Asked on every mouse-down, because a plain `clickCount >= 2` is not
    /// enough here: selecting a session reflows the list, so the two clicks of
    /// a double-click can land on two different rows.
    var isDoubleClick: ((String, Int) -> Bool)?

    static let height: CGFloat = 24
    /// Air above a heading, so a session reads as starting a block rather than
    /// being one more row in the list above it. Not applied to the first.
    static let topGap: CGFloat = 9

    private let isCurrent: Bool
    private let label = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let plusButton = NSButton()
    private let chevron = NSButton()
    private let activityDot = NSView()
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var pressed = false

    init(id: String, name: String, windowCount: Int, hasActivity: Bool,
         isCurrent: Bool, isExpanded: Bool)
    {
        sessionID = id
        sessionName = name
        self.isCurrent = isCurrent
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6

        // An SF Symbol rather than a drawn path or a text glyph: it is the
        // shape every other Mac list uses for this, it carries its own optical
        // alignment, and it flips with the layout direction for free.
        chevron.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: isExpanded ? "Collapse" : "Expand"
        )?.withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        chevron.imagePosition = .imageOnly
        chevron.isBordered = false
        chevron.bezelStyle = .inline
        chevron.target = self
        chevron.action = #selector(chevronClicked)
        chevron.toolTip = isExpanded ? "Hide \(name)'s windows" : "Show \(name)'s windows"
        addSubview(chevron)

        // Uppercased for the heading look, with a little tracking so 10pt
        // capitals do not read as one block. The real name is what the rename
        // editor and the tooltip show — this is display only.
        label.attributedStringValue = NSAttributedString(
            string: name.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .kern: 0.55,
            ]
        )
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        countLabel.stringValue = "\(windowCount)"
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        countLabel.alignment = .right
        addSubview(countLabel)

        plusButton.title = "+"
        plusButton.font = .systemFont(ofSize: 14, weight: .light)
        plusButton.isBordered = false
        plusButton.bezelStyle = .inline
        plusButton.target = self
        plusButton.action = #selector(plusClicked)
        plusButton.toolTip = "New window in \(name)"
        addSubview(plusButton)

        activityDot.wantsLayer = true
        activityDot.layer?.cornerRadius = 3
        // System orange on purpose, under every scheme: "something happened
        // where you are not looking" has to mean one thing.
        activityDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        activityDot.isHidden = !(hasActivity && !isCurrent)
        addSubview(activityDot)

        toolTip = "\(name) · \(windowCount) window\(windowCount == 1 ? "" : "s")"
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The + is shown for the session whose windows are listed, and for
    /// whichever heading the pointer is over. A heading with no + would leave
    /// the row looking inert exactly when the user is about to click it.
    private var showsPlus: Bool { isCurrent || isHovering }

    private func applyColors() {
        let theme = ChromeTheme.current
        layer?.backgroundColor = isHovering ? theme.hover.cgColor : NSColor.clear.cgColor
        label.textColor = (isCurrent || isHovering) ? theme.text : theme.faintText
        countLabel.textColor = theme.faintText
        plusButton.contentTintColor = theme.mutedText
        chevron.contentTintColor = isHovering ? theme.mutedText : theme.faintText
    }

    override func layout() {
        super.layout()
        countLabel.isHidden = showsPlus
        plusButton.isHidden = !showsPlus

        chevron.frame = CGRect(x: 4, y: (bounds.height - 14) / 2, width: 14, height: 14)

        // Everything after the triangle, so a heading's name lines up with its
        // own windows' names rather than with their indices.
        var left: CGFloat = 20
        if !activityDot.isHidden {
            activityDot.frame = CGRect(x: left, y: (bounds.height - 6) / 2, width: 6, height: 6)
            left += 11
        }

        let rightEdge = bounds.maxX - 6
        plusButton.frame = CGRect(x: rightEdge - 18, y: (bounds.height - 18) / 2, width: 18, height: 18)
        countLabel.frame = CGRect(x: rightEdge - 22, y: (bounds.height - 13) / 2, width: 20, height: 13)

        let textRight = rightEdge - 22
        label.frame = CGRect(
            x: left, y: (bounds.height - 13) / 2,
            width: max(0, textRight - 4 - left), height: 13
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        isHovering = true
        applyColors()
        needsLayout = true
    }

    override func mouseExited(with _: NSEvent) {
        isHovering = false
        applyColors()
        needsLayout = true
    }

    /// The whole box is one target, except the two controls in it, which are
    /// their own — the triangle especially: opening a session's list without
    /// switching to it is the one thing the heading itself must not do.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return (hit === plusButton || hit === chevron) ? hit : self
    }

    @objc private func plusClicked() { onNewWindow?() }
    @objc private func chevronClicked() { onToggle?() }

    override func mouseDown(with event: NSEvent) {
        if isDoubleClick?(rowIdentity, event.clickCount) ?? (event.clickCount >= 2) {
            onDoubleClick?()
            return
        }
        pressed = true
    }

    /// A press that started here, rather than `clickCount == 1`: synthesised
    /// events carry a click count of 0 and a guard on the exact value ignores
    /// them silently.
    override func mouseUp(with _: NSEvent) {
        guard pressed else { return }
        pressed = false
        onClick?()
    }
}

// MARK: - Window

/// One tmux window in the current session.
///
/// This is the row the old tab was. Everything a tab could do it can do:
/// click to select, double-click to rename, right-click for hide and kill,
/// and drag to reorder — vertically now, which is the only real difference.
@MainActor
final class SidebarWindowRow: NSView {
    let windowID: String
    /// Survives a rebuild, unlike the view itself. See
    /// `SessionSidebarView.isDoubleClick(on:clickCount:)`.
    var rowIdentity: String { "window:\(windowID)" }

    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var isDoubleClick: ((String, Int) -> Bool)?
    var onContextMenu: ((NSPoint) -> Void)?
    /// Pointer location in window coordinates, while a drag is in progress.
    var onDragged: ((NSPoint) -> Void)?
    /// The drag finished. The rail commits the move here rather than on every
    /// step: committing mid-drag sends `move-window`, tmux replies, the rail
    /// rebuilds, and the view being dragged stops existing.
    var onDragEnded: (() -> Void)?

    static let height: CGFloat = 27

    private let isActive: Bool
    private let indexLabel = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private let activityDot = NSView()
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var dragOrigin: NSPoint?
    private var didDrag = false

    init(window: TmuxWindow, isActive: Bool) {
        windowID = window.id
        self.isActive = isActive
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6

        indexLabel.stringValue = "\(window.index)"
        indexLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        indexLabel.alignment = .right
        addSubview(indexLabel)

        label.stringValue = window.name
        label.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        label.refusesFirstResponder = true
        addSubview(label)

        activityDot.wantsLayer = true
        activityDot.layer?.cornerRadius = 3
        activityDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        activityDot.isHidden = !(window.hasActivity && !isActive)
        addSubview(activityDot)

        toolTip = "\(window.index): \(window.name)"
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func applyColors() {
        let theme = ChromeTheme.current
        if isActive {
            layer?.backgroundColor = theme.accent.cgColor
        } else if isHovering {
            layer?.backgroundColor = theme.hover.cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        label.textColor = isActive ? theme.onAccent : (isHovering ? theme.text : theme.mutedText)
        indexLabel.textColor = isActive
            ? theme.onAccent.withAlphaComponent(0.7)
            : theme.faintText
    }

    override func layout() {
        super.layout()
        // Indented past the heading's own text, so the two levels read as a
        // tree rather than as one flat list with some rows in capitals.
        indexLabel.frame = CGRect(x: 14, y: (bounds.height - 13) / 2, width: 14, height: 13)

        var right = bounds.maxX - 8
        if !activityDot.isHidden {
            activityDot.frame = CGRect(x: right - 6, y: (bounds.height - 6) / 2, width: 6, height: 6)
            right -= 12
        }

        let left = indexLabel.frame.maxX + 10
        label.frame = CGRect(
            x: left, y: (bounds.height - 15) / 2,
            width: max(0, right - left), height: 15
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) { isHovering = true; applyColors() }
    override func mouseExited(with _: NSEvent) { isHovering = false; applyColors() }

    /// The whole box is one target — otherwise the row responds only in the
    /// gaps between its own labels, which reads as "clicking does nothing".
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        if isDoubleClick?(rowIdentity, event.clickCount) ?? (event.clickCount >= 2) {
            onDoubleClick?()
            return
        }
        dragOrigin = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        // Vertical slack, so a shaky click does not start reordering the list
        // out from under the user.
        guard didDrag || abs(event.locationInWindow.y - dragOrigin.y) > 5 else { return }
        didDrag = true
        onDragged?(event.locationInWindow)
    }

    override func mouseUp(with _: NSEvent) {
        defer { dragOrigin = nil }
        guard dragOrigin != nil else { return }
        if didDrag {
            onDragEnded?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(convert(event.locationInWindow, from: nil))
    }
}

// MARK: - Hidden count

/// The way back from hiding. One row per session that has hidden windows,
/// under that session's list — the counter the tab strip kept in its corner.
@MainActor
final class SidebarHiddenRow: NSView {
    var onClick: (() -> Void)?
    /// Reported so the rail's double-click bookkeeping stays honest — see
    /// `SessionSidebarView.isDoubleClick(on:clickCount:)`. This row has no
    /// double-click of its own; what it owes is to not let a press on it go
    /// unrecorded, so a press *through* it cannot look like a repeat.
    var onPress: (() -> Void)?

    static let height: CGFloat = 20

    private let label = NSTextField(labelWithString: "")
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var pressed = false

    init(count: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5

        label.stringValue = "\(count) hidden"
        label.font = .systemFont(ofSize: 10.5)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        toolTip = "Bring every hidden window back"
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func applyColors() {
        let theme = ChromeTheme.current
        layer?.backgroundColor = isHovering ? theme.hover.cgColor : NSColor.clear.cgColor
        label.textColor = isHovering ? theme.mutedText : theme.faintText
    }

    override func layout() {
        super.layout()
        // Lined up with the window names above it, not with their indices.
        label.frame = CGRect(x: 32, y: (bounds.height - 13) / 2, width: max(0, bounds.width - 40), height: 13)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) { isHovering = true; applyColors() }
    override func mouseExited(with _: NSEvent) { isHovering = false; applyColors() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with _: NSEvent) {
        onPress?()
        pressed = true
    }

    override func mouseUp(with _: NSEvent) {
        guard pressed else { return }
        pressed = false
        onClick?()
    }
}
