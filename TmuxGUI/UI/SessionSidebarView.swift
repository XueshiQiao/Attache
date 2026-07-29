//
//  SessionSidebarView.swift
//  TmuxGUI
//

import Cocoa

/// The rail, and now the only navigation the app has: sessions as group
/// headings, and under any of them that is open, its tmux windows.
///
/// Both levels used to be separate controls — a rail of sessions on the left
/// and a strip of window tabs across the top. The strip is gone and everything
/// it could do lives here: click a window to select it, double-click to rename,
/// right-click to hide or kill, drag to reorder, **+** on a heading to make a
/// new window, and a `N hidden` row to bring hidden ones back.
///
/// Any session can be opened, not just the one being shown. Every connection is
/// live whether or not its session is on screen — that is what keeps the
/// activity dots meaningful — so their window lists cost nothing to draw. A
/// window can also be dragged out of one open list and into another, which is
/// the same `move-window` a reorder sends with a different target session.
///
/// Same contract as before, which is the contract the whole app is built on:
/// nothing here is authored locally. Every click turns into a tmux command and
/// only takes visible effect when tmux reports back. There are exactly two
/// exceptions and both are commented where they live: the hidden window ids in
/// `SessionViewController`, and `expandedSessions` below.
@MainActor
final class SessionSidebarView: NSView {
    // Session level. Every one of these leads with a tmux **session id**, not
    // a name: a name is user text that any terminal can change between the rail
    // drawing a row and the user clicking it, and an action that misses is
    // silent. Names appear here only as something to draw.
    var onSelect: ((String) -> Void)?
    /// The session to rename, and what to call it.
    var onRename: ((String, String) -> Void)?
    var onNew: (() -> Void)?

    // Window level. Every one of these was a callback on the old tab strip.
    //
    // All of them lead with the session the rows belonged to, rather than
    // leaving the receiver to ask which session is current when the callback
    // finally fires. Those are not the same session: the rail deliberately
    // stops rebuilding while a rename field is open or a drag is in flight, so
    // both gestures can outlive a session switch — a mouse drag blocks other
    // clicks but not ⌃⌘2, and an open editor blocks nothing at all.
    //
    // It matters most for reordering. `rename-window -t @25` and
    // `kill-window -t @25` name a window by an id that is unique across the
    // whole server, so they would land correctly whichever connection carried
    // them; `move-window -t <session>:<index>` is session-*relative*, and sent
    // on the wrong connection it moves the window **into** that session
    // instead of reordering it where it was.
    var onNewWindow: ((String) -> Void)?
    var onSelectWindow: ((String, String) -> Void)?
    var onRenameWindow: ((String, String, String) -> Void)?
    /// A window dragged to a new position: the session it came from, its id,
    /// the session it was dropped in, and the id of the window it should land
    /// in front of — nil meaning "after everything already there".
    ///
    /// The anchor is a window **id**, not the index that window happens to have
    /// right now. tmux only takes an index, so one is worked out at the moment
    /// the command is sent; carrying the index instead would freeze a number
    /// that another client can make mean a different window between the drop
    /// and the send — and `move-window -b` onto a wrong-but-occupied index
    /// succeeds, quietly, in the wrong place. Same reason every other command
    /// here targets `@25` rather than a position.
    ///
    /// The two sessions are the same for an ordinary reorder. They differ when
    /// a window is dragged out of one session's list and into another's, which
    /// is the same `move-window` with a different `-t`.
    var onMoveWindow: ((String, String, String, String?) -> Void)?
    var onHideWindow: ((String, String) -> Void)?
    var onKillWindow: ((String, String) -> Void)?
    var onRestoreHidden: ((String) -> Void)?

    /// One session, and everything the rail needs to draw it expanded.
    ///
    /// Every session carries its own window list, not just the one on screen.
    /// That is what lets a session other than the current one be opened: the
    /// connections are all live whether or not their session is being shown —
    /// that is what keeps the activity dots honest — so their window lists are
    /// already there to hand over.
    struct Entry {
        /// tmux's `$N`. What this session *is*; `name` is what it is called.
        let id: String
        let name: String
        let hasActivity: Bool
        /// In tmux's order. Empty only for a session with no live connection.
        let windows: [TmuxWindow]
        let activeWindowID: String?
        /// Windows hidden from this session's list. Always empty for a session
        /// that has never been shown, because hiding lives in the session's
        /// view controller and one is only made when a session is displayed.
        let hiddenIDs: Set<String>
        /// What each window's row draws that tmux is not the source of, keyed
        /// by window id. Assembled by `MainViewController`, which is the one
        /// place that can see both the connection and the Git service.
        var decorations = [String: WindowDecoration]()

        var windowCount: Int { windows.count }
        var visibleWindows: [TmuxWindow] { windows.filter { !hiddenIDs.contains($0.id) } }
    }

    private let newButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    /// The account's rate-limit windows. They sit at the foot of the rail
    /// rather than on a row because they are not about any one window — every
    /// Claude Code session on the machine shares them.
    private let fiveHourGauge = UsageGaugeView(title: "5h")
    private let sevenDayGauge = UsageGaugeView(title: "Week")
    private let scrollView = NSScrollView()
    private let rowsView = RowsView()
    private let dropIndicator = NSView()

    /// Where the rail's own content starts.
    ///
    /// The window has no title bar and the traffic lights float over this rail,
    /// so something has to clear them. `safeAreaInsets.top` is the system's own
    /// answer and it is the sidebar split view item that supplies it — which is
    /// the point of using a real one. Measuring the close button is the
    /// fallback for a plain item, which contributes no safe area at all.
    private var contentTopInset: CGFloat {
        if safeAreaInsets.top > 0 { return safeAreaInsets.top + 6 }
        guard let button = window?.standardWindowButton(.closeButton),
              let frame = button.superview?.convert(button.frame, to: nil),
              let height = window?.frame.height
        else { return 38 }
        // Button frame is in window coordinates measured from the bottom.
        return height - frame.minY + 6
    }

    private var entries = [Entry]()
    private var selectedID: String?

    /// Sessions whose windows are listed. The app's one other piece of purely
    /// local state, alongside the hidden-window set — tmux has no notion of a
    /// list being open, so there is nothing to ask it.
    ///
    /// Keyed by session id, like everything else that identifies a session
    /// here, and pruned against the entries on every rebuild so a session that
    /// goes away does not leave an entry behind. Renaming a session used to
    /// close its list, because the old name was pruned and the new one had
    /// never been added.
    private var expandedSessions = Set<String>()

    private var rows = [Row]()
    private var editor: NSTextField?
    private var editTarget: EditTarget?
    private weak var editingRow: NSView?
    private var pendingRebuild = false
    private var pendingUpdate: Update?
    /// The row the last mouse-down landed on, as an identity that survives a
    /// rebuild. What it guards is in `isDoubleClick(on:clickCount:)`.
    private var lastPressedRow: String?
    /// The active window the rail last scrolled to. Scrolling on every rebuild
    /// would yank the list back while the user is looking somewhere else, and
    /// tmux sends a notification for nearly everything.
    private var revealedWindowID: String?

    private var draggingWindowID: String?
    /// The session the pointer is currently over, and where in it the row would
    /// land. Both are read off the rows rather than remembered from where the
    /// drag started, because the pointer is free to leave the list it came from.
    private var dropSession: String?
    private var dropPlace: DropPlace?

    /// Where a drop lands in the session it lands in.
    private enum DropPlace {
        /// Before the n-th of that session's visible windows, 0...count.
        case slot(Int)
        /// After everything the session already has. What dropping on a closed
        /// heading means: "put it in there" reads as the end — it is where
        /// `new-window` puts one — and a closed list shows no order to aim at.
        case end
    }

    private let gap: CGFloat = 1

    /// One complete description of what the rail should draw.
    private struct Update {
        let entries: [Entry]
        let selected: String?
    }

    private enum EditTarget {
        /// The session's id, and the name the field was seeded with — needed
        /// only to tell an edit that changed nothing from one that did.
        case session(id: String, was: String)
        case window(session: String, id: String)
    }

    /// What a window-level menu item acts on. A window id alone is not enough:
    /// see the callback declarations for why the session has to travel with it.
    private struct WindowTarget {
        /// The session's id.
        let session: String
        let id: String
    }

    /// A row, and the session it belongs to.
    ///
    /// The session travels with the row because more than one session's windows
    /// can be on screen now. A drag has to answer "which list is the pointer
    /// over" from the rows themselves, and answering it from anything else —
    /// the selected session, the session the drag started in — is wrong the
    /// moment the pointer crosses into another session's block.
    private enum Row {
        case session(SidebarSessionRow, id: String)
        case window(SidebarWindowRow, session: String)
        case hidden(SidebarHiddenRow, session: String)

        var view: NSView {
            switch self {
            case .session(let view, _): view
            case .window(let view, _): view
            case .hidden(let view, _): view
            }
        }

        var session: String {
            switch self {
            case .session(_, let id): id
            case .window(_, let session): session
            case .hidden(_, let session): session
            }
        }

        var height: CGFloat {
            switch self {
            case .session: SidebarSessionRow.height
            // The instance's own, not the type's: see `SidebarWindowRow
            // .rowHeight`. The type's answer follows the setting live and the
            // row on screen was built under whatever it said at the time.
            case .window(let view, _): view.rowHeight
            case .hidden: SidebarHiddenRow.height
            }
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setUp()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    private func setUp() {
        // The rows scroll now. They did not need to before: a rail of session
        // names is short, and a session with twenty windows put them in a strip
        // that shrank its tabs instead. Both levels are in this column now, so
        // the list can genuinely run past the bottom.
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = rowsView
        addSubview(scrollView)

        dropIndicator.wantsLayer = true
        dropIndicator.layer?.cornerRadius = 1
        dropIndicator.isHidden = true
        rowsView.addSubview(dropIndicator)

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

        for gauge in [fiveHourGauge, sevenDayGauge] {
            gauge.isHidden = true
            addSubview(gauge)
        }

        applyChromeTheme()
    }

    /// Re-read the chrome colours. The rows resolve theirs at construction, so
    /// they are rebuilt — a theme change is not a tmux notification and they
    /// would otherwise keep the old colours until one arrived.
    func applyChromeTheme() {
        let theme = ChromeTheme.current
        newButton.contentTintColor = theme.faintText
        statusLabel.textColor = theme.mutedText
        detailLabel.textColor = theme.faintText
        fiveHourGauge.applyTheme()
        sevenDayGauge.applyTheme()
        dropIndicator.layer?.backgroundColor = theme.accent.cgColor
        rebuild()
        needsDisplay = true
    }

    /// The account's rate-limit windows, or nil for "nothing has told us".
    ///
    /// Nil hides both gauges and gives the space back to the list. That is not
    /// a placeholder decision but the ordinary state of a machine where the
    /// status line wrapper is not installed, and a rail that reserved room for
    /// numbers it will never have would be worse for those users than one that
    /// simply does not mention them.
    func showUsage(_ usage: AccountUsage?) {
        let wanted = AppSettings.sidebarShowsUsage ? usage : nil
        let changed = fiveHourGauge.usage != wanted?.fiveHour
            || sevenDayGauge.usage != wanted?.sevenDay
        fiveHourGauge.usage = wanted?.fiveHour
        sevenDayGauge.usage = wanted?.sevenDay
        // The gauges hide themselves, but the list above them has to be told
        // to take the space back.
        if changed { needsLayout = true }
    }

    func showStatus(_ status: String, detail: String) {
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
        needsLayout = true
    }

    /// Everything the rail draws, in one call — every session, each carrying
    /// its own window list.
    ///
    /// Held whole while a rename field is open or a drag is in flight, not just
    /// held back from redrawing. The rows on screen were built from a
    /// particular set of window lists and `dragEnded` resolves the dragged row
    /// against them; letting them move underneath leaves the two describing
    /// different states. Switching sessions mid-drag — ⌃⌘2 is enough, a mouse
    /// drag does not block keys — then made the drop look up a window id that
    /// is not in the new list and silently do nothing.
    func update(entries: [Entry], selected: String?) {
        // Pruned here rather than only where an update is applied, because a
        // held-back update is *replaced* by the next one, not queued behind it.
        // A session that disappeared and came back under the same name while
        // the rail was busy would otherwise have both facts collapse into "it
        // is here", and an unrelated new session would open already expanded.
        expandedSessions.formIntersection(Set(entries.map(\.id)))

        let update = Update(entries: entries, selected: selected)
        guard editor == nil, draggingWindowID == nil else {
            pendingUpdate = update
            return
        }
        apply(update)
    }

    private func apply(_ update: Update) {
        entries = update.entries
        // Whatever the app switched to is opened, because the point of
        // switching is to work in it. Closing it again afterwards is allowed —
        // the disclosure triangle does not refuse — and then the pane grid and
        // ⌘0-9 are still the way to move around.
        if let selected = update.selected, selected != selectedID {
            expandedSessions.insert(selected)
        }
        selectedID = update.selected
        rebuild()
    }

    private func entry(_ id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    private func isExpanded(_ id: String) -> Bool {
        expandedSessions.contains(id)
    }

    /// Whatever tmux said while the rail was busy. Only the last one is kept:
    /// each is a complete description, so an older one has nothing to add.
    private func resumeUpdates() {
        if let pendingUpdate {
            self.pendingUpdate = nil
            pendingRebuild = false
            apply(pendingUpdate)
        } else if pendingRebuild {
            pendingRebuild = false
            rebuild()
        }
    }

    /// The rows a session currently shows, in order. The unit every drag and
    /// every reorder index is computed against, so it is read from one place.
    private func visibleWindows(in session: String) -> [TmuxWindow] {
        entry(session)?.visibleWindows ?? []
    }

    // MARK: - Building

    /// What the rail would draw, as one comparable value.
    ///
    /// Cheap insurance against a rebuild that changes nothing. Every rebuild
    /// destroys and recreates every row, which loses the hover on the row under
    /// the pointer and orphans any press in progress on it — so a rebuild that
    /// draws the identical thing is not free, it is a flicker and a dropped
    /// click. tmux chatters, and the Git service has its own reasons to speak.
    private var drawnSignature: String {
        var parts = [selectedID ?? "-"]
        for entry in entries {
            let sessionBadge = entry.visibleWindows
                .compactMap { entry.decorations[$0.id]?.agent }
                .reduce(nil) { AgentBadge.moreUrgent($0, $1) }
            parts.append(
                "\(entry.id)|\(entry.name)|\(entry.hasActivity ? 1 : 0)"
                    + "|\(sessionBadge?.state?.rawValue ?? "-")"
                    + "|\(sessionBadge?.isSettled == true ? "old" : "new")"
            )
            parts.append(isExpanded(entry.id) ? "+" : "-")
            guard isExpanded(entry.id) else { continue }
            for window in entry.visibleWindows {
                let decoration = entry.decorations[window.id]
                parts.append(
                    "\(window.id)|\(window.index)|\(window.name)"
                        + "|\(window.id == entry.activeWindowID ? 1 : 0)"
                        + "|\(window.hasActivity ? 1 : 0)"
                        + "|\(decoration?.git.map { "\($0.displayRef)/\($0.staged)/\($0.modified)/\($0.untracked)/\($0.conflicted)/\($0.ahead)/\($0.behind)/\($0.hasUpstream)" } ?? "-")"
                        // The *bucket*, not the timestamp. See `AgentBadge
                        // .isSettled` — a raw `since` never changes, so the
                        // short-circuit below matched forever and the 30-minute
                        // transition never repainted anything.
                        + "|\(decoration?.agent.map { "\($0.kind ?? "?")/\($0.state?.rawValue ?? "-")/\($0.isSettled ? "old" : "new")" } ?? "-")"
                        + "|\(decoration?.isNotARepository == true ? "!" : "")"
                        + "|\(decoration?.path ?? "")"
                )
            }
            parts.append("hidden:\(entry.hiddenIDs.count)")
        }
        return parts.joined(separator: "\u{01}")
    }

    private var lastDrawnSignature: String?

    private func rebuild() {
        // Never tear down a field the user is typing in, and never pull a row
        // out from under a drag, just because tmux said something. tmux
        // chatters constantly and both gestures take longer than the gap
        // between two notifications.
        guard editor == nil, draggingWindowID == nil else {
            pendingRebuild = true
            return
        }

        // Nor while a mouse button is down anywhere. A plain click is not a
        // drag, so the guard above does not cover it: the press lands on a row,
        // a notification arrives, the row is replaced, and the release goes to
        // a view that no longer exists — the click simply does nothing, which
        // is what "it is hard to click" turned out to be. Asked of `NSEvent`
        // rather than tracked as state, because a row destroyed mid-press never
        // delivers its mouse-up and any flag we kept would latch on forever.
        guard NSEvent.pressedMouseButtons == 0 else {
            pendingRebuild = true
            return
        }

        // Identical to what is already on screen. See `drawnSignature`.
        let signature = drawnSignature
        if signature == lastDrawnSignature, !rows.isEmpty { return }
        lastDrawnSignature = signature
        for row in rows { row.view.removeFromSuperview() }
        rows.removeAll()

        for entry in entries {
            // Captured, not read back later: from here on these rows belong to
            // this session no matter what the app switches to before the user
            // finishes what they started. See the callback declarations.
            let session = entry.id
            let isCurrent = session == selectedID
            let expanded = isExpanded(session)

            // The most urgent agent anywhere in this session, so a collapsed
            // heading still reports one that is waiting for input.
            // Settled-aware, like the window rows: a heading that kept saying
            // "just finished" hours later is the same defect one level up.
            let winner = entry.visibleWindows
                .compactMap { entry.decorations[$0.id]?.agent }
                .reduce(nil) { AgentBadge.moreUrgent($0, $1) }
            let sessionAgent = (winner?.isSettled == true) ? nil : winner?.state

            let header = SidebarSessionRow(
                id: session,
                name: entry.name,
                windowCount: entry.windowCount,
                hasActivity: entry.hasActivity,
                isCurrent: isCurrent,
                isExpanded: expanded,
                agent: sessionAgent
            )
            header.onClick = { [weak self] in
                self?.onSelect?(session)
                self?.resumeUpdates()
            }
            header.onDoubleClick = { [weak self] in self?.beginRenameSession(session) }
            header.onToggle = { [weak self] in self?.toggleExpanded(session) }
            header.onNewWindow = { [weak self] in
                self?.notePressElsewhere()
                self?.onNewWindow?(session)
            }
            header.isDoubleClick = { [weak self] row, count in
                self?.isDoubleClick(on: row, clickCount: count) ?? false
            }
            rowsView.addSubview(header)
            rows.append(.session(header, id: session))

            guard expanded else { continue }

            for window in entry.visibleWindows {
                // One filled row in the whole rail, and it is the window on
                // screen. tmux keeps an active window per session, so drawing
                // that faithfully put a selection in every open list — four
                // sessions open, four rows claiming to be selected, none of
                // them the one being looked at. The pill answers "where am I",
                // and there is only ever one answer.
                let row = SidebarWindowRow(
                    window: window,
                    isActive: isCurrent && window.id == entry.activeWindowID,
                    decoration: entry.decorations[window.id] ?? WindowDecoration()
                )
                row.onClick = { [weak self] in
                    self?.onSelectWindow?(session, window.id)
                    // The press held a rebuild back; the release is what lets
                    // it through. Without this a rail that nothing else
                    // disturbs keeps drawing whatever it had when the button
                    // went down.
                    self?.resumeUpdates()
                }
                row.onDoubleClick = { [weak self] in self?.beginRenameWindow(window, in: session) }
                row.isDoubleClick = { [weak self] identity, count in
                    self?.isDoubleClick(on: identity, clickCount: count) ?? false
                }
                row.onContextMenu = { [weak self, weak row] point in
                    guard let row else { return }
                    self?.showMenu(forWindow: window.id, in: session, at: point, from: row)
                }
                row.onDragged = { [weak self] location in
                    self?.dragMoved(windowID: window.id, from: session, to: location)
                }
                row.onDragEnded = { [weak self] in self?.dragEnded(from: session) }
                rowsView.addSubview(row)
                rows.append(.window(row, session: session))
            }

            if !entry.hiddenIDs.isEmpty {
                let row = SidebarHiddenRow(count: entry.hiddenIDs.count)
                row.onPress = { [weak self] in self?.notePressElsewhere() }
                row.onClick = { [weak self] in
                    self?.onRestoreHidden?(session)
                    self?.resumeUpdates()
                }
                rowsView.addSubview(row)
                rows.append(.hidden(row, session: session))
            }
        }

        // Back on top of the rows that were just added. Subviews stack in the
        // order they are added, and the gap between two rows is a single point
        // — a drop indicator left underneath them is hidden by whichever row it
        // is announcing, which is exactly the row the user is looking at.
        dropIndicator.removeFromSuperview()
        rowsView.addSubview(dropIndicator)

        // Lay out immediately rather than waiting for the next pass. A freshly
        // created row has a zero frame and tmux notifications arrive in bursts,
        // so several rebuilds can happen between two layout passes — leaving
        // the rail populated with invisible zero-sized rows.
        needsLayout = true
        layoutSubtreeIfNeeded()
        revealActiveWindowIfNeeded()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 10
        let width = bounds.width - inset * 2

        detailLabel.frame = CGRect(x: inset, y: bounds.maxY - 26, width: width, height: 14)
        statusLabel.frame = CGRect(x: inset, y: bounds.maxY - 62, width: width, height: 32)
        newButton.frame = CGRect(x: inset, y: bounds.maxY - 96, width: width, height: 26)

        // Above the button, and only when there is something to show. A hidden
        // gauge gives its height back to the window list rather than leaving a
        // gap where a number might one day be.
        var listBottom = newButton.frame.minY
        for gauge in [sevenDayGauge, fiveHourGauge] where !gauge.isHidden {
            listBottom -= UsageGaugeView.height + 6
            gauge.frame = CGRect(x: inset, y: listBottom, width: width, height: UsageGaugeView.height)
        }

        let top = contentTopInset
        scrollView.frame = CGRect(
            x: 0, y: top,
            width: bounds.width,
            height: max(0, listBottom - 6 - top)
        )
        layoutRows()
    }

    private func layoutRows() {
        let width = scrollView.contentSize.width
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            if case .session = row, index > 0 { y += SidebarSessionRow.topGap }
            row.view.frame = CGRect(x: 6, y: y, width: max(0, width - 12), height: row.height)
            y += row.height + gap
        }
        // At least as tall as the clip view, so the empty space below the last
        // row still belongs to a view that lets a drag move the window. The
        // rail is the only place left to grab: there is no title bar and no
        // tab strip any more.
        rowsView.frame = CGRect(
            x: 0, y: 0,
            width: width,
            height: max(y + 8, scrollView.contentSize.height)
        )
    }

    /// Bring the active window's row on screen, but only when the active window
    /// actually changed.
    private func revealActiveWindowIfNeeded() {
        // The session being shown, not any expanded one: opening another
        // session's list is a look, not a move, and it must not yank the rail
        // to a row in it.
        guard let selectedID, let active = entry(selectedID)?.activeWindowID,
              active != revealedWindowID else { return }
        revealedWindowID = active
        guard let row = rows.compactMap({ row -> SidebarWindowRow? in
            guard case .window(let view, _) = row, view.windowID == active else { return nil }
            return view
        }).first else { return }
        rowsView.scrollToVisible(row.frame.insetBy(dx: 0, dy: -SidebarSessionRow.topGap))
    }

    /// Empty space in the rail drags the window, since there is no title bar
    /// to grab. Rows and buttons handle their own clicks and opt out.
    override var mouseDownCanMoveWindow: Bool { true }

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
    ///
    /// The alpha was a constant 0.55 and produced nothing, because the window
    /// was opaque and a material with nothing behind it samples the window's
    /// own fill. Measured then: rail (43,46,56), panes (42,46,56) — the same
    /// colour to the eye, both solid. It follows the opacity setting now, plus
    /// `railExtraTint`, which is what keeps the rail reading a little deeper
    /// than the panes. That difference is the only thing marking where the list
    /// ends and the terminal begins once neither has a fill of its own.
    override func draw(_ dirtyRect: NSRect) {
        WindowGlass.resolved().railFill.setFill()
        dirtyRect.fill()
    }

    @objc private func newClicked() { onNew?() }

    /// Open or close a session's window list.
    ///
    /// Separate from selecting it, and that separation is the whole point: the
    /// triangle is a look at another session, clicking the heading is a move to
    /// it. Nothing here reaches tmux — "this list is open" is not a thing tmux
    /// has an opinion about.
    private func toggleExpanded(_ session: String) {
        notePressElsewhere()
        if expandedSessions.contains(session) {
            expandedSessions.remove(session)
        } else {
            expandedSessions.insert(session)
        }
        rebuild()
    }

    // MARK: - Clicks

    /// Whether a mouse-down should count as the second half of a double-click
    /// **on the same row**, and not merely the second click in a row.
    ///
    /// Selecting a session rebuilds the rail and the list changes height: the
    /// session that was showing collapses its windows away and the one just
    /// clicked expands its own. So the first click of a double-click on a
    /// heading can move that heading out from under the pointer before the
    /// second click lands — and the second click then arrives on whatever slid
    /// into that spot, usually a window row, which opened a *window* rename
    /// pre-filled with a window's name for a user who was renaming a session.
    ///
    /// The guard is on identity rather than on the view object, because the
    /// legitimate case rebuilds too: double-clicking a window row also sends
    /// `select-window`, and if tmux replies quickly enough the second click
    /// lands on a freshly built row for the same window. Same identity, so it
    /// still counts.
    ///
    /// The cost is that a double-click on a session that is *not* the one
    /// showing no longer opens its rename — it selects it, and the double-click
    /// after that one does. There is no way to have both: the row genuinely was
    /// not under the pointer when the second click happened.
    fileprivate func isDoubleClick(on row: String, clickCount: Int) -> Bool {
        defer { lastPressedRow = row }
        guard clickCount >= 2 else { return false }
        return lastPressedRow == row
    }

    /// A press on something in the rail that has no double-click of its own.
    ///
    /// Recorded anyway, so "the previous mouse-down was on this row" stays a
    /// statement about every press rather than about the two kinds of row that
    /// happen to report theirs. Without it the invariant holds only because the
    /// untracked targets sit far enough from any row that the window server
    /// resets the click count first — true today, and not a thing to leave a
    /// correctness argument resting on.
    private func notePressElsewhere() { lastPressedRow = nil }

    /// The rows' container. Flipped so the rail builds top-down like every
    /// other list here, and transparent to window drags in its empty space.
    private final class RowsView: NSView {
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { true }
    }

    // MARK: - Window context menu

    /// Hide and kill are *both* always present, whatever the setting says.
    ///
    /// The setting used to decide what the ✕ on a tab did, and the ✕ is gone —
    /// a row with a close button in it is exactly the clutter this layout was
    /// meant to remove. So it decides the order here instead: the action the
    /// user chose is the first one under the pointer, and the other one is
    /// still a menu item away. Neither title is ambiguous, and no setting can
    /// take a capability away — which is what a single "Close Window" item
    /// driven by a preference would have done.
    private func showMenu(forWindow id: String, in session: String, at point: NSPoint, from row: NSView) {
        let menu = NSMenu()
        let target = WindowTarget(session: session, id: id)

        let rename = NSMenuItem(title: "Rename…", action: #selector(renameFromMenu(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = target
        menu.addItem(rename)
        menu.addItem(.separator())

        let hide = NSMenuItem(
            title: "Hide From The Sidebar", action: #selector(hideFromMenu(_:)), keyEquivalent: ""
        )
        hide.target = self
        hide.representedObject = target

        // Killing is the only destructive action here, so it never sits
        // adjacent to the harmless one: a separator between them regardless of
        // which way round they go.
        let kill = NSMenuItem(
            title: "Kill This tmux Window…", action: #selector(killFromMenu(_:)), keyEquivalent: ""
        )
        kill.target = self
        kill.representedObject = target

        let ordered = AppSettings.closingTabKillsWindow ? [kill, hide] : [hide, kill]
        menu.addItem(ordered[0])
        menu.addItem(.separator())
        menu.addItem(ordered[1])

        menu.popUp(positioning: nil, at: point, in: row)
    }

    @objc private func renameFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? WindowTarget,
              let window = entry(target.session)?
                  .windows.first(where: { $0.id == target.id }) else { return }
        beginRenameWindow(window, in: target.session)
    }

    @objc private func hideFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? WindowTarget else { return }
        onHideWindow?(target.session, target.id)
    }

    @objc private func killFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? WindowTarget else { return }
        onKillWindow?(target.session, target.id)
    }

    // MARK: - Reorder

    /// Where the row would land, drawn as a line rather than applied.
    ///
    /// The tab strip sent `move-window` on every drag step, which meant tmux
    /// replied, the strip rebuilt, and the view being dragged stopped existing
    /// mid-gesture. Here the drag only moves a line; the command goes out once,
    /// on mouse up.
    private func dragMoved(windowID: String, from source: String, to location: NSPoint) {
        draggingWindowID = windowID
        let point = rowsView.convert(location, from: nil)

        // Which list the pointer is over: the session of the last row that
        // starts at or above it. Every row carries its session, so a collapsed
        // heading answers this as readily as a window row does — which is what
        // makes a closed session a place a window can be dropped into.
        let target = rows.last { point.y >= $0.view.frame.minY }?.session
            ?? rows.first?.session
            ?? source
        dropSession = target

        let windowRows = rows.compactMap { row -> SidebarWindowRow? in
            guard case .window(let view, let session) = row, session == target else { return nil }
            return view
        }

        // A closed session is one target, not a list of positions: the whole
        // heading lights up and the window goes to the end. Drawing a line
        // under a closed heading would be claiming a slot between two
        // *sessions*, which reads as reordering the sessions themselves.
        guard !windowRows.isEmpty else {
            dropPlace = .end
            guard let heading = rows.first(where: { $0.session == target })?.view else { return }
            showDropOutline(around: heading.frame)
            return
        }

        // The insertion point is however many rows have their midpoint above
        // the pointer, which is the only reading that stays right when the
        // pointer is past either end of the list.
        let slot = windowRows.filter { point.y > $0.frame.midY }.count
        dropPlace = .slot(slot)

        // Centred on the boundary the row would be inserted at, including the
        // one below the last row — dropping there is how the list says "put it
        // at the end", and it is a position the old tab strip had no way to
        // express at all.
        let boundary = slot < windowRows.count
            ? windowRows[slot].frame.minY
            : windowRows[windowRows.count - 1].frame.maxY
        showDropLine(at: boundary)
    }

    private func showDropLine(at boundary: CGFloat) {
        dropIndicator.layer?.borderWidth = 0
        dropIndicator.layer?.backgroundColor = ChromeTheme.current.accent.cgColor
        dropIndicator.layer?.cornerRadius = 1
        dropIndicator.frame = CGRect(
            x: 10, y: boundary - 1,
            width: max(0, rowsView.bounds.width - 20), height: 2
        )
        dropIndicator.isHidden = false
    }

    private func showDropOutline(around frame: CGRect) {
        dropIndicator.layer?.backgroundColor = NSColor.clear.cgColor
        dropIndicator.layer?.borderColor = ChromeTheme.current.accent.cgColor
        dropIndicator.layer?.borderWidth = 2
        dropIndicator.layer?.cornerRadius = 6
        dropIndicator.frame = frame
        dropIndicator.isHidden = false
    }

    private func dragEnded(from source: String) {
        defer {
            draggingWindowID = nil
            dropSession = nil
            dropPlace = nil
            dropIndicator.isHidden = true
            resumeUpdates()
        }

        guard let id = draggingWindowID, let place = dropPlace,
              let target = dropSession else { return }

        // Into another session: nothing is being reordered, so the insertion
        // point is already an index into that session's list as it stands. The
        // lift-out correction below is only meaningful when the dragged row is
        // a member of the list being dropped into — applied here it would land
        // the window one position above the line for every slot past where the
        // row would have been.
        guard target == source else {
            let destination = visibleWindows(in: target)
            let anchor: String? = switch place {
            case .end: nil
            case .slot(let slot): slot < destination.count ? destination[slot].id : nil
            }
            onMoveWindow?(source, id, target, anchor)
            return
        }

        guard case .slot(let slot) = place else { return }
        let visible = visibleWindows(in: source)
        guard let from = visible.firstIndex(where: { $0.id == id }) else { return }

        // The insertion point counts the dragged row itself, so everything
        // below it is off by one once that row is lifted out. `others` is the
        // list the row is being dropped *into*.
        var others = visible
        others.remove(at: from)
        let destination = slot > from ? slot - 1 : slot
        guard destination != from else { return }

        // Past the end of `others` is the one position `move-window -b` cannot
        // express, and it is reachable — dragging below the last row is the
        // obvious way to say "put it last".
        onMoveWindow?(
            source, id, source,
            destination < others.count ? others[destination].id : nil
        )
    }

    // MARK: - Rename

    private func beginRenameSession(_ id: String) {
        guard let row = rows.compactMap({ row -> SidebarSessionRow? in
            guard case .session(let view, _) = row, view.sessionID == id else { return nil }
            return view
        }).first else { return }
        beginEditing(over: row, text: row.sessionName, target: .session(id: id, was: row.sessionName))
    }

    private func beginRenameWindow(_ window: TmuxWindow, in session: String) {
        guard let row = rows.compactMap({ row -> SidebarWindowRow? in
            guard case .window(let view, _) = row, view.windowID == window.id else { return nil }
            return view
        }).first else { return }
        beginEditing(over: row, text: window.name, target: .window(session: session, id: window.id))
    }

    private func beginEditing(over row: NSView, text: String, target: EditTarget) {
        finishEditing(commit: true)

        // Into the scrolling container, because that is the coordinate space
        // the row's frame is in.
        let field = NSTextField(frame: row.frame.insetBy(dx: 2, dy: max(0, (row.frame.height - 20) / 2)))
        field.stringValue = text
        field.font = .systemFont(ofSize: 12)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        // Return is handled through the delegate rather than target/action: the
        // action only fires for some end-editing paths, and losing an edit
        // because the commit hook did not run is the worst outcome here.
        field.delegate = self
        // A name is an identifier, not prose. Left on, macOS puts an inline
        // completion popup over the field and swallows the Return that is
        // supposed to commit the edit.
        field.isAutomaticTextCompletionEnabled = false
        rowsView.addSubview(field)
        row.isHidden = true
        editingRow = row
        editTarget = target
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
        // Everything this method tests is cleared *before* the field is taken
        // out of the view tree, because removing it ends editing and AppKit
        // calls `controlTextDidEndEditing` back synchronously from inside
        // `removeFromSuperview`. With the guard still seeing an editor, the
        // whole body ran a second time and one Return sent two identical
        // `rename-window` commands — observed in the log, 2ms apart. Renaming
        // is idempotent so nothing was ever visibly wrong, which is why it
        // survived in the tab strip this was lifted from.
        self.editor = nil
        let target = editTarget
        editTarget = nil
        let row = editingRow
        editingRow = nil

        let new = editor.stringValue.trimmingCharacters(in: .whitespaces)
        editor.removeFromSuperview()
        row?.isHidden = false

        if commit, !new.isEmpty {
            switch target {
            case .session(let id, let was) where new != was: onRename?(id, new)
            case .window(let session, let id): onRenameWindow?(session, id, new)
            default: break
            }
        }
        resumeUpdates()
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

    /// Clicking away commits rather than discards — the user typed it on
    /// purpose, and there is no undo for text that was silently thrown out.
    func controlTextDidEndEditing(_: Notification) {
        finishEditing(commit: true)
    }
}
