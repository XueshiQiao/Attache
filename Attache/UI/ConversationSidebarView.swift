//
//  ConversationSidebarView.swift
//  Attache
//

import AppKit

/// The right-hand rail: the conversation happening in the window on screen.
///
/// **Everything here is authored locally, and it is the third exception to
/// CLAUDE.md's opening rule** — alongside the hidden window ids and
/// `expandedSessions`. Which turns are open and which progress rows are
/// expanded are facts about *looking*, not about the session; tmux has no
/// opinion and no format variable holds them. The conversation itself is read,
/// never written: this view cannot change what an agent said.
///
/// ## Why a turn is the unit
///
/// One prompt and everything it caused. Collapsed, a turn is one line — the
/// prompt — so a collapsed sidebar *is* the outline of the conversation, and no
/// separate outline has to be built or kept in step.
///
/// ## Why progress notes get one line each
///
/// The alternative was collapsing a run of them into a single "12 steps" line,
/// and it was rejected after seeing both against real data. An agent's progress
/// notes are where the findings are — "0 of 11 matched, not one of them" is a
/// short plain sentence, so it classifies as progress no matter how the rule is
/// written, and under the collapsed-run treatment it vanishes entirely.
/// One line each keeps it scannable; clicking one opens that note alone.
final class ConversationSidebarView: NSView {

    // MARK: - State

    private var conversation: AgentConversation?
    /// Ids of the prompts whose turns are open. Survives snapshots, which is
    /// the point: the file grows while the person is reading it, and a
    /// re-render that closed everything would make the sidebar unusable exactly
    /// when the agent is busiest.
    private var openTurns = Set<String>()
    private var openSteps = Set<String>()
    /// Set when the person has opened or closed something themselves. Until
    /// then the newest turn is opened automatically; afterwards it is not,
    /// because moving the reader's viewport while they are reading is worse
    /// than making them click.
    private var hasBeenTouched = false
    private var lastConversationID: String?

    // MARK: - Views

    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let headerSeparator = NSBox()
    private let titleDragStrip = TitleDragStrip()
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    /// The prompt of whichever turn the viewport is currently inside, pinned
    /// to the top of the scroll area. See `updateStickyHeader`.
    private let stickyHeader = StickyHeaderView()
    /// Each turn's view alongside what its pinned header would say. Rebuilt
    /// with the rows; read on every scroll, so it holds the strings rather
    /// than digging them back out of the view tree.
    private var pinnable = [PinnableTurn]()
    private let emptyLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// A resize re-wraps every reply, so the pinned header has to be placed
    /// against the new geometry rather than the one it was cached for.
    override func layout() {
        super.layout()
        updateStickyHeader()
    }

    /// Anything in this rail that does not answer inherits "yes, drag the
    /// window", and a rail whose content area drags the window fights the
    /// scroll gesture that starts in the same place.
    ///
    /// The band across the top is the deliberate exception — see
    /// `titleDragStrip`, which puts it back. Blanket-disabling it here without
    /// that strip took away the only part of this rail the window could be
    /// dragged from, which review caught on 2026-08-02.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - Build

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        metaLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        metaLabel.lineBreakMode = .byTruncatingTail

        // No buttons in this row any more: collapse-all, expand-all and the
        // rail toggle live together in the title band, hosted by
        // `MainViewController` — the band is window chrome and survives this
        // whole view collapsing. The header is text and nothing else.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [titleLabel, metaLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        header.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        headerSeparator.boxType = .separator
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 18, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        // **No layer flattening here, and that is a decision that was made
        // twice.** Measured on a nine-turn conversation, CPU during a
        // synthetic 60Hz scroll (median / peak): no layer 12.1% / 55.3%, one
        // layer per turn 12.1% / 51.0%, whole subtree flattened 9.9% / 44.5%.
        // Flattening won on those numbers and was shipped.
        //
        // Then the owner looked at it: text drawn into a flattened layer loses
        // subpixel antialiasing, so the rail rendered one way while idle and
        // visibly *changed* the moment anything made the layer redraw — his
        // words were that clicking "restores it to normal". A 20% saving on a
        // scroll he had already called acceptable does not buy a permanent
        // difference in how the text looks. Numbers decided the first round;
        // eyes decided this one.
        document.wantsLayer = true

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        // First, so everything else sits above it: the strip only claims the
        // pixels nothing else covers.
        addSubview(titleDragStrip)
        addSubview(header)
        addSubview(headerSeparator)
        addSubview(scrollView)
        addSubview(stickyHeader)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            titleDragStrip.topAnchor.constraint(equalTo: topAnchor),
            titleDragStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleDragStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleDragStrip.heightAnchor.constraint(equalToConstant: 30),

            // The title band the window drags by is 28pt; the header clears it
            // so the traffic lights and this never share a row.
            header.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),

            headerSeparator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7),
            headerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stickyHeader.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stickyHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            stickyHeader.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ])

        // The clip view does not post bounds changes unless asked, and this is
        // the notification the pinned header rides on.
        scrollView.contentView.postsBoundsChangedNotifications = true
        clockObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStickyHeader() }
            }
        )
        stickyHeader.onClick = { [weak self] in self?.scrollToPinnedTurn() }

        applyChromeTheme()
        watchTheClock()
    }

    /// Redraw when the time zone or locale moves under us.
    ///
    /// The equality guard in `show` exists to stop rebuilds, and this is the
    /// one input to what is drawn that the guard cannot see: timestamps are
    /// formatted against ambient state that no snapshot carries. Without this,
    /// changing the system time zone leaves every visible time an hour wrong
    /// until the conversation happens to change. Found by review 2026-08-01.
    private func watchTheClock() {
        for name in [
            NSLocale.currentLocaleDidChangeNotification,
            Notification.Name.NSSystemTimeZoneDidChange,
        ] {
            clockObservers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        ReplyView.resetClock()
                        self?.rebuild()
                    }
                }
            )
        }
    }

    private var clockObservers = [NSObjectProtocol]()

    deinit {
        for observer in clockObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Input

    /// What the header says, independent of whether there is a conversation —
    /// a window running an agent this app cannot read still gets a name.
    struct Header: Equatable {
        var windowName: String?
        var model: String?
        var cost: String?
        var contextPercent: Int?
    }

    func show(conversation: AgentConversation?, header: Header, placeholder: String) {
        // **The single most important line in this file for how the app
        // feels.** `refreshSidebar` runs on every tmux notification — an agent
        // writing output produces a stream of them — and it calls this
        // unconditionally. Without this test each one tore down and rebuilt
        // every view in the rail, several hundred of them, and the result was
        // a window that could not be scrolled. Nothing about the conversation
        // has changed on the overwhelming majority of these calls.
        if conversation == shown, header == shownHeader, placeholder == shownPlaceholder {
            return
        }
        shown = conversation
        shownHeader = header
        shownPlaceholder = placeholder
        apply(conversation: conversation, header: header, placeholder: placeholder)
    }

    private var shown: AgentConversation?
    private var shownHeader: Header?
    private var shownPlaceholder: String?

    private func apply(conversation: AgentConversation?, header: Header, placeholder: String) {
        // A different conversation is a different reading position. Keeping
        // the open set would apply one conversation's ids to another's, which
        // silently opens unrelated turns.
        if conversation?.id != lastConversationID {
            lastConversationID = conversation?.id
            openTurns.removeAll()
            openSteps.removeAll()
            hasBeenTouched = false
        }
        self.conversation = conversation

        titleLabel.stringValue = header.windowName ?? ""
        metaLabel.stringValue = [
            header.model,
            header.cost,
            header.contextPercent.map { "\($0)%" },
            conversation.map { "\(turns(of: $0).count) turns" },
        ].compactMap { $0 }.joined(separator: "   ")

        let isEmpty = conversation?.isEmpty ?? true
        emptyLabel.stringValue = isEmpty ? placeholder : ""
        emptyLabel.isHidden = !isEmpty
        scrollView.isHidden = isEmpty

        rebuild()
    }

    // MARK: - Turns

    private func turns(of conversation: AgentConversation) -> [Turn] {
        var result = [Turn]()
        var prompt: AgentMessage?
        var replies = [AgentMessage]()

        for message in conversation.messages {
            if message.author == .user {
                if prompt != nil || !replies.isEmpty {
                    result.append(Turn(prompt: prompt, replies: replies))
                }
                prompt = message
                replies = []
            } else {
                replies.append(message)
            }
        }
        if prompt != nil || !replies.isEmpty {
            result.append(Turn(prompt: prompt, replies: replies))
        }
        return result
    }

    private func rebuild() {
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            if ms > 16 {
                TmuxLog.lifecycle(
                    "conversation rail rebuilt \(stack.arrangedSubviews.count) turn(s)"
                        + " in \(Int(ms))ms"
                )
            }
        }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        pinnable.removeAll()
        turnOffsets.removeAll()
        headBottoms.removeAll()
        stickyHeader.isHidden = true
        guard let conversation, !conversation.isEmpty else { return }

        let all = turns(of: conversation)
        // Until the person touches it, the newest turn is the one they want
        // open — it is what the agent is doing right now.
        if !hasBeenTouched, let last = all.last { openTurns = [last.id] }

        for turn in all {
            let view = TurnView(
                turn: turn,
                isOpen: openTurns.contains(turn.id),
                openSteps: openSteps,
                onToggleTurn: { [weak self] in self?.toggleTurn(turn.id) },
                onToggleStep: { [weak self] in self?.toggleStep($0) }
            )
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if let prompt = turn.prompt, let head = view.head {
                pinnable.append(
                    PinnableTurn(
                        view: view,
                        head: head,
                        prompt: prompt.markdown,
                        replyCount: turn.replies.count,
                        id: turn.id
                    )
                )
            }
        }
        // Frames are not final until layout runs; the header is placed on the
        // first scroll or layout after this.
        DispatchQueue.main.async { [weak self] in self?.updateStickyHeader() }
    }

    /// Pin the prompt of the turn the viewport is inside — *while that turn is
    /// still running past the top edge*, and not otherwise.
    ///
    /// **The unit is a turn, and that is what makes this worth having.** A
    /// turn's replies can run for several screens, and once its prompt has
    /// scrolled away there is nothing on screen saying which question the
    /// answer belongs to. Same behaviour as a grouped table view on iOS.
    ///
    /// **Both of the tests below were missing and the rail was wrong with every
    /// turn collapsed**: a bar pinned over a list whose rows were all fully
    /// readable, captioning nothing. A collapsed turn is one row and no
    /// content, so there is never anything for a pinned copy of that row to
    /// stand in for.
    private func updateStickyHeader() {
        guard !pinnable.isEmpty else {
            stickyHeader.isHidden = true
            return
        }
        // **Positions are cached, and that is not premature.** This runs on
        // every scroll notification — many times a second — and a coordinate
        // conversion per turn per frame is thousands of calls a second on a
        // long conversation. The offsets only move when the rows do, so they
        // are computed once after layout and invalidated by `rebuild`.
        if offsetsAreStale { cacheTurnOffsets() }
        guard turnOffsets.count == pinnable.count, headBottoms.count == pinnable.count else {
            stickyHeader.isHidden = true
            return
        }

        let top = scrollView.contentView.bounds.origin.y

        // The last turn whose top has already passed the top edge.
        guard let found = ScrollGeometry.lastIndex(atOrAbove: top + 0.5, in: turnOffsets) else {
            stickyHeader.isHidden = true
            return
        }

        let current = pinnable[found]
        // Where this turn ends: the next turn's top, and for the last one its
        // own bottom, which the offsets do not carry.
        let bottom = found + 1 < turnOffsets.count
            ? turnOffsets[found + 1]
            : turnOffsets[found] + current.view.bounds.height

        // Two conditions, and a pin needs both.
        //
        // The turn's real prompt row has to have left the viewport. While it is
        // still on screen the pinned copy is a duplicate of a row the person
        // can already read — which is exactly what a fully collapsed rail is,
        // rows the whole way down with nothing under any of them.
        //
        // And enough of the turn has to be left below the top edge to be worth
        // captioning. The pin costs `stickyHeight` of viewport, so twice that
        // is the point where it starts covering as much of the turn as it
        // labels — and it is also what stops the pin flashing: below it, a turn
        // would be captioned for less scrolling than the caption is tall.
        //
        // Hiding here is what keeps the pin clear of the *next* turn's real
        // prompt row, which arrives at the top edge only when `bottom - top`
        // reaches zero. The `pushOffset` slide that used to prevent that
        // stacking is gone with it: it rode the pinned row up out of the scroll
        // area over exactly this interval, and while it was riding it drew over
        // the header above the scroll view, which nothing clips.
        guard top >= headBottoms[found], bottom - top >= stickyHeight * 2 else {
            stickyHeader.isHidden = true
            return
        }

        stickyHeader.isHidden = false
        stickyHeader.show(prompt: current.prompt, replyCount: current.replyCount)
        pinnedTurnID = current.id
    }

    /// Where each turn starts, in the document's coordinates.
    ///
    /// Emptied by `rebuild` and refilled on the next scroll or layout, because
    /// frames are not final until layout has run.
    private var turnOffsets = [CGFloat]()

    /// Where each turn's own prompt row *ends*, in the same coordinates. The
    /// pin only takes over once the viewport top is past this, so it is
    /// measured rather than guessed from the pinned row's height: a collapsed
    /// prompt runs to two lines and an open one to as many as it needs, while
    /// the pinned copy is always one.
    private var headBottoms = [CGFloat]()

    /// The pinned row's height, which is the floor on how much of a turn has to
    /// be left for pinning it to mean anything. Cached with the offsets because
    /// `fittingSize` runs a layout pass and this is read on every scroll event.
    private var stickyHeight: CGFloat = 0

    /// **Row count is not enough to know the offsets are still good.** Drag
    /// the divider and every reply re-wraps: each turn changes height, the
    /// document gets taller or shorter, and the *number* of turns is exactly
    /// what does not change. Offsets cached against a count alone would then
    /// pin the wrong turn for the rest of the session. Width and total height
    /// are the two things that move when the geometry does.
    private var offsetsAreStale: Bool {
        turnOffsets.count != pinnable.count
            || abs(cachedForWidth - bounds.width) > 0.5
            || abs(cachedForHeight - (scrollView.documentView?.bounds.height ?? 0)) > 0.5
    }

    private var cachedForWidth: CGFloat = 0
    private var cachedForHeight: CGFloat = 0

    private func cacheTurnOffsets() {
        guard let document = scrollView.documentView else { return }
        let computed = pinnable.map { ScrollGeometry.topEdge(of: $0.view, in: document) }
        // Refuse a snapshot taken before layout ran. Leaving the cache empty
        // keeps it "stale" so the next scroll tries again; storing the bad one
        // would strand the pinned header for the rest of the session.
        guard ScrollGeometry.areUsable(computed) else {
            turnOffsets.removeAll()
            headBottoms.removeAll()
            return
        }
        turnOffsets = computed
        headBottoms = pinnable.map {
            ScrollGeometry.topEdge(of: $0.head, in: document) + $0.head.bounds.height
        }
        stickyHeight = stickyHeader.fittingSize.height
        cachedForWidth = bounds.width
        cachedForHeight = document.bounds.height
    }


    private var pinnedTurnID: String?

    /// Clicking the pinned header goes back to where that turn starts, which is
    /// the only way back once its replies have scrolled a long way.
    private func scrollToPinnedTurn() {
        guard let pinnedTurnID,
              let index = pinnable.firstIndex(where: { $0.id == pinnedTurnID }),
              index < turnOffsets.count
        else { return }
        let y = turnOffsets[index]
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y - 1)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateStickyHeader()
    }

    private func toggleTurn(_ id: String) {
        hasBeenTouched = true
        if openTurns.contains(id) { openTurns.remove(id) } else { openTurns.insert(id) }
        rebuild()
    }

    private func toggleStep(_ id: String) {
        hasBeenTouched = true
        if openSteps.contains(id) { openSteps.remove(id) } else { openSteps.insert(id) }
        rebuild()
    }

    // Called by the band buttons `MainViewController` hosts; nothing inside
    // this view triggers them any more.
    func collapseAllTurns() {
        hasBeenTouched = true
        openTurns.removeAll()
        openSteps.removeAll()
        rebuild()
        scrollView.contentView.scroll(to: .zero)
    }

    func expandAllTurns() {
        hasBeenTouched = true
        guard let conversation else { return }
        openTurns = Set(turns(of: conversation).map(\.id))
        rebuild()
    }

    // MARK: - Theme

    func applyChromeTheme() {
        // The cached strings carry the old theme's colours baked in.
        ConversationMarkdown.flushCache()
        let theme = ChromeTheme.current
        titleLabel.textColor = theme.faintText
        metaLabel.textColor = theme.faintText
        emptyLabel.textColor = theme.faintText
        stickyHeader.applyChromeTheme()
        rebuild()
    }
}

// MARK: - One turn

/// A prompt and everything it caused.
///
/// A turn rather than a message is the unit because it is what makes the
/// collapsed sidebar an outline: shut, a turn is exactly the one line the
/// person typed.
private struct Turn {
    /// Nil for anything an agent said before the first prompt — a resumed
    /// session opens this way and dropping it would lose real content.
    let prompt: AgentMessage?
    let replies: [AgentMessage]
    var id: String { prompt?.id ?? "turn-zero" }
}

/// A turn the pinned header can stand in for, with everything reading it needs.
///
/// Turn zero is not one of these: it has no prompt, so there is no row to pin.
private struct PinnableTurn {
    let view: NSView
    /// The prompt row inside `view`. Its position decides when the pin takes
    /// over, so it is held rather than searched for on every scroll.
    let head: NSView
    let prompt: String
    let replyCount: Int
    let id: String
}

private final class TurnView: NSView {
    private let onToggleTurn: () -> Void

    /// The prompt row, when this turn has one. Read by the rail to place the
    /// pinned header; nothing else reaches into a turn's view tree.
    private(set) var head: NSView?

    init(
        turn: Turn,
        isOpen: Bool,
        openSteps: Set<String>,
        onToggleTurn: @escaping () -> Void,
        onToggleStep: @escaping (String) -> Void
    ) {
        self.onToggleTurn = onToggleTurn
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // One layer per turn — a tile the compositor can move without asking
        // any of the text inside to redraw. The unit is a turn rather than a
        // message because a turn is what opens and closes: its contents change
        // together or not at all.

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        if let prompt = turn.prompt {
            let head = PromptHeadView(
                prompt: prompt,
                replyCount: turn.replies.count,
                isOpen: isOpen,
                onClick: onToggleTurn
            )
            column.addArrangedSubview(head)
            head.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            self.head = head
        }

        if isOpen {
            for message in turn.replies {
                let view: NSView
                if message.standing == .finalReply {
                    view = ReplyView(message: message)
                } else {
                    view = StepRowView(
                        message: message,
                        isOpen: openSteps.contains(message.id),
                        onClick: { onToggleStep(message.id) }
                    )
                }
                column.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
        }

        // No rule between turns: the gap does that job, and the line was one
        // more horizontal edge in a rail that already has the prompt row's
        // block to mark where a turn starts. The 12pt this leaves between two
        // turns is what the line used to sit in the middle of, so removing it
        // changes no height.
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            // 3 + 3 between rows. Was 5 + 7; halved on the owner's read of it
            // once the divider line between rows was removed — with a line
            // there the gap had to carry the separation, without one it only
            // has to keep the rows from touching.
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

// MARK: - The prompt

/// The line the whole outline is made of.
private final class PromptHeadView: ClickableView {
    init(prompt: AgentMessage, replyCount: Int, isOpen: Bool, onClick: @escaping () -> Void) {
        super.init(onClick: onClick)
        let theme = ChromeTheme.current

        // The tinted block is inset from the rail's edges, but the *clickable*
        // view is not — the whole row answers a click, including the margin
        // beside the block. A target the width of the rail is easier to hit
        // than one that stops 8pt short of it, and nothing else lives there.
        let backing = NSView()
        backing.wantsLayer = true
        backing.layer?.backgroundColor = theme.accent.withAlphaComponent(0.22).cgColor
        backing.layer?.cornerRadius = 6
        backing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backing)
        NSLayoutConstraint.activate([
            backing.topAnchor.constraint(equalTo: topAnchor),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor),
            backing.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        let chevron = NSTextField(labelWithString: isOpen ? "▾" : "▸")
        chevron.font = .systemFont(ofSize: 9)
        chevron.textColor = theme.accent
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        let text = NSTextField(labelWithString: prompt.markdown)
        text.font = .systemFont(ofSize: AppSettings.conversationFontSize)
        text.textColor = theme.text
        text.maximumNumberOfLines = isOpen ? 0 : 2
        text.lineBreakMode = .byTruncatingTail
        // **Explicit, because the field is stretched.** Pinning the prompt's
        // trailing edge to the count makes the field as wide as the row, and a
        // short prompt then floats to whichever side the default alignment
        // picks — which came out right, so `start the app now.` sat against
        // the number while a wrapped prompt sat against the chevron. The row
        // reads as two ragged columns. Prompt left, count right.
        text.alignment = .left
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)

        // **The reply count is pinned to the trailing edge, not laid out after
        // the text.** In a horizontal stack the count sits wherever the prompt
        // stops, so it wandered from the middle of the row to its right edge
        // depending on how much the person typed — a column of numbers that is
        // not a column. This is the same trap as the collapse buttons at the
        // top of this file, and the same answer: say where it goes.
        var constraints = [
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            chevron.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            text.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ]
        if replyCount > 0 {
            let count = NSTextField(labelWithString: "\(replyCount)")
            count.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
            count.textColor = theme.mutedText
            count.setContentHuggingPriority(.required, for: .horizontal)
            count.setContentCompressionResistancePriority(.required, for: .horizontal)
            count.translatesAutoresizingMaskIntoConstraints = false
            addSubview(count)
            constraints += [
                count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17),
                // On the prompt's first baseline rather than its top: a 9.5pt
                // digit hung from the same top edge as 12pt text floats above
                // it and reads as a superscript.
                count.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
                // **`lessThanOrEqual`, not `equal`, and that is the whole
                // fix.** Pinning both edges stretches the field to the full
                // row, and a short prompt then sits wherever the stretched
                // field puts it — which came out flush right, so
                // `start the app now.` hugged the count while a wrapped prompt
                // hugged the chevron. Setting `alignment` does not help: the
                // field, not the text inside it, is what was in the wrong
                // place. Bounded on the right instead, the field is only as
                // wide as its content and its leading edge decides where it
                // starts. Prompt left, count right.
                text.trailingAnchor.constraint(
                    lessThanOrEqualTo: count.leadingAnchor, constant: -6
                ),
            ]
        } else {
            constraints.append(
                text.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingAnchor, constant: -17
                )
            )
        }
        NSLayoutConstraint.activate(constraints)
    }
}

// MARK: - A reply worth reading in full

private final class ReplyView: NSView {
    init(message: AgentMessage) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let theme = ChromeTheme.current

        let body = NSTextField(labelWithAttributedString: ConversationMarkdown.rendered(message.markdown, style: .current))
        body.maximumNumberOfLines = 0
        // Selectable so the person can lift a command or a path straight out of
        // a reply. Reading their own conversation and not being able to copy
        // from it would be a strange thing to ship.
        body.isSelectable = true
        body.allowsEditingTextAttributes = false
        body.translatesAutoresizingMaskIntoConstraints = false
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(body)

        let stamp = NSTextField(labelWithString: Self.time(message.timestamp))
        stamp.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        stamp.textColor = theme.faintText
        stamp.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stamp)

        NSLayoutConstraint.activate([
            stamp.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stamp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            body.topAnchor.constraint(equalTo: stamp.bottomAnchor, constant: 1),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// One formatter, not one per message.
    ///
    /// `DateFormatter()` is expensive to build, and this ran once for every
    /// message on every rebuild — hundreds of them, several times a second
    /// while an agent was working. Together with the rebuild itself it was
    /// what made the rail unscrollable.
    ///
    /// `var`, not `let`, because a cached formatter holds the time zone and
    /// locale it was built under. Both can change while the app is open, and
    /// the snapshot equality guard means an unchanged conversation would
    /// otherwise keep displaying times computed in the old zone indefinitely.
    /// `ConversationSidebarView` watches for that and calls `resetClock`.
    private static var clock = makeClock()

    private static func makeClock() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    static func resetClock() { clock = makeClock() }

    static func time(_ date: Date?) -> String {
        guard let date else { return "" }
        return clock.string(from: date)
    }
}

// MARK: - A step, one line until asked

private final class StepRowView: ClickableView {
    init(message: AgentMessage, isOpen: Bool, onClick: @escaping () -> Void) {
        super.init(onClick: onClick)
        let theme = ChromeTheme.current

        let stamp = NSTextField(labelWithString: ReplyView.time(message.timestamp))
        stamp.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        stamp.textColor = theme.faintText
        stamp.setContentHuggingPriority(.required, for: .horizontal)
        stamp.setContentCompressionResistancePriority(.required, for: .horizontal)

        let body = NSTextField()
        body.isBezeled = false
        body.isEditable = false
        body.drawsBackground = false
        if isOpen {
            body.attributedStringValue = ConversationMarkdown.rendered(
                message.markdown, style: .current
            )
            body.maximumNumberOfLines = 0
            body.isSelectable = true
        } else {
            body.stringValue = ConversationMarkdown.firstLine(of: message.markdown)
            body.font = .systemFont(ofSize: AppSettings.conversationFontSize - 1)
            body.textColor = theme.mutedText
            body.maximumNumberOfLines = 1
            body.lineBreakMode = .byTruncatingTail
        }
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [stamp, body])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // A hairline down the left edge, so a run of steps reads as one block
        // subordinate to the reply above it rather than as separate messages.
        let spine = NSBox()
        spine.boxType = .custom
        spine.borderWidth = 0
        spine.fillColor = theme.separator
        spine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spine)

        NSLayoutConstraint.activate([
            spine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            spine.topAnchor.constraint(equalTo: topAnchor),
            spine.bottomAnchor.constraint(equalTo: bottomAnchor),
            spine.widthAnchor.constraint(equalToConstant: 1),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            row.leadingAnchor.constraint(equalTo: spine.trailingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }
}

// MARK: - Shared bits

/// A view that reports a click.
///
/// Tracking that a press started here rather than reading `clickCount`, for the
/// reason CLAUDE.md records: synthesised events carry a click count of 0, so a
/// `clickCount == 1` test fails under exactly the automation used to check this
/// app's own interactions.
private class ClickableView: NSView {
    private let onClick: () -> Void
    private var pressedHere = false

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// This rail is draggable background everywhere else; a row that answers
    /// yes here never receives `mouseDown` at all — AppKit moves the window
    /// instead. That is the trap the pane splitter fell into.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { pressedHere = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressedHere = false }
        guard pressedHere, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        onClick()
    }
}

/// `NSScrollView` lays a document view out from the bottom otherwise, and a
/// conversation that starts at the bottom of its own scroll view reads as
/// broken.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The prompt of the turn currently being read, pinned to the top.
///
/// Drawn as the prompt row it stands in for — the same inset block, corner
/// radius, chevron and trailing count — so pinning reads as that row having
/// stayed put rather than as a second bar arriving over the list. It was an
/// opaque fill of `railBackground` before, a colour nothing else in this rail
/// uses, and it looked like exactly what it was.
private final class StickyHeaderView: NSView {
    var onClick: (() -> Void)?

    private let backing = NSView()
    private let chevron = NSTextField(labelWithString: "\u{25B4}")
    private let label = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let theme = ChromeTheme.current
        backing.wantsLayer = true
        backing.layer?.cornerRadius = 6
        backing.layer?.backgroundColor = Self.fill(theme)
        backing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backing)

        label.font = .systemFont(ofSize: AppSettings.conversationFontSize, weight: .medium)
        label.textColor = theme.text
        label.lineBreakMode = .byTruncatingTail
        // Two lines, matching the collapsed row it stands in for. One line
        // made a three-line prompt lose two of them the moment it pinned,
        // which reads as the pin showing a *different* prompt.
        label.maximumNumberOfLines = 2
        label.alignment = .left
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // Pointing up, unlike the real row's ▸/▾, because clicking this one does
        // something else: it goes back to where the turn started.
        chevron.font = .systemFont(ofSize: 9)
        chevron.textColor = theme.accent
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        count.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        count.textColor = theme.mutedText
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.translatesAutoresizingMaskIntoConstraints = false
        addSubview(count)

        // Every constant here matches `PromptHeadView`. They are the same row
        // seen twice and any difference between them shows up as the pinned
        // copy jumping as it takes over.
        NSLayoutConstraint.activate([
            backing.topAnchor.constraint(equalTo: topAnchor),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor),
            backing.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            chevron.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: count.leadingAnchor, constant: -6
            ),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17),
            count.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// What the pinned block is filled with.
    ///
    /// The real row lays 22% accent over whatever the rail shows and lets the
    /// window's translucency through. This one cannot: it floats over scrolling
    /// text and a 22% wash would let every line pass underneath it. So the same
    /// two colours are mixed against the theme background the rail sits on and
    /// laid down nearly opaque — one tone deeper, which is what the difference
    /// reads as, rather than a second colour. The 4% left over is not doing
    /// anything for legibility; it is there so the block still belongs to a
    /// window the desktop shows through.
    private static func fill(_ theme: ChromeTheme) -> CGColor {
        let tinted = theme.background.blended(withFraction: 0.22, of: theme.accent)
            ?? theme.background
        return tinted.withAlphaComponent(0.96).cgColor
    }

    func show(prompt: String, replyCount: Int) {
        // One line, markers stripped: this is a label standing in for a row,
        // not a second copy of the message.
        label.stringValue = ConversationMarkdown.firstLine(of: prompt)
        count.stringValue = replyCount > 0 ? "\(replyCount)" : ""
    }

    private var pressedHere = false
    override func mouseDown(with event: NSEvent) { pressedHere = true }
    override func mouseUp(with event: NSEvent) {
        defer { pressedHere = false }
        guard pressedHere, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        onClick?()
    }

    func applyChromeTheme() {
        let theme = ChromeTheme.current
        backing.layer?.backgroundColor = Self.fill(theme)
        label.textColor = theme.text
        chevron.textColor = theme.accent
        count.textColor = theme.mutedText
    }
}

/// The one part of this rail the window can be dragged from.
///
/// The top 30pt are left empty on purpose — it is the band the traffic lights
/// and the window title live in, and a window has to be draggable from it.
/// Everything else in the rail answers no, so without this view there would be
/// nowhere on the right-hand side to pick the window up.
private final class TitleDragStrip: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// A button that receives its own clicks.
///
/// **The trap CLAUDE.md records, arrived at from a new direction.** The window
/// sets `isMovableByWindowBackground`, and AppKit asks the *hit* view's
/// `mouseDownCanMoveWindow` before it delivers anything — a view that does not
/// answer inherits yes and its mouse handling becomes unreachable code. The
/// rows here answer no because `ClickableView` says so; a plain `NSButton`
/// whose image view is what gets hit does not, so collapse-all and expand-all
/// silently dragged the window instead of firing. Verified by clicking them.
///
/// Not private: `MainViewController`'s corner toggle sits in the title band —
/// the one strip of this window that exists to drag it — so it needs this
/// exact override for the same reason.
final class RailButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
}

extension ConversationMarkdown.Style {
    @MainActor static var current: ConversationMarkdown.Style {
        let theme = ChromeTheme.current
        let size = AppSettings.conversationFontSize
        return ConversationMarkdown.Style(
            body: .systemFont(ofSize: size),
            mono: .monospacedSystemFont(ofSize: size - 1.5, weight: .regular),
            bold: .systemFont(ofSize: size, weight: .semibold),
            text: theme.text,
            strong: theme.text,
            faint: theme.faintText,
            codeBackground: theme.hover
        )
    }
}

