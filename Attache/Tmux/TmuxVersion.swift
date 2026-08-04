//
//  TmuxVersion.swift
//  Attache
//

import Foundation

/// `tmux -V`, parsed just far enough to gate features on.
///
/// The app has never had a version check (issue #5, risk 3): every server it
/// met was the local one the person installed. A `[[host]]` can run anything,
/// and the one hard floor today is `refresh-client -B` — the subscriptions
/// every live badge in the rail arrives over — which is tmux ≥ 3.2, sent
/// fire-and-forget, so an older server fails it *unobservably*.
nonisolated struct TmuxVersion: Equatable, Comparable {
    let major: Int
    let minor: Int

    /// From `tmux -V` output: `tmux 3.5a`, `tmux next-3.6`, `tmux 3.4-rc2`,
    /// `tmux master` (nil — treated as new enough by callers that gate,
    /// because master is newer than any release).
    static func parse(_ output: String) -> TmuxVersion? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("tmux ") else { return nil }
        text = String(text.dropFirst("tmux ".count))
        if text.hasPrefix("next-") { text = String(text.dropFirst("next-".count)) }
        let numeric = text.prefix { $0.isNumber || $0 == "." }
        let parts = numeric.split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return TmuxVersion(major: major, minor: minor)
    }

    /// `refresh-client -B` — the subscription mechanism itself.
    var supportsSubscriptions: Bool {
        self >= TmuxVersion(major: 3, minor: 2)
    }

    /// Whether reply-block lines arrive with control characters escaped as
    /// `\ooo`. Measured 2026-08-04, one command sent to each over a pipe:
    /// 3.5a answers `list-windows` with a literal four-character `\001`
    /// where 3.6a sends the raw byte — so the `\u{01}` field separators this
    /// app relies on never match on an unescaped read. Notifications
    /// (`%subscription-changed` included) carry raw bytes on *both*, so the
    /// decode belongs to reply blocks alone.
    var escapesControlModeReplies: Bool {
        self < TmuxVersion(major: 3, minor: 6)
    }

    static func < (a: TmuxVersion, b: TmuxVersion) -> Bool {
        (a.major, a.minor) < (b.major, b.minor)
    }

    var text: String { "\(major).\(minor)" }
}
