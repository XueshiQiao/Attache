//
//  ContentHalfView.swift
//  Attache
//

import Cocoa

/// The content half's root view, and the one thing on this side of the window
/// that drags it.
///
/// Everything drawn over it — the pane grid, the panes — answers no, because a
/// press there belongs to a splitter or to a selection. What is left is the
/// strip behind `TitleBandView`, which is transparent to hit tests, so the
/// press lands here.
///
/// Written down rather than inherited. This view was a plain `NSView` and got
/// the same unwritten default that made pane splitters undraggable: AppKit
/// asks the hit view `mouseDownCanMoveWindow` and non-opaque views say yes. The
/// band carried an override of its own that had never once been consulted. One
/// accident was holding up the feature and the other was the bug, and they were
/// the same accident.
/// Not private: both content halves are this view. `EmbeddedEmbeddedSessionViewController`
/// is the other one, and the answer above is exactly as load-bearing there.
final class ContentHalfView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    /// **Nothing is painted here, and that is the fix rather than the bug.**
    ///
    /// This used to fill the strip `gridLeftInset` holds open with `paneFill`,
    /// on the reasoning that a region painted by nobody would sit at the
    /// window's own alpha while the panes reached `1-(1-a)²` beside it. That
    /// was true when it was written and is not true now — the translucency the
    /// window is built from moved into `WindowGlass` since.
    ///
    /// Measured on the running app, 2026-07-29, sampling across the boundary:
    ///
    ///     fill                 gutter            panes
    ///     paneFill        rgb(63, 66, 75)   rgb(82, 85, 92)
    ///     paneFill doubled rgb(53, 56, 66)   rgb(82, 85, 92)
    ///     opaque theme    rgb(42, 46, 56)   rgb(82, 85, 92)
    ///     nothing         rgb(82, 85, 92)   rgb(82, 85, 92)
    ///
    /// Every coat made it darker, which is the opposite of what the old
    /// arithmetic predicts, and the unpainted strip matches the panes exactly.
    /// So the fill was the seam: a band agreeing with neither half, eight
    /// points wide, down the whole window.
    ///
    /// Not drawing at all is also the safer shape. A view that draws gets a
    /// backing layer 66pt taller than itself on macOS 26 and the overhang is
    /// not clipped — see CLAUDE.md — so a view with no `draw` has one less way
    /// to go wrong.
}
