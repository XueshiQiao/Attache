//
//  TmuxModel.swift
//  TmuxGUI
//

import Foundation

/// A tmux window, as this app needs to know it.
///
/// Mirrors tmux — nothing here is authored by the GUI. Every field comes from
/// a `list-windows` reply or a notification, so the app can never disagree
/// with what a plain `tmux attach` in another terminal would show.
struct TmuxWindow: Equatable, Identifiable {
    /// tmux's stable window id, e.g. `@25`. Survives renumbering; the index
    /// does not, which is why this and not `index` is the identity.
    let id: String
    var index: Int
    var name: String
    var isActive: Bool
    /// True when tmux flagged unseen output — reused rather than tracked
    /// separately so the GUI's dot means exactly what tmux's `#` means.
    var hasActivity: Bool
    /// The pane tmux considers active in this window.
    ///
    /// Comes from tmux like everything else, and it has to: the app used to
    /// keep its own idea of which pane was focused, seeded with "the first one
    /// in the layout" and moved only by a GUI click. `prefix + o` never touched
    /// it, and neither did a click that landed on a terminal surface — which is
    /// every click inside a pane. The focus ring drew wherever that guess had
    /// got to, which was usually the left-hand pane, while the keystrokes went
    /// to whichever surface the click had made first responder.
    var activePaneID: String

    /// What tmux is displaying — `#{window_visible_layout}`. This is the one to
    /// place panes from, and it is not the same thing as `savedLayoutText`.
    ///
    /// `prefix z` reflows the active pane to the whole window and leaves the
    /// saved layout untouched, so a GUI drawing the saved layout goes on
    /// drawing every pane at its unzoomed size while the program inside the
    /// zoomed one redraws at the full width. Measured on tmux 3.6a: 40 columns
    /// against 80, which is the wrapped-line corruption in its worst form.
    var visibleLayoutText: String

    /// The arrangement tmux would return to — `#{window_layout}`, which zoom
    /// does not change.
    ///
    /// Kept for one thing: it is the only field that lists *every* pane the
    /// window has. While a pane is zoomed the visible layout is a single-pane
    /// tree, so a surface set derived from it would drop the other panes'
    /// surfaces — and their scrollback with them — on every `prefix z`.
    var savedLayoutText: String

    /// The tree to draw.
    var visibleLayout: TmuxLayoutNode? {
        try? TmuxLayout.parse(visibleLayoutText)
    }

    /// The tree that answers which panes exist, zoom-hidden ones included.
    var savedLayout: TmuxLayoutNode? {
        try? TmuxLayout.parse(savedLayoutText)
    }

    /// Every pane in the window, whether or not a zoom is currently hiding it.
    var paneIDs: [String] {
        savedLayout?.panes.map(\.id) ?? []
    }
}

/// A tmux session — one entry in the sidebar.
struct TmuxSessionInfo: Equatable, Identifiable {
    let id: String       // `$10`
    var name: String
    var windowCount: Int
    var isAttached: Bool
}

extension TmuxWindow {
    /// Parse one line of the `list-windows` format this app asks for.
    /// Fields are separated by U+0001 because window names may contain
    /// anything a program can print, spaces and pipes included.
    static func parse(listLine: String) -> TmuxWindow? {
        let fields = listLine.components(separatedBy: "\u{01}")
        guard fields.count >= 8, let index = Int(fields[1]) else { return nil }
        // A tmux without `window_visible_layout` expands it to the empty string
        // rather than failing — verified on 3.6a, an unknown variable yields
        // nothing at all — so an empty field means "this server cannot tell the
        // two apart" and the saved layout is the best answer available.
        return TmuxWindow(
            id: fields[0],
            index: index,
            name: fields[2],
            isActive: fields[3] == "1",
            hasActivity: fields[4] == "1",
            activePaneID: fields[5],
            visibleLayoutText: fields[7].isEmpty ? fields[6] : fields[7],
            savedLayoutText: fields[6]
        )
    }

    /// `#{pane_id}` in a `list-windows` format is not "some pane" — a
    /// pane-scoped variable asked of a window resolves against that window's
    /// *active* pane. Verified on tmux 3.6a: with two panes and `%1` selected
    /// it reports `%1`, and after `select-pane` on the other it reports `%0`.
    /// That is the whole reason the active pane costs no extra round trip.
    ///
    /// Both layouts, because `%layout-change` is not the only way a window's
    /// geometry reaches this app and the other way has to carry the same truth.
    /// Selecting a window that was left zoomed emits no `%layout-change` at all
    /// — measured on tmux 3.6a, only `%session-window-changed` — so the zoom
    /// state of every window arrives here or not at all.
    static let listFormat = [
        "#{window_id}", "#{window_index}", "#{window_name}",
        "#{window_active}", "#{window_activity_flag}", "#{pane_id}",
        "#{window_layout}", "#{window_visible_layout}",
    ].joined(separator: "\u{01}")
}

extension TmuxSessionInfo {
    static func parse(listLine: String) -> TmuxSessionInfo? {
        let fields = listLine.components(separatedBy: "\u{01}")
        guard fields.count >= 4, let count = Int(fields[2]) else { return nil }
        return TmuxSessionInfo(
            id: fields[0],
            name: fields[1],
            windowCount: count,
            isAttached: fields[3] == "1"
        )
    }

    static let listFormat = [
        "#{session_id}", "#{session_name}", "#{session_windows}", "#{session_attached}",
    ].joined(separator: "\u{01}")
}
