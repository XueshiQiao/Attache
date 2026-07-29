//
//  main.swift
//  ScreenStateCheck
//
//  Checks `ScreenAgentStrategy` against pane content captured from live agents.
//
//  This strategy reads a user interface, so every rule in it is a fact about one
//  version of one program rather than a contract. That is exactly why the cases
//  below are verbatim captures rather than hand-written approximations: when the
//  interface changes, a case here fails and says which rule died, instead of the
//  sidebar quietly reporting the wrong thing.
//
//  The half that matters is the idle side. A pane wrongly called `working` just
//  looks busy; a pane wrongly called `done` says "your turn" about an agent that
//  is still going, and that is the mistake this feature exists to prevent.
//
//  swiftc -O -o /tmp/screenstatecheck TmuxGUI/Status/AgentState.swift \
//      TmuxGUI/Status/AgentStateStrategy.swift Tools/ScreenStateCheck/main.swift \
//      && /tmp/screenstatecheck
//

import Foundation

var failures = 0
var total = 0

func check(_ name: String, screen: [String], command: String = "2.1.220",
           changed: Bool = false, wants: AgentState?)
{
    total += 1
    var evidence = AgentEvidence(paneID: "%1", currentCommand: command)
    evidence.screen = screen
    evidence.screenChanged = changed
    let got = ScreenAgentStrategy.badge(from: evidence)?.state
    if got == wants {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)\n      got \(got.map(\.rawValue) ?? "nil"), wanted \(wants.map(\.rawValue) ?? "nil")")
    }
}

// MARK: - Captured from live panes, 2026-07-29

/// An agent sitting at its prompt having answered. Note the input box is fully
/// drawn: two rules around a `❯` line, then the status footer. This shape is
/// present while working too, which is why nothing here keys on it.
let idle = [
    "✻ Cogitated for 21s",
    "※ recap: You were testing the option picker, and I ran three mock rounds.",
    "",
    "────────────────────────────────────────────────────────────",
    "❯ ",
    "────────────────────────────────────────────────────────────",
    "   ~/Code/PastePawX  ⎇ main  ◆ Opus 5 (1M context)  $1.33  ⬡ ▱▱▱▱▱ 6% ↑59.7k",
    "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 3 agents",
]

/// The same pane while the turn is running. The only difference that matters is
/// the elapsed counter on the spinner line.
let working = [
    "⏺ Created hello.txt containing hi.",
    "✻ Zigzagging… (10m 19s · ↓ 30.3k tokens)",
    "────────────────────────────────────────────────────────────",
    "❯ ",
    "────────────────────────────────────────────────────────────",
    "   ~/dotfiles  ⎇ master  ◆ Opus 5 (1M context)  $1.93  ⬡ ▱▱▱▱▱ 9%",
    "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 3 agents",
]

let workingXHigh = [
    "✻ Sock-hopping… (1m 56s · ↓ 6.0k tokens · thinking more with xhigh effort)",
    "────────────────────────────────────────────────────────────",
    "❯ ",
    "────────────────────────────────────────────────────────────",
]

/// Manual permission mode. The footer loses `(shift+tab to cycle)` entirely,
/// which is why an earlier rule keyed on that string was discarded.
let idleManualMode = [
    "⏺ Created hello.txt in permsample/ containing hi.",
    "✻ Sautéed for 5s",
    "────────────────────────────────────────────────────────────",
    "❯ show me the file contents",
    "────────────────────────────────────────────────────────────",
    "   ~/.claude/…/permsample  ⎇ main!?  ◆ Opus 5 (1M context)  $0.26",
    "  ⏸ manual mode on · ← 3 agents",
]

print("— the two states, from live captures —")
check("an agent at its prompt is the user's turn", screen: idle, wants: .done)
check("an elapsed counter means the turn is running", screen: working, wants: .working)
check("the counter is found with extra text after it", screen: workingXHigh, wants: .working)
check("manual mode, no shift+tab footer, still idle", screen: idleManualMode, wants: .done)

/// Reported from use, 2026-07-29: this was drawn as `done`. Verbatim tail of
/// the pane. The agent is waiting on a multiple-choice answer.
let askingAQuestion = [
    "  这样 A 负责「当下」，B 负责「事后」，各管一头，谁也不用迁就谁。",
    "  要我做哪些？",
    "────────────────────────────────────────────────────────────",
    "←  ☐ 做哪些  ☐ 看的地方  ☐ 抽哪个  ✔ Submit  →",
    "这四个办法，做哪些？（可多选）",
    "❯ 1. [ ] A 加规则（推荐）",
    "  往 CLAUDE.md 的 Reporting 小节里加三四行。",
    "  2. [ ] B 抽话器（推荐）",
]

/// The shape a permission prompt takes, which is the same shape.
let askingPermission = [
    "⏺ Bash(rm -rf build)",
    "────────────────────────────────────────────────────────────",
    "Do you want to proceed?",
    "❯ 1. Yes",
    "  2. No, and tell Claude what to do differently",
]

check("a multiple-choice question is blocked, not done", screen: askingAQuestion, wants: .needsInput)
check("a permission prompt is blocked too", screen: askingPermission, wants: .needsInput)
check("blocked outranks a spinner drawn above it",
      screen: ["✻ Thinking… (2m 4s · ↓ 1k tokens)"] + askingAQuestion, wants: .needsInput)

print("\n— the discarded ideas, pinned so they stay discarded —")
check("the input box alone does not mean idle", screen: working, wants: .working)
check("a `❯` line with text in it is still idle", screen: idleManualMode, wants: .done)

print("\n— the repaint fallback —")
check("a repainting pane is working even with no rule matched",
      screen: ["something with no marker at all"], changed: true, wants: .working)
check("a static pane with no marker is the user's turn",
      screen: ["something with no marker at all"], changed: false, wants: .done)

print("\n— what must never happen —")
// A spinner that scrolled up is not the current state. The working rules reach
// 10 lines; this one is 16 up, which is well inside the 24 the *blocked* rules
// use — so this case also pins that a wide rule cannot lend its reach to a
// narrow one.
check("a spinner that scrolled out of reach does not count", screen: [
    "an old line reading (10m 19s · ↓ 1k tokens) from an hour ago",
    "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12",
    "────────────────────────────────────────────────────────────",
    "❯ ",
    "────────────────────────────────────────────────────────────",
], wants: .done)

// And the converse: a question's marker sits above its own option list, so it
// must still be found from further up than a spinner ever is.
check("a question found 15 lines up is still blocked", screen: [
    "←  ☐ a  ☐ b  ✔ Submit  →",
    "❯ 1. [ ] first",
    "  detail", "  2. [ ] second", "  detail", "  3. [ ] third", "  detail",
    "  4. [ ] fourth", "  detail", "  5. [ ] Type something", "     Next",
    "  6. Chat about this",
    "────────────────────────────────────────────────────────────",
    "❯ ",
    "────────────────────────────────────────────────────────────",
], wants: .needsInput)

check("a pane with no agent gets no badge at all", screen: idle, command: "zsh", wants: nil)

// An agent this strategy has no rules for must not be classified by Claude
// Code's. Before the table was keyed by kind, `codex` got "working while it
// repaints, done otherwise" and never a permission prompt — confidently wrong
// rather than honestly silent.
check("an agent with no rules of its own is not classified",
      screen: askingAQuestion, command: "codex", wants: nil)
check("…and neither does the static fallback claim it is done",
      screen: idle, command: "codex", wants: nil)

total += 1
if ScreenAgentStrategy.badge(from: {
    var e = AgentEvidence(paneID: "%1", currentCommand: "2.1.220")
    e.screen = nil
    return e
}())?.state == nil {
    print("ok    a pane never captured reports no state rather than guessing idle")
} else {
    failures += 1
    print("FAIL  a pane never captured should not report a state")
}

// MARK: - Rules that are only reasoned about

print("\n— rules not yet seen on a live pane —")
let unverified = ScreenAgentStrategy.rules.filter { !$0.verified }
print("      \(unverified.count) of \(ScreenAgentStrategy.rules.count) rules are unverified:")
for rule in unverified { print("        \(rule.state.rawValue) ← \(rule.test)") }
print("      Inducing a permission prompt failed on the development machine —")
print("      the project's own settings auto-approve. These stay marked until one")
print("      is observed. They are additive, so an unverified rule can only ever")
print("      turn a `done` into a `needs-input`, never the reverse.")

print("")
if failures == 0 {
    print("\(total) cases, all passed")
} else {
    print("\(failures) of \(total) cases FAILED")
    exit(1)
}
