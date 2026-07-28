//
//  SessionViewController.swift
//  TmuxGUI
//

import Cocoa
import GhosttyTerminal

/// Shows one tmux session: the active window's panes, laid out as tmux has
/// them, filling the whole content area.
///
/// The window tabs used to be a strip across the top of this view. They are
/// rows in the rail now, so this controller draws panes and nothing else — but
/// it still *owns* the window level, because the hidden-window set and the
/// kill confirmation belong to a session rather than to a rail that outlives
/// every session it displays. `MainViewController` routes the rail's clicks
/// here.
///
/// Holds the pane surfaces for every window visited so far, not just the
/// visible one. tmux streams output for the whole session down one pipe
/// regardless, so keeping the surfaces alive costs nothing on the wire and
/// makes switching windows instant with content already current — the GPU
/// surface is what gets released when a pane goes off screen.
@MainActor
final class SessionViewController: NSViewController {
    let connection: TmuxSessionConnection

    private let gridView = PaneGridView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    private let titleBand = TitleBandView(frame: .zero)
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

    /// Windows the user hid from the rail.
    ///
    /// Hiding must never kill anything — an AI agent mid-run is the expensive
    /// case and there is no undo for it. But the rail is a mirror of tmux's
    /// window list, so "hidden" has to be remembered here or the row simply
    /// reappears on the next sync. This set is the app's one piece of state
    /// tmux cannot contradict, and the only one.
    private(set) var hiddenWindowIDs = Set<String>()

    /// A window hidden while it was the active one, until tmux reports that the
    /// selection has actually moved off it.
    ///
    /// Hiding sends tmux nothing about hiding — only a `select-window` for the
    /// row to move to. Until that comes back, tmux's idea of the active window
    /// is still the row that was just hidden, and the "tmux made it active
    /// again, so put it back" rule in `syncWithModel` reads that as tmux
    /// undoing the hide. It fired on every ⌘W: the window was hidden, restored
    /// a microsecond later, and all that survived was the selection change —
    /// which on a two-window session looks exactly like ⌘W toggling between
    /// window 1 and window 2, because that is what it was doing.
    private var hidingActiveWindow: String?

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
    /// Something about this session's window list changed and the rail draws
    /// it. Not the same signal as the connection's model observer: hiding and
    /// restoring never reach tmux, so nothing else would ever announce them.
    var onWindowsChanged: (() -> Void)?

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

        connection.addModelObserver { [weak self] in self?.setNeedsSync() }
        connection.onStatusChange = { [weak self] status in self?.onStatusChange?(status) }
    }

    // The connection is started by TmuxServer, not here: every session stays
    // connected whether or not it is on screen, which is what keeps the
    // sidebar's activity dots live and switching instant.

    /// A title bar restored to the top of the content half, and the pane grid
    /// under it.
    ///
    /// The band exists for two mechanical reasons, not for what it says. With
    /// the window-tab strip gone this half had nothing with
    /// `mouseDownCanMoveWindow`, and the window has no title bar, so the only
    /// way left to drag it was the rail's empty space — which runs out as soon
    /// as a session has enough windows to fill the list. And terminal text ran
    /// straight up under the window's rounded top corners.
    ///
    /// It is deliberately not painted. `window.backgroundColor` is already
    /// `ChromeTheme.background` and `PaneGridView` fills the same colour, so a
    /// view that never draws is pixel-identical to one painting the theme
    /// background, under every scheme, with nothing to keep in sync. That is
    /// also what "merged with the background" has to mean here — a fill of its
    /// own would be a second thing to get wrong, and a separator hairline would
    /// be the one obtrusive line in a band whose whole point is to disappear.
    /// The edge is already there without one: chrome sits 6% off the terminal
    /// background, so the top pane starts at a just-perceptible tonal step.
    ///
    /// 28pt is the standard macOS title-bar height for a titled window with no
    /// toolbar — the thing being restored — and it clears the window's corner
    /// radius. The old strip's 34pt was sized to hold 26pt tabs that no longer
    /// exist.
    ///
    /// The grid is *shrunk*, not overlaid: a band laid over a full-height grid
    /// would hide a row tmux still counts, which is the app-versus-tmux grid
    /// disagreement this whole codebase is built to avoid.
    static let titleBandHeight: CGFloat = 28

    /// Air between the rail and the first column of text.
    ///
    /// The sidebar is an inset rounded panel with its own margin, and the split
    /// divider sits just outside it — so with the grid starting at zero the
    /// terminal's leftmost character butted straight up against the app's own
    /// chrome, with the divider as the only thing between them. The gap is on
    /// the left only: that is the edge with something on the other side of it.
    ///
    /// It costs a column when it crosses a cell boundary, and that is fine —
    /// `PaneGridView` counts columns from its own bounds and reports what it
    /// counts, so tmux is told the smaller number and the two still agree.
    /// Nothing here may ever *assume* a column count; the whole file is built
    /// on measuring one.
    static let gridLeftInset: CGFloat = 8

    private func installSubviews() {
        gridView.translatesAutoresizingMaskIntoConstraints = false
        titleBand.translatesAutoresizingMaskIntoConstraints = false
        // Band after the grid, for the reason recorded in CLAUDE.md: on macOS 26
        // a view that draws gets a backing layer 66pt taller than itself and the
        // overhang is not clipped, so whichever sibling is added last wins. The
        // band itself never draws, but the label in it does.
        view.addSubview(gridView)
        view.addSubview(titleBand)

        NSLayoutConstraint.activate([
            titleBand.topAnchor.constraint(equalTo: view.topAnchor),
            titleBand.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleBand.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titleBand.heightAnchor.constraint(equalToConstant: Self.titleBandHeight),

            gridView.topAnchor.constraint(equalTo: titleBand.bottomAnchor),
            gridView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Self.gridLeftInset
            ),
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

        gridView.applyChromeTheme()
        titleBand.applyChromeTheme()
    }

    // MARK: - Commands the menu and the rail drive

    /// ⌘0-9 — the window tmux calls `index`, which is the number the rail draws
    /// beside it.
    ///
    /// It used to be a *position* in the hidden-filtered list, and the two are
    /// not the same number. With tmux's default `base-index 0` the row labelled
    /// **0** answered to ⌘1 and the row labelled **3** to ⌘4; with
    /// `base-index 1` they happened to line up until a window was hidden, and
    /// then everything below the hidden row shifted by one. `TitleBandView`'s
    /// comment about the rail being what these count against was describing the
    /// intent rather than the code.
    ///
    /// ⌘0 exists for the same reason `prefix 0` does in tmux: under
    /// `base-index 0` there is a window 0, and without it that window is the
    /// one thing on screen with no shortcut.
    ///
    /// A hidden window is not selected. Its row is not in the rail, so its
    /// number addresses nothing — and selecting it would bring it back, since
    /// `syncWithModel` restores whatever tmux makes active. Hiding is the one
    /// piece of state this app authors, and a shortcut should not undo it by
    /// arithmetic.
    func selectWindow(atIndex index: Int) {
        guard let window = connection.windows.first(where: { $0.index == index }),
              !hiddenWindowIDs.contains(window.id)
        else { return }
        connection.selectWindow(id: window.id)
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

    func selectWindow(id: String) { connection.selectWindow(id: id) }

    func renameWindow(id: String, to name: String) {
        connection.renameWindow(id: id, to: name)
    }

    /// `anchor` is the window this one should land in front of, or nil for
    /// "after everything else" — which needs a different tmux command, because
    /// `move-window -b` cannot append. See `TmuxSessionConnection`.
    func moveWindow(id: String, before anchor: String?) {
        guard connection.moveWindow(id: id, before: anchor) else {
            TmuxLog.lifecycle(
                "not moving \(id) — \(connection.sessionName) has no free index above its"
                    + " windows, or has not learned its session id yet",
                session: connection.sessionName
            )
            return
        }
    }

    func hideActiveWindow() {
        guard let id = connection.activeWindowID else { return }
        hideWindow(id)
    }

    func hideWindow(_ id: String) {
        // Hiding sends nothing to tmux, so it leaves no trace there. Logged
        // anyway: "the row is gone" has two causes and only one of them lost
        // anything, and telling them apart afterwards is otherwise guesswork.
        TmuxLog.lifecycle(
            "hiding window \(id) from the rail (tmux is untouched, nothing is killed)",
            session: connection.sessionName
        )
        hiddenWindowIDs.insert(id)
        let visible = connection.windows.filter { !hiddenWindowIDs.contains($0.id) }
        if connection.activeWindowID == id, let next = visible.first {
            hidingActiveWindow = id
            connection.selectWindow(id: next.id)
        } else if visible.isEmpty {
            // Never leave the user staring at nothing with no way back.
            hiddenWindowIDs.remove(id)
        }
        syncWithModel()
    }

    func restoreHiddenWindows() {
        hiddenWindowIDs.removeAll()
        hidingActiveWindow = nil
        syncWithModel()
    }

    /// The one destructive thing the rail can do, and the only place in the app
    /// that ends a process.
    ///
    /// Lives here rather than in the rail because the confirmation names the
    /// window and the log line names the session, and because the rail outlives
    /// every session it draws — this controller is what a kill actually belongs
    /// to. The wording is the wording the tab strip used; nothing about the
    /// stakes changed when the tabs became rows.
    func confirmKillWindow(id: String) {
        guard let window = connection.windows.first(where: { $0.id == id }) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Kill window \(window.index):\(window.name)?"
        alert.informativeText = "Every process in the window ends, including any AI agent mid-run."
            + "\nTo just get it out of the way, use Hide From The Sidebar."
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")

        // Both outcomes are logged, and the prompt itself is logged before it
        // is shown. If work disappears, the question is whether this dialog was
        // ever put in front of a human — a GUI driven by automation can answer
        // it without one, and the log is the only place that shows the
        // difference.
        TmuxLog.destructive(
            "kill confirmation shown for \(window.id) (\(window.index):\(window.name))",
            session: connection.sessionName
        )
        guard alert.runModal() == .alertFirstButtonReturn else {
            TmuxLog.lifecycle("kill cancelled for \(window.id)", session: connection.sessionName)
            return
        }
        TmuxLog.destructive(
            "kill CONFIRMED for \(window.id) (\(window.index):\(window.name)) — every process in it ends",
            session: connection.sessionName
        )
        connection.killWindow(id: window.id)
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
        //
        // Except while this controller is the one moving away from it. Hiding
        // the active window sends a `select-window` and then runs this
        // immediately, long before tmux can answer, so tmux still names the row
        // that was just hidden — which is not tmux putting it back, it is tmux
        // not having been told yet. See `hidingActiveWindow`.
        if let active = connection.activeWindowID {
            if active == hidingActiveWindow {
                // Still waiting on our own select-window.
            } else {
                hidingActiveWindow = nil
                hiddenWindowIDs.remove(active)
            }
        }
        hiddenWindowIDs.formIntersection(Set(connection.windows.map(\.id)))

        onWindowsChanged?()
        titleBand.show(name: connection.activeWindow?.name)
        releaseSurfacesForDepartedPanes()

        // Only for the session on screen, and only while this app is the one
        // being looked at. A session the user is not looking at has no business
        // fighting another terminal over its size — this app's grid describes
        // the window it is drawn in, and that window is showing exactly one
        // session.
        //
        // `isKeyWindow` rather than merely having a window, and that is the
        // whole difference between taking a size back and a fight. Two clients
        // of different sizes cannot both be satisfied: tmux gives a window one
        // size. So a background app that takes the size back on every
        // `%layout-change` produces exactly the loop it looks like — the user
        // resizes in their terminal, tmux announces it, this app grabs it back,
        // tmux announces that, the terminal's own client reacts, and the layout
        // visibly jumps back and forth with nobody winning. Observed here: eight
        // notification-driven reclaims in one short run.
        //
        // Backgrounded, the right behaviour is to draw what tmux says even when
        // it does not fit — dead space is honest, a fight is not. The moment the
        // user comes back to this window it becomes the key window, and
        // `MainViewController` asks for the size then. That is the one moment
        // this app is entitled to it, and no window has a key window while its
        // app is inactive, so this single test covers both conditions.
        if isViewLoaded, view.window?.isKeyWindow == true {
            connection.reclaimWindowSizeIfTaken()
        }

        // The *visible* layout, so a zoomed pane is drawn at the size tmux
        // actually gave it. The pane *set* comes from the saved layout instead,
        // in the release pass above — see `TmuxWindow`.
        guard let window = connection.activeWindow, let layout = window.visibleLayout else { return }

        for paneID in layout.panes.map(\.id) where surfaces[paneID] == nil {
            makeSurface(for: paneID)
        }

        // tmux's answer, not a guess this controller keeps. `#{pane_id}` on the
        // window is its active pane, and every path that can change it —
        // `prefix + o`, a click that reached the surface, another terminal —
        // arrives here as a refresh. The one thing left to check is that the
        // pane is really in this layout; the two come from the same reply, so
        // they can only disagree if tmux sent something impossible.
        focusedPaneID = layout.panes.contains { $0.id == window.activePaneID }
            ? window.activePaneID
            : layout.panes.first?.id

        gridView.setContent(layout: layout, surfaces: surfaces, focused: focusedPaneID)
        if let focusedPaneID, let surface = surfaces[focusedPaneID],
           view.window?.firstResponder !== surface.view
        {
            view.window?.makeFirstResponder(surface.view)
        }

        scheduleRepaint(of: layout.panes.filter { paintedFrames[$0.id] != $0.frame })
    }

    /// Give up the surfaces of panes this session no longer has.
    ///
    /// Surfaces are deliberately kept for every window visited, not just the
    /// one on screen — that is what makes switching windows instant with
    /// content already current. But "every window visited" was being read as
    /// "for ever": nothing dropped a surface when its pane stopped belonging to
    /// this session, so a window killed from another terminal, or dragged into
    /// a different session, left its surfaces alive and still registered with
    /// this session's router until the whole session went away. Dragging a
    /// window between sessions makes that a normal thing to do rather than an
    /// accident, and the destination builds its own surfaces for the same
    /// panes — two live copies of one pane, one of which can never receive
    /// another byte.
    ///
    /// Every window's panes, not the active window's: an off-screen window's
    /// surfaces are the ones being protected here.
    private func releaseSurfacesForDepartedPanes() {
        // Only against a window list that can actually answer the question. An
        // empty list, or a window whose layout has not arrived or did not
        // parse, reports *no* panes — and read as evidence that would condemn
        // every surface in the session on a half-delivered refresh.
        //
        // The saved layout, which is what `paneIDs` reads. The visible one
        // lists a single pane while a window is zoomed, so asking it "which
        // panes does this session have" would release the surfaces of every
        // other pane in that window — scrollback and all — on `prefix z`, and
        // rebuild them from a fresh `capture-pane` on the way back out.
        guard !connection.windows.isEmpty,
              connection.windows.allSatisfy({ $0.savedLayout != nil }) else { return }

        let live = Set(connection.windows.flatMap(\.paneIDs))
        let departed = surfaces.keys.filter { !live.contains($0) }
        guard !departed.isEmpty else { return }

        TmuxLog.lifecycle(
            "releasing \(departed.count) surface(s) whose panes left"
                + " \(connection.sessionName): \(departed.sorted().joined(separator: ", "))",
            session: connection.sessionName
        )
        for paneID in departed {
            connection.router.unregister(paneID: paneID)
            // Out of the view tree *before* it leaves the dictionary. The grid
            // no longer decides what to remove from `surfaces`, but a view left
            // behind here would still be one nothing owns.
            surfaces[paneID]?.view.removeFromSuperview()
            surfaces[paneID]?.setVisible(false)
            surfaces.removeValue(forKey: paneID)
            paintedFrames.removeValue(forKey: paneID)
            pendingRepaints.removeValue(forKey: paneID)
            repaintRetryItems.removeValue(forKey: paneID)?.cancel()
        }
        if let focusedPaneID, !live.contains(focusedPaneID) { self.focusedPaneID = nil }
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

                // A repaint takes the visible screen only. The history is
                // already in the surface's buffer, put there by the first
                // paint, and replaying it would stack a second copy on top.
                //
                // A pane whose first paint has not come back yet is having its
                // whole screen fetched already — a second snapshot on top of
                // that is a wasted round trip at best, and at worst it lands
                // first. `primeSurface` releases the pane to this path.
                guard surface.hasPrimedHistory else { continue }

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
    private func repaintWhenQuiet(
        paneID: String, since: UInt64, attemptsLeft: Int, isFirstPaint: Bool = false
    ) {
        guard surfaces[paneID] != nil else { return }
        guard connection.router.deliveryCount(paneID: paneID) == since else {
            retryRepaint(paneID: paneID, attemptsLeft: attemptsLeft, isFirstPaint: isFirstPaint,
                         reason: "it is still writing")
            return
        }

        // Read at use rather than captured: tmux clamps to what the pane
        // actually has, so this is a ceiling, and a change should apply to the
        // next pane opened rather than waiting for a relaunch.
        let history = isFirstPaint ? AppSettings.scrollbackPrimeLines : nil
        connection.capturePane(paneID: paneID, historyLines: history) { [weak self] snapshot in
            guard let self, !snapshot.screen.isEmpty else { return }
            // Through the router, not straight at the surface: the check and
            // the hand-off have to happen under the lock the reader queue
            // takes, or live output can be enqueued between them.
            let painted = self.connection.router.deliverSnapshot(
                paneID: paneID,
                data: TmuxScreenReplay.payload(for: snapshot, isFirstPaint: isFirstPaint),
                ifDeliveryCountIs: since
            )
            guard !painted else {
                if isFirstPaint { self.surfaces[paneID]?.hasPrimedHistory = true }
                return
            }
            self.retryRepaint(paneID: paneID, attemptsLeft: attemptsLeft, isFirstPaint: isFirstPaint,
                              reason: "it started writing while the capture was in flight")
        }
    }

    private func retryRepaint(
        paneID: String, attemptsLeft: Int, isFirstPaint: Bool, reason: String
    ) {
        repaintRetryItems[paneID]?.cancel()
        repaintRetryItems[paneID] = nil

        guard attemptsLeft > 0 else {
            TmuxLog.lifecycle(
                "not \(isFirstPaint ? "priming" : "repainting") \(paneID) — \(reason), and it"
                    + " has not stopped; a pane redrawing continuously does not need a snapshot",
                session: connection.sessionName
            )
            // Released to the ordinary repaint path either way. A pane that
            // never got its first paint and was left out of that path too would
            // never be snapshotted again for the life of the app.
            if isFirstPaint { surfaces[paneID]?.hasPrimedHistory = true }
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
                attemptsLeft: attemptsLeft - 1,
                isFirstPaint: isFirstPaint
            )
        }
        repaintRetryItems[paneID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.repaintRetryDelay, execute: work)
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
        surface.onFocusRequested = { [weak self] pane in self?.focusPane(pane) }
        surfaces[paneID] = surface

        primeSurface(paneID)
    }

    /// A pane's first paint: live output at once, then tmux's own picture of
    /// the pane painted over it.
    ///
    /// Both, and in that order, because they answer different questions. The
    /// router hands over whatever tmux sent before this surface existed, which
    /// for a pane that has been streaming since the client attached is the only
    /// account of it there is and has to appear now rather than after a round
    /// trip. The snapshot then supplies what that buffer cannot: the pane's
    /// scrollback from before the app was running, and a screen that is
    /// certainly current rather than however far the buffer happened to get.
    ///
    /// They used to be *stacked* — the buffer, then a snapshot of the grid
    /// those same bytes had been written into, appended below it — so a pane
    /// mid-stream showed its recent output twice. `replayPayload` erases first
    /// now, which is what makes the second one a replacement instead of an
    /// addition.
    ///
    /// Gated on the pane being quiet, by the same machinery a resize repaint
    /// uses: painting a captured screen over a live one is a stale screen
    /// landing on top of a current one, and can land in the middle of an escape
    /// sequence the pane is halfway through emitting. A pane that never falls
    /// quiet keeps the buffer and its live output, and is a pane whose program
    /// is drawing the screen anyway.
    private func primeSurface(_ paneID: String) {
        guard let surface = surfaces[paneID] else { return }
        connection.router.register(paneID: paneID, session: surface.terminalSession)
        repaintWhenQuiet(
            paneID: paneID,
            since: connection.router.deliveryCount(paneID: paneID),
            attemptsLeft: Self.repaintRetryLimit,
            isFirstPaint: true
        )
    }

    /// Tell tmux which pane the keyboard is in, and stop there.
    ///
    /// It used to move the ring itself and then inform tmux, which is the one
    /// shape this codebase does not allow: the GUI deciding and tmux catching
    /// up. Now the command goes out and the ring moves when tmux says so, by
    /// exactly the path `prefix + o` in another terminal takes.
    ///
    /// Gated on tmux's current answer rather than on a local memory, so the
    /// `makeFirstResponder` that `syncWithModel` does after every refresh
    /// cannot bounce a redundant `select-pane` back out.
    private func focusPane(_ paneID: String) {
        guard connection.activeWindow?.activePaneID != paneID else { return }
        connection.focus(paneID: paneID)
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
                        isHiddenFromSidebar: hiddenWindowIDs.contains($0.id)
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
