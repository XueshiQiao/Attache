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
    var layoutText: String

    var layout: TmuxLayoutNode? {
        try? TmuxLayout.parse(layoutText)
    }

    var paneIDs: [String] {
        layout?.panes.map(\.id) ?? []
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
        guard fields.count >= 7, let index = Int(fields[1]) else { return nil }
        return TmuxWindow(
            id: fields[0],
            index: index,
            name: fields[2],
            isActive: fields[3] == "1",
            hasActivity: fields[4] == "1",
            activePaneID: fields[5],
            layoutText: fields[6]
        )
    }

    /// `#{pane_id}` in a `list-windows` format is not "some pane" — a
    /// pane-scoped variable asked of a window resolves against that window's
    /// *active* pane. Verified on tmux 3.6a: with two panes and `%1` selected
    /// it reports `%1`, and after `select-pane` on the other it reports `%0`.
    /// That is the whole reason the active pane costs no extra round trip.
    static let listFormat = [
        "#{window_id}", "#{window_index}", "#{window_name}",
        "#{window_active}", "#{window_activity_flag}", "#{pane_id}", "#{window_layout}",
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
