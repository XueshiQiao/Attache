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
    /// Placeholder cell size, replaced by the first real metrics from a
    /// surface. Only ever used for the one layout pass that happens before
    /// any surface has reported, which exists solely to trigger that report.
    private var cellSize = CGSize(width: 8, height: 17)
    /// Cell size in device pixels, kept alongside the point value. The grid
    /// has to be counted the same way libghostty counts it — in pixels —
    /// because converting to points first and flooring there can land one
    /// cell away from what the surface actually allocates.
    private var cellPixels = CGSize(width: 16, height: 34)
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
        for view in subviews where !(view is TmuxTerminalView) { view.removeFromSuperview() }
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
        let scale = pixelScale
        guard metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else { return }
        let size = CGSize(
            width: CGFloat(metrics.cellWidthPixels) / scale,
            height: CGFloat(metrics.cellHeightPixels) / scale
        )
        let pixels = CGSize(
            width: CGFloat(metrics.cellWidthPixels),
            height: CGFloat(metrics.cellHeightPixels)
        )
        guard size != cellSize || pixels != cellPixels else { return }
        cellSize = size
        cellPixels = pixels
        needsLayout = true
        reportGridSize()
    }

    /// Pixels a surface consumes beyond `columns × cellWidth` — padding,
    /// insets, whatever libghostty decides to reserve.
    ///
    /// Measured rather than assumed. Setting `window-padding-*` to zero makes
    /// this zero today, but the whole layout depends on the GUI and tmux
    /// agreeing on the column count to the cell, and an off-by-one there
    /// corrupts every wrapped line. So instead of trusting the config, the
    /// grid watches what each surface actually reports for a known frame and
    /// backs out the difference. If a future libghostty reserves space again,
    /// this absorbs it on the next layout pass instead of silently
    /// reintroducing the bug.
    private var surfaceOverhead = CGSize.zero

    /// Cells that fit in the current bounds — the size reported to tmux.
    ///
    /// Counted in device pixels, the same units libghostty counts in.
    /// Converting to points first and flooring there can land a cell away
    /// from what the surface allocates.
    var gridSize: (columns: Int, rows: Int) {
        (
            max(1, Int((bounds.width * pixelScale - surfaceOverhead.width) / cellPixels.width)),
            max(1, Int((bounds.height * pixelScale - surfaceOverhead.height) / cellPixels.height))
        )
    }

    /// Backing scale of whatever display the window is on, falling back to the
    /// main screen and finally to 1 — a non-Retina display is unusual, not
    /// impossible, and assuming 2 there would halve every measurement.
    private var pixelScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    /// Compare what a surface reports against the frame it was given, and
    /// record any systematic difference. Called for every resize a surface
    /// reports, so the correction keeps itself honest.
    func calibrate(paneID: String, metrics: TerminalGridMetrics) {
        guard metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0,
              let frame = layoutTree?.panes.first(where: { $0.id == paneID })?.frame,
              frame.columns > 0, frame.rows > 0,
              metrics.columns > 0, metrics.rows > 0
        else { return }

        let assigned = rect(for: frame)
        let overhead = CGSize(
            width: assigned.width * pixelScale - CGFloat(metrics.columns) * CGFloat(metrics.cellWidthPixels),
            height: assigned.height * pixelScale - CGFloat(metrics.rows) * CGFloat(metrics.cellHeightPixels)
        )
        // A sane correction is under one cell in each direction; anything
        // larger means the surface has not caught up with its new frame yet
        // and should not be treated as a measurement.
        guard overhead.width >= 0, overhead.width < cellPixels.width * 2,
              overhead.height >= 0, overhead.height < cellPixels.height * 2,
              overhead != surfaceOverhead
        else { return }

        surfaceOverhead = overhead
        needsLayout = true
        reportGridSize()
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

    /// A pane's rect in points, sized so the surface inside it resolves to
    /// exactly `frame.columns × frame.rows` cells — the measured overhead is
    /// added back on top of the cells themselves.
    private func rect(for frame: TmuxLayoutFrame) -> CGRect {
        let scale = pixelScale
        return CGRect(
            x: CGFloat(frame.x) * cellSize.width,
            y: CGFloat(frame.y) * cellSize.height,
            width: CGFloat(frame.columns) * cellSize.width + surfaceOverhead.width / scale,
            height: CGFloat(frame.rows) * cellSize.height + surfaceOverhead.height / scale
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

#if DEBUG

    extension PaneGridView {
        /// Everything the column count is derived from, so a disagreement with
        /// tmux can be traced to the number that caused it rather than guessed
        /// at from a screenshot.
        func debugReport() -> DebugInspector.GridViewReport {
            let size = gridSize
            return DebugInspector.GridViewReport(
                boundsInPoints: DebugInspector.Rect(bounds),
                pixelScale: Double(pixelScale),
                cellSizeInPoints: DebugInspector.Size(cellSize),
                cellSizeInPixels: DebugInspector.Size(cellPixels),
                measuredSurfaceOverheadInPixels: DebugInspector.Size(surfaceOverhead),
                computedGrid: DebugInspector.GridSize(columns: size.columns, rows: size.rows),
                splitterCount: splitters.count
            )
        }
    }

#endif
