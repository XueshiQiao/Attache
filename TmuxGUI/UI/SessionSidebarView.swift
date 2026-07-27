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

    private let appIcon = NSImageView()
    private let appName = NSTextField(labelWithString: "TmuxGUI")
    private let appVersion = NSTextField(labelWithString: "")
    private let newButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    /// Where the rail's own content starts.
    ///
    /// The window has no title bar and the traffic lights float over this rail,
    /// so something has to clear them. `safeAreaInsets.top` is the system's own
    /// answer and it is the sidebar split view item that supplies it — which is
    /// the point of using a real one. This used to read the close button's
    /// frame and add a constant, and that number was already wrong on macOS 26:
    /// measured here, the sidebar item's safe area is 42pt, of which the inset
    /// glass panel the system draws the rail inside has already absorbed 32, so
    /// the rail itself is told 10. A hand-rolled 38 would have pushed the
    /// header a further 28pt down for no reason.
    private var contentTopInset: CGFloat {
        // The rail is a plain split view item now, so the system contributes no
        // safe area for the traffic lights — the whole point of the change was
        // to stop it inseting the column. Measure the buttons instead, the way
        // this did before, and keep the safe-area reading as the answer when
        // there is one, so nothing depends on which kind of item is in use.
        if safeAreaInsets.top > 0 { return safeAreaInsets.top + 6 }
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
        // The same brand block the settings sidebar opens with — app icon,
        // name, version — instead of a small all-caps "SESSIONS". The two
        // lists sit in the same app and were reported for not looking like it,
        // and a section header above a list of five is not carrying enough to
        // be worth the difference.
        appIcon.image = NSApp.applicationIconImage
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.wantsLayer = true
        appIcon.layer?.cornerRadius = 8
        appIcon.layer?.masksToBounds = true
        addSubview(appIcon)

        appName.font = .systemFont(ofSize: 14, weight: .bold)
        addSubview(appName)

        appVersion.stringValue = "v" + ((Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?")
        appVersion.font = .systemFont(ofSize: 11)
        addSubview(appVersion)

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
        appName.textColor = theme.text
        appVersion.textColor = theme.faintText
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
        appIcon.frame = CGRect(x: inset + 6, y: contentTopInset, width: 34, height: 34)
        appName.frame = CGRect(
            x: appIcon.frame.maxX + 10, y: contentTopInset + 2,
            width: max(0, bounds.width - appIcon.frame.maxX - 18), height: 17
        )
        appVersion.frame = CGRect(
            x: appName.frame.minX, y: contentTopInset + 19,
            width: appName.frame.width, height: 14
        )

        var y = contentTopInset + 34 + 12
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

    /// The rail's fill, and the reason the system sidebar material is not
    /// visible.
    ///
    /// A sidebar split view item paints a vibrant material behind whatever it
    /// contains, and this covers it. That is the deliberate choice: the point
    /// of `ChromeTheme` is that the app's chrome follows the terminal scheme,
    /// and a translucent grey rail beside a Dracula tab strip reads as a piece
    /// of a different application. The native structure — full height, traffic
    /// lights on the rail, the divider, drag to resize — is what was wanted
    /// from the split view, not its colour. Deleting this override is all it
    /// takes to hand the rail back to the material.
    ///
    /// The right-hand hairline that used to be drawn here is gone; the split
    /// view's own divider is that line now.
    /// A tint over the sidebar material, not a fill instead of it.
    ///
    /// The rail used to paint `ChromeTheme.background` opaque, which made the
    /// chrome follow the terminal theme — asked for — but also painted over the
    /// system's sidebar material, so the window lost the translucency every
    /// other Mac sidebar has. Also asked for. The two are only in conflict if
    /// the theme colour is opaque.
    ///
    /// So it goes on at partial alpha: the material still samples what is
    /// behind the window and still shifts as things move under it, and the
    /// theme still decides what colour that glass reads as. `NSVisualEffectView`
    /// draws first because it is the split view item's own backing view; this
    /// only has to leave enough of it showing.
    private static let tintAlpha: CGFloat = 0.55

    override func draw(_ dirtyRect: NSRect) {
        ChromeTheme.current.background.withAlphaComponent(Self.tintAlpha).setFill()
        dirtyRect.fill()
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
    private let icon = NSImageView()
    private let iconTile = NSView()
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

        // A coloured tile with a glyph, the same 26pt rounded square the
        // settings sidebar puts beside every page. Without it the two lists
        // read as different applications: one is icon-plus-label, the other is
        // a bare line of text.
        //
        // The hue is derived from the session's own name rather than assigned,
        // because sessions are not a fixed list the way settings pages are.
        // Same name, same colour, every launch — which makes it a weak
        // identifier rather than decoration.
        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = 6
        iconTile.layer?.backgroundColor = Self.tileColor(for: entry.name).cgColor
        addSubview(iconTile)

        icon.image = NSImage(
            systemSymbolName: "terminal.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyDown
        iconTile.addSubview(icon)

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

    /// A stable colour for a session name.
    ///
    /// The settings sidebar hands each page a colour by hand because there are
    /// four of them and they never change. Sessions come and go, so the colour
    /// is hashed out of the name instead — deterministic, so a session keeps
    /// its colour across launches, and drawn from the same set the settings
    /// pages use so the two lists look related.
    private static func tileColor(for name: String) -> NSColor {
        let palette: [NSColor] = [
            .systemBlue, .systemPurple, .systemTeal, .systemPink,
            .systemIndigo, .systemGreen, .systemOrange, .systemBrown,
        ]
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }

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
        let tile: CGFloat = 26
        iconTile.frame = CGRect(x: 7, y: (bounds.height - tile) / 2, width: tile, height: tile)
        icon.frame = CGRect(x: 0, y: 0, width: tile, height: tile)

        var left = iconTile.frame.maxX + 9
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
