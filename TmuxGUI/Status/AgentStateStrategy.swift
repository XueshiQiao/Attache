//
//  AgentStateStrategy.swift
//  TmuxGUI
//

import Foundation

/// Everything a strategy is allowed to look at for one pane.
///
/// Deliberately a plain value with no way to go and fetch more: whichever
/// strategy is selected declares what it needs through
/// `AgentStateStrategy.needsScreen`, and the connection gathers exactly that.
/// A strategy that could reach out on its own would make "how expensive is this
/// setting" unanswerable.
struct AgentEvidence {
    let paneID: String
    /// `#{pane_current_command}` — the pane's foreground process.
    var currentCommand: String

    /// The tmux pane options a hook writes. Empty strings when nothing has.
    var optionState = ""
    var optionKind = ""
    var optionAt = ""
    /// `@agent_why` — the hook event that produced `optionState`.
    var optionWhy = ""
    /// `@agent_stat` — the whole status-line JSON, written by the wrapper
    /// `AgentStatusLineInstaller` installs. Empty when it is not installed,
    /// which is the ordinary case and not a failure.
    var optionStats = ""

    /// The pane's visible lines, newest last. Nil unless the strategy asked.
    var screen: [String]?
    /// Whether `screen` differs from the previous capture of the same pane.
    /// A terminal that is repainting is a terminal with something happening in
    /// it, which is the cheapest working-signal there is.
    var screenChanged = false
}

/// How the app decides what an agent in a pane is doing.
///
/// Two of these exist and they are not variations on a theme — they read
/// different things and fail differently. The setting exists because which one
/// is better is not answerable in the abstract: one is exact and needs
/// installing, the other needs nothing and infers.
///
/// The protocol is also what makes a second *agent* cheap. Everything specific
/// to Claude Code lives either in the hook script or in a rule table, so adding
/// Codex is a table entry rather than a branch in the drawing code.
protocol AgentStateStrategy {
    static var id: String { get }
    static var title: String { get }
    /// Whether the connection should capture pane contents for this strategy.
    /// Capturing costs a tmux round trip per pane, so it is opt-in.
    static var needsScreen: Bool { get }

    /// Nil means "there is no agent here", not "I do not know". A strategy that
    /// sees an agent but cannot classify it returns a badge with a nil state.
    static func badge(from evidence: AgentEvidence) -> AgentBadge?
}

// MARK: - Hooks

/// Reads what a Claude Code hook wrote into the pane's tmux options.
///
/// Exact, because the agent is reporting on itself rather than being watched;
/// works when the pane has never been drawn; and the state lives in tmux, so a
/// plain `tmux attach` from any terminal reads the same value. The cost is that
/// somebody has to install the hook, and that the state has to be reconstructed
/// from events — which is a real cost: Claude Code exposes no event meaning
/// "finished and waiting for you" as distinct from "finished", so that
/// distinction is inferred.
enum HookAgentStrategy: AgentStateStrategy {
    static let id = "hook"
    static let title = "Hooks"
    static let needsScreen = false

    static func badge(from evidence: AgentEvidence) -> AgentBadge? {
        guard AgentDetector.isAgentCommand(evidence.currentCommand) else { return nil }
        var badge = AgentBadge(
            state: AgentState.parse(evidence.optionState),
            kind: evidence.optionKind.isEmpty
                ? AgentDetector.kind(ofCommand: evidence.currentCommand)
                : evidence.optionKind,
            since: TimeInterval(evidence.optionAt).map { Date(timeIntervalSince1970: $0) }
        )
        badge.reason = evidence.optionWhy.isEmpty ? nil : evidence.optionWhy
        return badge
    }
}

// MARK: - Screen

/// Infers the state from what the pane is drawing.
///
/// Needs nothing installed and works the moment an agent appears, which is what
/// makes it worth having. What it cannot do is be certain: it is reading a user
/// interface that its author is free to change, so every rule here is a fact
/// about one version of one program. That is why the rules are a table and not
/// code, and why the table records where each rule came from.
///
/// **Derived by measurement on this machine, 2026-07-29**, against eight live
/// Claude Code panes whose true state was known independently from the hook:
///
/// - Two structural ideas were tried and **discarded** for not discriminating.
///   The input box — two horizontal rules around a `❯` line — is drawn while
///   the agent is working too, so its presence says nothing. The footer's
///   `(shift+tab to cycle)` is absent in manual permission mode, so its absence
///   says nothing either.
/// - What does discriminate is the **elapsed counter** a working agent renders
///   and removes when it stops: every idle pane scored 0 and every working pane
///   scored at least 1.
/// - A pane whose screen differs from its previous capture is repainting, and a
///   terminal that repaints has something happening in it. Cheapest signal
///   available and the only one that is not text-matching.
enum ScreenAgentStrategy: AgentStateStrategy {
    static let id = "screen"
    static let title = "Read the pane"
    static let needsScreen = true

    /// One test against the pane's recent lines.
    struct Rule {
        enum Test {
            case contains(String)
            case regex(String)
        }

        let state: AgentState
        /// Higher wins. Blocked outranks working because a pane can be drawing
        /// a spinner above a prompt it is blocked on.
        let priority: Int
        /// How many lines up from the bottom this rule may look.
        ///
        /// Per rule rather than one number for all of them, because the two
        /// kinds of marker sit at very different heights and the cost of
        /// getting it wrong runs in opposite directions. A spinner is always
        /// just above the input box — six lines, measured — so letting it look
        /// further only invites a match on an old one that scrolled up. A
        /// question's cursor sits *above its own option list*, so a short reach
        /// misses it entirely, which is the defect this rule was added for.
        let reach: Int
        let test: Test
        /// Whether this was checked against a live pane or only reasoned about.
        let verified: Bool
    }

    /// How many lines from the bottom to look at. The whole screen invites a
    /// match on scrollback that has nothing to do with the current state — an
    /// agent that *printed* the words "do you want to proceed" an hour ago is
    /// not blocked now.
    /// Rules per agent kind. Everything below was measured against Claude Code
    /// and describes Claude Code's interface; another agent draws its own.
    ///
    /// A table rather than one array because the alternative is silent: run
    /// `codex` under this strategy against Claude Code's rules and not one of
    /// them fires, so the pane reads `working` while it repaints and `done` the
    /// rest of the time, and a permission prompt is never seen at all. Adding an
    /// agent is an entry here.
    static let rulesByKind: [String: [Rule]] = ["claude": claudeRules]

    /// Whatever the kind is, or nothing — never another agent's rules.
    static func rules(for kind: String?) -> [Rule] {
        guard let kind else { return [] }
        return rulesByKind[kind] ?? []
    }

    /// Kept for the check tool, which exercises the Claude Code set by name.
    static var rules: [Rule] { claudeRules }

    private static let claudeRules: [Rule] = [
        // Blocked, and the general form rather than any one prompt's wording.
        // Reported from use, 2026-07-29: a window sitting on a multiple-choice
        // question was drawn as `done`, because every rule here had been
        // written for a *permission* prompt and the thing on screen was an
        // `AskUserQuestion` picker. What both have in common is not their text
        // — one says "Do you want to proceed?", the other asks whatever the
        // agent decided to ask — but their **shape**: a selection cursor
        // resting on a numbered option.
        //
        // Captured verbatim from the pane that was misread:
        //
        //     ←  ☐ 做哪些  ☐ 看的地方  ☐ 抽哪个  ✔ Submit  →
        //     这四个办法，做哪些？（可多选）
        //     ❯ 1. [ ] A 加规则（推荐）
        //
        // The cursor form is deliberately loose about what follows the number,
        // so it covers a permission prompt's `❯ 1. Yes` and a question's
        // `❯ 1. [ ] anything` alike, in any language.
        Rule(state: .needsInput, priority: 300, reach: 24, test: .regex(#"(?m)^\s*❯\s*\d+\."#), verified: true),
        Rule(state: .needsInput, priority: 300, reach: 24, test: .contains("✔ submit"), verified: true),
        // Kept as belt and braces for a prompt that renders without the cursor.
        Rule(state: .needsInput, priority: 300, reach: 24, test: .contains("do you want to proceed"), verified: false),
        Rule(state: .needsInput, priority: 300, reach: 24, test: .contains("do you want to allow"), verified: false),

        // Working. `Nm Ns ·` and `(Ns · ` are the elapsed counter; it advances
        // once a second and disappears the moment the turn ends.
        Rule(state: .working, priority: 100, reach: 10, test: .regex(#"\d+m \d+s ·"#), verified: true),
        Rule(state: .working, priority: 100, reach: 10, test: .regex(#"\(\d+s · "#), verified: true),
        Rule(state: .working, priority: 100, reach: 10, test: .contains("esc to interrupt"), verified: false),
    ]

    static func badge(from evidence: AgentEvidence) -> AgentBadge? {
        guard AgentDetector.isAgentCommand(evidence.currentCommand) else { return nil }
        let kind = AgentDetector.kind(ofCommand: evidence.currentCommand)

        // No capture yet — say an agent is here and nothing more, rather than
        // guessing "idle" about a pane that has never been read.
        guard let screen = evidence.screen else {
            var badge = AgentBadge(state: nil, kind: kind, since: nil)
            badge.reason = "not captured yet"
            return badge
        }

        let winner = Self.rules(for: kind)
            .filter { rule in
                let window = screen.suffix(rule.reach).joined(separator: "\n").lowercased()
                return matches(rule.test, in: window)
            }
            .max { $0.priority < $1.priority }

        if let winner {
            var badge = AgentBadge(state: winner.state, kind: kind, since: nil)
            badge.reason = "rule \(winner.priority): \(winner.test)"
            return badge
        }
        // A repainting pane is a busy pane, even when no rule named why.
        // No rules for this kind at all — say an agent is here and stop. The
        // repaint/static fallback below is only meaningful next to rules that
        // could have fired instead; on its own it would report `done` about
        // every quiet moment of an agent nobody has written rules for.
        guard !Self.rules(for: kind).isEmpty else {
            var badge = AgentBadge(state: nil, kind: kind, since: nil)
            badge.reason = "no screen rules for \(kind ?? "this agent")"
            return badge
        }

        if evidence.screenChanged {
            var badge = AgentBadge(state: .working, kind: kind, since: nil)
            badge.reason = "the pane repainted"
            return badge
        }
        // Nothing moving and nothing matched: the turn is over and the ball is
        // in the user's court. This strategy cannot tell "finished normally"
        // from "finished a long time ago" — it has no clock, only a picture —
        // so it always reports the fresher of the two and lets the row's own
        // ageing decide. `since` is nil for exactly that reason.
        var badge = AgentBadge(state: .done, kind: kind, since: nil)
        badge.reason = "no rule matched and the pane is static"
        return badge
    }

    private static func matches(_ test: Rule.Test, in text: String) -> Bool {
        switch test {
        case .contains(let needle):
            return text.contains(needle.lowercased())
        case .regex(let pattern):
            return text.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

// MARK: - Selection

enum AgentStateSource: String, CaseIterable {
    case hook
    case screen

    var title: String {
        switch self {
        case .hook: HookAgentStrategy.title
        case .screen: ScreenAgentStrategy.title
        }
    }

    var needsScreen: Bool {
        switch self {
        case .hook: HookAgentStrategy.needsScreen
        case .screen: ScreenAgentStrategy.needsScreen
        }
    }

    func badge(from evidence: AgentEvidence) -> AgentBadge? {
        switch self {
        case .hook: HookAgentStrategy.badge(from: evidence)
        case .screen: ScreenAgentStrategy.badge(from: evidence)
        }
    }
}
