//
//  WindowGlass.swift
//  TmuxGUI
//

import Cocoa

/// How the window is made to show what is behind it, in one place.
///
/// There are three ways to do this on macOS and they are not variations on each
/// other — they put the transparency, the blur and the colour in different
/// places, and a drawing site that guessed would double one of them:
///
/// - **`.blur`** is this app's own. The window is not opaque, a `CIGaussianBlur`
///   on the content view's layer blurs the desktop behind it at whatever radius
///   is asked for, and each half paints the theme colour over the result. It is
///   the only one of the three where the blur is a number the user can turn.
/// - **`.liquidGlass`** is macOS 26's `NSGlassEffectView`, which is what Ghostty
///   calls `macos-glass-regular` and `macos-glass-clear`. The glass does the
///   blurring *and* the tinting — it takes a `tintColor` — so the halves must
///   paint nothing at all or the colour lands twice.
/// - **`.material`** is the classic `NSVisualEffectView`. Its blur is whatever
///   Apple chose for the material and cannot be changed; its opacity is most of
///   the window's and no tint on top can reduce it. Kept because it is the only
///   one that looks like the rest of the system.
///
/// Every drawing site asks this type what colour to use and gets `.clear` when
/// the answer is "something else is already doing it". That is the whole reason
/// this exists rather than three `if` statements in three files.
@MainActor
enum WindowGlass {
    /// Everything the window and its two halves need, already resolved.
    struct Resolved {
        /// What `PaneGridView` fills, and what the window's background colour
        /// must match — see the 66pt overhang note at that fill.
        let paneFill: NSColor
        /// What the rail fills. Deeper than `paneFill` by
        /// `AppSettings.railExtraTint`, which since the divider line went away
        /// is the only thing marking where one half ends.
        let railFill: NSColor
        /// Radius for the backdrop blur, or 0 for none.
        let blurRadius: CGFloat
        /// What to install behind each half, or nil to install nothing.
        let paneEffect: Effect?
        let railEffect: Effect?
    }

    /// A view to put behind a half, described rather than built, so the
    /// decision and the AppKit calls stay apart.
    enum Effect: Equatable {
        case material(NSVisualEffectView.Material, alpha: CGFloat, blurs: Bool)
        /// `style` is carried as the raw value so this type still compiles
        /// against an SDK without `NSGlassEffectView`.
        case liquid(clear: Bool, tint: NSColor)
    }

    static func resolved() -> Resolved {
        let theme = ChromeTheme.current
        let opacity = AppSettings.windowOpacity
        let railOpacity = min(1, opacity + AppSettings.railExtraTint)

        switch AppSettings.glassStyle {
        case .blur:
            return Resolved(
                paneFill: theme.background.withAlphaComponent(opacity),
                railFill: theme.railBackground.withAlphaComponent(railOpacity),
                blurRadius: AppSettings.blurRadius,
                paneEffect: nil,
                railEffect: nil
            )

        case .liquidGlass:
            // Nothing is painted by the halves. `NSGlassEffectView` tints the
            // backdrop *and* the glass toward its `tintColor`; a fill on top of
            // that is the same colour applied twice, which is how a "clear"
            // glass ends up looking like the solid window it was meant to
            // replace.
            let clear = AppSettings.liquidGlassIsClear
            return Resolved(
                paneFill: .clear,
                railFill: .clear,
                blurRadius: 0,
                paneEffect: .liquid(clear: clear, tint: theme.background.withAlphaComponent(opacity)),
                railEffect: .liquid(clear: clear, tint: theme.railBackground.withAlphaComponent(railOpacity))
            )

        case .material:
            let material = Self.material(for: AppSettings.chromeMaterial)
            let effect = material.map {
                Effect.material($0, alpha: AppSettings.frostiness, blurs: AppSettings.backgroundBlur)
            }
            return Resolved(
                paneFill: theme.background.withAlphaComponent(opacity),
                railFill: theme.railBackground.withAlphaComponent(railOpacity),
                blurRadius: 0,
                paneEffect: effect,
                railEffect: effect
            )
        }
    }

    private static func material(
        for choice: AppSettings.ChromeMaterial
    ) -> NSVisualEffectView.Material? {
        switch choice {
        case .none: nil
        case .underWindowBackground: .underWindowBackground
        case .windowBackground: .windowBackground
        case .sidebar: .sidebar
        case .menu: .menu
        case .popover: .popover
        case .hudWindow: .hudWindow
        case .fullScreenUI: .fullScreenUI
        }
    }
}

/// The view each half puts behind its content, whatever the style is.
///
/// Holds at most one effect view and swaps it when the style changes, so
/// switching between the three is a live change rather than a relaunch — which
/// matters because the only way to choose between them is to look at all three.
@MainActor
final class GlassBackdropView: NSView {
    private var installed: WindowGlass.Effect?
    private var effectView: NSView?

    func apply(_ effect: WindowGlass.Effect?) {
        guard effect != installed else { return }
        installed = effect
        effectView?.removeFromSuperview()
        effectView = nil

        guard let effect else { return }
        let view: NSView
        switch effect {
        case .material(let material, let alpha, let blurs):
            let visual = NSVisualEffectView()
            visual.material = material
            visual.blendingMode = blurs ? .behindWindow : .withinWindow
            // `.followsWindowActiveState` is the default and is wrong here: it
            // desaturates whenever the window is not key, which on a terminal
            // reads as the panes greying out every time you look elsewhere.
            visual.state = .active
            visual.alphaValue = alpha
            view = visual

        case .liquid(let clear, let tint):
            guard #available(macOS 26.0, *) else { return }
            let glass = NSGlassEffectView()
            glass.style = clear ? .clear : .regular
            glass.tintColor = tint
            // Square, because these fill a half of the window rather than
            // floating in it. The rounded default is for a control.
            glass.cornerRadius = 0
            view = glass
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        effectView = view
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
/// `dividerThickness` is deliberately left alone. The drag target has to stay
/// where it was, or a rail that can no longer be resized is the price of a
/// cosmetic change.
final class SeamlessSplitView: NSSplitView {
    override var dividerColor: NSColor { .clear }
}
