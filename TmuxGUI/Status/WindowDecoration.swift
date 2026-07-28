//
//  WindowDecoration.swift
//  TmuxGUI
//

import Foundation

/// Everything drawn on a window row that tmux is not the source of.
///
/// Deliberately not fields on `TmuxWindow`. That struct is a mirror of a
/// `list-windows` reply and the app's central rule is that it can never
/// disagree with tmux; a Git field on it would be the first thing in the file
/// tmux could not confirm. This travels beside the window instead, assembled by
/// `MainViewController` — the one place that can see both a session's
/// connection and the Git service.
///
/// The agent half is a borderline case worth naming: `AgentBadge` *is* tmux
/// state, read from a pane option over a subscription. It is here rather than
/// on `TmuxWindow` only because it is per-pane and the row needs one answer per
/// window, so what is stored here is already a decision — see
/// `AgentBadge.moreUrgent`.
struct WindowDecoration: Equatable {
    /// The active pane's working directory, straight from tmux.
    var path: String?
    /// Nil until the repository has been read once. A row draws nothing rather
    /// than a placeholder, because the rail rebuilds on nearly every tmux
    /// notification and a placeholder would flicker on all of them.
    var git: GitSummary?
    /// True once the path has been looked at and found not to be in a
    /// repository — which is a real answer, and different from "not yet known".
    var isNotARepository = false
    /// Whether `git.behind` is being kept current for *this* repository.
    /// See `GitStatusService.fetchIsLive(forPath:)` — the setting being on is
    /// not enough, because a repository can be refusing to fetch.
    var fetchIsLive = false
    var agent: AgentBadge?

    var isEmpty: Bool {
        git == nil && agent == nil && !isNotARepository
    }
}
