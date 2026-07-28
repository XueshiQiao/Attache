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
        adoptHoverFromPointer()
    }

    /// Take the hover state from where the pointer actually is.
    ///
    /// A tracking area installed *under* a stationary pointer sends no
    /// `mouseEntered` — AppKit reports crossings, and nothing crossed. The rail
    /// rebuilds its rows on tmux notifications and on every Git change, so a
    /// row under the pointer is replaced regularly by a new one that believes
    /// it is not hovered, and the highlight blinks off until the pointer moves.
    /// That is the flicker, and it is why the row also looked unclickable: the
    /// only thing that ever set it back was a movement the user was not making.
    private func adoptHoverFromPointer() {
        guard let window, window.isKeyWindow else { return }
        let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        guard inside != isHovering else { return }
        isHovering = inside
        applyColors()
        needsLayout = true
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

    /// One line or two, decided by the settings rather than by the row.
    ///
    /// A constant would have been simpler and is wrong: the second line nearly
    /// halves how many windows fit on screen, and that is a trade only the
    /// person looking at their own twenty windows can make. With both status
    /// settings off the rail is exactly the 27pt list it was before any of this.
    static var height: CGFloat { showsSecondLine ? 40 : 27 }

    private static var showsSecondLine: Bool {
        AppSettings.sidebarShowsGit
    }

    private let isActive: Bool
    private let indexLabel = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    /// The branch, or the pane's directory when there is no repository.
    /// Truncated from the *head*: these are `type/topic` names and the topic is
    /// the half that identifies one, so `…/glass-note` survives where
    /// `post/glass…` would not.
    private let branchLabel = NSTextField(labelWithString: "")
    /// `+3 ~1 ↑2`. Never truncated — it is five characters and it is the part
    /// that changes.
    private let statsLabel = NSTextField(labelWithString: "")
    private let activityDot = NSView()
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var dragOrigin: NSPoint?
    private var didDrag = false
    private let decoration: WindowDecoration
    private let showsSecondLine: Bool

    /// The height this row was *built* for.
    ///
    /// The container must place a row at the height the row lays itself out
    /// for, and `SidebarWindowRow.height` cannot answer that: it reads the
    /// setting live, while an instance decides once, in `init`. Toggling the
    /// setting and then causing any ordinary layout pass — a window resize, a
    /// divider drag — would otherwise resize existing rows to the new height
    /// while their contents were still positioned for the old one. Found by
    /// review, not by running it.
    let rowHeight: CGFloat

    init(window: TmuxWindow, isActive: Bool, decoration: WindowDecoration = WindowDecoration()) {
        windowID = window.id
        self.isActive = isActive
        self.decoration = decoration
        let twoLines = Self.showsSecondLine
        showsSecondLine = twoLines
        rowHeight = twoLines ? 40 : 27
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

        for status in [branchLabel, statsLabel] {
            status.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            status.isSelectable = false
            status.refusesFirstResponder = true
            status.isHidden = !showsSecondLine
            addSubview(status)
        }
        branchLabel.lineBreakMode = .byTruncatingHead

        activityDot.wantsLayer = true
        activityDot.layer?.cornerRadius = 3.5
        addSubview(activityDot)

        applyStatus(window: window)
        applyColors()
    }

    /// Fill the second line and the dot, and decide what the tooltip says.
    ///
    /// The agent replaces tmux's activity dot rather than sitting beside it:
    /// both are "something happened here", and the agent's is the more specific
    /// of the two. A row with an agent in it has no use for "unseen output".
    private func applyStatus(window: TmuxWindow) {
        var tips = ["\(window.index): \(window.name)"]

        if let agent = decoration.agent {
            activityDot.isHidden = false
            let name = agent.kind.map { $0 == "claude" ? "Claude Code" : $0 } ?? "An agent"
            switch agent.state {
            case .needsInput: tips.append("\(name) · waiting for you\(Self.age(agent.since))")
            case .working: tips.append("\(name) · working\(Self.age(agent.since))")
            case .done: tips.append("\(name) · finished\(Self.age(agent.since))")
            case nil: tips.append("\(name) is running — install the hook to see what it is doing")
            }
        } else {
            // tmux's own flag, unchanged in meaning: it is what the `#` in a
            // plain `tmux attach` status line means.
            activityDot.isHidden = !(window.hasActivity && !isActive)
        }

        if showsSecondLine {
            if let git = decoration.git {
                branchLabel.stringValue = git.displayRef
                statsLabel.stringValue = Self.stats(for: git)
                tips.append(Self.gitTooltip(for: git, fetchIsLive: decoration.fetchIsLive))
            } else if decoration.isNotARepository, let path = decoration.path {
                branchLabel.stringValue = Self.abbreviate(path)
                statsLabel.stringValue = ""
                tips.append(path)
            } else {
                // Not looked at yet. Blank, never a placeholder — the rail
                // rebuilds on nearly every tmux notification and a spinner here
                // would flicker on all of them.
                branchLabel.stringValue = ""
                statsLabel.stringValue = ""
                if let path = decoration.path { tips.append(path) }
            }
        }

        toolTip = tips.joined(separator: "\n")
    }

    /// `+3 ~1 ↑2` — staged, unstaged, and what is not pushed.
    ///
    /// Untracked files are left out on purpose and appear only in the tooltip:
    /// an unignored `node_modules` would read `+4000` forever and crowd out the
    /// two numbers that mean something. A tree with *only* untracked files
    /// still says so, with `?N`, rather than claiming to be clean.
    private static func stats(for git: GitSummary) -> String {
        var parts = [String]()
        if git.conflicted > 0 { parts.append("!\(git.conflicted)") }
        if git.staged > 0 { parts.append("+\(git.staged)") }
        if git.modified > 0 { parts.append("~\(git.modified)") }
        if parts.isEmpty, git.untracked > 0 { parts.append("?\(git.untracked)") }
        if parts.isEmpty { parts.append("✓") }
        if git.hasUpstream {
            if git.ahead > 0 { parts.append("↑\(git.ahead)") }
            if git.behind > 0 { parts.append("↓\(git.behind)") }
        }
        return parts.joined(separator: " ")
    }

    private static func gitTooltip(for git: GitSummary, fetchIsLive: Bool) -> String {
        var lines = [git.displayRef]
        var changes = [String]()
        if git.staged > 0 { changes.append("\(git.staged) staged") }
        if git.modified > 0 { changes.append("\(git.modified) modified") }
        if git.untracked > 0 { changes.append("\(git.untracked) untracked") }
        if git.conflicted > 0 { changes.append("\(git.conflicted) conflicted") }
        lines.append(changes.isEmpty ? "clean" : changes.joined(separator: ", "))

        guard git.hasUpstream else {
            lines.append("no upstream — nothing to compare against")
            return lines.joined(separator: "\n")
        }
        lines.append(git.ahead > 0 ? "↑\(git.ahead) to push" : "nothing to push")
        // The honest version. `# branch.ab` is measured against the last fetch,
        // so a `↓0` is "nothing known to pull" and not "the remote has nothing".
        // Saying which is the difference between a number and a claim.
        //
        // Keyed on whether *this* repository is actually being fetched, not on
        // whether the setting is on: a repository whose fetch is being refused
        // is exactly as stale as one with the setting off, and claiming
        // otherwise for it would be the one thing this wording exists to avoid.
        if fetchIsLive {
            lines.append(git.behind > 0 ? "↓\(git.behind) to pull" : "nothing to pull")
        } else if let fetched = git.lastFetch {
            lines.append("↓ unknown — last fetch\(age(fetched))")
        } else {
            lines.append("↓ unknown — never fetched")
        }
        return lines.joined(separator: "\n")
    }

    /// " 3m ago", or "" when there is nothing to say. Leading space included so
    /// callers can append it without deciding.
    private static func age(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = Int(Date().timeIntervalSince(date))
        guard seconds >= 0 else { return "" }
        if seconds < 60 { return " \(seconds)s ago" }
        if seconds < 3600 { return " \(seconds / 60)m ago" }
        if seconds < 86400 { return " \(seconds / 3600)h ago" }
        return " \(seconds / 86400)d ago"
    }

    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The dot's colour, which is the only thing on the row that has to mean
    /// the same thing under every terminal scheme.
    ///
    /// System colours rather than theme-derived ones, for the reason the
    /// activity dot already used `systemOrange`: "this one is waiting for you"
    /// has to be one colour, and a hue blended out of whatever scheme is
    /// loaded would be a different one in every theme.
    private var dotColor: NSColor {
        switch decoration.agent?.state {
        case .needsInput: .systemOrange
        case .working: .systemBlue
        case .done: .systemGreen
        // An agent with no hook installed. Deliberately colourless: the app
        // knows something is running and does not know what, and a coloured
        // dot would be claiming otherwise.
        case nil where decoration.agent != nil: ChromeTheme.current.faintText
        // No agent — tmux's own activity flag, unchanged.
        default: .systemOrange
        }
    }

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
        activityDot.layer?.backgroundColor = dotColor.cgColor

        // On the filled row every colour is a tint of `onAccent`, because a
        // semantic hue over the accent fill is a second colour fighting the
        // first one and neither reads.
        if isActive {
            branchLabel.textColor = theme.onAccent.withAlphaComponent(0.85)
            statsLabel.textColor = theme.onAccent.withAlphaComponent(0.75)
        } else {
            branchLabel.textColor = decoration.git == nil ? theme.faintText : theme.mutedText
            statsLabel.textColor = statsColor(theme)
        }
    }

    /// One colour for the whole stats field, chosen by the most serious thing
    /// in it. Colouring each number separately needs one label per number, and
    /// at 110pt of usable width the row cannot afford the layout.
    private func statsColor(_ theme: ChromeTheme) -> NSColor {
        guard let git = decoration.git else { return theme.faintText }
        if git.conflicted > 0 { return .systemRed }
        if git.staged > 0 || git.modified > 0 { return .systemYellow }
        if git.untracked > 0 { return theme.faintText }
        if git.hasUpstream, git.ahead > 0 || git.behind > 0 { return .systemBlue }
        return .systemGreen
    }

    override func layout() {
        super.layout()
        let dotSize: CGFloat = 7

        guard showsSecondLine else {
            // The single-line row exactly as it was, so turning the setting off
            // is a return to the old rail rather than a narrower version of the
            // new one.
            indexLabel.frame = CGRect(x: 14, y: (bounds.height - 13) / 2, width: 14, height: 13)
            var right = bounds.maxX - 8
            if !activityDot.isHidden {
                activityDot.frame = CGRect(
                    x: right - dotSize, y: (bounds.height - dotSize) / 2,
                    width: dotSize, height: dotSize
                )
                right -= dotSize + 6
            }
            let left = indexLabel.frame.maxX + 10
            label.frame = CGRect(
                x: left, y: (bounds.height - 15) / 2,
                width: max(0, right - left), height: 15
            )
            return
        }

        // Indented past the heading's own text, so the two levels read as a
        // tree rather than as one flat list with some rows in capitals.
        indexLabel.frame = CGRect(x: 14, y: 5, width: 14, height: 13)
        let left = indexLabel.frame.maxX + 10

        var right = bounds.maxX - 8
        if !activityDot.isHidden {
            activityDot.frame = CGRect(x: right - dotSize, y: 5, width: dotSize, height: dotSize)
            right -= dotSize + 6
        }
        label.frame = CGRect(x: left, y: 3, width: max(0, right - left), height: 15)

        // The stats are measured and given exactly what they need; the branch
        // gets whatever is left. The other way round truncates the numbers,
        // which are the part that changes and the part that is five characters
        // long.
        let statusRight = bounds.maxX - 8
        let statsWidth = statsLabel.stringValue.isEmpty
            ? 0
            : ceil(statsLabel.attributedStringValue.size().width) + 1
        statsLabel.frame = CGRect(
            x: statusRight - statsWidth, y: 21, width: statsWidth, height: 14
        )
        let branchRight = statsWidth > 0 ? statsLabel.frame.minX - 5 : statusRight
        branchLabel.frame = CGRect(
            x: left, y: 21, width: max(0, branchRight - left), height: 14
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
        adoptHoverFromPointer()
    }

    /// Take the hover state from where the pointer actually is.
    ///
    /// A tracking area installed *under* a stationary pointer sends no
    /// `mouseEntered` — AppKit reports crossings, and nothing crossed. The rail
    /// rebuilds its rows on tmux notifications and on every Git change, so a
    /// row under the pointer is replaced regularly by a new one that believes
    /// it is not hovered, and the highlight blinks off until the pointer moves.
    /// That is the flicker, and it is why the row also looked unclickable: the
    /// only thing that ever set it back was a movement the user was not making.
    private func adoptHoverFromPointer() {
        guard let window, window.isKeyWindow else { return }
        let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        guard inside != isHovering else { return }
        isHovering = inside
        applyColors()
        needsLayout = true
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
        adoptHoverFromPointer()
    }

    /// Take the hover state from where the pointer actually is.
    ///
    /// A tracking area installed *under* a stationary pointer sends no
    /// `mouseEntered` — AppKit reports crossings, and nothing crossed. The rail
    /// rebuilds its rows on tmux notifications and on every Git change, so a
    /// row under the pointer is replaced regularly by a new one that believes
    /// it is not hovered, and the highlight blinks off until the pointer moves.
    /// That is the flicker, and it is why the row also looked unclickable: the
    /// only thing that ever set it back was a movement the user was not making.
    private func adoptHoverFromPointer() {
        guard let window, window.isKeyWindow else { return }
        let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        guard inside != isHovering else { return }
        isHovering = inside
        applyColors()
        needsLayout = true
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
