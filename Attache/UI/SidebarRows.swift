//
//  SidebarRows.swift
//  Attache
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

// MARK: - Host

/// A machine, drawn above its sessions — the tier that exists only when a
/// `[[host]]` is configured. With no remote hosts the rail never shows one,
/// so a machine that has always been local-only looks exactly as it did.
///
/// The row is also where a host's *state* lives: "connecting…", or the ssh
/// error, in full in the tooltip and truncated beside the name. That is the
/// issue's honesty rule at the top level — an unreachable host must say so
/// here, not present an empty list indistinguishable from "no sessions".
/// Clicking a down host retries now instead of waiting out the backoff.
@MainActor
final class SidebarHostRow: NSView {
    let hostID: String

    /// What a down row's click means. Wired only when the host is down.
    var onRetry: (() -> Void)?
    /// The heading's context menu — reconnect, edit, remove. Wired only for
    /// remote hosts; the local heading has no menu at all rather than a menu
    /// of disabled items.
    var onContextMenu: ((NSPoint) -> Void)?

    static let height: CGFloat = 22
    static let topGap: CGFloat = 14

    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private var pressed = false

    /// `state` is prose, already localised to the host row's size by the
    /// caller; `tone` picks the dot. nil prose means all is well and the row
    /// is just a heading.
    init(id: String, name: String, state: String?, tone: Tone) {
        hostID = id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        let theme = ChromeTheme.current
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        dot.layer?.backgroundColor = switch tone {
        case .ready: theme.faintText.withAlphaComponent(0.8).cgColor
        case .connecting: NSColor.systemYellow.cgColor
        case .down: NSColor.systemRed.cgColor
        }
        addSubview(dot)

        label.attributedStringValue = NSAttributedString(
            string: name.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .kern: 0.8,
            ]
        )
        label.textColor = theme.mutedText
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        stateLabel.stringValue = state ?? ""
        stateLabel.font = .systemFont(ofSize: 9.5)
        stateLabel.textColor = tone == .down ? .systemRed : theme.faintText
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.alignment = .right
        addSubview(stateLabel)
        if let state { toolTip = state }

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Host \(name)\(state.map { ", \($0)" } ?? "")")
    }

    enum Tone { case ready, connecting, down }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        dot.frame = CGRect(x: 8, y: bounds.midY - 2.5, width: 5, height: 5)
        // The name takes what it needs and the state text truncates in what
        // is left. Clamping the name by `intrinsicContentSize` looked
        // equivalent and was not: for this attributed string it under-reports
        // and "THIS MAC" drew as "THIS" — seen live on the first demo.
        let available = bounds.width - 20 - 8
        let nameWidth = stateLabel.stringValue.isEmpty
            ? available
            : min(label.attributedStringValue.size().width + 4, available * 0.6)
        label.frame = CGRect(
            x: 20, y: bounds.midY - 7, width: max(0, nameWidth), height: 14
        )
        let stateX = label.frame.maxX + 8
        stateLabel.frame = CGRect(
            x: stateX, y: bounds.midY - 7,
            width: max(0, bounds.width - stateX - 8), height: 14
        )
    }

    // Selection on mouse up, like every row here; a host row only acts at
    // all when it is down, and then the action is one retry.
    override func mouseDown(with _: NSEvent) { pressed = onRetry != nil }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, let onRetry,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onRetry()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onContextMenu else { return super.rightMouseDown(with: event) }
        onContextMenu(convert(event.locationInWindow, from: nil))
    }

    override var mouseDownCanMoveWindow: Bool { onRetry == nil }
}

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
    /// The most urgent thing any agent in this session is doing, or nil.
    ///
    /// It matters most when the session is *collapsed*, which is exactly when
    /// its window rows are not on screen to say it. A heading that only ever
    /// reported "some output happened" would hide the one state worth
    /// interrupting someone for behind a disclosure triangle.
    private let agent: AgentState?
    private let label = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let plusButton = NSButton()
    private let chevron = NSButton()
    private let activityDot = NSView()
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var pressed = false

    init(id: String, name: String, windowCount: Int, hasActivity: Bool,
         isCurrent: Bool, isExpanded: Bool, agent: AgentState? = nil)
    {
        sessionID = id
        sessionName = name
        self.isCurrent = isCurrent
        self.agent = agent
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
        // Same rule as a window row: a colour means an agent, neutral means
        // tmux noticed output. An agent outranks activity, and it is shown even
        // for the session being looked at — "waiting for you" does not stop
        // being true because you are in that session but another window.
        switch agent {
        case .needsInput: activityDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        case .working: activityDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        case .done: activityDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        case nil: activityDot.layer?.backgroundColor = ChromeTheme.current.faintText.cgColor
        }
        activityDot.isHidden = agent == nil && !(hasActivity && !isCurrent)
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
    /// The height a row *without* an agent's numbers gets. The rail's own
    /// layout asks each instance instead — see `rowHeight` — because a third
    /// line depends on what is in the window, not only on the settings.
    static var height: CGFloat { showsSecondLine ? 40 : 27 }

    private static var showsSecondLine: Bool {
        AppSettings.sidebarShowsGit
    }

    /// How tall each line is, and where it starts. One place, because the
    /// stats line moves up into the second slot when the Git line is off.
    private static let lineHeight: CGFloat = 15

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
    /// The state in words, beside the dot.
    ///
    /// A colour means nothing until it has been learned, and there is no legend
    /// on screen to learn it from — the first question this feature was asked
    /// was what the colours meant. The word answers it without a tooltip, and
    /// can be switched off once it stops being needed.
    private let agentLabel = NSTextField(labelWithString: "")
    /// The third line: which model, how full its context is, what it has cost.
    ///
    /// Four views rather than one string, because each is measured separately
    /// and they give way in a fixed order as the rail narrows — the cost is
    /// the last thing to go and the model is the first, since the model is the
    /// field that changes least.
    private let modelLabel = NSTextField(labelWithString: "")
    private let contextBar = NSView()
    private let contextFill = NSView()
    private let contextLabel = NSTextField(labelWithString: "")
    private let costLabel = NSTextField(labelWithString: "")
    /// The prompt-cache chip: `cache 43m` while warm, `cold +$8~13` once
    /// resuming means re-uploading the context. Words, not icons — the same
    /// reasoning as `agentLabel`.
    private let cacheLabel = NSTextField(labelWithString: "")
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var dragOrigin: NSPoint?
    private var didDrag = false
    private let decoration: WindowDecoration
    private let showsSecondLine: Bool
    /// Whether this row drew a third line, decided once in `init` for the same
    /// reason `rowHeight` is. A row that grew because an agent started must
    /// keep laying itself out that way until the rail rebuilds it.
    private let showsStatsLine: Bool

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
        // **Only when there is something to draw**, which is why this is not
        // just a setting. A rail whose windows are all shells is the rail that
        // existed before this feature, to the pixel; only the rows running an
        // agent that reports pay the 13pt.
        let stats = decoration.stats
        // The cache chip earns the line on its own: with nothing installed
        // there are no stats at all, and the wrapper-less machine is exactly
        // the one this chip exists for.
        showsStatsLine = (stats != nil && !(stats?.isEmpty ?? true)) || decoration.cache != nil
        rowHeight = (twoLines ? 40 : 27) + (showsStatsLine ? 13 : 0)
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
        addSubview(activityDot)

        agentLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        agentLabel.alignment = .right
        agentLabel.lineBreakMode = .byClipping
        addSubview(agentLabel)

        for line in [modelLabel, contextLabel, costLabel, cacheLabel] {
            line.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            line.isSelectable = false
            line.refusesFirstResponder = true
            line.isHidden = !showsStatsLine
            addSubview(line)
        }
        modelLabel.lineBreakMode = .byTruncatingTail
        cacheLabel.lineBreakMode = .byClipping
        // All three left-aligned. The line reads left to right from a fixed
        // edge, so each field starts where the one before it ended and none of
        // them needs a box wider than its own text.

        contextBar.wantsLayer = true
        contextBar.layer?.cornerRadius = 2.5
        contextBar.isHidden = !showsStatsLine
        contextFill.wantsLayer = true
        contextFill.layer?.cornerRadius = 2.5
        contextBar.addSubview(contextFill)
        addSubview(contextBar)

        applyStatus(window: window)
        applyColors()
    }

    /// Fill the second line and the dot, and decide what the tooltip says.
    ///
    /// The agent replaces tmux's activity dot rather than sitting beside it:
    /// both are "something happened here", and the agent's is the more specific
    /// of the two. A row with an agent in it has no use for "unseen output".
    private func applyStatus(window: TmuxWindow) {
        shownCache = computeShown()
        var tips = ["\(window.index): \(window.name)"]

        // Switched on `shown`, so every case that has an agent takes the same
        // branch. **An agent's dot is drawn whether or not the row is
        // selected.** Only the last case — no agent at all — defers to tmux's
        // activity flag, which is the one mark that genuinely has nothing to
        // say about the row you are already looking at.
        switch shown {
        case .state(let state):
            activityDot.isHidden = false
            let name = agentName
            switch state {
            case .needsInput: tips.append("\(name) · waiting for you\(Self.age(decoration.agent?.since))")
            case .working: tips.append("\(name) · working\(Self.age(decoration.agent?.since))")
            case .done: tips.append("\(name) · finished\(Self.age(decoration.agent?.since))")
            }

        case .settled:
            activityDot.isHidden = false
            tips.append("\(agentName) · idle, finished\(Self.age(decoration.agent?.since))")

        case .silent:
            activityDot.isHidden = false
            tips.append(
                AgentHookInstaller.isInstalled()
                    ? "\(agentName) is running. It started before the hook was installed —"
                        + " restart it to see what it is doing."
                    : "\(agentName) is running. Install the hook in Settings to see"
                        + " what it is doing."
            )

        case .none:
            // tmux's own flag, unchanged in meaning: it is what the `#` in a
            // plain `tmux attach` status line means. Hidden on the selected row
            // because "output arrived where you are not looking" is not true of
            // the row you are looking at.
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

        agentLabel.stringValue = agentWord ?? ""

        if let cache = decoration.cache {
            cacheLabel.stringValue = Self.cacheText(for: cache, now: Date())
            tips.append(contentsOf: Self.cacheTooltip(for: cache, now: Date()))
        }

        if let stats = decoration.stats {
            modelLabel.stringValue = stats.shortModel ?? ""
            // Nothing at all while the percentage is null, which is what a
            // session that has not sent a message reports. An empty bar there
            // would read as "context is empty" — true by accident today and
            // wrong the moment it is not.
            // No padding. The line runs left to right from a fixed left edge,
            // so nothing downstream depends on this field having a constant
            // width — and a pad character would only push the digits away from
            // the bar on the rows that have one digit.
            contextLabel.stringValue = stats.contextPercent.map { "\($0)%" } ?? ""
            contextBar.isHidden = !showsStatsLine || stats.contextPercent == nil
            costLabel.stringValue = stats.costText ?? ""
            tips.append(contentsOf: Self.statsTooltip(for: stats))
        }

        toolTip = tips.joined(separator: "\n")
    }

    /// Everything the agent reports that the row has no width for.
    ///
    /// The row shows three fields because at the default 168pt rail three is
    /// what fits. The rest is real and worth keeping, so it goes here rather
    /// than being thrown away — which is also why the wrapper sends the whole
    /// object instead of the three numbers the row draws.
    private static func statsTooltip(for stats: AgentStats) -> [String] {
        var lines = [String]()
        if let model = stats.model { lines.append(model) }

        var context = [String]()
        if let percent = stats.contextPercent { context.append("\(percent)% of context") }
        if let tokens = stats.contextTokens {
            context.append(
                stats.contextWindowSize.map { "\(compact(tokens)) / \(compact($0))" }
                    ?? compact(tokens)
            )
        }
        if !context.isEmpty { lines.append(context.joined(separator: " · ")) }

        var session = [String]()
        if let cost = stats.costText { session.append(cost) }
        if let added = stats.linesAdded, let removed = stats.linesRemoved,
           added + removed > 0
        {
            session.append("+\(added) −\(removed) lines")
        }
        if let duration = stats.durationMS, duration > 0 {
            session.append(elapsed(milliseconds: duration))
        }
        if !session.isEmpty { lines.append(session.joined(separator: " · ")) }

        var mode = [String]()
        if let effort = stats.effort { mode.append("effort \(effort)") }
        if let style = stats.outputStyle, style != "default" { mode.append(style) }
        if !mode.isEmpty { lines.append(mode.joined(separator: " · ")) }

        return lines
    }

    /// What the chip says. Warm is a countdown, because "how long can I
    /// step away" is the question; cold is the bill, because "what does
    /// coming back cost" is. The cold figure is a range and stays one: which
    /// cache tier the next request gets is unknowable before it is sent.
    private static func cacheText(for cache: PromptCacheEstimate, now: Date) -> String {
        let left = cache.remaining(now: now)
        guard left > 0 else {
            return "cold +\(moneyRange(cache.resumeExtraLoUSD, cache.resumeExtraHiUSD))"
        }
        return "cache \(shortDuration(left))"
    }

    private static func cacheTooltip(for cache: PromptCacheEstimate, now: Date) -> [String] {
        let tier = cache.tier.rawValue
        let left = cache.remaining(now: now)
        if left > 0 {
            return [
                "Prompt cache warm — \(shortDuration(left)) left (\(tier) tier, renews on use)",
                "Next message rides it for ≈ \(money(cache.resumeWarmUSD))"
                    + " instead of \(moneyRange(cache.resumeColdLoUSD, cache.resumeColdHiUSD))",
            ]
        }
        return [
            "Prompt cache cold — expired \(shortDuration(-left)) ago (\(tier) tier)",
            "Next message re-uploads \(compact(cache.contextTokens)) tokens: "
                + "+\(moneyRange(cache.resumeExtraLoUSD, cache.resumeExtraHiUSD))"
                + " over the warm \(money(cache.resumeWarmUSD))",
            "One-time: that message rebuilds the cache. The range is the two"
                + " write tiers; which one the next request gets is decided server-side.",
        ]
    }

    /// `43m`, `1h07m`, `<1m`, `6d`.
    private static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "<1m" }
        let days = total / 86400
        if days > 0 { return "\(days)d" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return String(format: "%dh%02dm", hours, minutes) }
        return "\(minutes)m"
    }

    /// `$0.70`, `$8.10`.
    private static func money(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    /// `$8~13` when dollars carry the message, `$0.5~0.8` when cents do.
    private static func moneyRange(_ lo: Double, _ hi: Double) -> String {
        if hi >= 2 {
            return "$\(Int(lo.rounded()))~\(Int(hi.rounded()))"
        }
        return String(format: "$%.1f~%.1f", lo, hi)
    }

    /// `812k`, `1.2M`. Token counts, where the exact digit never matters and
    /// the magnitude always does.
    private static func compact(_ value: Int) -> String {
        if value >= 1_000_000 {
            let millions = Double(value) / 1_000_000
            return millions >= 10
                ? "\(Int(millions.rounded()))M"
                : String(format: "%.1fM", millions)
        }
        if value >= 1000 { return "\(value / 1000)k" }
        return "\(value)"
    }

    private static func elapsed(milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h\(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
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

    /// What the row should draw, which is not always the word tmux is holding.
    ///
    /// `none` and `silent` were one case and had to be separated: "there is no
    /// agent in this window" and "there is one and it has never reported" want
    /// different marks, and collapsing them made the visibility rule below fall
    /// through to tmux's activity flag — which hides the dot on the selected
    /// row. An agent's mark disappearing because you clicked its row is the
    /// kind of thing that has to mean something, and it meant nothing.
    private enum Shown {
        case state(AgentState)
        /// Finished, and long enough ago that it is no longer news.
        case settled
        /// An agent is here and has never said anything — its session started
        /// before the hook did. Genuinely unknown, unlike `settled`.
        case silent
        /// No agent in this window at all.
        case none
    }

    /// Decided once, in `applyStatus`, and read from everywhere else.
    ///
    /// It depends on the clock, and `applyColors()` and `layout()` are called
    /// independently — AppKit lays a view out on a window resize without
    /// repainting it. Recomputing in both meant the dot could take its *size*
    /// from one side of the 30-minute boundary and its *colour* from the other.
    private var shownCache: Shown = .none

    private var shown: Shown { shownCache }

    private func computeShown() -> Shown {
        guard let agent = decoration.agent else { return .none }
        guard agent.state != nil else { return .silent }
        if agent.isSettled { return .settled }
        return agent.state.map { Shown.state($0) } ?? .silent
    }

    private var agentName: String {
        decoration.agent?.kind.map { $0 == "claude" ? "Claude Code" : $0 } ?? "An agent"
    }

    /// The state in words. Nil when there is nothing to say, or when the
    /// setting is off.
    ///
    /// Deliberately not the tooltip's wording: this has to fit beside a window
    /// name in a rail that is 168pt wide by default, so it is the shortest
    /// phrase that is still unambiguous. "waiting" alone would not be —
    /// waiting for what.
    private var agentWord: String? {
        guard AppSettings.sidebarShowsAgentText, decoration.agent != nil else { return nil }
        switch shown {
        case .state(.working): return "working"
        case .state(.needsInput): return "needs you"
        case .state(.done): return "done"
        // Finished a while ago. Not "unknown" — the app knows exactly what
        // happened, it just happened long enough ago to stop being news.
        case .settled: return "idle"
        // Never said anything. This is the one case that really is unknown.
        case .silent: return "unknown"
        // No agent — the guard above already returned, so this is unreachable.
        // Spelled out rather than defaulted so that adding a state to `Shown`
        // is a compile error here, which is how the last one got missed.
        case .none: return nil
        }
    }

    /// The dot, as colour plus whether it is filled.
    ///
    /// **One rule, and it is the whole design: a colour means an agent.** Blue,
    /// amber and green are things a coding agent is doing and are worth
    /// crossing the room for. Anything neutral is not about an agent.
    ///
    /// tmux's own activity flag used to be `systemOrange` — the same amber that
    /// now means "an agent is waiting for you". Two very different messages in
    /// one colour, told apart only by whether an agent happens to be in that
    /// window, which the dot does not show. It is neutral now.
    ///
    /// System colours rather than theme-derived ones: "this one is waiting for
    /// you" has to be the same colour under every terminal scheme, and a hue
    /// blended out of whatever is loaded would be a different one each time.
    private var dotStyle: (color: NSColor, filled: Bool, size: CGFloat) {
        let theme = ChromeTheme.current
        switch shown {
        case .state(.needsInput): return (.systemOrange, true, 7)
        case .state(.working): return (.systemBlue, true, 7)
        case .state(.done): return (.systemGreen, true, 7)
        // Settled: still an agent, no longer an event. Neutral and filled —
        // filled because this *is* known, unlike the hollow ring below.
        case .settled: return (theme.mutedText, true, 6)
        case .silent:
            // An agent that has never reported. Hollow on purpose: the app
            // knows something is running and does not know what, and a filled
            // dot in any colour would be claiming more than that.
            return (theme.mutedText, false, 8)
        default:
            // tmux's `#`: output arrived in a window you are not looking at.
            // Neutral and smaller, because it is ambient rather than addressed
            // to you.
            return (theme.faintText, true, 5)
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
        // The word and the dot are one mark and must agree, including on the
        // selected row. They did not: the word switched to `onAccent` over the
        // accent fill while the dot kept its own colour, so a neutral one — the
        // hollow "state unknown" ring, and tmux's activity dot — vanished into
        // the fill the moment its row was selected. Reported as "sometimes the
        // circle is there and sometimes it is not".
        let dot = dotStyle
        let mark = isActive ? theme.onAccent.withAlphaComponent(0.9) : dot.color
        activityDot.layer?.backgroundColor = dot.filled ? mark.cgColor : NSColor.clear.cgColor
        activityDot.layer?.borderColor = mark.cgColor
        activityDot.layer?.borderWidth = dot.filled ? 0 : 1.5
        agentLabel.textColor = mark

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

        applyStatsColors(theme)
    }

    /// The third line's colours.
    ///
    /// Only the context bar carries a hue, and it carries it for one reason:
    /// a context that is nearly full is the thing on this line that is about
    /// to cost you something. The model and the cost are facts, not warnings,
    /// so they stay in the rail's own greys — colouring them too would leave
    /// three competing signals on a line 122pt wide.
    private func applyStatsColors(_ theme: ChromeTheme) {
        guard showsStatsLine else { return }
        let percent = decoration.stats?.contextPercent ?? 0
        let hue = Self.contextColor(percent, theme)

        if isActive {
            modelLabel.textColor = theme.onAccent.withAlphaComponent(0.75)
            costLabel.textColor = theme.onAccent.withAlphaComponent(0.85)
            contextLabel.textColor = theme.onAccent.withAlphaComponent(0.85)
            contextBar.layer?.backgroundColor = theme.onAccent.withAlphaComponent(0.25).cgColor
            contextFill.layer?.backgroundColor = theme.onAccent.withAlphaComponent(0.9).cgColor
            cacheLabel.textColor = theme.onAccent.withAlphaComponent(0.85)
        } else {
            modelLabel.textColor = theme.faintText
            costLabel.textColor = theme.mutedText
            contextLabel.textColor = hue
            contextBar.layer?.backgroundColor = theme.faintText.withAlphaComponent(0.25).cgColor
            contextFill.layer?.backgroundColor = hue.withAlphaComponent(
                percent >= Self.contextWarnPercent ? 1 : 0.8
            ).cgColor
            cacheLabel.textColor = cacheColor(theme)
        }
    }

    /// The chip's hue. **Blue for cold, and red stays out of it**: red on
    /// this line already means "context nearly full", and cold is not a
    /// failure — it is a price. Cold-is-blue needs no legend, cannot collide
    /// with the context colours, and follows the line's own rule: grey while
    /// nothing needs saying (a comfortably warm cache is the normal state),
    /// colour only when the number is telling you to act — amber while the
    /// last minutes run out, blue once resuming costs real money.
    private func cacheColor(_ theme: ChromeTheme) -> NSColor {
        guard let cache = decoration.cache else { return theme.faintText }
        let left = cache.remaining(now: Date())
        if left <= 0 { return .systemBlue }
        if left < 300 { return .systemOrange }
        return theme.faintText
    }

    static let contextWarnPercent = 70
    private static let contextHotPercent = 90

    /// **Grey until it means something.**
    ///
    /// This started blue, which made the one coloured thing on the row the
    /// number that is normally fine — so the line read as three greys and an
    /// alarm, on every row, all day. A context under 70% is not news; it is the
    /// same kind of fact as the model name and the cost beside it, and it is
    /// drawn the same way.
    ///
    /// The colour is kept for the two states where it is telling you something
    /// you would otherwise have to read the number to find out: amber when
    /// there is not much room left, red when the next long file is going to
    /// force a compaction.
    private static func contextColor(_ percent: Int, _ theme: ChromeTheme) -> NSColor {
        if percent >= contextHotPercent { return .systemRed }
        if percent >= contextWarnPercent { return .systemOrange }
        return theme.mutedText
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
        let dotSize = dotStyle.size
        activityDot.layer?.cornerRadius = dotSize / 2

        guard showsSecondLine else {
            // The single-line row exactly as it was, so turning the setting off
            // is a return to the old rail rather than a narrower version of the
            // new one. Centred within **27pt**, not within `bounds.height`: a
            // row that grew for an agent's numbers is 40pt tall and centring
            // the name in that would leave it floating over the line below.
            let band: CGFloat = 27
            indexLabel.frame = CGRect(x: 14, y: (band - 13) / 2, width: 14, height: 13)
            var right = bounds.maxX - 8
            if !activityDot.isHidden {
                activityDot.frame = CGRect(
                    x: right - dotSize, y: (band - dotSize) / 2,
                    width: dotSize, height: dotSize
                )
                right -= dotSize + 6
            }
            let left = indexLabel.frame.maxX + 10
            label.frame = CGRect(
                x: left, y: (band - 15) / 2,
                width: max(0, right - left), height: 15
            )
            // With the Git line off the numbers move up into the slot it would
            // have used. They are the second line, not the third.
            layoutStatsLine(left: left, y: 25)
            return
        }

        // Indented past the heading's own text, so the two levels read as a
        // tree rather than as one flat list with some rows in capitals.
        indexLabel.frame = CGRect(x: 14, y: 5, width: 14, height: 13)
        let left = indexLabel.frame.maxX + 10

        var right = bounds.maxX - 8
        if !activityDot.isHidden {
            activityDot.frame = CGRect(x: right - dotSize, y: 5, width: dotSize, height: dotSize)
            right -= dotSize + 5
        }
        // The word sits to the *left* of the dot and is measured rather than
        // guessed: it is the one element here whose width depends on which
        // state is showing, and a fixed reservation would either clip
        // "needs you" or waste the space "done" does not need.
        if !agentLabel.stringValue.isEmpty {
            let width = min(
                ceil(agentLabel.attributedStringValue.size().width) + 1,
                max(0, right - left - 40)
            )
            agentLabel.frame = CGRect(x: right - width, y: 4, width: max(0, width), height: 13)
            agentLabel.isHidden = width <= 0
            right -= width + 6
        } else {
            agentLabel.isHidden = true
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

        layoutStatsLine(left: left, y: 37)
    }

    /// `Opus 5  ▰▱▱ 34%  $2.14`, laid out left to right.
    ///
    /// **Everything hangs off the left edge, which is the one thing on this
    /// line that never moves.** Anchoring on the right was the other way to do
    /// it and it could not be made to settle: with the fields right-aligned,
    /// whichever one changed width pushed everything to its left along with
    /// it, so a cost going from `$9.99` to `$10.01`, or a context going from
    /// `9%` to `10%`, shifted a whole column. Any two of the three could be
    /// held still, never all three.
    ///
    /// From the left there is nothing to trade. The model name is what decides
    /// where the bar starts, and on a machine running one model — which is the
    /// ordinary case — every row has the same model name and therefore the
    /// same bar position, for free and without reserving anything.
    ///
    /// What gives way as the rail narrows is the model, by truncation and then
    /// entirely: it is the field that changes least and the one already known.
    /// Then the bar, because the percentage beside it says the same thing in
    /// fewer pixels.
    private func layoutStatsLine(left: CGFloat, y: CGFloat) {
        guard showsStatsLine else { return }
        let height: CGFloat = 13
        let barWidth: CGFloat = 22
        let barHeight: CGFloat = 5
        /// Below this the model can only draw an ellipsis, which is worse than
        /// drawing nothing.
        let modelFloor: CGFloat = 30
        let rightEdge = bounds.maxX - 8

        let percentWidth = Self.measure(contextLabel)
        let costWidth = Self.measure(costLabel)
        let wantsBar = !contextBar.isHidden

        // What the fields after the model need, so the model can be given the
        // rest rather than pushing them off the row.
        var tail = percentWidth
        if wantsBar { tail += barWidth + Self.fieldGap }
        if costWidth > 0 { tail += Self.fieldGap + costWidth }

        var x = left
        let roomForModel = rightEdge - left - tail - Self.fieldGap
        let modelWidth = min(Self.box(modelLabel), max(0, roomForModel))
        modelLabel.isHidden = modelWidth < modelFloor
        if !modelLabel.isHidden {
            modelLabel.frame = CGRect(x: x, y: y, width: modelWidth, height: height)
            // Advanced past the *glyphs*, not past the box: the extra the cell
            // needed is empty on both sides, and counting it would leave the
            // bar further from the model than every other field is from its
            // neighbour.
            let inset = max(0, (modelWidth - Self.measure(modelLabel)) / 2)
            x += modelWidth - inset + Self.fieldGap
        }

        let showsBar = wantsBar && x + barWidth + Self.fieldGap + percentWidth <= rightEdge
        if showsBar {
            contextBar.frame = CGRect(
                x: x, y: y + (height - barHeight) / 2, width: barWidth, height: barHeight
            )
            let fraction = min(1, max(0, Double(decoration.stats?.contextPercent ?? 0) / 100))
            contextFill.frame = CGRect(x: 0, y: 0, width: barWidth * fraction, height: barHeight)
            x += barWidth + Self.fieldGap
        } else {
            contextBar.isHidden = true
        }

        if percentWidth > 0 {
            contextLabel.frame = CGRect(x: x, y: y, width: percentWidth, height: height)
            x += percentWidth + Self.fieldGap
        }
        contextLabel.isHidden = percentWidth <= 0

        costLabel.frame = CGRect(
            x: x, y: y, width: max(0, min(costWidth, rightEdge - x)), height: height
        )
        costLabel.isHidden = costWidth <= 0 || x >= rightEdge
        if !costLabel.isHidden { x += Self.measure(costLabel) + Self.fieldGap }

        // Last in the give-way order, like the cost: the model and the bar
        // have already yielded by the time this clips.
        let cacheWidth = Self.measure(cacheLabel)
        cacheLabel.frame = CGRect(
            x: x, y: y, width: max(0, min(cacheWidth, rightEdge - x)), height: height
        )
        cacheLabel.isHidden = cacheWidth <= 0 || x >= rightEdge
    }

    /// The space between the fields on the third line. One constant, because
    /// the whole point of the line is that its columns agree.
    private static let fieldGap: CGFloat = 7

    /// The width of a label's glyphs. What a field needs in order to *draw*
    /// them can be more — see `box`.
    private static func measure(_ label: NSTextField) -> CGFloat {
        label.stringValue.isEmpty
            ? 0
            : ceil(label.attributedStringValue.size().width) + 1
    }

    /// The width a label needs before it will stop truncating itself.
    ///
    /// **A cell wants more than its glyphs**, and only the field that is
    /// allowed to truncate cares. Measured at 10pt: `Opus 5` advances 34.70
    /// and its cell reports 38.70, and a frame of 34, 35 or 36 draws `Opu…`
    /// while 38 and up draws all of it. `intrinsicContentSize` is not the
    /// answer either — it reports 35.00, under the width at which the field
    /// truncates, which is how this was got wrong once already.
    ///
    /// The other two fields are measured, not truncating, so they are given
    /// their glyphs and nothing more.
    private static func box(_ label: NSTextField) -> CGFloat {
        guard !label.stringValue.isEmpty, let cell = label.cell else { return 0 }
        return ceil(cell.cellSize.width)
    }

    /// The drawn width of a string in a given font, for reserving a column
    /// against the widest value rather than the current one.
    private static func width(of text: String, font: NSFont?) -> CGFloat {
        guard let font else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
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

// MARK: - Small action rows

/// A quiet one-line row that does one thing when clicked: the "N hidden"
/// counter under a session's list, and the "+ New session" a connected host
/// with nothing to show offers instead of an empty block. Generalised from
/// the hidden-count row when the second caller appeared; the hover wash and
/// press-on-mouse-up rules are the rail's usual ones.
@MainActor
final class SidebarActionRow: NSView {
    var onClick: (() -> Void)?
    /// Reported so the rail's double-click bookkeeping stays honest — see
    /// `SessionSidebarView.isDoubleClick(on:clickCount:)`. This row has no
    /// double-click of its own; what it owes is to not let a press on it go
    /// unrecorded, so a press *through* it cannot look like a repeat.
    var onPress: (() -> Void)?

    static let height: CGFloat = 20

    private let label = NSTextField(labelWithString: "")
    private let indent: CGFloat
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var pressed = false

    init(text: String, toolTip: String, indent: CGFloat = 32) {
        self.indent = indent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5

        label.stringValue = text
        label.font = .systemFont(ofSize: 10.5)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        self.toolTip = toolTip
        applyColors()
    }

    /// The hidden-count reading, exactly as it always was.
    convenience init(count: Int) {
        // Lined up with the window names above it, not with their indices.
        self.init(text: "\(count) hidden", toolTip: "Bring every hidden window back", indent: 32)
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
        label.frame = CGRect(
            x: indent, y: (bounds.height - 13) / 2,
            width: max(0, bounds.width - indent - 8), height: 13
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
