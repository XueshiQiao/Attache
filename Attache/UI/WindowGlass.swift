//
//  WindowGlass.swift
//  Attache
//

import Cocoa

/// How the window is made to show what is behind it, in one place.
///
/// The window is not opaque, the window server blurs the desktop behind it at
/// whatever radius is asked for, and each half paints the theme colour over the
/// result. `WindowServerBlur` holds the call and the reason it is not the
/// obvious `CALayer.backgroundFilters` gaussian: a backdrop filter cannot reach
/// under the panes' Metal layers.
///
/// This used to be a choice of three. The other two were `NSGlassEffectView`
/// (macOS 26's Liquid Glass) and `NSVisualEffectView` (the classic frosted
/// materials), and both were removed once this one was settled on — a blur
/// radius the user can actually turn is the thing neither of the system
/// effects will give up, and carrying three mechanisms meant every drawing
/// site had to ask which one was live before it knew whether to paint at all.
///
/// It still exists as a type rather than as two properties because the two
/// halves have to agree, and the arithmetic that keeps them agreeing —
/// `railFillAlpha`, which corrects for the coat the window has already put
/// down — belongs somewhere both of them read from.
@MainActor
enum WindowGlass {
    /// Everything the window and its two halves need, already resolved.
    struct Resolved {
        /// What the window's `backgroundColor` is set to, which is the colour
        /// the content half ends up showing: nothing in that half paints, so
        /// this is its one and only coat.
        let paneFill: NSColor
        /// What the rail fills: `ChromeTheme.railCoat(depth:)` at the alpha a
        /// *second* coat needs so the pair lands on
        /// `min(1, windowOpacity + railExtraOpacity)` — see
        /// `AppSettings.railFillAlpha`. Deeper than `paneFill` by
        /// `AppSettings.railExtraOpacity`, which since the divider line went
        /// away is the only thing marking where one half ends.
        let railFill: NSColor
        /// Radius for the backdrop blur, or 0 for none.
        let blurRadius: CGFloat
    }

    static func resolved() -> Resolved {
        let theme = ChromeTheme.current
        return Resolved(
            paneFill: theme.background.withAlphaComponent(AppSettings.windowOpacity),
            // Two quantities, and they are separate on purpose. The alpha is
            // not `min(1, windowOpacity + railExtraOpacity)`: the rail is
            // painted on top of `paneFill`, so it has to be the alpha that
            // lands the *pair* of coats on that total — using the total itself
            // is the double-coat defect, where the rail squared how much
            // backdrop it let through while the panes only halved it. The
            // colour is a ramp rather than `railBackground`, because the alpha
            // saturates at a fully opaque window and a fixed colour would make
            // the slider an on/off switch there.
            railFill: theme.railCoat(depth: AppSettings.railCoatDepth)
                .withAlphaComponent(AppSettings.railFillAlpha),
            blurRadius: AppSettings.blurRadius
        )
    }
}

/// The split view with the line between the halves taken out.
///
/// A divider says where one half ends when both are the same colour. These two
/// are not — the rail carries a deeper tint, and over a blurred desktop that
/// boundary is already the clearest edge in the window. The line on top of it
/// read as a seam in a single sheet of glass.
///
/// Subclassing is the documented way to change a divider's colour, and this one
/// is applied to the split view `NSSplitViewController` already made rather
/// than by supplying one: a split view built here and handed over comes up
/// **completely blank**, because the controller wires the one it creates in
/// ways that setting `delegate` does not reproduce. Re-classing the instance is
/// safe only because this subclass adds no stored properties, and only because
/// the instance really is a plain `NSSplitView` — checked at runtime before
/// this was written, and checked again on every launch below.
///
/// A clear divider is not the same thing as no divider, and the difference is
/// visible. `dividerColor` only stops AppKit painting the strip; the strip is
/// still there, one point wide, and *nobody* paints it — so it shows the bare
/// window backdrop between two halves that each carry this app's tint. That is
/// a third tone in a window whose whole point is that it has two, and on a 2x
/// display it reads as exactly the two-pixel line it is. Measured on this
/// machine, 2026-07-28: `.thin` is `dividerThickness == 1.0`pt, `dividerColor`
/// is gray 0 at alpha 0, backing scale 2. (The halves carried a system material
/// as well when that was measured; the strip is a third tone either way,
/// because what shows through it is the unpainted window.)
///
/// So the thickness goes to zero and the halves become adjacent. This is a
/// geometric fix rather than a colour one, which matters because no colour
/// could have worked: what the neighbours show is the blurred desktop under a
/// tint, and a flat fill over the strip would have been a third tone too, just
/// a closer one.
///
/// `dividerThickness` was previously left alone on the grounds that shrinking
/// it costs the drag target. It does — and `NSSplitViewDelegate`'s
/// `splitView(_:effectiveRect:forDrawnRect:ofDividerAt:)` exists for precisely
/// this case, which is where the drag comes back. `MainViewController`
/// implements it. Verified headlessly before this was written: with the
/// thickness at 0 the two arranged subviews meet at exactly the same x, and
/// the delegate is still consulted with a zero-width drawn rect, so the widened
/// hit area is live.
final class SeamlessSplitView: NSSplitView {
    override var dividerColor: NSColor { .clear }
    override var dividerThickness: CGFloat { 0 }
}
