//
//  ChatPaneView.swift
//  Attache
//

import Cocoa

/// One agent's conversation, drawn as a chat: the content half's default
/// face for a window that has an agent in it.
///
/// It renders `AgentChatModel` and nothing else. Every row is the agent's own
/// transcript as attache-cli reads it; every button turns into an
/// `attache-cli input`, which presses the key only after reading the screen
/// again itself. The terminal under it keeps running, so switching back is
/// instant and shows exactly what this page did.
///
/// The phone's `AgentChatScreen` is the reference for what each part does;
/// the layout is this app's own.
@MainActor
final class ChatPaneView: NSView {
    /// Asked when the person wants the terminal instead.
    var onShowTerminal: (() -> Void)?

    private(set) var model: AgentChatModel?
    private let header = ChatHeaderView()
    private let scroll = NSScrollView()
    private let list = NSStackView()
    private let dock = WheelStackView()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let working = ChatWorkingBar()
    private let approval = ChatApprovalDock()
    private let questionDock = ChatQuestionDock()
    private let unreadable = ChatUnreadableDock()
    private let panel = ChatPanelDock()
    private let composer = ChatComposer()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let minimap = ChatMinimapView()
    private let tip = MinimapTip()
    private var tipY: NSLayoutConstraint?

    /// What is drawn, by key, so a change re-makes only the rows it touched.
    private var drawn: [(id: String, view: NSView, mark: ChatMinimapView.Kind)] = []
    /// The folds the person opened, by `ChatFold.key`. The page's own, like
    /// which way the chat is switched: no one else has an opinion about it.
    private var openFolds = Set<String>()
    /// Room let out below the last row so a fold shut near the bottom can
    /// stay where it was clicked (`toggle(fold:)`); taken in again once the
    /// person scrolls it out of view or the page changes.
    private var slack: CGFloat = 0 {
        didSet { if slack != oldValue { list.edgeInsets.bottom = 12 + slack } }
    }
    private var togglingFold = false
    /// The first element drawn. Fixed once chosen, so new rows at the bottom
    /// do not slide the window and rebuild everything; moved up a page at a
    /// time as the person scrolls to the top. Every row drawn is a live text
    /// field that rewraps on a width change, and a long conversation drawn
    /// whole made resizing the window crawl.
    private var firstShown: Int?
    /// The key of the first drawn element: what `firstShown` is found again
    /// by. An index went wrong twice (found by review, 2026-11-06): rows read
    /// from further back shifted every index, so the limit stopped applying
    /// and everything was drawn; and a new transcript shorter than the index
    /// drew nothing at all.
    private var firstShownKey: String?
    /// Earlier rows were asked for: once they arrive in front of the first
    /// drawn row, a page of them is drawn. Found again by key alone, the
    /// page kept starting at the old first row and what was read stayed out
    /// of sight (found by review, 2026-11-06).
    private var revealEarlier = false
    private static let page = 150
    private var followsBottom = true
    /// Set while this view moves the scroll position itself, so that move
    /// is not taken for the person scrolling away from the bottom.
    private var movingScroll = false
    private var noticeTimer: Timer?
    /// What the drawn rows were built with (`rowLook`), and whether a
    /// change to it is waiting for this page to be seen.
    private var rowsBuiltFor = ChatPaneView.rowLook()
    private var rowsStale = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    /// The page itself: a solid rounded sheet set into the window's glass,
    /// or nothing at all, by `ChatStyle`. Text set in a column straight over
    /// a wallpaper that shows through read as odd (the owner's call,
    /// 2026-11-06), so the glass look puts every reply on a card instead.
    private let sheet = ChatSheetView()
    private var sheetEdges: [NSLayoutConstraint] = []

    /// The widest the conversation column gets: wide enough never to bind.
    /// 860 left a wide window's column floating in empty space; the owner
    /// wants the width used, with ordinary margins, and the window itself
    /// opening narrower instead (2026-11-06, see `AppDelegate`).
    static let column: CGFloat = 10_000

    /// How hard the column tries to fill the width below that: under the
    /// priority a window resize drags at (510). At 750 the wish to fill an
    /// 860pt column pinned the window's width — it could be made taller and
    /// never wider or narrower (measured 2026-11-06: a resize to 1400 came
    /// back 1260).
    static let fillColumn = NSLayoutConstraint.Priority(490)

    /// Shows this agent's conversation, or the placeholder when there is none.
    func show(_ model: AgentChatModel?, placeholder: String) {
        if model !== self.model {
            self.model?.onChange = nil
            self.model?.isOnScreen = false
            self.model = model
            drawn.forEach { $0.view.removeFromSuperview() }
            drawn = []
            firstShown = nil
            firstShownKey = nil
            followsBottom = true
            openFolds = []
            model?.onChange = { [weak self] in self?.refresh() }
            model?.isOnScreen = window != nil && !isHidden
        }
        empty.stringValue = placeholder
        refresh()
    }

    func setOnScreen(_ on: Bool) {
        model?.isOnScreen = on
    }

    /// The composer, for whoever is placing the keyboard.
    var keyView: NSView { composer.textView }

    /// Puts the sheet where the style wants it.
    private func applyStyle() {
        let style = ChatStyle.current
        let inset = style.sheetInset ?? NSEdgeInsets()
        sheetEdges[0].constant = inset.top
        sheetEdges[1].constant = inset.left
        sheetEdges[2].constant = inset.right
        sheetEdges[3].constant = inset.bottom
        sheet.style = style
    }

    /// Every settings change comes through here, for every session's page,
    /// and rebuilding the rows is the expensive part — every reply laid out
    /// again, every table cell, then the page twice over (measured 2026-11-07:
    /// about 1.8 s of main thread per step of the text-size stepper, the
    /// window beachballing). So the rows are rebuilt only when what they are
    /// drawn with moved (an opacity drag or the terminal's font does not touch
    /// them), and on a page nobody can see only once it is shown.
    func applyChromeTheme() {
        applyStyle()
        sheet.needsDisplay = true
        header.applyChromeTheme()
        composer.applyChromeTheme()
        guard Self.rowLook() != rowsBuiltFor else { return }
        guard window != nil, !isHiddenOrHasHiddenAncestor else {
            rowsStale = true
            return
        }
        rebuildRows()
    }

    private func rebuildRows() {
        rowsStale = false
        rowsBuiltFor = Self.rowLook()
        drawn.forEach { $0.view.removeFromSuperview() }
        drawn = []
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if rowsStale, window != nil, !isHiddenOrHasHiddenAncestor { rebuildRows() }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if rowsStale, window != nil { rebuildRows() }
    }

    /// Everything a row's look is made from: the text size, the chat style
    /// and the theme's colours (which move with the opacity settings too,
    /// since the text roles are solved against the composited window).
    private static func rowLook() -> String {
        let t = ChromeTheme.current
        let colours = [t.background, t.text, t.mutedText, t.faintText, t.accent, t.separator, t.hover]
        return colours.map { "\($0)" }.joined(separator: "|") + "|\(ChatRowViews.size)|\(ChatStyle.current.rawValue)"
    }

    // MARK: - Layout

    private func build() {
        let theme = ChromeTheme.current
        // The header last: on macOS 26 a drawing view's layer overhangs it by
        // 66pt and the sibling added last wins (CLAUDE.md), so the scroll
        // view must not be the one added after it.
        sheet.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sheet)
        sheetEdges = [
            sheet.topAnchor.constraint(equalTo: topAnchor),
            sheet.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailingAnchor.constraint(equalTo: sheet.trailingAnchor),
            bottomAnchor.constraint(equalTo: sheet.bottomAnchor),
        ]
        NSLayoutConstraint.activate(sheetEdges)
        // Added bottom of the page first: on macOS 26 a drawing view's layer
        // overhangs upward by 66pt and the sibling added last wins, so the
        // dock goes in before the conversation above it, and the header,
        // above both, last of the three.
        for v in [dock, scroll, minimap, empty, header, tip] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sheet.addSubview(v)
        }
        minimap.onScroll = { [weak self] top in self?.scroll(toDocumentTop: top) }
        minimap.onHover = { [weak self] hover in self?.showTip(hover) }
        minimap.onDragEnded = { [weak self] in self?.scrolled() }
        // The wheel anywhere on the page scrolls the conversation: over the
        // minimap, the docks and a composer with nothing of its own to
        // scroll, as much as over the rows (asked for 2026-11-06).
        minimap.onWheel = { [weak self] event in self?.scroll.scrollWheel(with: event) }
        dock.onWheel = { [weak self] event in self?.scroll.scrollWheel(with: event) }
        composer.onWheel = { [weak self] event in self?.scroll.scrollWheel(with: event) }
        let tipY = tip.centerYAnchor.constraint(equalTo: minimap.topAnchor)
        self.tipY = tipY
        NSLayoutConstraint.activate([
            tipY,
            tip.trailingAnchor.constraint(equalTo: minimap.leadingAnchor, constant: -6),
        ])
        header.onShowTerminal = { [weak self] in self?.onShowTerminal?() }

        list.orientation = .vertical
        list.alignment = .leading
        // Further than a paragraph inside a message (8 more than a line), so
        // each message reads as one.
        list.spacing = 20
        list.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)

        notice.font = .systemFont(ofSize: 12)
        notice.textColor = theme.mutedText
        notice.isHidden = true
        dock.orientation = .vertical
        dock.alignment = .leading
        dock.spacing = 8
        dock.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 12, right: 16)
        for v in [notice, working, approval, questionDock, unreadable, panel, composer] as [NSView] {
            dock.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: dock.widthAnchor, constant: -32).isActive = true
        }
        working.onStop = { [weak self] in self?.confirmStop() }
        approval.onAnswer = { [weak self] option in self?.answer(option) }
        questionDock.onChoose = { [weak self] option in self?.model?.choose(option) }
        questionDock.onSubmitChoices = { [weak self] in self?.model?.submitChoices() }
        questionDock.onShowTerminal = { [weak self] in self?.onShowTerminal?() }
        unreadable.onShowTerminal = { [weak self] in self?.onShowTerminal?() }
        panel.onKey = { [weak self] key in self?.model?.panelKey(key) }
        composer.onPasteFiles = { [weak self] urls, insert in
            self?.model?.stage(files: urls, then: insert)
        }
        composer.onPasteImage = { [weak self] png, insert in
            self?.model?.stage(image: png, then: insert)
        }
        composer.onSend = { [weak self] text in
            guard let self, let model else { return false }
            followsBottom = true
            model.send(text)
            return true
        }

        empty.alignment = .center
        empty.textColor = theme.mutedText
        empty.font = .systemFont(ofSize: 13)
        applyStyle()

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: sheet.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: sheet.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: sheet.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: minimap.leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: dock.topAnchor),
            minimap.topAnchor.constraint(equalTo: scroll.topAnchor),
            minimap.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            minimap.trailingAnchor.constraint(equalTo: sheet.trailingAnchor),
            minimap.widthAnchor.constraint(equalToConstant: ChatMinimapView.width),

            // The conversation is a column, not the whole width: lines as
            // long as a wide window are hard to read, and the dock lines up
            // with the column above it.
            dock.centerXAnchor.constraint(equalTo: sheet.centerXAnchor),
            dock.widthAnchor.constraint(lessThanOrEqualToConstant: Self.column + 32),
            dock.leadingAnchor.constraint(greaterThanOrEqualTo: sheet.leadingAnchor),
            dock.widthAnchor.constraint(equalTo: sheet.widthAnchor).with(priority: Self.fillColumn),
            dock.bottomAnchor.constraint(equalTo: sheet.bottomAnchor),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            list.widthAnchor.constraint(lessThanOrEqualToConstant: Self.column),
            list.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor),
            list.widthAnchor.constraint(equalTo: document.widthAnchor).with(priority: Self.fillColumn),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 40),
            empty.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -40),
        ])
    }

    /// The document's height when the scroll position was last judged.
    private var judgedHeight: CGFloat = 0
    private var judgedViewport = NSSize.zero

    /// A row the person opened grows the page under them: what they opened
    /// stays where it is, rather than the page following its bottom past it.
    func holdPosition() {
        followsBottom = false
    }

    @objc private func scrolled() {
        updateMinimapViewport()
        guard !movingScroll, let document = scroll.documentView else { return }
        if minimap.isDragging {
            // The person is scrolling with the thumb: whatever the content
            // does meanwhile, this is not following the bottom, and nothing
            // pages in until the thumb is let go.
            judgedHeight = document.frame.height
            judgedViewport = scroll.contentView.bounds.size
            followsBottom = scroll.contentView.bounds.maxY >= document.frame.height - 40
            return
        }
        // Content that grew under the view — wrapped text settling at its
        // width after the first layout — is not the person scrolling away:
        // taken for that, a freshly opened chat stopped short of its newest
        // messages (screenshot, 2026-11-06).
        // So is the view itself changing size with the window: the visible
        // rect moves with nobody scrolling, and read as a scroll it left a
        // resized window short of the newest rows (screenshot, 2026-11-06).
        if document.frame.height != judgedHeight || scroll.contentView.bounds.size != judgedViewport {
            judgedHeight = document.frame.height
            judgedViewport = scroll.contentView.bounds.size
            if followsBottom, !inLiveResize { scrollToBottom() }
            return
        }
        let visible = scroll.contentView.bounds
        if slack > 0, visible.maxY < document.frame.height - slack {
            slack = 0
            return
        }
        followsBottom = slack == 0 && visible.maxY >= document.frame.height - 40
        // The top of what is drawn came into view: draw the page before it,
        // or, when everything read is drawn, fetch what is before that.
        guard visible.minY < 40 else { return }
        if let first = firstShown, first > 0 {
            firstShown = max(0, first - Self.page)
            firstShownKey = nil
            refresh()
        } else if model?.earlierNotLoaded == true {
            revealEarlier = true
            model?.loadEarlier()
        }
    }

    // MARK: - Minimap

    /// Where every drawn row sits, for the minimap: the person's prompts as
    /// ticks with their text, replies as blocks, tool steps as hairlines.
    private func updateMinimap() {
        guard let document = scroll.documentView else { return }
        minimap.marks = drawn.map { entry in
            let frame = entry.view.convert(entry.view.bounds, to: document)
            return ChatMinimapView.Mark(kind: entry.mark, y: frame.minY, height: frame.height)
        }
        minimap.documentHeight = max(1, document.frame.height)
        updateMinimapViewport()
    }

    private func updateMinimapViewport() {
        minimap.viewport = scroll.contentView.bounds
    }

    /// Puts the top of the page at a document y the minimap's thumb is at.
    private func scroll(toDocumentTop y: CGFloat) {
        guard let document = scroll.documentView else { return }
        let visible = scroll.contentView.bounds.height
        document.scroll(NSPoint(x: 0, y: min(max(0, y), max(0, document.frame.height - visible))))
    }

    private func showTip(_ hover: (String, CGFloat)?) {
        guard let (text, y) = hover else {
            tip.isHidden = true
            return
        }
        tipY?.constant = min(max(y, 14), max(14, minimap.bounds.height - 14))
        tip.show(text)
    }

    /// Two passes, not one: a reply learns its width in the first and only
    /// then knows its height (`MarkdownTextView`), so after one pass a row
    /// just added still counts as nothing and the document's height is short
    /// by every new reply — a jump when history goes in above, or a page
    /// that thinks it is too short to scroll.
    private func settle() {
        layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
    }

    private func scrollToBottom() {
        guard let document = scroll.documentView else { return }
        settle()
        movingScroll = true
        document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
        judgedHeight = document.frame.height
        judgedViewport = scroll.contentView.bounds.size
        movingScroll = false
    }

    override func layout() {
        super.layout()
        updateMinimap()
        // A width change rewraps every row and moves the bottom. Not while
        // the window is being dragged: a layout forced from inside layout,
        // every frame, was half of why resizing crawled. Once, at the end.
        guard !inLiveResize, followsBottom, let document = scroll.documentView,
              document.frame.height != judgedHeight else { return }
        DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if followsBottom { scrollToBottom() }
    }

    // MARK: - Drawing what the model says

    private func refresh() {
        guard let model else {
            header.show(title: "", chips: [])
            redrawRows([])
            empty.isHidden = false
            [working, approval, questionDock, unreadable, panel, composer, notice].forEach { $0.isHidden = true }
            return
        }
        let agent = model.agent
        header.show(title: Self.title(of: agent), chips: Self.chips(agent: agent, status: model.status))

        let following = followsBottom

        let placeholder: String? = switch true {
        case model.paneGone: "This pane has closed."
        case model.rows.isEmpty && model.transcriptState == .missing:
            agent?.isFollowed == false
                ? "\(Self.kindName(agent?.kind)) has no conversation this page can read. The terminal shows it."
                : "There is no conversation to show yet."
        case model.rows.isEmpty && model.transcriptState == .loading: "Reading the conversation…"
        default: nil
        }
        empty.stringValue = placeholder ?? ""
        empty.isHidden = placeholder == nil

        let phase = agent?.phase
        working.isHidden = !(phase == .working && !model.agentExited)
        working.show(model.activity, since: agent?.since)
        approval.show(model.approval)
        approval.isHidden = model.approval == nil
        questionDock.show(model.question)
        questionDock.isHidden = model.question == nil
        unreadable.isHidden = !(phase == .needsYou && model.approval == nil && model.question == nil)
        panel.show(model.panel)
        panel.isHidden = model.panel == nil
        composer.isHidden = false
        composer.isEnabled = model.canType
        composer.placeholder = model.paneGone
            ? "This pane has closed."
            : model.agentExited
            ? "The agent is no longer running in this pane."
            : model.approval != nil || model.question != nil
            ? "Answer the question above"
            : "Message \(Self.kindName(agent?.kind))"

        // The docks above are settled before the rows go in, so the height
        // the conversation gets is the one it will keep: done the other way
        // round, a dock appearing after the scroll to the bottom covered the
        // newest message and read as the person scrolling away (found by
        // review, 2026-11-06).
        defer { updateMinimap() }
        let all = Self.elements(rows: model.rows, pending: model.pending,
                                working: model.agent?.phase == .working && !model.agentExited,
                                open: openFolds)
        // A row inside a fold that was shut since is found by its fold.
        func index(of key: String) -> Int? {
            all.firstIndex { $0.key == key } ?? all.firstIndex {
                guard let f = $0.folded else { return false }
                return "f:" + f.key == key || f.members.contains { "r:" + $0 == key }
            }
        }
        if let key = firstShownKey, let found = index(of: key) {
            if revealEarlier, found > 0 {
                revealEarlier = false
                firstShown = max(0, found - Self.page)
            } else {
                firstShown = found
            }
        } else if firstShownKey != nil || firstShown == nil || (firstShown ?? 0) > all.count {
            // Never chosen, or the row it was is gone (another transcript).
            firstShown = all.isEmpty ? nil : max(0, all.count - Self.page)
        }
        var first = min(firstShown ?? 0, all.count)
        // Never start a page inside an open fold: its rows would be drawn
        // with nothing above them to shut it by.
        if first < all.count, case .row(let row) = all[first],
           let header = all[..<first].lastIndex(where: {
               guard let f = $0.folded else { return false }
               return f.open && f.members.contains(row.key)
           }) {
            first = header
        }
        firstShownKey = first < all.count ? all[first].key : nil
        redrawRows(Array(all[first...]))
        // What follows reads the document's height: settle it first —
        // `scrollToBottom` settles for itself.
        if following { scrollToBottom() } else { settle() }
        // Too little to scroll is too little to reach the top by scrolling:
        // fetch what came before until there is something to scroll.
        if let document = scroll.documentView, first == 0, model.earlierNotLoaded, !model.loadingEarlier,
           document.frame.height <= scroll.contentView.bounds.height {
            revealEarlier = true
            model.loadEarlier()
        }

        if let text = model.notice {
            model.notice = nil
            notice.stringValue = text
            notice.isHidden = false
            noticeTimer?.invalidate()
            noticeTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.notice.isHidden = true }
            }
        }
    }

    private func redrawRows(_ elements: [ChatElement]) {
        // Rows are replaced from the first one that changed, which is almost
        // always the tail: a new reply, a result landing on its call.
        var keep = 0
        while keep < drawn.count, keep < elements.count {
            if drawn[keep].id == elements[keep].id { keep += 1; continue }
            // A line whose run grew, finished, opened or shut: the same line,
            // so its mark is told rather than the line (and every row after
            // it) rebuilt — a re-render per step, and an opened run's steps
            // shut under the person.
            if case .reply(let row, let fold) = elements[keep], case .agent(_, let said) = row,
               let marked = drawn[keep].view as? MarkedReply, marked.rowKey == row.key, marked.text == said {
                marked.update(fold)
                drawn[keep].id = elements[keep].id
                keep += 1
                continue
            }
            break
        }
        guard keep < drawn.count || keep < elements.count else { return }
        if !togglingFold { slack = 0 }
        // Earlier history goes in above what is being read: keep the rows
        // under the person's eyes where they are, measured from the bottom.
        let document = scroll.documentView
        let fromBottom = document.map { $0.frame.height - scroll.contentView.bounds.minY } ?? 0
        let prepended = keep == 0 && !drawn.isEmpty && !followsBottom
        for gone in drawn[keep...] { gone.view.removeFromSuperview() }
        drawn.removeSubrange(keep...)
        for (i, element) in elements.enumerated().dropFirst(keep) {
            let view: NSView
            if case .fold(let fold) = element {
                let folded = WorkFold(fold)
                folded.onToggle = { [weak self] in self?.toggle(fold: fold.key) }
                view = folded
            } else if case .reply(let row, let fold) = element, case .agent(_, let text) = row {
                let reply = MarkedReply(row: row, markdown: text, fold: fold)
                reply.onToggle = { [weak self] in self?.toggle(fold: fold.key) }
                view = reply
            } else {
                view = ChatRowViews.make(element, width: { [weak self] in self?.bounds.width ?? 600 })
            }
            list.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            // A run of tool steps reads as one block.
            if i > 0, element.isTool, elements[i - 1].isTool, let previous = drawn.last?.view {
                // A timeline's rule runs on unbroken; cards sit close.
                list.setCustomSpacing(ChatStyle.current.toolLayout == .card ? 2 : 0, after: previous)
            }
            drawn.append((element.id, view, element.minimapKind))
        }
        if prepended, let document {
            settle()
            movingScroll = true
            document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - fromBottom)))
            judgedHeight = document.frame.height
            judgedViewport = scroll.contentView.bounds.size
            movingScroll = false
        }
    }

    // MARK: - Actions that need asking first

    private func confirmStop() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Stop \(Self.kindName(model?.agent?.kind))?"
        alert.informativeText = "The same as pressing Esc in the terminal. You can tell it to carry on afterwards."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.model?.interrupt() }
        }
    }

    private func answer(_ option: ApprovalMenu.Option) {
        guard let risk = option.risk else {
            model?.answer(option)
            return
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "“\(option.label)”"
        alert.informativeText = "This answer \(risk)."
        alert.addButton(withTitle: "Answer")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.model?.answer(option) }
        }
    }

    // MARK: - Words

    static func kindName(_ kind: String?) -> String {
        switch kind {
        case "claude": "Claude"
        case "agy": "Antigravity"
        case let k?: k.prefix(1).uppercased() + k.dropFirst()
        case nil: "the agent"
        }
    }

    private static func title(of agent: AgentRow?) -> String {
        guard let agent else { return "" }
        let title = agent.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? agent.windowName : title
    }

    /// The header's chips: what the agent is doing, then what its status
    /// line says — model, effort, context, and whether the prompt cache is
    /// still warm.
    private static func chips(agent: AgentRow?, status: ChatStatus?) -> [ChatHeaderView.Chip] {
        guard let agent else { return [] }
        let state: (String, NSColor) = switch agent.phase {
        case .needsYou: ("needs you", .systemOrange)
        case .working: ("working", ChromeTheme.current.accent)
        case .done: ("done", .systemGreen)
        case .idle: ("idle", ChromeTheme.current.faintText)
        }
        var chips = [ChatHeaderView.Chip(text: "\(kindName(agent.kind)) · \(state.0)", dot: state.1)]
        if let model = status?.model ?? agent.model { chips.append(.init(text: model)) }
        if let effort = status?.effort { chips.append(.init(text: "effort \(effort)")) }
        if let ctx = status?.contextPercent { chips.append(.init(text: "ctx \(ctx)%")) }
        if let warm = status?.cacheWarm {
            if warm, let until = status?.cacheExpiresAt {
                let minutes = max(0, until - Int(Date().timeIntervalSince1970)) / 60
                chips.append(.init(text: "cache \(minutes)m"))
            } else {
                chips.append(.init(text: warm ? "cache warm" : "cache cold"))
            }
        }
        return chips
    }

    /// Opens or shuts a fold without its line moving on screen, by a point:
    /// a click opens it and a second click, the pointer not moved, shuts it
    /// again. Holding the scroll offset is not enough — shut near the bottom,
    /// the page gets shorter than the offset and the clip view pulls it back
    /// down — so the line is measured before, found after, scrolled back to
    /// where it was, and room is let out below when the page is short.
    private func toggle(fold key: String) {
        guard let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let before = foldView(key).map { $0.convert($0.bounds, to: document).minY - clip.bounds.minY }
        followsBottom = false
        if openFolds.remove(key) == nil { openFolds.insert(key) }
        togglingFold = true
        slack = 0
        refresh()
        togglingFold = false
        guard let before, let view = foldView(key) else { return }
        settle()
        let target = view.convert(view.bounds, to: document).minY - before
        let short = target + clip.bounds.height - document.frame.height
        if short > 0 {
            slack = ceil(short)
            settle()
        }
        movingScroll = true
        document.scroll(NSPoint(x: 0, y: max(0, target)))
        judgedHeight = document.frame.height
        judgedViewport = clip.bounds.size
        movingScroll = false
        // The line is back under the pointer only now: its mark has to show
        // its words for the click back, whatever it worked out while the
        // page was still moving.
        (foldView(key) as? MarkedReply)?.refreshHover()
    }

    private func foldView(_ key: String) -> NSView? {
        drawn.first { $0.id.hasPrefix("f:\(key):") }?.view
    }

    /// The rows as drawn: a sent message sits right after the row that was
    /// last when it went out. Each tool step is its own element, so the next
    /// step does not rebuild — and close — the ones the person opened.
    ///
    /// The work is folded (design F in `docs/chat-tool-folding-designs.html`,
    /// with what the agent writes kept): each run of thinking and tool steps
    /// is one line, and everything the agent wrote to the person — its
    /// `text` blocks, the lines along the way and the answer alike — stands
    /// between them as it was written. The two are told apart by the block's
    /// own type in the transcript, not guessed. Thinking is a summary at most
    /// (often empty), so it stays folded until opened. The run still going
    /// in a running turn says what it is doing.
    static func elements(rows: [ChatRow], pending: [PendingMessage], working: Bool,
                         open: Set<String>) -> [ChatElement] {
        let keys = Set(rows.map(\.key))
        let byAnchor = Dictionary(grouping: pending.filter { $0.anchorKey.map(keys.contains) ?? false },
                                  by: { $0.anchorKey ?? "" })
        var out: [ChatElement] = []
        func put(_ row: ChatRow) {
            out.append(.row(row))
            if let sent = byAnchor[row.key] { out += sent.map(ChatElement.pending) }
        }
        func fold(_ stretch: [ChatRow], key: String, live: Bool) -> ChatFold {
            var thoughts = 0, steps = 0, failed = 0
            var progress: String?, running: String?
            for row in stretch {
                switch row {
                case .thinking(_, let text):
                    thoughts += 1
                    progress = ChatFold.firstLine(text) ?? progress
                case .tool(_, let name, let summary, _, let result, let isError, _):
                    steps += 1
                    if isError { failed += 1 }
                    // Tools run side by side: one that came back does not
                    // mean the one before it did.
                    if result == nil { running = "\(name)  \(summary)" }
                default: break
                }
            }
            return ChatFold(key: key, thoughts: thoughts, steps: steps, failed: failed,
                            live: live, open: open.contains(key),
                            progress: live ? progress : nil, running: live ? running : nil,
                            members: stretch.map(\.key))
        }
        /// The folded rows when open, then whatever was sent meanwhile — after
        /// the work, open or shut, so opening does not move it.
        func putWork(_ stretch: [ChatRow], open isOpen: Bool) {
            if isOpen { stretch.forEach { out.append(.row($0)) } }
            for row in stretch { if let sent = byAnchor[row.key] { out += sent.map(ChatElement.pending) } }
        }
        /// A turn as the page draws it: the agent's lines, each carrying the
        /// run of thinking and tools that came with it; anything else as it
        /// is; and a run with no line to carry it on its own.
        enum Item {
            case text(ChatRow, run: [ChatRow], key: String)
            case other(ChatRow)
            case loose([ChatRow], key: String)
        }
        // Turns start at each prompt.
        var turns: [[ChatRow]] = [[]]
        for row in rows {
            if case .user = row { turns.append([row]) } else { turns[turns.count - 1].append(row) }
        }
        for (t, turn) in turns.enumerated() {
            // The last turn is the running one — unless a message is on its
            // way: then the agent is working on that, its prompt has not
            // reached the transcript yet, and the last turn is finished.
            let live = working && t == turns.count - 1 && pending.isEmpty
            let turnKey = turn.first?.key ?? "start"
            var items: [Item] = []
            var stretch: [ChatRow] = []
            // A run with no line before it waits for the next line, keyed by
            // where it fell; keys only ever grow at the end of a turn, so a
            // fold the person opened stays open as the turn goes on.
            var lead: (run: [ChatRow], key: String)?
            func closeRun() {
                guard !stretch.isEmpty else { return }
                // Most often what the agent just said is what it then did.
                if case .text(let row, let run, let key)? = items.last {
                    items[items.count - 1] = .text(row, run: run + stretch, key: key)
                } else if let waiting = lead {
                    lead = (waiting.run + stretch, waiting.key)
                } else {
                    lead = (stretch, "\(turnKey)#\(items.count)")
                }
                stretch = []
            }
            for row in turn {
                switch row {
                case .thinking, .tool:
                    stretch.append(row)
                case .agent:
                    closeRun()
                    items.append(.text(row, run: lead?.run ?? [], key: lead?.key ?? "w:" + row.key))
                    lead = nil
                default:
                    closeRun()
                    if let waiting = lead { items.append(.loose(waiting.run, key: waiting.key)); lead = nil }
                    items.append(.other(row))
                }
            }
            // The run still going is the live one, wherever it hangs.
            let liveRun = live && !stretch.isEmpty
            closeRun()
            if let waiting = lead { items.append(.loose(waiting.run, key: waiting.key)) }
            for (i, item) in items.enumerated() {
                // The run still going, or — when the agent spoke while tools
                // it started were still out — the last run holding one.
                let holdsRunning: Bool = {
                    switch item {
                    case .text(_, let run, _), .loose(let run, _):
                        run.contains { if case .tool(_, _, _, _, nil, _, _) = $0 { true } else { false } }
                    case .other: false
                    }
                }()
                let isLive = live && i == items.count - 1 && (liveRun || holdsRunning)
                switch item {
                case .other(let row):
                    put(row)
                case .text(let row, let run, _) where run.isEmpty:
                    put(row)
                case .text(let row, let run, let key):
                    let f = fold(run, key: key, live: isLive)
                    out.append(.reply(row, f))
                    putWork(run, open: f.open)
                    if let sent = byAnchor[row.key] { out += sent.map(ChatElement.pending) }
                case .loose(let run, let key):
                    let f = fold(run, key: key, live: isLive)
                    out.append(.fold(f))
                    putWork(run, open: f.open)
                }
            }
        }
        out += pending.filter { !($0.anchorKey.map(keys.contains) ?? false) }.map(ChatElement.pending)
        return out
    }
}

/// One thing in the list: a row, a message on its way, or a line of this
/// page's own.
/// A run of thinking and tool steps, folded into one line.
struct ChatFold: Equatable {
    /// The first folded row's key: the same as the work grows, so a fold
    /// the person opened stays open.
    let key: String
    let thoughts: Int
    let steps: Int
    let failed: Int
    /// The turn is still running.
    let live: Bool
    let open: Bool
    /// While live: the first line of the latest thinking.
    let progress: String?
    /// While live: the step still running.
    let running: String?
    /// The keys of the rows folded, to find the fold a row is in.
    let members: [String]

    /// A line of prose for the progress line: fences, rules and table rows
    /// skipped, heading and list marks and emphasis taken off.
    static func firstLine(_ text: String) -> String? {
        var inFence = false
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.hasPrefix("|") || line.allSatisfy({ "-*_=".contains($0) }) { continue }
            while let mark = ["#", ">", "- ", "* ", "+ "].first(where: { line.hasPrefix($0) }) {
                line = String(line.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if !line.isEmpty { return line }
        }
        return nil
    }
}

enum ChatElement {
    case row(ChatRow)
    case pending(PendingMessage)
    case note(id: String, text: String)
    /// A run with no line of the agent's to hang on: its own line.
    case fold(ChatFold)
    /// A line of the agent's with the run that came with it, as a mark at
    /// its right (design E in `docs/chat-fold-attach-designs.html`).
    case reply(ChatRow, ChatFold)

    var isTool: Bool {
        if case .row(.tool) = self { return true }
        return false
    }

    /// The run this element folds, whichever way it is drawn.
    var folded: ChatFold? {
        switch self {
        case .fold(let f), .reply(_, let f): f
        default: nil
        }
    }

    /// Which row this is, whatever it says: stays the same as the row grows.
    var key: String {
        switch self {
        case .row(let row): "r:" + row.key
        case .pending(let p): "p:\(p.id)"
        case .note(let id, _): "n:" + id
        case .fold(let f): "f:" + f.key
        case .reply(let row, _): "r:" + row.key
        }
    }

    var minimapKind: ChatMinimapView.Kind {
        switch self {
        case .row(.user(_, let text, _)): .prompt(text)
        case .pending(let p): .prompt(p.text)
        case .row(.agent), .row(.output): .reply
        case .row(.tool): .tool
        case .reply: .reply
        case .fold(let f) where f.steps > 0: .tool
        case .row(.thinking), .row(.note), .note, .fold: .quiet
        }
    }

    /// Same id, same drawing: an id changes whenever what is drawn would.
    var id: String {
        switch self {
        case .row(let row): "r:\(row.key):\(Self.digest(row))"
        case .pending(let p): "p:\(p.id):\(p.unconfirmed)"
        case .note(let id, _): "n:\(id)"
        // Open, the header says only that it folds: with the counts in its
        // id, every new step of an opened running turn redrew everything
        // after it and shut every step the person had opened.
        case .reply(let row, let f):
            "f:\(f.key):\(Self.digest(row)):\(f.thoughts):\(f.steps):\(f.failed):\(f.live):\(f.open):\(f.running ?? "")"
        case .fold(let f) where f.open: "f:\(f.key):open"
        case .fold(let f):
            "f:\(f.key):\(f.thoughts):\(f.steps):\(f.failed):\(f.live):\(f.progress ?? ""):\(f.running ?? "")"
        }
    }

    private static func digest(_ row: ChatRow) -> Int {
        var h = Hasher()
        switch row {
        case .user(_, let t, let q): h.combine(t); h.combine(q)
        case .agent(_, let t), .thinking(_, let t), .note(_, let t): h.combine(t)
        case .tool(_, let n, let s, let d, let r, let e, let diff):
            h.combine(n); h.combine(s); h.combine(d); h.combine(r); h.combine(e)
            for line in diff { h.combine(String(line.mark)); h.combine(line.text) }
        case .output(_, let t, let e, _): h.combine(t); h.combine(e)
        }
        return h.finalize()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension NSLayoutConstraint {
    func with(priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

/// The chat's page: solid and rounded, with a hairline and a soft shadow,
/// for a style with a sheet; clear for one without.
final class ChatSheetView: NSView {
    var style = ChatStyle.card { didSet { needsDisplay = true } }

    override func layout() {
        super.layout()
        if style.sheetInset != nil {
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: style.sheetRadius,
                                       cornerHeight: style.sheetRadius, transform: nil)
        }
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let theme = ChromeTheme.current
        if style.sheetInset != nil {
            layer.cornerRadius = style.sheetRadius
            layer.backgroundColor = theme.background.withAlphaComponent(1).cgColor
            layer.borderWidth = 0.5
            layer.borderColor = theme.separator.cgColor
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.12
            layer.shadowRadius = 3
            layer.shadowOffset = CGSize(width: 0, height: -1)
            // A shadow with no path is worked out from the layer's contents
            // on every frame, which made resizing the window crawl.
            layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: style.sheetRadius,
                                      cornerHeight: style.sheetRadius, transform: nil)
            layer.masksToBounds = false
        } else {
            layer.cornerRadius = 0
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderWidth = 0
            layer.shadowOpacity = 0
        }
    }
}

/// The whole conversation in a strip down the right: the person's prompts as
/// accent ticks, replies as grey blocks, tool steps as hairlines, and a frame
/// round what is on screen. The frame is a thumb: grabbed, it drags the page
/// with it; a press elsewhere brings it there and keeps dragging. Hovering a
/// prompt shows how it began, at once. Drawn from where the rows really are,
/// so it can never disagree with the page.
final class ChatMinimapView: NSView {
    static let width: CGFloat = 88

    enum Kind: Equatable {
        case prompt(String)
        case reply
        case tool
        case quiet
    }

    struct Mark: Equatable {
        let kind: Kind
        let y: CGFloat
        let height: CGFloat
    }

    var marks: [Mark] = [] { didSet { if marks != oldValue { needsDisplay = true } } }
    var documentHeight: CGFloat = 1 { didSet { if documentHeight != oldValue { needsDisplay = true } } }
    var viewport: NSRect = .zero { didSet { if viewport != oldValue { needsDisplay = true } } }
    /// Scroll the page so its top is at this document y.
    var onScroll: ((CGFloat) -> Void)?
    /// A prompt is under the pointer (its text and the strip y), or none.
    var onHover: ((String, CGFloat)?) -> Void = { _ in }

    private static let pad: CGFloat = 8
    /// Where in the thumb it was grabbed, while dragging.
    private var grab: CGFloat?
    /// The pointer is over the thumb: it lights up as it does while held,
    /// so it reads as something to grab before it is grabbed.
    private var overThumb = false { didSet { if overThumb != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    /// A press here is a press on the minimap, never on the window's
    /// background: as a transparent view it would otherwise move the window
    /// and the thumb never moved (reported 2026-11-06).
    override var mouseDownCanMoveWindow: Bool { false }

    /// Document points per strip point: the whole conversation fits, and a
    /// short one is drawn at a readable size rather than stretched.
    private var scale: CGFloat {
        min(0.12, (bounds.height - 2 * Self.pad) / max(1, documentHeight))
    }

    private func stripY(_ y: CGFloat) -> CGFloat { Self.pad + y * scale }

    /// Whether the thumb is held: the page does not page or follow the
    /// bottom meanwhile, or the drag fights it (found by review, 2026-11-06).
    var isDragging: Bool { grab != nil }

    private var thumb: NSRect {
        let height = max(14, viewport.height * scale)
        // Kept inside the strip when stretched to its minimum height.
        let y = min(stripY(viewport.minY), bounds.height - Self.pad - height)
        return NSRect(x: 3, y: max(Self.pad, y), width: bounds.width - 6, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ChromeTheme.current
        theme.separator.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        // Laid out as the page is: the agent's side flush left in grey, the
        // person's prompts flush right in the accent. Nothing in the middle —
        // replies drawn across the strip read as centred, which the page
        // never is (the owner's call, 2026-11-06).
        let inner = bounds.width - 12
        for mark in marks {
            let y = stripY(mark.y)
            switch mark.kind {
            case .prompt(let text):
                let width = inner * min(0.75, max(0.4, CGFloat(text.count) / 120))
                theme.accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: bounds.width - 5 - width, y: y, width: width,
                                                 height: max(3.5, min(10, mark.height * scale))),
                             xRadius: 1.75, yRadius: 1.75).fill()
            case .reply:
                theme.mutedText.withAlphaComponent(0.4).setFill()
                NSBezierPath(roundedRect: NSRect(x: 6, y: y, width: inner * 0.72,
                                                 height: max(2, mark.height * scale)), xRadius: 1.5, yRadius: 1.5).fill()
            case .tool:
                theme.mutedText.withAlphaComponent(0.25).setFill()
                NSRect(x: 6, y: y, width: inner * 0.42, height: 1).fill()
            case .quiet:
                break
            }
        }
        // Hovered or held, the thumb takes the accent: a deeper grey was too
        // slight to notice (the owner's call, 2026-11-06).
        let lit = grab != nil || overThumb
        let path = NSBezierPath(roundedRect: thumb.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
        (lit ? theme.accent.withAlphaComponent(0.2) : theme.text.withAlphaComponent(0.07)).setFill()
        path.fill()
        (lit ? theme.accent : theme.separator).setStroke()
        path.lineWidth = lit ? 1.5 : 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let frame = thumb
        // On the thumb: held where it was grabbed. Elsewhere: centred under
        // the pointer, then held there.
        grab = frame.contains(p) ? p.y - frame.minY : max(1, viewport.height * scale) / 2
        onHover(nil)
        drag(to: p.y)
    }

    override func mouseDragged(with event: NSEvent) {
        drag(to: convert(event.locationInWindow, from: nil).y)
    }

    var onDragEnded: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        grab = nil
        onDragEnded?()
        overThumb = thumb.contains(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    private func drag(to y: CGFloat) {
        guard let grab else { return }
        onScroll?(max(0, (y - grab - Self.pad) / max(scale, 0.0001)))
        needsDisplay = true
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        overThumb = thumb.contains(point)
        let y = point.y
        // The nearest prompt within a few points: ticks are thin.
        let near = marks.compactMap { mark -> (String, CGFloat)? in
            guard case .prompt(let text) = mark.kind else { return nil }
            return (text, stripY(mark.y))
        }.min { abs($0.1 - y) < abs($1.1 - y) }
        if let near, abs(near.1 - y) <= 6 { onHover(near) } else { onHover(nil) }
    }

    override func mouseExited(with event: NSEvent) {
        overThumb = false
        onHover(nil)
    }

    /// The wheel over the strip scrolls the page, as it does over the page.
    var onWheel: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) { onWheel?(event) }
}

/// The hint beside the minimap: how a prompt began.
final class MinimapTip: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11.5)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true
        label.preferredMaxLayoutWidth = 280
        ChatRowViews.pin(label, in: self, insets: NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9))
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        isHidden = true
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 6
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.25)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let theme = ChromeTheme.current
        layer?.cornerRadius = 7
        layer?.backgroundColor = (theme.background.blended(withFraction: 0.1, of: theme.text) ?? theme.background).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = theme.separator.cgColor
        label.textColor = theme.text
    }

    func show(_ text: String) {
        label.stringValue = text.replacingOccurrences(of: "\n", with: " ")
        isHidden = false
        needsDisplay = true
    }
}

/// A stack that hands the wheel on: the docks under the conversation.
final class WheelStackView: NSStackView {
    var onWheel: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if let onWheel { onWheel(event) } else { super.scrollWheel(with: event) }
    }
}
