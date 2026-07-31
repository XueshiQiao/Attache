//
//  WindowServerBlur.swift
//  Attache
//

import Cocoa

/// Blur the desktop behind a whole window, at a radius of one's choosing.
///
/// ## Why this is here rather than a `CALayer` filter
///
/// The first attempt used `CALayer.backgroundFilters` with a `CIGaussianBlur`,
/// which is public and does blur a layer's backdrop. It cannot do this job.
/// A backdrop filter is evaluated against what is behind *that layer*, and
/// every pane is a libghostty Metal layer composited separately above it — so
/// the desktop seen through a pane never passes through the filter. Reported
/// exactly that way after looking at it: the window's edges, the title band and
/// the rail changed with the radius and the middle of the window did not.
///
/// A `NSVisualEffectView` does not have that problem, because it *renders* a
/// blurred copy of the backdrop into its own content and everything above
/// composites over that normally — but its radius is fixed per material and
/// there is no API to change it. Adjustable and reaching under Metal is not a
/// combination the public API offers.
///
/// ## What this is
///
/// `CGSSetWindowBackgroundBlurRadius`, the window server's own. Private, in the
/// sense that it appears in no public header — but it is an ordinary exported
/// symbol of CoreGraphics, and it is what Ghostty's `background-blur = <n>`
/// calls: its binary imports `_CGSMainConnectionID`,
/// `_CGSSetWindowBackgroundBlurRadius` and `_CGSDefaultConnectionForThread`
/// from CoreGraphics directly. Checked against the shipped app rather than
/// assumed.
///
/// Resolved with `dlsym` rather than linked. Declaring it with
/// `@_silgen_name` and letting the linker bind it means an OS that ever drops
/// the symbol stops this app from launching at all; looked up at runtime, the
/// same OS costs the blur and nothing else.
///
/// Nothing about this is App Store safe. It is one call, it is isolated here,
/// and `WindowGlass` has two other styles that use nothing private.
@MainActor
enum WindowServerBlur {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetBlurRadius = @convention(c) (Int32, Int32, Int32) -> Int32

    /// Resolved once. `RTLD_DEFAULT` because CoreGraphics is already loaded
    /// into every AppKit process — there is nothing to open.
    private static let entryPoints: (connection: MainConnectionID, setRadius: SetBlurRadius)? = {
        guard let connectionSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID"),
              let radiusSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetWindowBackgroundBlurRadius")
        else {
            TmuxLog.lifecycle(
                "the window server's blur is not available on this system;"
                    + " the Blur style will show no blur"
            )
            return nil
        }
        return (
            unsafeBitCast(connectionSymbol, to: MainConnectionID.self),
            unsafeBitCast(radiusSymbol, to: SetBlurRadius.self)
        )
    }()

    static var isAvailable: Bool { entryPoints != nil }

    /// Ask for `radius`, or 0 to take the blur off again.
    ///
    /// Always call it, including with 0: the radius lives on the window in the
    /// window server, not in this process, so a style switched away from leaves
    /// its blur behind until something says otherwise.
    static func apply(radius: CGFloat, to window: NSWindow) {
        guard let entryPoints else { return }
        _ = entryPoints.setRadius(
            entryPoints.connection(),
            Int32(window.windowNumber),
            Int32(max(0, radius.rounded()))
        )
    }
}
