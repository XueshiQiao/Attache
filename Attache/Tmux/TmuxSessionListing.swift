//
//  TmuxSessionListing.swift
//  Attache
//

import Foundation

nonisolated struct TmuxSessionListing: Equatable {
    let id: String
    let name: String
    /// Position chosen by dragging in the rail (`@attache_order`), or nil for
    /// sessions that have never been reordered and stay in tmux's own order.
    let order: Int?
    /// The *server's* `#{version}`, the same on every row. Asked on every
    /// listing because the server can be replaced under a running app — a
    /// `kill-server` and a new one from an upgraded binary — and every
    /// version gate is about the server. Empty from a server older than 2.4.
    var serverVersion: String = ""
}

extension TmuxSessionListing {
    /// The `list-sessions -F` this parses. `#{version}` is the server's and
    /// the same on every row; see `serverVersion`.
    static let format = "#{session_id} #{version} #{@attache_order} #{session_name}"

    /// Three splits (`omittingEmptySubsequences: false` because an unset
    /// `@attache_order`, or a pre-2.4 `#{version}`, expands to nothing
    /// between two spaces), so a name containing spaces arrives whole.
    /// Measured on 3.5a and 3.6a: `$0 3.6a  name with spaces`. A row with no
    /// id is not a session this app can address and is dropped rather than
    /// guessed at.
    static func parse(listOutput: String) -> [TmuxSessionListing] {
        listOutput.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard let id = parts.first, id.hasPrefix("$") else { return nil }
            return TmuxSessionListing(
                id: String(id),
                name: parts.count > 3 ? String(parts[3]) : "",
                order: parts.count > 2 ? Int(parts[2]) : nil,
                serverVersion: parts.count > 1 ? String(parts[1]) : ""
            )
        }
    }
}
