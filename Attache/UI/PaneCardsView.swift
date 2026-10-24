//
//  PaneCardsView.swift
//  Attache
//

import Cocoa

/// One rounded card under each tmux pane, so the window reads as separate
/// panels with the desktop showing between them.
///
/// tmux still draws every pane; this view sits *under* the terminal surface,
/// whose background is fully transparent, and fills in behind the cells that
/// carry the default background. A cell a program gave a colour of its own is
/// opaque and covers the card, which is why htop's header bar sits on top of
/// it rather than inside it.
///
/// The gaps between cards are tmux's own divider cells, blanked by
/// `pane-border-lines spaces` (see `TmuxSessionConnection.blankPaneBorders`).
/// Nothing here decides where a pane is: every rectangle comes from the
/// window's visible layout, so a zoom, a split or a resize typed into a plain
/// `tmux attach` moves the cards the same way.
///
/// Not right with `pane-border-status` on, and that is a known gap rather than
/// an oversight: tmux then puts each pane a row lower than the layout string
/// says — measured on 3.6a, `window_visible_layout` is byte-identical with the
/// option on and off while the top pane's `pane_top` goes from 0 to 1. The
/// cards were designed with the title rows off, which is what this option's
/// owner chose after trying them.
///
/// Layers, not `draw(_:)`. A view that draws gets a backing layer 66pt taller
/// than itself on macOS 26 and the overhang is not clipped (CLAUDE.md), and
/// this view sits directly under the terminal it would overdraw.
final class PaneCardsView: NSView {
    struct Card: Equatable {
        var rect: CGRect
        var isActive: Bool
        /// How far along each edge the corner curve starts. See `cornerSpan`.
        var cornerSpan: CGFloat
    }

    /// How far a card reaches past its pane's cells, left and right, and down
    /// onto the status line. A divider column is one cell wide, so two of these
    /// out of it leave the visible gap; there is no room for more without
    /// covering a neighbour's text.
    static let horizontalReach: CGFloat = 2
    /// The gap between two cards stacked one above the other. The divider row
    /// is a whole cell tall, so what is left of it after this goes to the two
    /// cards as padding, half each.
    static let verticalGap: CGFloat = 4.5
    /// The gap between the outermost cards and the window's edge. Wider than
    /// the 4.5pt between cards on purpose: the owner asked for the frame to
    /// breathe while the gaps between panes stay as they are, after an HTML
    /// round (2026-10-24) where widening only the stacked gap read as odd.
    ///
    /// The padding on the window's side of an outer card is the same as on
    /// its other sides — `horizontalReach` sideways, the divider padding up
    /// and down — even though that margin is the app's and could be anything.
    /// A larger one was tried first and every edge pane came out lopsided,
    /// 7pt of padding on the window's side and 2pt on its neighbour's; the
    /// neighbour's side cannot grow, so the window's side matches it.
    static let outerGap: CGFloat = 9

    /// The padding above and below a card's text: half of what a divider row
    /// leaves after the gap. Used on the window's side too, so every card's
    /// text sits the same distance from its top and bottom edges.
    static func verticalPadding(cellHeight: CGFloat) -> CGFloat {
        max(0, (cellHeight - verticalGap) / 2)
    }

    /// The corner shape: a superellipse quadrant, |x|ⁿ + |y|ⁿ = 1, joined to
    /// the straight edges with no jump in curvature — the "continuous" corner
    /// of macOS windows and icons. A circular corner bends at full curvature
    /// the instant the straight edge ends, which reads as hard; this one
    /// starts bending well before and eases into it. It is drawn as a path
    /// here, rather than with `cornerCurve = .continuous`, because the shadow
    /// and its cutout have to be the exact same shape as the card or the
    /// shadow shows through at the corners, and `CGPath` has no continuous
    /// rounded rectangle of its own.
    static let cornerExponent: CGFloat = 4
    /// The span the corner is drawn at when nothing limits it — roughly the
    /// look of a 12pt circular corner.
    static let preferredCornerSpan: CGFloat = 18

    /// The largest corner that still covers a square cell inset by `dx`, `dy`.
    ///
    /// A cell a program gave its own background is opaque and square, it sits
    /// on top of the card, and nothing can clip it — a layer mask does not
    /// contain what libghostty draws. So the cell's corner has to fall inside
    /// the curve: with the curve's centre at (s, s), that is
    /// ((s − dx)/s)ⁿ + ((s − dy)/s)ⁿ ≤ 1. A 9pt circular corner at a 2pt reach
    /// failed exactly this — a coding agent's dark input bar stuck its square
    /// corner out through the curve, reported from a screenshot.
    static func cornerSpan(coveringInset dx: CGFloat, _ dy: CGFloat) -> CGFloat {
        let n = cornerExponent
        func covers(_ s: CGFloat) -> Bool {
            guard s > max(dx, dy) else { return true }
            return pow((s - dx) / s, n) + pow((s - dy) / s, n) <= 1
        }
        var low: CGFloat = 0, high: CGFloat = 200
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if covers(mid) { low = mid } else { high = mid }
        }
        return low
    }

    /// A rounded rectangle with `cornerExponent` corners spanning `span`.
    static func cardPath(_ rect: CGRect, span: CGFloat) -> CGPath {
        let s = max(0, min(span, rect.width / 2, rect.height / 2))
        let path = CGMutablePath()
        guard s > 0 else {
            path.addRect(rect)
            return path
        }
        let steps = 24
        let exponent = 2 / cornerExponent
        // Corner centres, each with the signs that point from it to the
        // corner, walked clockwise in a flipped (y-down) space: top-left,
        // top-right, bottom-right, bottom-left.
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX + s, y: rect.minY + s), -1, -1),
            (CGPoint(x: rect.maxX - s, y: rect.minY + s), 1, -1),
            (CGPoint(x: rect.maxX - s, y: rect.maxY - s), 1, 1),
            (CGPoint(x: rect.minX + s, y: rect.maxY - s), -1, 1),
        ]
        for (index, (center, sx, sy)) in corners.enumerated() {
            for step in 0...steps {
                // Each corner runs from the edge it arrives on to the edge it
                // leaves on: top-left from the left edge to the top, and so on
                // round, so the angle direction alternates with the corner.
                var t = CGFloat(step) / CGFloat(steps) * .pi / 2
                if index % 2 == 1 { t = .pi / 2 - t }
                let cx = pow(cos(t), exponent), cy = pow(sin(t), exponent)
                let point = CGPoint(x: center.x + sx * s * cx, y: center.y + sy * s * cy)
                if index == 0 && step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        path.closeSubpath()
        return path
    }

    private var cards: [Card] = []
    private var cardLayers: [CAShapeLayer] = []
    private var shadowLayers: [CALayer] = []
    /// Every shadow lives in here, under every card, with one mask that cuts
    /// out all the cards at once. A mask per shadow cutting out only its own
    /// card was the first version, and a 4.5pt gap is nothing to a shadow
    /// that spreads 20pt: each card's shadow crossed the gap and greyed its
    /// neighbour's near edge through the neighbour's translucent fill.
    private let shadowContainer = CALayer()
    private let shadowMask = CAShapeLayer()
    private let fillContainer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shadowMask.fillRule = .evenOdd
        shadowContainer.mask = shadowMask
        layer?.addSublayer(shadowContainer)
        layer?.addSublayer(fillContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Clicks go through to whatever is underneath or beside: the terminal,
    /// where tmux decides what a press on a pane or a divider means, or the
    /// content half, which drags the window.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The cards for one window, in this view's coordinates.
    ///
    /// `gridOrigin` is the top-left corner of the window's first cell.
    /// `rightEdge` and `bottomEdge` are where the terminal view itself ends:
    /// the grid is a whole number of cells and the view is not, so up to a
    /// cell's worth of view is left over past the last column and row. A card
    /// on that side is carried out to the view's edge, so the gap from it to
    /// the window's edge is exactly `outerGap` rather than that plus whatever
    /// the window's size happened to leave over. `paneAreaBottom` is the
    /// lowest a pane can reach on screen, status line excluded. `bottomEdge` is
    /// nil when a status line is under the grid; the last row's cards stop
    /// just short of it instead. Pure, so the arithmetic can be checked
    /// without a window.
    static func cards(
        layout: TmuxLayoutNode,
        activePaneID: String?,
        cell: CGSize,
        gridOrigin: CGPoint,
        rightEdge: CGFloat,
        bottomEdge: CGFloat?,
        paneAreaBottom: CGFloat,
        statusAbove: Bool
    ) -> [Card] {
        guard cell.width > 0, cell.height > 0 else { return [] }
        let window = layout.frame
        let dividerPadding = verticalPadding(cellHeight: cell.height)
        // One corner for every card, sized by the tightest corner any card
        // has: sideways it is always the 2pt reach, and up or down it is the
        // divider padding — on the window's side too — or, where a status line
        // sits hard against the grid, only the sideways reach.
        let topReach = statusAbove ? horizontalReach : dividerPadding
        let bottomReach = bottomEdge == nil ? horizontalReach : dividerPadding
        let tightestVertical = min(dividerPadding, topReach, bottomReach)
        let span = min(
            preferredCornerSpan,
            cornerSpan(coveringInset: horizontalReach, tightestVertical)
        )
        return layout.panes.compactMap { pane in
            let f = pane.frame
            let x = CGFloat(f.x - window.x), y = CGFloat(f.y - window.y)
            let atRight = f.x + f.columns >= window.x + window.columns
            let atBottom = f.y + f.rows >= window.y + window.rows
            let minX = gridOrigin.x + x * cell.width - horizontalReach
            let lastColumn = gridOrigin.x + (x + CGFloat(f.columns)) * cell.width
            // Every card stops at the view's edge plus its reach, not only the
            // edge column: in the frame before tmux catches up with a sudden
            // shrink, a left-hand pane can still be wider than the whole view.
            let maxX = min(
                atRight ? toViewEdge(lastColumn, rightEdge, cell.width) : lastColumn,
                rightEdge
            ) + horizontalReach
            // A pane below another one starts after the divider row; a pane at
            // the top reaches up into the margin the terminal is inset by, or
            // only a little into a status line that sits there instead.
            let top = f.y > window.y ? dividerPadding : topReach
            let lastRow = gridOrigin.y + (y + CGFloat(f.rows)) * cell.height
            var maxY = !atBottom ? lastRow + dividerPadding
                : bottomEdge.map { toViewEdge(lastRow, $0, cell.height) + bottomReach }
                    ?? lastRow + horizontalReach
            // `paneAreaBottom` is where panes can end at all — the view's edge,
            // or the top of a status line under the grid. A card is held to it
            // whether or not a status line is there, so the frame before tmux
            // catches up with a shrink cannot run a card over the status line.
            maxY = min(maxY, paneAreaBottom + bottomReach)
            let minY = gridOrigin.y + y * cell.height - top
            // A grid tmux has not shrunk yet can start a pane past the view's
            // edge; there is nothing of it on screen to put a card under, and a
            // sliver of card in the margin would be worse than none.
            guard minX + horizontalReach < rightEdge, maxX > minX, maxY > minY,
                  minY + top < paneAreaBottom
            else { return nil }
            return Card(
                rect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                isActive: pane.id == activePaneID,
                cornerSpan: span
            )
        }
    }

    /// Where an edge card ends, given where the grid ends and where the view
    /// does.
    ///
    /// Less than a cell of view past the grid is the rounding leftover, and the
    /// card takes it. A grid *past* the view — tmux has not caught up with a
    /// resize yet, or turning cards on just pulled the view in — is clipped by
    /// the view, so the card stops at the view's edge too rather than running
    /// across the margin. A whole cell or more of view past the grid is tmux
    /// drawing a window smaller than this client (another, smaller client sets
    /// the size), and that area is tmux's filler, not the pane's.
    private static func toViewEdge(_ grid: CGFloat, _ view: CGFloat, _ cell: CGFloat) -> CGFloat {
        if grid > view { return view }
        return view - grid < cell ? view : grid
    }

    override func layout() {
        super.layout()
        // The containers and the mask's outer rectangle are sized to the view,
        // and a resize that moves no card would otherwise leave them at the
        // old size.
        if shadowMask.frame != bounds { rebuild() }
    }

    func show(_ newCards: [Card]) {
        guard newCards != cards else { return }
        cards = newCards
        rebuild()
    }

    func applyChromeTheme() {
        rebuild()
    }

    private func rebuild() {
        guard let root = layer else { return }
        CATransaction.begin()
        // A card follows tmux's layout, and tmux's redraw of the cells arrives
        // on its own pipe with no animation; a card that eased into place
        // would lag the text it is behind.
        CATransaction.setDisableActions(true)
        shadowContainer.frame = root.bounds
        fillContainer.frame = root.bounds
        while cardLayers.count < cards.count {
            let shadow = CALayer()
            shadow.shadowColor = NSColor.black.cgColor
            // A shape layer, so the fill, the shadow and the cutout under it
            // are all one path — see `cornerExponent`.
            let fill = CAShapeLayer()
            shadowContainer.addSublayer(shadow)
            fillContainer.addSublayer(fill)
            shadowLayers.append(shadow)
            cardLayers.append(fill)
        }
        while cardLayers.count > cards.count {
            cardLayers.removeLast().removeFromSuperlayer()
            shadowLayers.removeLast().removeFromSuperlayer()
        }
        let style = Style(ChromeTheme.current)
        let cutout = CGMutablePath()
        cutout.addRect(root.bounds)
        for ((card, fill), shadow) in zip(zip(cards, cardLayers), shadowLayers) {
            let shape = Self.cardPath(
                CGRect(origin: .zero, size: card.rect.size), span: card.cornerSpan
            )
            fill.frame = card.rect
            fill.path = shape
            fill.fillColor = (card.isActive ? style.activeFill : style.fill).cgColor

            shadow.frame = card.rect
            shadow.shadowPath = shape
            shadow.shadowOpacity = card.isActive ? style.activeShadowOpacity : style.shadowOpacity
            shadow.shadowRadius = card.isActive ? 9 : 6
            shadow.shadowOffset = Self.shadowOffset(in: root, active: card.isActive)
            cutout.addPath(shape, transform: CGAffineTransform(
                translationX: card.rect.minX, y: card.rect.minY
            ))
        }
        // Cards never overlap, so even-odd leaves exactly the space between
        // and around them: the shadows show in the gaps and nowhere else.
        shadowMask.frame = root.bounds
        shadowMask.path = cutout
        CATransaction.commit()
    }

    /// Down and to the right, as from a light up and to the left.
    ///
    /// Which sign is "down" depends on whether AppKit flipped this view's
    /// backing layer, so it is asked rather than assumed.
    private static func shadowOffset(in root: CALayer, active: Bool) -> CGSize {
        let down: CGFloat = active ? 3 : 2
        return CGSize(width: active ? 2 : 1.5, height: root.contentsAreFlipped() ? down : -down)
    }

    /// The card colours, from the chrome theme so they follow the scheme and
    /// the light/dark switch with everything else.
    ///
    /// A card is a second coat over the window's own tint, so its alpha is how
    /// much *more* of the backdrop it hides, not a total: at a 55% window tint,
    /// 72% here leaves an inactive card at about 87% and 82% an active one at
    /// about 92%, while the gaps stay at the window's 55%. On a light scheme
    /// the colour is lifted most of the way to white: bright, nearly solid
    /// sheets on the glass, the look of the app the design came from. Three
    /// rounds got here — lifted and 82/93% read as heavy on the active pane,
    /// the plain window colour at 69/75% read as grey over a dark wallpaper —
    /// and the rule that held throughout is that the active pane is only a few
    /// points more solid than the rest.
    ///
    /// No outline. The edge is the shadow's, and the active pane is told apart
    /// by its alpha and a deeper shadow — a coloured ring was tried first and
    /// read as a heavy black frame on a light scheme.
    private struct Style {
        let fill: NSColor
        let activeFill: NSColor
        let shadowOpacity: Float
        let activeShadowOpacity: Float

        init(_ theme: ChromeTheme) {
            // Light or dark by the same test the chrome's own text uses
            // (`ChromeTheme.systemInk`), so the rail and the cards never take
            // opposite sides on a mid-grey scheme.
            let isLight = ChromeTheme.lightness(of: theme.background) >= 50
            // Mixed by hand in sRGB rather than with `blended(withFraction:)`:
            // that converts to a calibrated space and can answer nil, and a
            // colour that is not RGB at all would throw on `redComponent`.
            let lift: CGFloat = isLight ? 0.6 : 0.06
            let sheet: NSColor
            if let rgb = theme.background.usingColorSpace(.sRGB) {
                sheet = NSColor(
                    srgbRed: rgb.redComponent + (1 - rgb.redComponent) * lift,
                    green: rgb.greenComponent + (1 - rgb.greenComponent) * lift,
                    blue: rgb.blueComponent + (1 - rgb.blueComponent) * lift,
                    alpha: 1
                )
            } else {
                sheet = theme.background
            }
            fill = sheet.withAlphaComponent(isLight ? 0.72 : 0.45)
            activeFill = sheet.withAlphaComponent(isLight ? 0.82 : 0.6)
            // A dark scheme has little room below its background for a shadow
            // to show in, so it gets a heavier one to read at all.
            shadowOpacity = isLight ? 0.08 : 0.3
            activeShadowOpacity = isLight ? 0.14 : 0.4
        }
    }
}
