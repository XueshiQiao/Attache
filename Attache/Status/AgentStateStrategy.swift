//
//  AgentStateStrategy.swift
//  Attache
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

    /// `#{pane_title}` — terminal OSC 0/2 title.
    var paneTitle = ""
    /// True once `paneTitle` has carried an active spinner glyph (`⠋`..`⠏` /
    /// `◐`..`◒`) during the current `working` stretch. Measured on Claude Code
    /// 2.1.308 (`%13`, 2026-11-01): recent releases can leave `#{pane_title}`
    /// static at `✳ <topic>` throughout an entire working turn, so `✳` only
    /// reconciles an interrupted `working` state to `done` when this session
    /// actually spun its title during that turn.
    var sawTitleSpinnerInCurrentTurn = false

    mutating func recordSubscriptionUpdate(
        previousState: String,
        previousAt: String,
        newTitle: String
    ) {
        paneTitle = newTitle
        guard AgentDetector.isAgentCommand(currentCommand), optionState == "working" else {
            sawTitleSpinnerInCurrentTurn = false
            return
        }
        if previousState != "working"
            || (optionWhy == "UserPromptSubmit" && optionAt != previousAt)
        {
            sawTitleSpinnerInCurrentTurn = false
        }
        if HookAgentStrategy.claudeTitleSignal(newTitle) == .spinning {
            sawTitleSpinnerInCurrentTurn = true
        }
    }

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

/// Reads what `attache-agent-hub` wrote into the pane's tmux options.
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

    enum TitleSignal: Equatable {
        case spinning
        case idleAsterisk
        case none
    }

    static func claudeTitleSignal(_ title: String) -> TitleSignal {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first else { return .none }
        // Braille spinner frames (excluding U+2800 blank) and circle quadrants.
        if (0x2801 ... 0x28FF).contains(first.value)
            || (0x25D0 ... 0x25D3).contains(first.value)
        {
            return .spinning
        }
        if first.value == 0x2733 { // ✳
            return .idleAsterisk
        }
        return .none
    }

    static func badge(from evidence: AgentEvidence) -> AgentBadge? {
        guard AgentDetector.isAgentCommand(evidence.currentCommand) else { return nil }
        let commandKind = AgentDetector.kind(ofCommand: evidence.currentCommand)
        guard AgentDetector.optionsMatchCommand(
            optionKind: evidence.optionKind, command: evidence.currentCommand
        ) else {
            return AgentBadge(state: nil, kind: commandKind, since: nil)
        }

        let resolvedKind = evidence.optionKind.isEmpty ? commandKind : evidence.optionKind
        // Pre-v2 hooks mapped `SessionStart` to `working`; normalise leftover
        // v1 panes to idle/registered immediately without requiring a restart.
        let parsedState = (evidence.optionState == "working" && evidence.optionWhy == "SessionStart")
            ? nil
            : AgentState.parse(evidence.optionState)
        var badge = AgentBadge(
            state: parsedState,
            kind: resolvedKind,
            since: parsedState == nil
                ? nil
                : TimeInterval(evidence.optionAt).map { Date(timeIntervalSince1970: $0) }
        )
        badge.reason = evidence.optionWhy.isEmpty ? nil : evidence.optionWhy

        if resolvedKind == "claude" {
            let signal = claudeTitleSignal(evidence.paneTitle)
            if badge.state == nil, signal == .spinning {
                badge.state = .working
                badge.reason = "osc_title_working"
            } else if badge.state == .working,
                      evidence.sawTitleSpinnerInCurrentTurn,
                      signal == .idleAsterisk
            {
                badge.state = .done
                badge.reason = "osc_title_idle"
            }
        }
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
        // Unnumbered confirmation pickers (such as the startup folder-trust
        // dialog, `❯ No, exit` / `Yes, I trust this folder`) draw no `1.` prefix
        // and identify themselves by their footer instead. Measured on `%28`
        // (`HyperCapslock`), 2026-11-01, Claude Code 2.1.308.
        Rule(state: .needsInput, priority: 300, reach: 10, test: .contains("enter to confirm · esc to cancel"), verified: true),
        // Kept as belt and braces for a prompt that renders without the cursor.
        Rule(state: .needsInput, priority: 300, reach: 24, test: .contains("do you want to proceed"), verified: false),
        Rule(state: .needsInput, priority: 300, reach: 24, test: .contains("do you want to allow"), verified: false),

        // Working. The opening `(` is what distinguishes a live elapsed counter
        // from a finished-turn summary and from a background subagent row:
        //
        // - Live spinner / tool progress (always parenthesised):
        //     `✢ Cooking… (53s · ↓ 5.8k tokens · thought for 6s)`
        //     `✻ Zigzagging… (10m 19s · ↓ 30.3k tokens)`
        //     `✻ Thinking… (1h 2m 3s · ↓ 90.1k tokens)` / `(1h 2m · …)`
        // - Finished turn in Claude Code 2.1.292+ (never parenthesised):
        //     `✻ Cogitated for 12m 21s · done 10:12 PM`
        //     `✻ Sautéed for 6m 25s · done 12:03 PM`
        //     `✻ Worked for 8m 37s · done 11:57 AM`
        //     `✻ Crunched for 7m 10s · done 3:48 PM · 1 monitor still running`
        // - Background subagent footer below `⏺ main` (never parenthesised):
        //     `◯ alice  …  2m 43s · ↓ 11.8k tokens`
        //
        // Measured across ten live Claude Code 2.1.308 panes on 2026-11-01:
        // omitting `\(` on the minutes rule left every >= 1m finished turn
        // stuck on `working` until ten new lines pushed it off screen.
        Rule(
            state: .working, priority: 100, reach: 10,
            test: .regex(#"\((?:\d+h (?:\d+m )?(?:\d+s )?|\d+m \d+s |\d+s )· "#),
            verified: true
        ),
        Rule(state: .working, priority: 100, reach: 10, test: .contains("esc to interrupt"), verified: true),
    ]

    static func badge(from evidence: AgentEvidence) -> AgentBadge? {
        guard AgentDetector.isAgentCommand(evidence.currentCommand) else { return nil }
        let kind = AgentDetector.kind(ofCommand: evidence.currentCommand)
        let rules = Self.rules(for: kind)

        // No rules for this kind at all — say an agent is here and stop. The
        // repaint/static fallback below is only meaningful next to rules that
        // could have fired instead; on its own it would report `done` about
        // every quiet moment of an agent nobody has written rules for.
        guard !rules.isEmpty else {
            var badge = AgentBadge(state: nil, kind: kind, since: nil)
            badge.reason = "no screen rules for \(kind ?? "this agent")"
            return badge
        }

        // No capture yet — say an agent is here and nothing more, rather than
        // guessing "idle" about a pane that has never been read.
        guard let screen = evidence.screen else {
            var badge = AgentBadge(state: nil, kind: kind, since: nil)
            badge.reason = "not captured yet"
            return badge
        }

        // `capture-pane -p` pads every reply to the full terminal height with
        // trailing empty lines. On a fresh or `/clear`-ed session in a 77-row
        // pane, the whole UI sits in the top 15 rows and `screen.suffix(...)`
        // would read only blank padding at the bottom.
        let drawn = trimTrailingBlankLines(screen)
        // Claude Code's working spinner always renders *above* the `─── / ❯ / ───`
        // input box, whereas multi-line drafts inside `❯`, the status line, and
        // background subagent rows (`⏺ main` / `◯ …`) below the box can grow past
        // ten lines and push an active spinner out of a bottom-anchored reach.
        // Measuring `.working` reach upward from the input box's top rule keeps
        // active spinners in reach regardless of footer height while still
        // rejecting scrolled-up spinners from earlier turns.
        let inputBox = (kind == "claude") ? claudeInputBox(in: drawn) : nil
        let aboveInputBox = inputBox.map { Array(drawn[..<$0.topIndex]) } ?? drawn

        let winner = rules
            .filter { rule in
                let source = (rule.state == .working) ? aboveInputBox : drawn
                let window = source.suffix(rule.reach).joined(separator: "\n").lowercased()
                return matches(rule.test, in: window)
            }
            .max { $0.priority < $1.priority }

        if let winner {
            var badge = AgentBadge(state: winner.state, kind: kind, since: nil)
            badge.reason = "rule \(winner.priority): \(winner.test)"
            return badge
        }

        // A repainting pane is a busy pane, even when no rule named why.
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

    /// Whether `current` shows new agent output compared with `previous`,
    /// ignoring terminal resizes and idle UI chrome.
    ///
    /// Measured across 91,413 logged transitions on 2026-11-01: raw
    /// `previous != lines` produced 40,981 single-tick (`2s`) false `working`
    /// blips on idle Claude Code panes — and reset already-read `idle` rows
    /// back to unread green `done` — from four non-turn repaints:
    ///
    /// 1. Changes in or below the `─── / ❯ / ───` input box: status-line
    ///    clocks and quota bars refreshing every 5–60s, typing or async ghost
    ///    suggestions in `❯`, and background subagent timers below `⏺ main`.
    /// 2. Terminal resizes (`capture-pane -p` row count or the full-width
    ///    `───` border length changing, e.g. when the conversation rail opens
    ///    or hides).
    /// 3. Viewport top-clipping when a growing draft or footer shifts the
    ///    input box upward without adding anything new above it.
    /// 4. Claude Code's asynchronous idle notices above the input box:
    ///    `new task? /clear…`, `Update available!…`, the 3-minute `※ recap:`
    ///    away summary, and `⏺ Compacted while idle…`.
    static func didOutputChange(from previous: [String], to current: [String], kind: String?) -> Bool {
        guard previous != current else { return false }
        // `capture-pane -p` always emits one entry per terminal row, so a
        // changed count is a pane height resize rather than agent output.
        guard previous.count == current.count else { return false }

        let prevDrawn = trimTrailingBlankLines(previous)
        let currDrawn = trimTrailingBlankLines(current)
        guard kind == "claude" else { return prevDrawn != currDrawn }

        let prevBox = claudeInputBox(in: prevDrawn)
        let currBox = claudeInputBox(in: currDrawn)
        // The input box's horizontal rules span the full pane width; a
        // changed width means a column resize reflowed wrapped text.
        if let pw = prevBox?.ruleWidth, let cw = currBox?.ruleWidth, pw != cw {
            return false
        }

        let prevAbove = prevBox.map { Array(prevDrawn[..<$0.topIndex]) } ?? prevDrawn
        let currAbove = currBox.map { Array(currDrawn[..<$0.topIndex]) } ?? currDrawn

        let prevBody = stripClaudeIdleChrome(prevAbove)
        let currBody = stripClaudeIdleChrome(currAbove)

        if isIdleCompactionNotice(currBody.last), !isIdleCompactionNotice(prevBody.last) {
            return false
        }

        guard !prevBody.isEmpty, !currBody.isEmpty else {
            return !currBody.isEmpty
        }

        if prevBox != nil, currBox != nil {
            let overlap = min(prevBody.count, currBody.count)
            if prevBody.suffix(overlap) != currBody.suffix(overlap) { return true }
            if currBody.count > prevBody.count, prevDrawn.count < previous.count - 2 {
                return true
            }
            return false
        }
        return prevBody != currBody
    }

    private struct InputBox {
        let topIndex: Int
        let ruleWidth: Int
    }

    /// Locate Claude Code's `─── / ❯ … / ───` input box near the bottom of the
    /// drawn screen.
    ///
    /// Returns nil when an interactive picker (`AskUserQuestion` or a
    /// permission prompt) has replaced the input box: those draw a single
    /// divider above a question or tab bar, never two horizontal rules framing
    /// a `❯` prompt.
    private static func claudeInputBox(in drawn: [String]) -> InputBox? {
        guard drawn.count >= 3 else { return nil }
        let floor = max(0, drawn.count - 24)
        var rules = [(index: Int, width: Int)]()
        for index in floor ..< drawn.count {
            if let width = horizontalRuleWidth(drawn[index]) {
                rules.append((index, width))
            }
        }
        guard rules.count >= 2 else { return nil }
        for pairIndex in stride(from: rules.count - 2, through: 0, by: -1) {
            let top = rules[pairIndex]
            let bottom = rules[pairIndex + 1]
            let span = bottom.index - top.index
            guard span >= 2, span <= 12,
                  bottom.index >= drawn.count - 14
            else { continue }
            let prompt = drawn[top.index + 1].trimmingCharacters(in: .whitespaces)
            guard prompt.hasPrefix("❯") else { continue }
            return InputBox(topIndex: top.index, ruleWidth: top.width)
        }
        return nil
    }

    private static func horizontalRuleWidth(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 10, trimmed.allSatisfy({ $0 == "─" }) else { return nil }
        return trimmed.count
    }

    private static func trimTrailingBlankLines(_ lines: [String]) -> [String] {
        guard let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return [] }
        return Array(lines[...last])
    }

    private static func stripClaudeIdleChrome(_ lines: [String]) -> [String] {
        var out = trimTrailingBlankLines(lines)
        while let last = out.last, isClaudeIdleNotice(last) {
            out.removeLast()
            out = trimTrailingBlankLines(out)
        }
        let searchFloor = max(0, out.count - 8)
        if let recapIndex = (searchFloor ..< out.count).last(where: { index in
            out[index].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("※ recap:")
        }) {
            let tailIsContinuation = ((recapIndex + 1) ..< out.count).allSatisfy { index in
                let line = out[index]
                return line.hasPrefix("  ") && !line.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if tailIsContinuation {
                out.removeSubrange(recapIndex ..< out.count)
                out = trimTrailingBlankLines(out)
            }
        }
        return out
    }

    private static func isClaudeIdleNotice(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("⏺"), !trimmed.hasPrefix("❯"), !trimmed.hasPrefix("✻")
        else { return false }
        let lower = trimmed.lowercased()
        return lower.contains("new task? /clear") || lower.contains("update available!")
    }

    private static func isIdleCompactionNotice(_ line: String?) -> Bool {
        guard let line else { return false }
        return line.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .hasPrefix("⏺ compacted while idle")
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
