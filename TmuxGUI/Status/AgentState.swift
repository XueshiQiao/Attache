//
//  AgentState.swift
//  TmuxGUI
//

import Foundation

/// What a coding agent running in a pane is doing.
///
/// Unlike the Git half, none of this is authored by the GUI. It lives in tmux
/// as a pane user option — `@agent_state`, written by a hook inside the pane —
/// and arrives on the same control mode connection as everything else. A plain
/// `tmux attach` in another terminal can read the same value, and a status-line
/// format could draw it. That is what keeps CLAUDE.md's opening rule intact for
/// a feature that looks like it needs local state and does not.
enum AgentState: String, Equatable {
    /// Doing something. The one state you do not have to act on.
    case working
    /// Blocked on the user — a permission prompt, or a question.
    case needsInput = "needs-input"
    /// Finished its turn.
    case done

    /// The vocabulary a hook may write. Anything else is treated as no state at
    /// all rather than guessed at: a value this app does not recognise is more
    /// likely a newer hook than a typo, and inventing a meaning for it would
    /// make the badge wrong in exactly the case where someone is relying on it.
    static func parse(_ raw: String) -> AgentState? {
        AgentState(rawValue: raw.trimmingCharacters(in: .whitespaces))
    }
}

/// One pane's agent, as the rail needs to draw it.
struct AgentBadge: Equatable {
    static func == (a: AgentBadge, b: AgentBadge) -> Bool {
        a.state == b.state && a.kind == b.kind
            && a.since == b.since && a.seenAt == b.seenAt
    }

    /// Nil when an agent is present but has said nothing — no hook installed.
    /// The row still shows a dot, because "something is running here" is true
    /// and is the thing that makes installing the hook look worth it.
    var state: AgentState?
    /// `claude`, or whatever else wrote the option. Drawn only in the tooltip;
    /// an unrecognised kind still gets the right coloured dot, because the
    /// state is what the colour means.
    var kind: String?
    /// When the state was last written, from `@agent_at`. Nil if the hook did
    /// not set one.
    var since: Date?
    /// What caused this state — a hook event name, or the screen rule that
    /// matched. Recorded so a transition log can be checked against the state
    /// machine it is supposed to implement.
    ///
    /// **Excluded from equality on purpose.** Two badges that mean the same
    /// thing are the same badge whatever explained them, and including this
    /// would make the rail redraw every time a cause changed without the state
    /// doing so.
    var reason: String?

    /// When the user last looked at this window, from `@agent_seen`.
    var seenAt: Date?

    /// True once a finished agent has been *seen*, rather than once it is old.
    ///
    /// This was a thirty-minute timer and the timer was the wrong idea. It is
    /// arbitrary — thirty minutes rather than ten or ninety for no reason — and
    /// it throws the information away at exactly the moment it is worth most:
    /// come back after lunch and every agent that finished while you were gone
    /// has already faded, so the sidebar cannot tell you the one thing you went
    /// to it for.
    ///
    /// "Seen" is the predicate that was actually meant, and it is the same one
    /// tmux uses for its own activity flag — set when something happens,
    /// cleared when you select the window. Reusing that shape rather than
    /// inventing a clock also deletes the timer, the interval constant, and the
    /// bug where the rail's redraw signature could not change at a boundary
    /// nothing announced.
    var isSettled: Bool {
        guard state == .done, let seenAt else { return false }
        // Seen *after* it finished. A window looked at before the agent
        // finished has not been looked at since.
        return seenAt >= (since ?? .distantPast)
    }

    /// Which of two badges the row should show when a window has several panes.
    ///
    /// The badge answers "does anything in this window want me", so a pane
    /// blocked on a permission prompt outranks one that is happily working —
    /// burying that under `working` would defeat the whole feature. A bare
    /// presence outranks nothing at all.
    static func moreUrgent(_ a: AgentBadge?, _ b: AgentBadge?) -> AgentBadge? {
        guard let a else { return b }
        guard let b else { return a }
        guard rank(a) == rank(b) else { return rank(a) > rank(b) ? a : b }
        // **A tie goes to whichever happened later**, and that is not
        // cosmetic. Two panes in one window both finish; the window inherits
        // one of their timestamps, and `isSettled` compares the seen-mark
        // against it. Keeping the accumulator meant keeping whichever pane came
        // first in `paneIDs` — so a pane that finished an hour ago and was seen
        // could speak for a sibling that finished ten seconds ago, and the row
        // would report itself already read. Under the old timer that was a
        // wrong "3m ago" in a tooltip; under the unread model it silently hides
        // news, and nothing later brings it back.
        return (b.since ?? .distantPast) > (a.since ?? .distantPast) ? b : a
    }

    private static func rank(_ badge: AgentBadge) -> Int {
        // A finished agent stops outranking a bare presence once it has aged.
        // Without this a collapsed session heading kept a bright "just
        // finished" dot for as long as the session lived, because the ranking
        // had no time dimension at all.
        if badge.isSettled { return 1 }
        return switch badge.state {
        case .needsInput: 4
        case .working: 3
        case .done: 2
        case nil: 0
        }
    }
}

/// Reads the four fields the pane subscription carries, and decides whether to
/// believe them.
enum AgentDetector {
    /// The subscription this app registers, joined by U+0001 for the same
    /// reason every other multi-field format here is: a pane's current path and
    /// command are arbitrary text and a space is not a separator.
    /// `@agent_stat` goes last, and everything reading this splits by index, so
    /// a field added here must go on the end. It is also the only one that
    /// carries a whole JSON object — about 1.3 KB, written by the status line
    /// wrapper. Measured on tmux 3.6a: a 1864-byte single-line option value
    /// arrives through `%subscription-changed` byte for byte, so it needs no
    /// transport of its own. The separator stays safe because JSON cannot carry
    /// a raw U+0001.
    static let paneFormat = [
        "#{@agent_state}", "#{@agent_kind}", "#{@agent_at}", "#{pane_current_command}",
        "#{@agent_why}", "#{@agent_stat}",
    ].joined(separator: "\u{01}")

    /// Parse one `%subscription-changed` value into a badge, or nil for a pane
    /// with no agent in it.
    ///
    /// **The command is a liveness check, not the state.** `@agent_state` is a
    /// value in tmux, so it outlives the process that wrote it: an agent killed
    /// with `^C` never runs its exit hook and would otherwise leave `working`
    /// on that pane forever. A pane sitting at a shell prompt shows no badge
    /// whatever its options still say, which makes the hook's own cleanup an
    /// optimisation rather than a correctness requirement — the right way
    /// round, because a hook is the thing that can fail to run.
    static func badge(fromSubscriptionValue value: String) -> AgentBadge? {
        let fields = value.components(separatedBy: "\u{01}")
        guard fields.count >= 4 else { return nil }
        let command = fields[3]
        guard isAgentCommand(command) else { return nil }

        return AgentBadge(
            state: AgentState.parse(fields[0]),
            kind: fields[1].isEmpty ? kind(ofCommand: command) : fields[1],
            since: TimeInterval(fields[2]).map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// Whether a pane's foreground process looks like a coding agent.
    ///
    /// This is the zero-configuration half, and it is deliberately the *weaker*
    /// of the two signals. Measured on this machine 2026-07-28: a pane running
    /// Claude Code reports `#{pane_current_command}` as its bare version
    /// string — `2.1.220`, matching `claude --version` exactly. Nobody promised
    /// that, and it can change in any release.
    ///
    /// So it decides only two things, both of which it can be wrong about
    /// cheaply: whether to draw a dot at all, and whether a stored state is
    /// still live. It never decides *which* state to show. When it is wrong the
    /// feature degrades to no badge, never to a confident wrong one.
    static func isAgentCommand(_ command: String) -> Bool {
        !command.isEmpty && (looksLikeVersion(command) || namedAgents.contains(command))
    }

    /// Agents that identify themselves by name rather than by version. Data
    /// rather than logic, so adding one is a line.
    private static let namedAgents: Set<String> = ["claude", "codex", "grok", "aider", "gemini"]

    static func kind(ofCommand command: String) -> String? {
        if namedAgents.contains(command) { return command }
        // A version and nothing else is Claude Code's signature; there is no
        // other candidate, so naming it is more useful than "unknown".
        return looksLikeVersion(command) ? "claude" : nil
    }

    /// `N.N` or `N.N.N`, digits and dots only.
    ///
    /// Tight on purpose. A loose test — "contains a digit and a dot" — would
    /// match a pane running `python3.12` or a file called `2.txt`, and every
    /// false positive here puts a dot on a row where nothing is running.
    private static func looksLikeVersion(_ command: String) -> Bool {
        let parts = command.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }
}
