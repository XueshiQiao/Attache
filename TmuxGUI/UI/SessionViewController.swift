//
//  SessionViewController.swift
//  TmuxGUI
//

import Cocoa
import GhosttyTerminal

/// Shows one tmux session: its active window's panes, laid out as tmux has
/// them.
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
    private lazy var controller: TerminalController = .init { builder in
        builder.withBackgroundOpacity(0)
    }

    private var surfaces = [String: TmuxPaneSurface]()
    private var adoptedCellSize = false
    private var focusedPaneID: String?
    /// Last geometry each pane was painted at. tmux reflows a pane when the
    /// layout changes but does not make the program inside repaint, so a pane
    /// keeps showing text wrapped for its old width until something writes to
    /// it — which for an idle shell can be never.
    private var paintedFrames = [String: TmuxLayoutFrame]()
    private var repaintWorkItem: DispatchWorkItem?

    var onStatusChange: ((String) -> Void)?

    init(connection: TmuxSessionConnection) {
        self.connection = connection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        gridView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gridView)
        NSLayoutConstraint.activate([
            gridView.topAnchor.constraint(equalTo: view.topAnchor),
            gridView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

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

        connection.onModelChange = { [weak self] in self?.syncWithModel() }
        connection.onStatusChange = { [weak self] status in self?.onStatusChange?(status) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        connection.start()
    }

    // MARK: - Model → view

    /// Rebuild the visible pane set from whatever tmux currently says.
    ///
    /// Called for every structural notification. Cheap because it is
    /// idempotent: surfaces already present are reused, and only genuinely new
    /// panes cost anything.
    private func syncWithModel() {
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
