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
        guard fields.count >= 6, let index = Int(fields[1]) else { return nil }
        return TmuxWindow(
            id: fields[0],
            index: index,
            name: fields[2],
            isActive: fields[3] == "1",
            hasActivity: fields[4] == "1",
            layoutText: fields[5]
        )
    }

    static let listFormat = [
        "#{window_id}", "#{window_index}", "#{window_name}",
        "#{window_active}", "#{window_activity_flag}", "#{window_layout}",
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
