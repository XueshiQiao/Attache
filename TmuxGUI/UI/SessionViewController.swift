//
//  SessionViewController.swift
//  TmuxGUI
//

import Cocoa
import GhosttyTerminal

/// Shows one tmux session: a tab per window, and the active window's panes
/// laid out as tmux has them.
///
/// Holds the pane surfaces for every window visited so far, not just the
/// visible one. tmux streams output for the whole session down one pipe
/// regardless, so keeping the surfaces alive costs nothing on the wire and
/// makes switching windows instant with content already current — the GPU
/// surface is what gets released when a pane goes off screen.
@MainActor
final class SessionViewController: NSViewController {
    let connection: TmuxSessionConnection

    private let tabBar = WindowTabBarView(frame: .zero)
    private let gridView = PaneGridView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    /// Three layers, and which one a setting belongs in matters: the base
    /// template below is what this app needs to be true of any surface, the
    /// user's font goes in the per-session overrides, and the colours go in
    /// the theme. libghostty renders them in that order, so a later layer wins
    /// — and `applySettings` can replace one without disturbing the others.
    private lazy var controller: TerminalController = {
        let base = TerminalConfiguration(startingFrom: .default) { builder in
            builder.withBackgroundOpacity(0)
            // No padding around the grid. Ghostty reserves 2pt on each edge by
            // default, which at a normal font size costs a whole cell — libghostty
            // then reports one column and one row fewer than tmux gave the pane.
            // Every line after that wraps in a different place than tmux thinks,
            // and the damage accumulates into unreadable overdraw wherever a TUI
            // keeps rewriting a region, which is exactly what a coding agent does
            // to the bottom of its pane.
            builder.withCustom("window-padding-x", "0")
            builder.withCustom("window-padding-y", "0")
            builder.withCustom("window-padding-balance", "false")
            // Scrollback keys have to be bound explicitly: unbound, Shift+PageUp
            // is forwarded to the pane as a CSI-u sequence and lands in the shell
            // as literal `;5u` text. The buffer being scrolled is libghostty's
            // own, seeded from tmux by the scrollback prime.
            builder.withCustom("keybind", "shift+page_up=scroll_page_up")
            builder.withCustom("keybind", "shift+page_down=scroll_page_down")
            builder.withCustom("keybind", "shift+home=scroll_to_top")
            builder.withCustom("keybind", "shift+end=scroll_to_bottom")
        }
        return TerminalController(
            configSource: .generated(base.rendered),
            theme: AppSettings.terminalTheme(),
            terminalConfiguration: AppSettings.terminalConfiguration()
        )
    }()

    private var surfaces = [String: TmuxPaneSurface]()
    private var adoptedCellSize = false
    private var focusedPaneID: String?

    /// Windows the user closed from the tab strip.
    ///
    /// Closing a tab must never kill anything — an AI agent mid-run is the
    /// expensive case and there is no undo for it. But the strip is a mirror
    /// of tmux's window list, so "closed" has to be remembered here or the tab
    /// simply reappears on the next sync.
    private var hiddenWindowIDs = Set<String>()

    /// Last geometry each pane was painted at. tmux reflows a pane when the
    /// layout changes but does not make the program inside repaint, so a pane
    /// keeps showing text wrapped for its old width until something writes to
    /// it — which for an idle shell can be never.
    private var paintedFrames = [String: TmuxLayoutFrame]()
    private var repaintWorkItem: DispatchWorkItem?
    /// Panes waiting for the coalesced snapshot, each with what it had produced
    /// when its geometry last changed.
    ///
    /// Accumulated across batches rather than replaced by the latest one. The
    /// timer is a single work item and rescheduling it cancels the one before,
    /// so a batch whose pane set the next batch does not repeat used to be
    /// dropped outright — and `paintedFrames` was already advanced for those
    /// panes, so no later sync ever asked for them again. See `scheduleRepaint`.
    private var pendingRepaints = [String: UInt64]()
    /// Per pane, because the panes that were still writing when the snapshot
    /// came due are re-checked on their own schedule — one shared item would
    /// let the second pane to be skipped cancel the first one's retry.
    private var repaintRetryItems = [String: DispatchWorkItem]()
    private var syncScheduled = false

    var onStatusChange: ((String) -> Void)?

    init(connection: TmuxSessionConnection) {
        self.connection = connection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installSubviews()
        wireGrid()
        wireTabBar()

        connection.addModelObserver { [weak self] in self?.setNeedsSync() }
        connection.onStatusChange = { [weak self] status in self?.onStatusChange?(status) }
    }

    // The connection is started by TmuxServer, not here: every session stays
    // connected whether or not it is on screen, which is what keeps the
    // sidebar's activity dots live and switching instant.

    private func installSubviews() {
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        gridView.translatesAutoresizingMaskIntoConstraints = false
        // The tab bar must be ABOVE the grid. On macOS 26 AppKit gives the
        // grid's drawn content a window-sized backing layer (ContentLayer,
        // 66pt taller than the grid) for the titlebar scroll-edge effect;
        // that unclipped overhang paints windowBackgroundColor across the
        // tab-bar strip and hides anything z-ordered below the grid.
        view.addSubview(gridView)
        view.addSubview(tabBar)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: WindowTabBarView.preferredHeight),

            gridView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            gridView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func wireGrid() {
        gridView.onGridSizeChange = { [weak self] columns, rows in
            self?.connection.reportGrid(columns: columns, rows: rows)
        }
        gridView.onPaneClicked = { [weak self] paneID in
            self?.focusPane(paneID)
        }
        gridView.onSplitterDrag = { [weak self] drag in
            self?.connection.resizePane(
                id: drag.paneID,
                columns: drag.isVertical ? drag.cells : nil,
                rows: drag.isVertical ? nil : drag.cells
            )
        }
    }

    private func wireTabBar() {
        tabBar.onSelect = { [weak self] id in self?.connection.selectWindow(id: id) }
        tabBar.onNew = { [weak self] in self?.connection.newWindow() }
        tabBar.onRename = { [weak self] id, name in
            self?.connection.renameWindow(id: id, to: name)
        }
        tabBar.onReorder = { [weak self] id, index in
            self?.connection.moveWindow(id: id, toIndex: index)
        }
        tabBar.onKill = { [weak self] id in self?.connection.killWindow(id: id) }
        tabBar.onHide = { [weak self] id in self?.hideWindow(id) }
        tabBar.onRestoreHidden = { [weak self] in
            self?.hiddenWindowIDs.removeAll()
            self?.syncWithModel()
        }
    }

    // MARK: - Settings

    /// Push the current font, colours and chrome onto everything this session
    /// owns. Runs once per session, because each one has its own
    /// `TerminalController`.
    ///
    /// Order matters, and all of it has to happen in one main-actor turn:
    ///
    /// 1. `adoptedCellSize` is a one-shot latch. Left set, `cellPixels` stays
    ///    at the old font's value forever and the app's idea of the grid
    ///    drifts from tmux's permanently.
    /// 2. Calibration is suspended, because between the config push and the
    ///    next layout pass a surface reports the new cell size against its old
    ///    frame. See `PaneGridView.prepareForCellSizeChange`.
    /// 3. The config goes through the controller rather than recreating
    ///    surfaces: it reaches every live surface, hidden windows included,
    ///    and a recreated surface would lose its scrollback.
    /// 4. Every surface is nudged. libghostty *should* announce the new cell
    ///    size on its own and usually does, but that is an upstream contract
    ///    nobody here has measured, and the nudge costs nothing when the
    ///    metrics are already current — the coordinator drops it as unchanged.
    func applySettings() {
        let configuration = AppSettings.terminalConfiguration()
        if controller.terminalConfiguration != configuration {
            // Gated on the font config actually differing, so a settings change
            // that cannot move the cell size — a colour scheme, the rail width —
            // never resets the latch or suspends calibration. Logged because
            // entering this branch is the only thing after launch that changes
            // the grid out from under tmux.
            TmuxLog.lifecycle(
                "font changed — re-measuring the cell size for \(surfaces.count) surface(s)",
                session: connection.sessionName
            )
            adoptedCellSize = false
            gridView.prepareForCellSizeChange()
            controller.setTerminalConfiguration(configuration)
            for surface in surfaces.values { surface.view.fitToSize() }
            // Guarantee a layout pass this turn even if nothing reported a new
            // cell size, so the calibration suspension above cannot latch on.
            gridView.needsLayout = true
        }
        controller.setTheme(AppSettings.terminalTheme())

        tabBar.applyChromeTheme()
        gridView.applyChromeTheme()
    }

    // MARK: - Commands the menu drives

    func selectWindow(atVisibleSlot slot: Int) {
        let visible = connection.windows.filter { !hiddenWindowIDs.contains($0.id) }
        guard slot >= 0, slot < visible.count else { return }
        connection.selectWindow(id: visible[slot].id)
    }

    func selectAdjacentWindow(offset: Int) {
        let visible = connection.windows.filter { !hiddenWindowIDs.contains($0.id) }
        guard !visible.isEmpty,
              let current = visible.firstIndex(where: { $0.id == connection.activeWindowID })
        else { return }
        let next = (current + offset + visible.count) % visible.count
        connection.selectWindow(id: visible[next].id)
    }

    func newWindow() { connection.newWindow() }

    func hideActiveWindow() {
        guard let id = connection.activeWindowID else { return }
        hideWindow(id)
    }

    private func hideWindow(_ id: String) {
        // Hiding sends nothing to tmux, so it leaves no trace there. Logged
        // anyway: "the tab is gone" has two causes and only one of them lost
        // anything, and telling them apart afterwards is otherwise guesswork.
        TmuxLog.lifecycle(
            "hiding window \(id) from the strip (tmux is untouched, nothing is killed)",
            session: connection.sessionName
        )
        hiddenWindowIDs.insert(id)
        let visible = connection.windows.filter { !hiddenWindowIDs.contains($0.id) }
        if connection.activeWindowID == id, let next = visible.first {
            connection.selectWindow(id: next.id)
        } else if visible.isEmpty {
            // Never leave the user staring at nothing with no way back.
            hiddenWindowIDs.remove(id)
        }
        syncWithModel()
    }

    // MARK: - Model → view

    /// Coalesce model changes to one rebuild per runloop turn.
    ///
    /// Attaching to a session with a dozen windows produces a burst of
    /// notifications — one per window plus a layout change each — and every
    /// one of them re-reads the window list. Rebuilding the strip that many
    /// times in a single frame is both wasted work and a source of flicker.
    private func setNeedsSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.syncWithModel()
        }
    }

    /// Rebuild the visible pane set from whatever tmux currently says.
    ///
    /// Called for every structural notification, and once by `MainViewController`
    /// when this controller is put on screen — see the call there for why a
    /// controller cannot rely on being told a second time. Cheap because it is
    /// idempotent: surfaces already present are reused, and only genuinely new
    /// panes cost anything.
    func syncWithModel() {
        // A window that came back on its own — tmux made it active again —
        // should not stay hidden; that would leave the GUI showing something
        // other than what tmux says is current.
        if let active = connection.activeWindowID, hiddenWindowIDs.contains(active) {
            hiddenWindowIDs.remove(active)
        }
        hiddenWindowIDs.formIntersection(Set(connection.windows.map(\.id)))

        tabBar.update(
            windows: connection.windows,
            activeID: connection.activeWindowID,
            hidden: hiddenWindowIDs
        )

        guard let window = connection.activeWindow, let layout = window.layout else { return }

        for paneID in layout.panes.map(\.id) where surfaces[paneID] == nil {
            makeSurface(for: paneID)
        }

        if focusedPaneID == nil || !layout.panes.contains(where: { $0.id == focusedPaneID }) {
            focusedPaneID = layout.panes.first?.id
            if let focusedPaneID { connection.focus(paneID: focusedPaneID) }
        }

        gridView.setContent(layout: layout, surfaces: surfaces, focused: focusedPaneID)
        if let focusedPaneID, let surface = surfaces[focusedPaneID],
           view.window?.firstResponder !== surface.view
        {
            view.window?.makeFirstResponder(surface.view)
        }

        scheduleRepaint(of: layout.panes.filter { paintedFrames[$0.id] != $0.frame })
    }

    /// Re-snapshot panes whose geometry changed.
    ///
    /// Coalesced, because dragging a window edge produces a burst of layout
    /// changes and each repaint is a `capture-pane` round trip. Waiting for
    /// the resize to settle turns dozens of captures into one.
    ///
    /// Coalescing means *merging* the pane sets, not keeping the last one. Two
    /// batches inside the same 150ms need not describe the same panes — a
    /// window resize reflows the active window's panes, and selecting another
    /// window immediately after produces a batch made entirely of that window's
    /// panes — and cancelling the timer used to throw the earlier set away.
    /// Measured against the pre-fix code: the app window resized and another
    /// tmux window selected 134ms later, and the pane that had just been
    /// reflowed received **no `capture-pane` at all**, permanently, because
    /// `paintedFrames` had already been advanced for it on the way in and no
    /// later sync could see it as changed. It kept text wrapped for its old
    /// width until its geometry happened to change again.
    private func scheduleRepaint(of panes: [(id: String, frame: TmuxLayoutFrame)]) {
        guard !panes.isEmpty else { return }
        for pane in panes {
            paintedFrames[pane.id] = pane.frame
            // What the pane had written as of this geometry change, to compare
            // against when the snapshot comes due. The snapshot exists for a
            // pane that will not repaint itself; painting one over a pane that
            // is actively writing is a stale screen landing on a live one, and
            // it can land in the middle of an escape sequence the pane is
            // halfway through emitting. See `repaintWhenQuiet`.
            //
            // A pane already pending takes the newer reading: the question is
            // whether it has been quiet since its *latest* geometry change, and
            // that is the change the snapshot is now for.
            pendingRepaints[pane.id] = connection.router.deliveryCount(paneID: pane.id)
        }

        repaintWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let due = self.pendingRepaints
            self.pendingRepaints.removeAll()
            // Sorted only so the log reads the same way twice; the captures are
            // independent round trips and their order carries no meaning.
            for (paneID, outputBefore) in due.sorted(by: { $0.key < $1.key }) {
                guard let surface = self.surfaces[paneID] else { continue }

                // The first paint of a pane pulls history as well as the
                // visible screen, so the wheel can scroll back into what
                // happened before the app was even running. Later repaints —
                // after a resize — take the visible screen only; the history
                // is already in the surface's own buffer and replaying it
                // would stack a second copy on top.
                guard surface.hasPrimedHistory else {
                    surface.hasPrimedHistory = true
                    // Read at use rather than captured: tmux clamps to what the
                    // pane actually has, so this is a ceiling, and a change
                    // should apply to the next pane opened rather than waiting
                    // for a relaunch.
                    self.connection.captureScrollback(
                        paneID: paneID,
                        lines: AppSettings.scrollbackPrimeLines
                    ) { lines in
                        guard !lines.isEmpty else { return }
                        surface.terminalSession.receive(Self.replayPayload(lines, clearingScreen: false))
                    }
                    continue
                }

                self.repaintWhenQuiet(
                    paneID: paneID,
                    since: outputBefore,
                    attemptsLeft: Self.repaintRetryLimit
                )
            }
        }
        repaintWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// How many times a pane that was still writing gets re-checked, and how
    /// long between tries.
    ///
    /// A pane that has produced output since the resize has redrawn itself and
    /// wants no snapshot — but one chunk is not proof that the program
    /// repainted the whole viewport at the new width, and a snapshot that is
    /// merely skipped would leave that pane wrapped for its old width until its
    /// geometry changed again. So a skip waits rather than ending it. A pane
    /// that is still going after four tries is one that redraws continuously,
    /// which is the case where a snapshot has nothing to add.
    private static let repaintRetryLimit = 4
    private static let repaintRetryDelay: TimeInterval = 0.4

    /// Snapshot a pane over its own screen, once it has stopped writing.
    ///
    /// `since` is what the pane had produced when this attempt's quiet window
    /// opened. Unchanged at the end of it means the pane said nothing and the
    /// snapshot is safe to paint; changed means the program is redrawing itself
    /// and painting a captured screen over it would be a stale screen landing
    /// on a live one — possibly in the middle of an escape sequence.
    private func repaintWhenQuiet(paneID: String, since: UInt64, attemptsLeft: Int) {
        guard surfaces[paneID] != nil else { return }
        guard connection.router.deliveryCount(paneID: paneID) == since else {
            retryRepaint(paneID: paneID, attemptsLeft: attemptsLeft, reason: "it is still writing")
            return
        }

        connection.capturePane(paneID: paneID) { [weak self] lines in
            guard let self, !lines.isEmpty else { return }
            // Through the router, not straight at the surface: the check and
            // the hand-off have to happen under the lock the reader queue
            // takes, or live output can be enqueued between them.
            let painted = self.connection.router.deliverSnapshot(
                paneID: paneID,
                data: Self.replayPayload(lines, clearingScreen: true),
                ifDeliveryCountIs: since
            )
            guard !painted else { return }
            self.retryRepaint(paneID: paneID, attemptsLeft: attemptsLeft,
                              reason: "it started writing while the capture was in flight")
        }
    }

    private func retryRepaint(paneID: String, attemptsLeft: Int, reason: String) {
        repaintRetryItems[paneID]?.cancel()
        repaintRetryItems[paneID] = nil

        guard attemptsLeft > 0 else {
            TmuxLog.lifecycle(
                "not repainting \(paneID) — \(reason), and it has not stopped;"
                    + " a pane redrawing continuously does not need a snapshot",
                session: connection.sessionName
            )
            return
        }

        TmuxLog.lifecycle(
            "deferring the repaint of \(paneID) — \(reason);"
                + " \(attemptsLeft) more \(attemptsLeft == 1 ? "try" : "tries")",
            session: connection.sessionName
        )

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.repaintRetryItems[paneID] = nil
            // A fresh baseline each time: the question is whether the pane is
            // quiet *now*, not whether it has been quiet since the resize.
            self.repaintWhenQuiet(
                paneID: paneID,
                since: self.connection.router.deliveryCount(paneID: paneID),
                attemptsLeft: attemptsLeft - 1
            )
        }
        repaintRetryItems[paneID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.repaintRetryDelay, execute: work)
    }

    /// Join reply lines into something a terminal surface can be fed.
    ///
    /// Assembled as bytes rather than as a `String`, because that is what
    /// `capture-pane` returns and the point of taking it as bytes is that
    /// nothing between tmux and libghostty's parser reinterprets it. CR LF
    /// between rows, since the surface is a terminal and a bare LF would step
    /// down a row without returning to column one.
    private static func replayPayload(_ lines: [Data], clearingScreen: Bool) -> Data {
        var payload = Data()
        // Home, then erase: a repaint is replacing the screen, not adding to
        // it. Omitted for the first paint of a pane, which is appending
        // history to an empty buffer and has nothing to erase.
        if clearingScreen { payload.append(contentsOf: Array("\u{1b}[H\u{1b}[2J".utf8)) }
        for (index, line) in lines.enumerated() {
            if index > 0 { payload.append(contentsOf: [0x0d, 0x0a]) }
            payload.append(line)
        }
        return payload
    }

    private func makeSurface(for paneID: String) {
        let surface = TmuxPaneSurface(
            paneID: paneID,
            controller: controller,
            sendKeys: { [weak self] pane, data in
                self?.connection.sendKeys(paneID: pane, data: data)
            }
        )
        surface.onGridMetrics = { [weak self] metrics in
            guard let self else { return }
            // The latch closes on a measurement, not on the arrival of one.
            // Setting it first and letting `adoptCellSize` reject the metrics
            // leaves the app on the previous font's cell size with no way back
            // until the next font change — the grid it reports to tmux would
            // then be right about the window and wrong about the font.
            if !self.adoptedCellSize {
                self.adoptedCellSize = self.gridView.adoptCellSize(from: metrics)
            }
            self.gridView.calibrate(paneID: paneID, metrics: metrics)
        }
        surfaces[paneID] = surface

        // Live output starts flowing immediately and whatever tmux already
        // sent gets replayed. The initial paint is left to the repaint pass in
        // `syncWithModel`, which runs for every pane whose geometry it has not
        // seen before — a brand new surface always qualifies.
        connection.router.register(paneID: paneID, session: surface.terminalSession)
    }

    private func focusPane(_ paneID: String) {
        guard focusedPaneID != paneID else { return }
        focusedPaneID = paneID
        connection.focus(paneID: paneID)
        if let surface = surfaces[paneID] {
            view.window?.makeFirstResponder(surface.view)
        }
        gridView.setContent(
            layout: connection.activeWindow?.layout,
            surfaces: surfaces,
            focused: paneID
        )
    }

    // MARK: - Teardown

    /// Give up the GPU surfaces this controller built, and nothing else.
    ///
    /// Deliberately does *not* stop the connection. `TmuxServer` created it and
    /// is the only thing that stops it; when this method did both, a session
    /// that had ever been on screen was detached twice. Unregistering each pane
    /// is what makes the two halves independent rather than order-dependent —
    /// the router stops holding a surface the moment that surface is released,
    /// whether or not the connection has been torn down yet.
    func releaseSurfaces() {
        repaintWorkItem?.cancel()
        pendingRepaints.removeAll()
        for item in repaintRetryItems.values { item.cancel() }
        repaintRetryItems.removeAll()
        for (paneID, surface) in surfaces {
            connection.router.unregister(paneID: paneID)
            surface.setVisible(false)
        }
        surfaces.removeAll()
    }
}

#if DEBUG

    extension SessionViewController {
        /// Feed the grid a cell size as though a surface had just reported one.
        ///
        /// A font change is only observable through libghostty: it measures the
        /// new cell and announces it, and everything downstream — the grid the
        /// app reports, tmux's reflow, the layout that comes back — hangs off
        /// that one number. libghostty needs a live GPU surface to produce it,
        /// which rules the whole path out on any machine that cannot give it
        /// one; a locked screen is enough. This substitutes the number and
        /// leaves every other step real, so "does the app recover from a cell
        /// size change" can be answered without a font, a pointer, or a screen.
        ///
        /// It is a simulation of one input, not of the font change. It says
        /// nothing about whether libghostty reports the size this argues about.
        func debugAdoptCellSize(widthPixels: UInt32, heightPixels: UInt32) {
            gridView.prepareForCellSizeChange()
            gridView.adoptCellSize(from: TerminalGridMetrics(
                columns: 0, rows: 0, widthPixels: 0, heightPixels: 0,
                cellWidthPixels: widthPixels, cellHeightPixels: heightPixels
            ))
            gridView.needsLayout = true
        }

        /// What this controller believes about its session, next to what tmux
        /// told it. The two should be identical everywhere except
        /// `hiddenWindowIDs`, which is the app's one piece of authored state.
        func debugReport(isShown: Bool) -> DebugInspector.SessionReport {
            DebugInspector.SessionReport(
                name: connection.sessionName,
                sessionID: connection.debugSessionID,
                isShown: isShown,
                hasSurfaces: !surfaces.isEmpty,
                activeWindowID: connection.activeWindowID,
                hiddenWindowIDs: hiddenWindowIDs.sorted(),
                focusedPaneID: focusedPaneID,
                reportedGrid: connection.debugLastReportedGrid.map {
                    DebugInspector.GridSize(columns: $0.columns, rows: $0.rows)
                },
                grid: gridView.debugReport(),
                windows: connection.windows.map {
                    DebugInspector.WindowReport(
                        window: $0,
                        isHiddenFromStrip: hiddenWindowIDs.contains($0.id)
                    )
                },
                surfaces: surfaces.sorted { $0.key < $1.key }.map { paneID, surface in
                    DebugInspector.SurfaceReport(
                        paneID: paneID,
                        hasPrimedHistory: surface.hasPrimedHistory,
                        isAttached: surface.view.superview != nil,
                        viewFrame: DebugInspector.Rect(surface.view.frame),
                        grid: surface.gridMetrics.map {
                            DebugInspector.GridSize(columns: Int($0.columns), rows: Int($0.rows))
                        },
                        cellSizeInPixels: surface.gridMetrics.map {
                            DebugInspector.Size(CGSize(
                                width: CGFloat($0.cellWidthPixels),
                                height: CGFloat($0.cellHeightPixels)
                            ))
                        }
                    )
                }
            )
        }
    }

#endif
