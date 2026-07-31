//
//  ToastView.swift
//  Attache
//

import Cocoa

/// One notice, drawn in the rail's own vocabulary — Option A of the design
/// note, chosen because it adds no new visual language: 6 pt radius, 12 pt
/// semibold title, 10.5 pt secondary line, and severity as a 2 pt accent edge
/// are all measurements the sidebar rows already put on screen.
///
/// Dark glass regardless of the window's theme, like the design's mockup: a
/// toast floats over terminal content whose colours the app does not control,
/// and a fixed dark surface is the only one that is legible over all of them.
final class ToastView: NSView {
    /// Fixed, from the design mockup's stack. Height depends on the body text.
    static let width: CGFloat = 316

    var onDismiss: (() -> Void)?

    private static let titleColor = NSColor(srgbRed: 0.925, green: 0.922, blue: 0.906, alpha: 1)
    private static let bodyColor = NSColor(srgbRed: 0.663, green: 0.690, blue: 0.729, alpha: 1)

    private static func edgeColor(for severity: AppNotice.Severity) -> NSColor {
        switch severity {
        case .info: NSColor(srgbRed: 0.427, green: 0.561, blue: 0.710, alpha: 1) // #6d8fb5
        case .warning: NSColor(srgbRed: 0.851, green: 0.635, blue: 0.290, alpha: 1) // #d9a24a
        case .error: NSColor(srgbRed: 0.820, green: 0.408, blue: 0.361, alpha: 1) // #d1685c
        }
    }

    // Mockup metrics: padding 8/11/9/10, edge 2 wide, 9 gap to text, 2 between
    // title and body.
    private static let paddingTop: CGFloat = 8
    private static let paddingBottom: CGFloat = 9
    private static let paddingLeading: CGFloat = 10
    private static let paddingTrailing: CGFloat = 11
    private static let edgeWidth: CGFloat = 2
    private static let edgeGap: CGFloat = 9
    private static let titleBodyGap: CGFloat = 2

    private static var textWidth: CGFloat {
        width - paddingLeading - edgeWidth - edgeGap - paddingTrailing
    }

    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let bodyFont = NSFont.systemFont(ofSize: 10.5)

    override var isFlipped: Bool { true }

    init(notice: AppNotice) {
        // Measured by the fields that will draw them, at the exact width they
        // will draw at — never by `boundingRect`. The first version measured
        // with `boundingRect` and the two disagreed about where lines break:
        // an `NSTextField` wraps a few points earlier than the raw string
        // measure predicts, so a body measured at 2.6 lines was given a
        // 2.6-line frame, drew two complete lines, and clipped the third —
        // which happened to carry the duration, the one number the notice
        // exists to deliver. Seen on screen 2026-07-30. The card is sized to
        // whatever the fields answer, so nothing can be dropped, today or the
        // first time somebody writes a longer message.
        let title = Self.label(notice.title, font: Self.titleFont, color: Self.titleColor)
        let body = Self.label(notice.body, font: Self.bodyFont, color: Self.bodyColor)
        let titleHeight = Self.measuredHeight(of: title)
        let bodyHeight = Self.measuredHeight(of: body)
        let height = Self.paddingTop + titleHeight + Self.titleBodyGap
            + bodyHeight + Self.paddingBottom
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))

        wantsLayer = true
        // Shadow on this wrapper; the glass below masks to its corners, and a
        // layer that masks cannot also cast.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.34
        layer?.shadowRadius = 11
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.masksToBounds = false

        let glass = NSVisualEffectView(frame: bounds)
        glass.autoresizingMask = [.width, .height]
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        // Not `.followsWindowActiveState` — a notice about the app losing
        // input is exactly the one that must not grey out when it does.
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 6
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        addSubview(glass)

        let edge = NSView(frame: NSRect(
            x: Self.paddingLeading, y: Self.paddingTop,
            width: Self.edgeWidth, height: height - Self.paddingTop - Self.paddingBottom
        ))
        edge.wantsLayer = true
        edge.layer?.backgroundColor = Self.edgeColor(for: notice.severity).cgColor
        edge.layer?.cornerRadius = 1
        addSubview(edge)

        let textX = Self.paddingLeading + Self.edgeWidth + Self.edgeGap
        title.frame = NSRect(x: textX, y: Self.paddingTop, width: Self.textWidth, height: titleHeight)
        addSubview(title)
        body.frame = NSRect(
            x: textX, y: Self.paddingTop + titleHeight + Self.titleBodyGap,
            width: Self.textWidth, height: bodyHeight
        )
        addSubview(body)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// A click anywhere on the toast dismisses it. `mouseDown` rather than a
    /// gesture recogniser for the same reason the rest of this app tracks
    /// presses itself: synthesised test events carry `clickCount == 0` and a
    /// recogniser never fires for them.
    override func mouseDown(with _: NSEvent) {
        onDismiss?()
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        return label
    }

    /// The field's own answer for "how tall at this width" — `cellSize(forBounds:)`
    /// wraps exactly where the field will wrap, which a raw string measure
    /// does not. See the note in `init`.
    private static func measuredHeight(of label: NSTextField) -> CGFloat {
        let size = label.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude
        )) ?? .zero
        return ceil(size.height)
    }
}
