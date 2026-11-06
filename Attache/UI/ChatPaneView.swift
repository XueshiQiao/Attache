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

    func applyChromeTheme() {
        applyStyle()
        sheet.needsDisplay = true
        drawn.forEach { $0.view.removeFromSuperview() }
        drawn = []
        header.applyChromeTheme()
        composer.applyChromeTheme()
        refresh()
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
        list.spacing = 10
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
        followsBottom = visible.maxY >= document.frame.height - 40
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

    private func scrollToBottom() {
        guard let document = scroll.documentView else { return }
        layoutSubtreeIfNeeded()
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
            : "Message \(Self.kindName(agent?.kind))"

        // The docks above are settled before the rows go in, so the height
        // the conversation gets is the one it will keep: done the other way
        // round, a dock appearing after the scroll to the bottom covered the
        // newest message and read as the person scrolling away (found by
        // review, 2026-11-06).
        defer { updateMinimap() }
        let all = Self.elements(rows: model.rows, pending: model.pending)
        if let key = firstShownKey, let found = all.firstIndex(where: { $0.key == key }) {
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
        let first = min(firstShown ?? 0, all.count)
        firstShownKey = first < all.count ? all[first].key : nil
        redrawRows(Array(all[first...]))
        // What follows reads the document's height: settle it first.
        scroll.documentView?.layoutSubtreeIfNeeded()
        if following { scrollToBottom() }
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
        while keep < drawn.count, keep < elements.count, drawn[keep].id == elements[keep].id { keep += 1 }
        guard keep < drawn.count || keep < elements.count else { return }
        // Earlier history goes in above what is being read: keep the rows
        // under the person's eyes where they are, measured from the bottom.
        let document = scroll.documentView
        let fromBottom = document.map { $0.frame.height - scroll.contentView.bounds.minY } ?? 0
        let prepended = keep == 0 && !drawn.isEmpty && !followsBottom
        for gone in drawn[keep...] { gone.view.removeFromSuperview() }
        drawn.removeSubrange(keep...)
        for (i, element) in elements.enumerated().dropFirst(keep) {
            let view = ChatRowViews.make(element, width: { [weak self] in self?.bounds.width ?? 600 })
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
            layoutSubtreeIfNeeded()
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

    /// The rows as drawn: a sent message sits right after the row that was
    /// last when it went out. Each tool step is its own element, so the next
    /// step does not rebuild — and close — the ones the person opened.
    static func elements(rows: [ChatRow], pending: [PendingMessage]) -> [ChatElement] {
        let keys = Set(rows.map(\.key))
        let byAnchor = Dictionary(grouping: pending.filter { $0.anchorKey.map(keys.contains) ?? false },
                                  by: { $0.anchorKey ?? "" })
        var out: [ChatElement] = []
        for row in rows {
            out.append(.row(row))
            if let sent = byAnchor[row.key] { out += sent.map(ChatElement.pending) }
        }
        out += pending.filter { !($0.anchorKey.map(keys.contains) ?? false) }.map(ChatElement.pending)
        return out
    }
}

/// One thing in the list: a row, a message on its way, or a line of this
/// page's own.
enum ChatElement {
    case row(ChatRow)
    case pending(PendingMessage)
    case note(id: String, text: String)

    var isTool: Bool {
        if case .row(.tool) = self { return true }
        return false
    }

    /// Which row this is, whatever it says: stays the same as the row grows.
    var key: String {
        switch self {
        case .row(let row): "r:" + row.key
        case .pending(let p): "p:\(p.id)"
        case .note(let id, _): "n:" + id
        }
    }

    var minimapKind: ChatMinimapView.Kind {
        switch self {
        case .row(.user(_, let text, _)): .prompt(text)
        case .pending(let p): .prompt(p.text)
        case .row(.agent), .row(.output): .reply
        case .row(.tool): .tool
        case .row(.thinking), .row(.note), .note: .quiet
        }
    }

    /// Same id, same drawing: an id changes whenever what is drawn would.
    var id: String {
        switch self {
        case .row(let row): "r:\(row.key):\(Self.digest(row))"
        case .pending(let p): "p:\(p.id):\(p.unconfirmed)"
        case .note(let id, _): "n:\(id)"
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
