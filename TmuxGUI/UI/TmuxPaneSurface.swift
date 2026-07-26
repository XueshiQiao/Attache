//
//  TmuxPaneSurface.swift
//  TmuxGUI
//

import Cocoa
import GhosttyTerminal

/// One tmux pane, rendered by one libghostty surface.
///
/// The surface never learns it is talking to tmux. It asks for bytes through
/// the `.inMemory` backend and hands keystrokes back; where those come from
/// and go to is entirely this class's business.
@MainActor
final class TmuxPaneSurface {
    let paneID: String
    let view: TerminalView
    let terminalSession: InMemoryTerminalSession

    /// Cell geometry from the last resize. The pane grid needs it to place
    /// views on the same character grid tmux is laying panes out on.
    private(set) var gridMetrics: TerminalGridMetrics?

    /// Called when this surface learns the cell size, so the grid can do its
    /// first real layout pass.
    var onGridMetrics: ((TerminalGridMetrics) -> Void)?
    var onFocusRequested: ((String) -> Void)?

    private let sendKeys: (String, Data) -> Void
    private var delegateBox: DelegateBox?

    init(
        paneID: String,
        controller: TerminalController,
        sendKeys: @escaping (String, Data) -> Void
    ) {
        self.paneID = paneID
        self.sendKeys = sendKeys

        view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        // The surface's own resize callback is deliberately NOT wired to
        // `refresh-client`: a pane's size is decided by tmux's layout, not by
        // how big this particular view happens to be. Only the whole grid
        // reports its size to tmux, in TmuxSessionConnection.
        terminalSession = InMemoryTerminalSession(
            write: { data in
                Task { @MainActor in sendKeys(paneID, data) }
            },
            resize: { _ in }
        )

        let box = DelegateBox(owner: self)
        delegateBox = box
        view.delegate = box
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("tmux 窗格 \(paneID)")
    }

    /// Hidden panes stay attached to tmux and keep receiving output, so
    /// switching back to a window shows current content with no reload. Only
    /// the GPU-side surface is released.
    func setVisible(_ visible: Bool) {
        view.setSurfaceVisible(visible)
    }

    fileprivate func gridDidResize(_ metrics: TerminalGridMetrics) {
        let isFirst = gridMetrics == nil
        gridMetrics = metrics
        if isFirst { onGridMetrics?(metrics) }
    }

    /// AppKit delegates are unowned-unsafe in libghostty's view, and a
    /// `TerminalView` outlives individual callbacks, so the conformance lives
    /// on a separate object the surface owns rather than on the surface
    /// itself. That keeps the retain graph one-directional.
    private final class DelegateBox: NSObject, TerminalSurfaceGridResizeDelegate {
        weak var owner: TmuxPaneSurface?
        init(owner: TmuxPaneSurface) { self.owner = owner }

        func terminalDidResize(_ size: TerminalGridMetrics) {
            owner?.gridDidResize(size)
        }
    }
}
