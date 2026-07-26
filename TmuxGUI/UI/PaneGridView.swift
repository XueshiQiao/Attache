//
//  PaneGridView.swift
//  TmuxGUI
//

import Cocoa
import GhosttyTerminal

/// Lays out a window's panes on the same character grid tmux is using.
///
/// Rather than approximating tmux's tree with nested `NSSplitView`s and hoping
/// the two agree, this places every pane by arithmetic on tmux's own numbers:
/// a pane at cell `(x, y)` sized `columns x rows` goes at exactly
/// `(x·cellWidth, y·cellHeight)`. Because the app also tells tmux how many
/// cells the container has, both sides are working from one grid and the
/// splitters cannot drift apart — which is the failure mode that makes
/// tmux-backed GUIs show black gaps.
///
/// The one-cell gap tmux leaves between siblings for its divider becomes the
/// visible splitter, and doubles as the drag target.
@MainActor
final class PaneGridView: NSView {
    /// Reports how many whole cells fit, whenever that changes. The owner
    /// forwards it to tmux via `refresh-client -C`.
    var onGridSizeChange: ((Int, Int) -> Void)?
    /// A splitter was dragged to a new cell position.
    var onSplitterDrag: ((SplitterDrag) -> Void)?
    var onPaneClicked: ((String) -> Void)?

    struct SplitterDrag {
        /// Pane immediately before the splitter — the one being resized.
        let paneID: String
        let isVertical: Bool
        /// New size in cells for `paneID`.
        let cells: Int
    }

    private(set) var layoutTree: TmuxLayoutNode?
    private var surfaces = [String: TmuxPaneSurface]()
    private var focusedPaneID: String?
    private var cellSize = CGSize(width: 8, height: 17)
    private var splitters = [Splitter]()
    private var activeDrag: (splitter: Splitter, startCells: Int)?

    private struct Splitter {
        let rect: CGRect
        let isVertical: Bool
        let beforePaneID: String
        let beforeCells: Int
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    // MARK: - Content

    /// Replace the visible pane set. Surfaces are supplied by the owner so
    /// they can outlive a layout change and keep receiving output.
    func setContent(layout: TmuxLayoutNode?, surfaces: [String: TmuxPaneSurface], focused: String?) {
        layoutTree = layout
        self.surfaces = surfaces
        focusedPaneID = focused

        let wanted = Set(layoutTree?.panes.map(\.id) ?? [])
        for view in subviews where !(view is TerminalView) { view.removeFromSuperview() }
        for (paneID, surface) in surfaces {
            if wanted.contains(paneID) {
                if surface.view.superview !== self { addSubview(surface.view) }
                surface.setVisible(true)
            } else if surface.view.superview === self {
                surface.view.removeFromSuperview()
                surface.setVisible(false)
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    func adoptCellSize(from metrics: TerminalGridMetrics) {
        let scale = window?.backingScaleFactor ?? 2
        guard metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else { return }
        let size = CGSize(
            width: CGFloat(metrics.cellWidthPixels) / scale,
            height: CGFloat(metrics.cellHeightPixels) / scale
        )
        guard size != cellSize else { return }
        cellSize = size
        needsLayout = true
        reportGridSize()
    }

    /// Cells that fit in the current bounds — the size reported to tmux.
    var gridSize: (columns: Int, rows: Int) {
        (
            max(1, Int(bounds.width / cellSize.width)),
            max(1, Int(bounds.height / cellSize.height))
        )
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        reportGridSize()

        guard let layoutTree else { return }
        splitters.removeAll()
        place(node: layoutTree)
        needsDisplay = true
    }

    private func place(node: TmuxLayoutNode) {
        switch node {
        case .pane(let id, let frame):
            surfaces[id]?.view.frame = rect(for: frame)

        case .leftRight(let children, _):
            for child in children { place(node: child) }
            recordSplitters(between: children, vertical: true)

        case .topBottom(let children, _):
            for child in children { place(node: child) }
            recordSplitters(between: children, vertical: false)
        }
    }

    /// The gap tmux leaves between two siblings is one cell wide; that strip
    /// is the splitter. Dragging it resizes the pane before it, which is
    /// exactly what `resize-pane -x/-y` does.
    private func recordSplitters(between children: [TmuxLayoutNode], vertical: Bool) {
        for (index, child) in children.enumerated() where index < children.count - 1 {
            let frame = child.frame
            // Use the last pane inside the child subtree that touches the gap,
            // since resize-pane addresses a pane, not a container.
            guard let anchor = anchorPane(in: child, vertical: vertical) else { continue }

            let rect: CGRect = if vertical {
                CGRect(
                    x: CGFloat(frame.x + frame.columns) * cellSize.width,
                    y: CGFloat(frame.y) * cellSize.height,
                    width: cellSize.width,
                    height: CGFloat(frame.rows) * cellSize.height
                )
            } else {
                CGRect(
                    x: CGFloat(frame.x) * cellSize.width,
                    y: CGFloat(frame.y + frame.rows) * cellSize.height,
                    width: CGFloat(frame.columns) * cellSize.width,
                    height: cellSize.height
                )
            }
            splitters.append(Splitter(
                rect: rect,
                isVertical: vertical,
                beforePaneID: anchor,
                beforeCells: vertical ? frame.columns : frame.rows
            ))
        }
    }

    /// Any pane inside the subtree works as a resize target as long as it
    /// spans the edge being dragged; the first one that does is enough.
    private func anchorPane(in node: TmuxLayoutNode, vertical: Bool) -> String? {
        switch node {
        case .pane(let id, _):
            return id
        case .leftRight(let children, _):
            return vertical ? anchorPane(in: children.last!, vertical: vertical)
                : anchorPane(in: children.first!, vertical: vertical)
        case .topBottom(let children, _):
            return vertical ? anchorPane(in: children.first!, vertical: vertical)
                : anchorPane(in: children.last!, vertical: vertical)
        }
    }

    private func rect(for frame: TmuxLayoutFrame) -> CGRect {
        CGRect(
            x: CGFloat(frame.x) * cellSize.width,
            y: CGFloat(frame.y) * cellSize.height,
            width: CGFloat(frame.columns) * cellSize.width,
            height: CGFloat(frame.rows) * cellSize.height
        )
    }

    private var lastReportedGrid: (Int, Int)?

    private func reportGridSize() {
        let size = gridSize
        guard lastReportedGrid?.0 != size.columns || lastReportedGrid?.1 != size.rows else { return }
        lastReportedGrid = (size.columns, size.rows)
        onGridSizeChange?(size.columns, size.rows)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        NSColor.separatorColor.setFill()
        for splitter in splitters {
            splitter.rect.insetBy(
                dx: splitter.isVertical ? cellSize.width * 0.35 : 0,
                dy: splitter.isVertical ? 0 : cellSize.height * 0.35
            ).fill()
        }

        // A one-pane window needs no focus ring; with several, the active one
        // has to be obvious at a glance or keystrokes go somewhere surprising.
        guard let focusedPaneID, (layoutTree?.panes.count ?? 0) > 1,
              let frame = layoutTree?.panes.first(where: { $0.id == focusedPaneID })?.frame
        else { return }
        let path = NSBezierPath(rect: rect(for: frame).insetBy(dx: -1, dy: -1))
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    // MARK: - Splitter dragging

    override func resetCursorRects() {
        super.resetCursorRects()
        for splitter in splitters {
            addCursorRect(
                splitter.rect.insetBy(dx: -2, dy: -2),
                cursor: splitter.isVertical ? .resizeLeftRight : .resizeUpDown
            )
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Splitters are one cell wide, so give them a couple of extra points
        // of slop and let them win over the terminal surface underneath —
        // otherwise the gap is nearly impossible to grab.
        let local = convert(point, from: superview)
        if splitters.contains(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(local) }) {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let splitter = splitters.first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(point) })
        else {
            if let paneID = pane(at: point) { onPaneClicked?(paneID) }
            return
        }
        activeDrag = (splitter, splitter.beforeCells)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let splitter = activeDrag.splitter

        let cells: Int = if splitter.isVertical {
            Int(round((point.x - splitter.rect.minX) / cellSize.width)) + activeDrag.startCells
        } else {
            Int(round((point.y - splitter.rect.minY) / cellSize.height)) + activeDrag.startCells
        }
        guard cells >= 1, cells != splitter.beforeCells else { return }

        onSplitterDrag?(SplitterDrag(
            paneID: splitter.beforePaneID,
            isVertical: splitter.isVertical,
            cells: cells
        ))
    }

    override func mouseUp(with _: NSEvent) {
        activeDrag = nil
    }

    private func pane(at point: CGPoint) -> String? {
        layoutTree?.panes.first { rect(for: $0.frame).contains(point) }?.id
    }
}
