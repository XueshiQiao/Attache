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
    /// The cell size `layoutTree` was drawn up for.
    ///
    /// Normally identical to `cellSize`. They come apart for one tmux round
    /// trip after a font change, and keeping them apart is the whole point: a
    /// layout is a count of *cells*, decided by tmux for the grid it was told
    /// about. The moment the font changes, `cellSize` becomes the new one and
    /// the layout in hand is still the old one — multiplying those two
    /// together places panes for a window that is 20% wider than this view,
    /// and the overflow is not clipped, so the last pane in each direction
    /// runs off the edge and the splitters land inside their neighbours.
    ///
    /// Placing the old counts at the old size instead keeps the panes tiling
    /// the view exactly as they did a moment ago — stale, but whole — until
    /// tmux answers the new `refresh-client -C` with a layout for the new
    /// grid, which is when this catches up. What tmux is *told* still comes
    /// from `cellPixels`, so the count the two sides agree on is never the
    /// stale one.
    private var layoutCellSize = CGSize(width: 8, height: 17)
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
        let isNewsFromTmux = layout != layoutTree
        layoutTree = layout
        self.surfaces = surfaces
        focusedPaneID = focused
        adoptCellSizeForLayout(isNewsFromTmux: isNewsFromTmux)

        let wanted = Set(layoutTree?.panes.map(\.id) ?? [])
        let keep = Set(
            surfaces.filter { wanted.contains($0.key) }.map { ObjectIdentifier($0.value.view) }
        )

        // Driven by what is actually on screen, not by what is in `surfaces`.
        // Deciding from the dictionary leaves a terminal view stranded the
        // moment its surface stops being in it — and a stranded view keeps
        // drawing the last frame it had, over the top of the window the user
        // switched to. Two panes' output visibly interleaved in one rectangle
        // is what that looks like.
        for view in subviews {
            guard view is TmuxTerminalView else {
                view.removeFromSuperview()
                continue
            }
            if !keep.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        }

        for (paneID, surface) in surfaces {
            if wanted.contains(paneID) {
                if surface.view.superview !== self { addSubview(surface.view) }
                surface.setVisible(true)
                // Pushed on every pass, not just when a pane appears. It is the
                // only way a surface ever hears that it does not have the
                // keyboard, and the answer changes whenever tmux moves its
                // active pane. The focused one is handed the keyboard by
                // `SessionViewController`, which is the other half of this.
                if paneID != focused { surface.view.relinquishFocusIfNotFirstResponder() }
            } else {
                surface.setVisible(false)
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    /// Take a surface's cell size as the app's own.
    ///
    /// Answers whether the metrics were usable at all, so the caller's
    /// once-per-font-change latch closes on a measurement rather than on the
    /// mere arrival of one. A surface that reports a zero cell — it has been
    /// asked for its size before it has a font — would otherwise close the
    /// latch on the old cell size and keep it until the next font change.
    @discardableResult
    func adoptCellSize(from metrics: TerminalGridMetrics) -> Bool {
        let scale = pixelScale
        guard metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else { return false }
        let size = CGSize(
            width: CGFloat(metrics.cellWidthPixels) / scale,
            height: CGFloat(metrics.cellHeightPixels) / scale
        )
        let pixels = CGSize(
            width: CGFloat(metrics.cellWidthPixels),
            height: CGFloat(metrics.cellHeightPixels)
        )
        guard size != cellSize || pixels != cellPixels else { return true }
        cellSize = size
        cellPixels = pixels
        // The old overhead was measured against the old cell size and is not a
        // correction for this one. Zeroed here rather than when the change was
        // announced, so a font change that turns out not to move the cell size
        // does not throw away a good measurement.
        surfaceOverhead = .zero
        // Every frame in the view tree is still the old size; nothing measured
        // before the next layout pass places them means anything.
        calibrationSuspended = true
        needsLayout = true
        if reportGridSize() {
            // tmux has been asked for a new grid, so a new layout is due and
            // placement waits for it — but not forever.
            waitForTmuxThenAdoptAnyway()
        } else if !isLayoutBehindReportedGrid {
            // A new cell size that leaves the grid the same size — a font a
            // hair wider that still fits the same 217 columns — tells tmux
            // nothing, so there is no layout coming and the new size applies to
            // the one already in hand. Only when that one is current, though:
            // an earlier resize still unanswered means a layout is on its way
            // regardless of what this change did to the count.
            layoutCellSize = cellSize
        }
        return true
    }

    /// Give tmux a moment to answer the new `refresh-client -C`, then place at
    /// the new cell size whether it did or not.
    ///
    /// tmux is not obliged to resize a window to what a client asks for.
    /// `resize-window -x` pins one outright, and a second client attached to the
    /// same session can be the one the size follows. Measured with a window
    /// pinned to 100x30: the app reports 86x30, tmux says nothing at all, and
    /// with no deadline the panes stay at the *previous* font's cell size for
    /// as long as the app runs — while every surface renders the new one. That
    /// is worse than the overflow this whole mechanism exists to avoid, and it
    /// is indistinguishable from the bug that started it: the layout stops
    /// responding to the font.
    ///
    /// So the wait is bounded. When tmux cooperates — the ordinary case, and
    /// the one worth being smooth — the layout arrives in a few milliseconds
    /// and this finds nothing to do. When it does not, the app goes back to
    /// showing tmux's real geometry at the real cell size, which is honest
    /// about the disagreement rather than hiding it behind stale pixels.
    private func waitForTmuxThenAdoptAnyway() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.layoutCellSize != self.cellSize else { return }
            self.layoutCellSize = self.cellSize
            self.needsLayout = true
            self.needsDisplay = true
        }
    }

    /// Whether tmux still owes an answer: the layout in hand was drawn for a
    /// window size other than the one this view last reported.
    private var isLayoutBehindReportedGrid: Bool {
        guard let root = layoutTree?.frame, let reported = lastReportedGrid else { return false }
        return root.columns != reported.0 || root.rows != reported.1
    }

    /// Switch placement over to the current cell size once tmux has answered
    /// for it.
    ///
    /// The first test is tmux's own: a layout carries the window size it was
    /// drawn for, so a layout whose root matches the grid this view last
    /// reported is a layout for the size the app is now rendering at.
    ///
    /// The second test is what keeps a disagreement from becoming permanent.
    /// tmux does not have to answer with the size it was asked for — another
    /// client attached to the same session can size the window instead — and
    /// waiting for a match that will never come would leave every pane placed
    /// at a cell size the surfaces stopped rendering at, forever. So any layout
    /// tmux has actually changed is taken as its answer, matching or not:
    /// showing tmux's real geometry at the real cell size is right even when
    /// the two sides disagree about how many columns there is room for, and it
    /// converges the moment they agree again.
    ///
    /// What is deliberately *not* adopted is a repeat of the layout already in
    /// hand, which is what arrives when some other notification re-syncs the
    /// session while the answer is still in flight.
    private func adoptCellSizeForLayout(isNewsFromTmux: Bool) {
        guard layoutTree != nil else { return }
        if isNewsFromTmux || !isLayoutBehindReportedGrid { layoutCellSize = cellSize }
    }

    /// Called before something changes the cell size — a font or size change.
    ///
    /// Between the config being pushed and the next layout pass, a surface
    /// reports metrics for the *new* cell size while its view still has its
    /// *old* frame. `calibrate` compares those metrics against `rect(for:)`
    /// computed with the new `cellSize`, so the difference it records is the
    /// frame lag, not a real overhead. The "under two cells" sanity check does
    /// not catch it: a cell width moving 16.0 → 16.1 px across an 80-column
    /// pane produces exactly 16.1 px of apparent overhead, which is one cell
    /// and passes. A poisoned `surfaceOverhead` costs a column, and a column
    /// of disagreement with tmux breaks every wrapped line from then on.
    func prepareForCellSizeChange() {
        calibrationSuspended = true
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

    /// Whether a measurement taken right now would be comparing a surface's
    /// new metrics against a frame that has not been re-placed yet. See
    /// `prepareForCellSizeChange`.
    private var calibrationSuspended = false

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
    /// main screen and finally to 2.
    ///
    /// The final fallback is copied from libghostty rather than chosen. Its
    /// `core.scaleFactor` — `AppTerminalView.swift`, the closure that produces
    /// the `cellWidthPixels` `gridSize` divides by — is the same expression
    /// ending in `?? 2.0`. The two only ever meet as a ratio, so what matters
    /// is not which number is right but that both sides pick the same one: at
    /// `?? 1` against its `?? 2.0`, a view with no window on a machine
    /// reporting no main screen computes half the true column count and hands
    /// that to tmux, reflowing every window in the session for every client
    /// attached to it. Nobody has observed `NSScreen.main` being nil here, and
    /// `reportGridSize` now refuses to speak from a windowless view anyway —
    /// this is the second of the two locks.
    private var pixelScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Compare what a surface reports against the frame it was given, and
    /// record any systematic difference. Called for every resize a surface
    /// reports, so the correction keeps itself honest.
    func calibrate(paneID: String, metrics: TerminalGridMetrics) {
        // Both sides have to be counting in the same cell before a difference
        // between them means anything, and there are two ways for them not to
        // be. A report that still carries the previous font's cell size — a
        // surface that has not caught up yet — measured against a `rect(for:)`
        // built from the new one yields a difference that is entirely the font
        // change. And the mirror image: while a layout is still the previous
        // grid's, `rect(for:)` is deliberately built from the *old* cell size
        // while the surface reports the new one, so the slack between the two
        // would be banked as overhead. It is small enough to pass the sanity
        // check below and it sticks, which costs a column for good.
        guard !calibrationSuspended,
              layoutCellSize == cellSize,
              CGFloat(metrics.cellWidthPixels) == cellPixels.width,
              CGFloat(metrics.cellHeightPixels) == cellPixels.height,
              metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0,
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

        // Everything below assigns frames from the current cell size, and a
        // frame assignment is what makes a surface report. So from this point
        // on a report describes a frame this pass placed, which is exactly the
        // condition `calibrate` needs — the reports arrive synchronously from
        // inside `place`, so releasing afterwards would drop the first honest
        // measurement of the new cell size.
        calibrationSuspended = false

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
                    x: CGFloat(frame.x + frame.columns) * layoutCellSize.width,
                    y: CGFloat(frame.y) * layoutCellSize.height,
                    width: layoutCellSize.width,
                    height: CGFloat(frame.rows) * layoutCellSize.height
                )
            } else {
                CGRect(
                    x: CGFloat(frame.x) * layoutCellSize.width,
                    y: CGFloat(frame.y + frame.rows) * layoutCellSize.height,
                    width: CGFloat(frame.columns) * layoutCellSize.width,
                    height: layoutCellSize.height
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
            x: CGFloat(frame.x) * layoutCellSize.width,
            y: CGFloat(frame.y) * layoutCellSize.height,
            width: CGFloat(frame.columns) * layoutCellSize.width + surfaceOverhead.width / scale,
            height: CGFloat(frame.rows) * layoutCellSize.height + surfaceOverhead.height / scale
        )
    }

    private var lastReportedGrid: (Int, Int)?

    /// Answers whether this was news — a caller that has just changed the cell
    /// size needs to know whether a new layout is on its way or whether tmux
    /// has nothing to say.
    @discardableResult
    private func reportGridSize() -> Bool {
        // A view with no window has no honest grid to report. Its `bounds` are
        // whatever they were when it was last on screen and its `pixelScale`
        // is a guess, yet what comes out of here is sent to tmux and resizes
        // every window in a live session for every client attached to it.
        //
        // This is reachable, and the settings work is what made it so: a font
        // change runs `applySettings` on *every* session controller, on screen
        // or not, and libghostty's `synchronizeMetrics` does not check whether
        // its view is attached — only that the frame is non-empty. So an
        // off-screen session reports a grid derived from stale bounds. Nothing
        // is lost by staying quiet: the view reports from `layout()` the moment
        // it is put back in a window, which is the first point it knows its
        // real size.
        guard window != nil else { return false }
        let size = gridSize
        guard lastReportedGrid?.0 != size.columns || lastReportedGrid?.1 != size.rows else {
            return false
        }
        lastReportedGrid = (size.columns, size.rows)
        onGridSizeChange?(size.columns, size.rows)
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let theme = ChromeTheme.current
        // Must match the window's own background colour, alpha included. On
        // macOS 26 this view's backing layer runs 66pt past its bounds and
        // paints the *window's* colour in the overhang; the two agreeing is
        // what keeps that from being visible the moment a theme leaves the
        // system grey. Two different alphas over the same desktop are more
        // visible than two similar greys ever were, so this is now the tighter
        // of the two constraints rather than the looser.
        //
        // A tint over the material behind it, not a fill instead of it: the
        // surfaces are built with `withBackgroundOpacity(0)`, so what shows
        // between glyphs is this fill, and what shows through this fill is the
        // desktop. See `AppSettings.windowOpacity`.
        theme.background.withAlphaComponent(AppSettings.windowOpacity).setFill()
        dirtyRect.fill()

        theme.separator.setFill()
        for splitter in splitters {
            splitter.rect.insetBy(
                dx: splitter.isVertical ? layoutCellSize.width * 0.35 : 0,
                dy: splitter.isVertical ? 0 : layoutCellSize.height * 0.35
            ).fill()
        }

        // A one-pane window needs no focus ring; with several, the active one
        // has to be obvious at a glance or keystrokes go somewhere surprising.
        //
        // Quiet, because it is drawn around the thing being read. It was 2pt of
        // full accent, which on a scheme with a bright accent framed the pane
        // you were working in like a selection rather than marking it — and it
        // sat there being wrong, which is a lot of ink to spend on a lie. What
        // it marks now is tmux's own active pane, so it is at least true; a
        // hairline at partial alpha is enough to answer "which one am I in"
        // without competing with the text inside it.
        guard AppSettings.showsPaneFocusRing, let focusedPaneID,
              (layoutTree?.panes.count ?? 0) > 1,
              let frame = layoutTree?.panes.first(where: { $0.id == focusedPaneID })?.frame
        else { return }
        let path = NSBezierPath(rect: rect(for: frame).insetBy(dx: -0.5, dy: -0.5))
        theme.accent.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// The theme changed. Nothing here caches a colour, so a redraw is enough.
    func applyChromeTheme() {
        needsDisplay = true
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
            Int(round((point.x - splitter.rect.minX) / layoutCellSize.width)) + activeDrag.startCells
        } else {
            Int(round((point.y - splitter.rect.minY) / layoutCellSize.height)) + activeDrag.startCells
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
            let placed = layoutTree.map { tree in
                CGSize(
                    width: CGFloat(tree.frame.columns) * layoutCellSize.width
                        + surfaceOverhead.width / pixelScale,
                    height: CGFloat(tree.frame.rows) * layoutCellSize.height
                        + surfaceOverhead.height / pixelScale
                )
            }
            return DebugInspector.GridViewReport(
                boundsInPoints: DebugInspector.Rect(bounds),
                pixelScale: Double(pixelScale),
                cellSizeInPoints: DebugInspector.Size(cellSize),
                cellSizeInPixels: DebugInspector.Size(cellPixels),
                layoutCellSizeInPoints: DebugInspector.Size(layoutCellSize),
                layoutGrid: layoutTree.map {
                    DebugInspector.GridSize(columns: $0.frame.columns, rows: $0.frame.rows)
                },
                placedSizeInPoints: placed.map(DebugInspector.Size.init),
                overflowsBounds: placed.map {
                    $0.width > bounds.width + 0.5 || $0.height > bounds.height + 0.5
                } ?? false,
                measuredSurfaceOverheadInPixels: DebugInspector.Size(surfaceOverhead),
                computedGrid: DebugInspector.GridSize(columns: size.columns, rows: size.rows),
                splitterCount: splitters.count
            )
        }
    }

#endif
