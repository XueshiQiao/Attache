//
//  AgentRowBadge.swift
//  Attache
//

import Foundation

extension AgentBadge {
    /// The rail's badge for one of attache-cli's rows.
    ///
    /// Idle is a finished agent the person has looked at since (or one that
    /// never had a turn), which is what the rail draws as settled; so it is
    /// Done, seen when it happened. `unknown` is the rail's silent dot: an
    /// agent is there and nothing says what it is doing.
    init(row: AgentRow) {
        let since = row.since.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        switch row.phase {
        case .needsYou: self.init(state: .needsInput, kind: row.kind, since: since)
        case .working: self.init(state: .working, kind: row.kind, since: since)
        case .done: self.init(state: .done, kind: row.kind, since: since)
        case .idle where row.isUnknown: self.init(state: nil, kind: row.kind, since: nil)
        case .idle:
            self.init(state: .done, kind: row.kind, since: since)
            seenAt = since ?? .distantPast
        }
    }
}
