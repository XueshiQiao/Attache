//
//  WindowTabBarView.swift
//  TmuxGUI
//

import Cocoa

/// The second-level tab strip: one tab per tmux window in the current session.
///
/// The strip is a view of tmux, not a store. Selecting, reordering, renaming
/// and closing all turn into tmux commands and only take visible effect when
/// tmux reports back — so a `prefix + c` typed in another terminal adds a tab
/// here by exactly the same path a click on ＋ does.
@MainActor
final class WindowTabBarView: NSView {
    var onSelect: ((String) -> Void)?
    var onHide: ((String) -> Void)?
    var onKill: ((String) -> Void)?
    var onRename: ((String, String) -> Void)?
    /// Window id and the tmux index it was dropped on.
    var onReorder: ((String, Int) -> Void)?
    var onNew: (() -> Void)?
    var onRestoreHidden: (() -> Void)?

    static let preferredHeight: CGFloat = 34

    /// Tabs live directly in this view rather than inside an `NSScrollView`.
    /// A scroll view owns its document view's frame, so hand-placing tabs
    /// inside one silently loses to whatever the scroll view recomputes — the
    /// strip ends up the right height with nothing visible in it. Overflow is
    /// handled by letting tabs shrink instead.
    private let newButton = NSButton()
    private let hiddenBadge = NSButton()

    private var windows = [TmuxWindow]()
    private var hiddenIDs = Set<String>()
    private var activeID: String?
    private var itemViews = [WindowTabItemView]()
    private var editor: NSTextField?
    private var pendingRebuild = false
    private weak var editingItem: WindowTabItemView?

    private let tabHeight: CGFloat = 26
    private let minTabWidth: CGFloat = 88
    private let maxTabWidth: CGFloat = 190
    private let gap: CGFloat = 4

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setUp()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    private func setUp() {
        // A borderless square button whose whole box responds, not just the
        // glyph — a 12pt plus sign is a miserable target otherwise.
        newButton.title = "＋"
        newButton.bezelStyle = .inline
        newButton.isBordered = false
        newButton.font = .systemFont(ofSize: 15, weight: .light)
        newButton.target = self
        newButton.action = #selector(newWindowClicked)
        newButton.toolTip = "新建窗口（⌘T）"
        addSubview(newButton)

        hiddenBadge.bezelStyle = .inline
        hiddenBadge.isBordered = false
        hiddenBadge.font = .systemFont(ofSize: 11)
        hiddenBadge.target = self
        hiddenBadge.action = #selector(restoreHiddenClicked)
        hiddenBadge.isHidden = true
        addSubview(hiddenBadge)
    }

    // MARK: - Content

    func update(windows: [TmuxWindow], activeID: String?, hidden: Set<String>) {
        self.windows = windows
        self.activeID = activeID
        hiddenIDs = hidden
        rebuild()
    }

    private var visibleWindows: [TmuxWindow] {
        windows.filter { !hiddenIDs.contains($0.id) }
    }

    private func rebuild() {
        // Never rebuild while the user is typing a new name. tmux chatters
        // constantly — selecting the tab that is being renamed is itself
        // enough to trigger a refresh — and tearing the field out mid-edit
        // throws away what was typed.
        guard editor == nil else {
            pendingRebuild = true
            return
        }
        for view in itemViews { view.removeFromSuperview() }
        itemViews.removeAll()

        for window in visibleWindows {
            let item = WindowTabItemView(window: window, isActive: window.id == activeID)
            item.onClick = { [weak self] in self?.onSelect?(window.id) }
            item.onClose = { [weak self] in self?.onHide?(window.id) }
            item.onDoubleClick = { [weak self] in self?.beginRename(window) }
            item.onContextMenu = { [weak self] point in self?.showMenu(for: window, at: point) }
            item.onDragged = { [weak self] location in self?.handleDrag(of: window, to: location) }
            addSubview(item)
            itemViews.append(item)
        }

        let hiddenCount = hiddenIDs.count
        hiddenBadge.isHidden = hiddenCount == 0
        hiddenBadge.title = "\(hiddenCount) 个已隐藏"
        hiddenBadge.toolTip = "点一下把隐藏的窗口全部显示回来"

        // Lay out immediately instead of waiting for the next pass. A freshly
        // created item has a zero frame, and tmux notifications arrive in
        // bursts — several rebuilds can happen between two layout passes,
        // leaving the strip populated with invisible zero-sized tabs.
        needsLayout = true
        layoutSubtreeIfNeeded()
        needsDisplay = true
    }

    override func layout() {
        super.layout()

        let inset: CGFloat = 8
        var rightEdge = bounds.maxX - inset

        if !hiddenBadge.isHidden {
            let width = hiddenBadge.intrinsicContentSize.width + 12
            hiddenBadge.frame = CGRect(
                x: rightEdge - width, y: (bounds.height - tabHeight) / 2,
                width: width, height: tabHeight
            )
            rightEdge -= width + gap
        }

        let plusWidth: CGFloat = 30
        newButton.frame = CGRect(
            x: rightEdge - plusWidth, y: (bounds.height - tabHeight) / 2,
            width: plusWidth, height: tabHeight
        )
        rightEdge -= plusWidth + gap

        let available = max(0, rightEdge - inset)
        let count = CGFloat(itemViews.count)
        guard count > 0 else { return }

        // Share the space evenly, capped so a lone tab does not stretch across
        // the bar. Below `minTabWidth` the name stops being readable, but a
        // cramped tab still beats one that is not on screen at all — tmux
        // sessions with a dozen windows are the normal case here, not the edge.
        let ideal = (available - gap * (count - 1)) / count
        let width = max(28, min(maxTabWidth, ideal < minTabWidth ? ideal : max(minTabWidth, ideal)))

        for (index, item) in itemViews.enumerated() {
            item.frame = CGRect(
                x: inset + CGFloat(index) * (width + gap),
                y: (bounds.height - tabHeight) / 2,
                width: width,
                height: tabHeight
            )
        }
    }


    override func draw(_: NSRect) {
        // Only the hairline. Filling the whole bounds is unnecessary — the
        // window background already shows through — and an opaque fill here
        // is exactly the trap the sibling grid falls into.
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: - Actions

    @objc private func newWindowClicked() { onNew?() }
    @objc private func restoreHiddenClicked() { onRestoreHidden?() }

    private func showMenu(for window: TmuxWindow, at point: NSPoint) {
        let menu = NSMenu()
        menu.addItem(withTitle: "重命名…", action: nil, keyEquivalent: "").representedObject = window.id
        menu.items[0].target = self
        menu.items[0].action = #selector(renameFromMenu(_:))

        let hide = NSMenuItem(title: "从这里隐藏", action: #selector(hideFromMenu(_:)), keyEquivalent: "")
        hide.target = self
        hide.representedObject = window.id
        menu.addItem(hide)

        menu.addItem(.separator())

        // Killing is the only destructive action in the strip, so it is the
        // one thing that never happens by accident: separate item, explicit
        // wording, and a confirmation before anything dies.
        let kill = NSMenuItem(title: "杀掉这个 tmux 窗口…", action: #selector(killFromMenu(_:)), keyEquivalent: "")
        kill.target = self
        kill.representedObject = window.id
        menu.addItem(kill)

        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func renameFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let window = windows.first(where: { $0.id == id }) else { return }
        beginRename(window)
    }

    @objc private func hideFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onHide?(id)
    }

    @objc private func killFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let window = windows.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "杀掉窗口「\(window.index):\(window.name)」？"
        alert.informativeText = "窗口里的所有进程都会被结束，包括正在跑的 AI Agent。"
            + "\n如果只是不想看见它，用「从这里隐藏」。"
        alert.addButton(withTitle: "杀掉")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onKill?(window.id)
    }

    // MARK: - Rename

    private func beginRename(_ window: TmuxWindow) {
        guard let item = itemViews.first(where: { $0.windowID == window.id }) else { return }
        finishEditing(commit: true)

        let field = NSTextField(frame: item.frame.insetBy(dx: 4, dy: 3))
        field.stringValue = window.name
        field.font = .systemFont(ofSize: 12)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        // Return is handled through the delegate rather than target/action:
        // the action only fires for some end-editing paths, and losing an
        // edit because the commit hook did not run is the worst outcome here.
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier(window.id)
        // A window name is an identifier, not prose. Left on, macOS puts an
        // inline completion popup over the field and swallows the Return that
        // is supposed to commit the edit — and would happily turn a quote into
        // a curly one on its way to a shell command.
        field.isAutomaticTextCompletionEnabled = false
        addSubview(field)
        // Hide the tab underneath so the old name does not show through.
        item.isHidden = true
        editingItem = item
        editor = field
        // `self.` is required: the parameter shadows NSView.window.
        self.window?.makeFirstResponder(field)

        guard let fieldEditor = field.currentEditor() as? NSTextView else { return }
        fieldEditor.isAutomaticTextReplacementEnabled = false
        fieldEditor.isAutomaticSpellingCorrectionEnabled = false
        fieldEditor.isContinuousSpellCheckingEnabled = false
        fieldEditor.isAutomaticQuoteSubstitutionEnabled = false
        fieldEditor.isAutomaticDashSubstitutionEnabled = false
        fieldEditor.selectAll(nil)
    }

    /// Tear down the inline editor, optionally applying what was typed, and
    /// run any rebuild that was held back while it was open.
    fileprivate func finishEditing(commit: Bool) {
        guard let editor else { return }
        let id = editor.identifier?.rawValue
        let name = editor.stringValue.trimmingCharacters(in: .whitespaces)
        editor.removeFromSuperview()
        self.editor = nil
        editingItem?.isHidden = false
        editingItem = nil

        if commit, let id, !name.isEmpty { onRename?(id, name) }
        if pendingRebuild {
            pendingRebuild = false
            rebuild()
        }
    }

    override func cancelOperation(_: Any?) {
        finishEditing(commit: false)
    }

    // MARK: - Reorder

    /// Reordering is expressed as "the window now belongs at this tmux index".
    /// The strip does not move anything itself — tmux's `move-window` reply
    /// comes back as a fresh window list and the strip rebuilds from that.
    private func handleDrag(of window: TmuxWindow, to location: NSPoint) {
        let point = convert(location, from: nil)
        let visible = visibleWindows
        guard let currentSlot = visible.firstIndex(where: { $0.id == window.id }),
              let itemWidth = itemViews.first?.frame.width, itemWidth > 0
        else { return }

        let slot = max(0, min(visible.count - 1, Int((point.x - 8) / (itemWidth + gap))))
        guard slot != currentSlot else { return }
        onReorder?(window.id, visible[slot].index)
    }
}


/// One tab.
///
/// Built from a backing layer and a real `NSTextField` rather than a custom
/// `draw(_:)`. An earlier version drew itself and rendered nothing visible
/// even with correct frames and confirmed draw calls; layer-backed content
/// plus a stock control has no such failure mode, and it costs less code.
///
/// The whole rounded box is the click target — the label and the activity dot
/// are non-interactive, so there is no dead zone between them.
@MainActor
final class WindowTabItemView: NSView {
    let windowID: String

    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onContextMenu: ((NSPoint) -> Void)?
    var onDragged: ((NSPoint) -> Void)?

    private let tmuxWindow: TmuxWindow
    private let isActive: Bool
    private let label = NSTextField(labelWithString: "")
    private let activityDot = NSView()
    private let closeButton = NSButton()
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var dragOrigin: NSPoint?
    private var didDrag = false

    init(window: TmuxWindow, isActive: Bool) {
        tmuxWindow = window
        self.isActive = isActive
        windowID = window.id
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    private func setUp() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = isActive ? 1 : 0
        applyColors()
        toolTip = "\(tmuxWindow.index): \(tmuxWindow.name)"

        label.stringValue = "\(tmuxWindow.index): \(tmuxWindow.name)"
        label.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        // Clicks have to reach the tab, not stop at the label.
        label.refusesFirstResponder = true
        addSubview(label)

        activityDot.wantsLayer = true
        activityDot.layer?.cornerRadius = 3
        activityDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        activityDot.isHidden = !(tmuxWindow.hasActivity && !isActive)
        addSubview(activityDot)

        closeButton.title = "✕"
        closeButton.font = .systemFont(ofSize: 10)
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "从这里隐藏（不会杀掉 tmux 窗口）"
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    private func applyColors() {
        if isActive {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func layout() {
        super.layout()
        let showsClose = isHovering || isActive
        closeButton.isHidden = !showsClose
        closeButton.frame = CGRect(x: bounds.maxX - 22, y: (bounds.height - 18) / 2, width: 18, height: 18)

        var textLeft = bounds.minX + 9
        if !activityDot.isHidden {
            activityDot.frame = CGRect(x: textLeft, y: (bounds.height - 6) / 2, width: 6, height: 6)
            textLeft += 11
        }
        let textRight = showsClose ? closeButton.frame.minX - 4 : bounds.maxX - 8
        label.frame = CGRect(
            x: textLeft, y: (bounds.height - 16) / 2,
            width: max(0, textRight - textLeft), height: 16
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // cgColor snapshots the appearance current at the call site, so the
        // layer keeps yesterday's light/dark value unless it is re-resolved.
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
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

    /// The whole rounded box is one target.
    ///
    /// Without this the label and the activity dot each swallow clicks that
    /// land on them, so a tab only responds on the gaps between its own
    /// contents — which reads as "clicking tabs doesn't work".
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton ? hit : self
    }

    @objc private func closeClicked() { onClose?() }

    /// Selection happens on mouse *up*, not down.
    ///
    /// Selecting sends `select-window`, tmux reports back, and the strip
    /// rebuilds from scratch — which destroys this very view mid-gesture and
    /// leaves a drag with nothing to deliver its events to. Waiting for mouse
    /// up means a click still selects and a drag reorders, and neither one
    /// pulls the view out from under the other.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        dragOrigin = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        // A few points of slack so a slightly shaky click does not reorder the
        // strip out from under the user.
        guard abs(event.locationInWindow.x - dragOrigin.x) > 6 else { return }
        didDrag = true
        onDragged?(event.locationInWindow)
    }

    override func mouseUp(with _: NSEvent) {
        defer { dragOrigin = nil }
        guard dragOrigin != nil, !didDrag else { return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(convert(event.locationInWindow, from: nil))
    }
}

// MARK: - Inline rename

extension WindowTabBarView: NSTextFieldDelegate {
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

    /// Clicking away commits rather than discards — the user typed it on
    /// purpose, and there is no undo for text that was silently thrown out.
    func controlTextDidEndEditing(_: Notification) {
        finishEditing(commit: true)
    }
}
