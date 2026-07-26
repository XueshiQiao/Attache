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
    private lazy var controller: TerminalController = .init { builder in
        builder.withBackgroundOpacity(0)
        // Scrollback keys have to be bound explicitly: unbound, Shift+PageUp
        // is forwarded to the pane as a CSI-u sequence and lands in the shell
        // as literal `;5u` text. The buffer being scrolled is libghostty's
        // own, seeded from tmux by the scrollback prime.
        builder.withCustom("keybind", "shift+page_up=scroll_page_up")
        builder.withCustom("keybind", "shift+page_down=scroll_page_down")
        builder.withCustom("keybind", "shift+home=scroll_to_top")
        builder.withCustom("keybind", "shift+end=scroll_to_bottom")
    }

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
    private var syncScheduled = false

    var onStatusChange: ((String) -> Void)?

    /// How much history to replay when a pane is first shown. tmux clamps to
    /// what the pane actually has, so this is a ceiling rather than a cost.
    /// Matched to a typical `history-limit` without making the opening of a
    /// busy session pull megabytes through the control pipe at once.
    private static let scrollbackPrimeLines = 2000

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
    /// Called for every structural notification. Cheap because it is
    /// idempotent: surfaces already present are reused, and only genuinely new
    /// panes cost anything.
    private func syncWithModel() {
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
    private func scheduleRepaint(of panes: [(id: String, frame: TmuxLayoutFrame)]) {
        guard !panes.isEmpty else { return }
        for pane in panes { paintedFrames[pane.id] = pane.frame }

        repaintWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for pane in panes {
                guard let surface = self.surfaces[pane.id] else { continue }

                // The first paint of a pane pulls history as well as the
                // visible screen, so the wheel can scroll back into what
                // happened before the app was even running. Later repaints —
                // after a resize — take the visible screen only; the history
                // is already in the surface's own buffer and replaying it
                // would stack a second copy on top.
                guard surface.hasPrimedHistory else {
                    surface.hasPrimedHistory = true
                    self.connection.captureScrollback(
                        paneID: pane.id,
                        lines: Self.scrollbackPrimeLines
                    ) { lines in
                        guard !lines.isEmpty else { return }
                        surface.terminalSession.receive(lines.joined(separator: "\r\n"))
                    }
                    continue
                }

                self.connection.capturePane(paneID: pane.id) { lines in
                    guard !lines.isEmpty else { return }
                    surface.terminalSession.receive(
                        "\u{1b}[H\u{1b}[2J" + lines.joined(separator: "\r\n")
                    )
                }
            }
        }
        repaintWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
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
            guard let self, !self.adoptedCellSize else { return }
            self.adoptedCellSize = true
            self.gridView.adoptCellSize(from: metrics)
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

    func stop() {
        connection.stop()
        for surface in surfaces.values { surface.setVisible(false) }
        surfaces.removeAll()
    }
}
