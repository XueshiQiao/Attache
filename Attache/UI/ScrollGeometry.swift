//
//  ScrollGeometry.swift
//  Attache
//

import AppKit

/// Geometry the conversation rail needs, kept apart from the views that use it.
///
/// **Its own file so it can be checked, and it needs checking.** These are one
/// or two lines each and every one of them is a coordinate-system question
/// whose wrong answer still produces plausible-looking motion on screen. The
/// sticky header shipped with the wrong one — it followed each turn's bottom
/// edge instead of its top — and the symptom was a header that lagged by a
/// whole turn, which reads as "the feature is a bit sluggish" rather than as a
/// bug. `Tools/StickyOffsetCheck` is the table.
///
/// Nothing here touches a theme, a setting or a view's contents, which is what
/// lets the check tool compile it on its own.
enum ScrollGeometry {

    /// Where a row's **top** sits in a scroll view's document coordinates.
    ///
    /// **Converting `bounds.origin` gives the bottom, not the top, and the two
    /// differ by the whole height of the row.** A document view that lays
    /// content out downward is flipped; an ordinary row inside it is not, so
    /// the row's own origin is its lower-left corner. Converting that point
    /// lands on the row's bottom edge in document space.
    ///
    /// Measured with a 250pt row at top 300: converting the point gives 550,
    /// converting the rectangle gives 300.
    static func topEdge(of view: NSView, in document: NSView) -> CGFloat {
        view.convert(view.bounds, to: document).minY
    }

    /// Whether a set of row offsets can be trusted.
    ///
    /// **Rows堆在一起 means layout has not run yet, and caching that set is
    /// worse than having none.** Between a rebuild and the layout pass that
    /// sizes it, every row still sits at the stack's origin — so converting
    /// them all yields the *same* number, and in a flipped document that
    /// number is the bottom of the content. Observed live: sixteen turns all
    /// reporting 30126 in a 30126pt document, after which the pinned header
    /// could never find a turn again, because the cache looked full and the
    /// staleness test only watches width and height.
    ///
    /// Rows are laid out top to bottom with non-zero heights, so genuine
    /// offsets strictly increase. Anything else is a snapshot taken too early.
    static func areUsable(_ offsets: [CGFloat]) -> Bool {
        guard !offsets.isEmpty else { return false }
        guard offsets.count > 1 else { return true }
        return zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 }
    }

    /// The index of the last offset at or above `position`, or nil if none is.
    ///
    /// Binary search because this runs on every scroll notification and the
    /// offsets are sorted by construction — rows are laid out top to bottom.
    /// A linear scan with a coordinate conversion per row was the first
    /// version and cost thousands of conversions a second on a long
    /// conversation.
    ///
    /// `offsets` must be sorted ascending; `StickyOffsetCheck` asserts that
    /// the caller's fixture is.
    static func lastIndex(atOrAbove position: CGFloat, in offsets: [CGFloat]) -> Int? {
        var low = 0
        var high = offsets.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if offsets[mid] <= position {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}
