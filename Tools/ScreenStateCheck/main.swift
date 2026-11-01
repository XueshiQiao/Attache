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
//  swiftc -O -o /tmp/screenstatecheck AgentHub/AgentHubTypes.swift \
//      Attache/Status/AgentState.swift Attache/Status/AgentStateStrategy.swift \
//      Tools/ScreenStateCheck/main.swift && /tmp/screenstatecheck
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

// MARK: - Captured from live panes, 2026-11-01 (Claude Code 2.1.308)

print("\n— finished turns >= 1m with `· done` timestamps, and tall footers —")

/// Verbatim tail of `Dev 11:HyperCapslock` (%28), which sat stuck on `working`
/// because Claude Code started appending ` · done 10:12 PM` after the finished
/// turn duration (`12m 21s ·`), matching the unparenthesised `\d+m \d+s ·` rule.
let idleHyperCapslock = [
    "✻ Cogitated for 12m 21s · done 10:12 PM",
    "※ recap: 26.10.110 已经发布，所有测试都通过了，App 内更新和 Homebrew 都能装到新版。下一步：你在 Release",
    "  版里检查更新，打开 Release 版之前，记得先退出正在运行的 Dev 版。",
    "                                                                    new task? /clear to save 134.3k tokens",
    "─────────────────────────────────────────────────────────────────────────────────────────────────────────────",
    "❯\u{00A0}",
    "─────────────────────────────────────────────────────────────────────────────────────────────────────────────",
    "  ~/Code/HyperCapslock   main  |  Opus 5.5  ctx 13%                                              12:00",
    "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent",
]

/// Verbatim tail of `Dev 13:DroidPaw` (%14): narrow pane, finished 6m 25s turn,
/// truncated idle notice, and an unsent draft sitting in `❯`.
let idleDroidPaw = [
    "  开头的虚拟机会话输出，可以直接看出失败在哪一步。",
    "✻ Sautéed for 6m 25s · done 12:03 PM",
    "  new task? /clear to save 139.4k… · Update available! Run: brew upgrade claude-…",
    "───────────────────────────────────────────────────────────────────────────────────",
    "❯\u{00A0}我刚才测了，还是连不上，日志在这里",
    "───────────────────────────────────────────────────────────────────────────────────",
    "  ~/Code/DroidPaw   main  |  Sonnet 5.5  ctx 14%  |  wk ▓▓▓░▒░░░░░ used 34%/43% …",
    "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent",
]

/// Verbatim tail of `Dev 5:CCSwitcher` (%107).
let idleCCSwitcher = [
    "  还有两个遗留：#46、#47 两个 PR 因为改了和 #52 相同的文件，现在有冲突；CI 没有保存 dSYM。",
    "✻ Worked for 8m 37s · done 11:57 AM",
    "                                                                                        new task? /clear to save 147.4k tokens · Update available! Run: brew upgrade claude-code",
    "─────────────────────────────────────────────────────────────────────────────────────────────────────────────",
    "❯\u{00A0}",
    "─────────────────────────────────────────────────────────────────────────────────────────────────────────────",
    "  ~/Code/CCSwitcher   main  |  Sonnet 5.5  ctx 15%                                                    15:06",
    "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent",
]

/// Verbatim tail of `Dev 1:QDuo` (%10) after finishing with a background monitor
/// and a background subagent still ticking in the footer below `⏺ main`.
let idleWithRunningSubagent = [
    "✻ Crunched for 7m 10s · done 3:48 PM · 1 monitor still running",
    "⏺ Agent \"Alice code review of logging changes\" finished · 2m 19s",
    "                                                        Update available! Run: brew upgrade claude-code",
    "─────────────────────────────────────────────────────────────────────────────────────────────────────────",
    "❯\u{00A0}",
    "─────────────────────────────────────────────────────────────────────────────────────────────────────────",
    "  ~/Code/qduo   main  |  Sonnet 5.5  ctx 14%  |  5h ▓▓▓░░▒░░░░ used 25%/57%",
    "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent",
    "",
    "  ⏺ main",
    "  ◯ alice  Alice 复核 heldDelivery 改法                2m 43s · ↓ 11.8k tokens",
]

/// Verbatim tail of `Dev 1:QDuo` (%10) while genuinely working, with tip,
/// update banner, and background subagent footer pushing the spinner 11+ lines
/// up from the bottom of the pane.
let workingAboveTallFooter = [
    "✳ Puzzling… (54s · ↓ 4.5k tokens)",
    "  ⎿  Tip: Run Claude Code locally or remotely using the Claude desktop app",
    "                                                        Update available! Run: brew upgrade claude-code",
    "─────────────────────────────────────────────────────────────────────────────────────────────────────────",
    "❯\u{00A0}first line of a queued follow-up",
    "  second line wrapped inside the input box",
    "─────────────────────────────────────────────────────────────────────────────────────────────────────────",
    "  ~/Code/qduo   main  |  Sonnet 5.5  ctx 13%  |  5h ▓▓░░░▒░░░░ used 20%/50%",
    "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent",
    "",
    "  ⏺ main",
    "  ◯ alice  Alice 复核 heldDelivery 改法                   2s · ↑ 3 tokens",
]

/// Verbatim folder-trust confirmation dialog from `Dev 11:HyperCapslock` (%28):
/// unnumbered `❯ No, exit` options with `Enter to confirm · Esc to cancel`.
let askingFolderTrust = [
    " Claude Code'll be able to read, edit, and execute files here.",
    "",
    " ⚠ This folder pre-approves 22 tool permissions in .claude/settings.local.json:",
    " These will apply without asking. Only proceed if you trust this configuration.",
    "",
    " ❯ No, exit",
    "   Yes, I trust this folder",
    "",
    " Enter to confirm · Esc to cancel",
]

check("HyperCapslock finished 12m 21s turn (`· done 10:12 PM`) is idle",
      screen: idleHyperCapslock, command: "claude", wants: .done)
check("DroidPaw finished 6m 25s turn (`· done 12:03 PM`) is idle",
      screen: idleDroidPaw, command: "claude", wants: .done)
check("CCSwitcher finished 8m 37s turn (`· done 11:57 AM`) is idle",
      screen: idleCCSwitcher, command: "claude", wants: .done)
check("finished turn + background subagent footer (`2m 43s ·`) is still idle for main",
      screen: idleWithRunningSubagent, command: "claude", wants: .done)
check("live spinner above tall subagent footer + multi-line draft is working",
      screen: workingAboveTallFooter, command: "claude", wants: .working)
check("live spinner over an hour (`(1h 2m 3s ·` / `(1h 2m ·`) is working",
      screen: ["✻ Thinking… (1h 2m 3s · ↓ 90.1k tokens)"] + Array(idle.suffix(5)),
      command: "claude", wants: .working)
check("live spinner over an hour without seconds (`(1h 2m ·`) is working",
      screen: ["✻ Thinking… (1h 2m · ↓ 90.1k tokens)"] + Array(idle.suffix(5)),
      command: "claude", wants: .working)
check("fresh pane padded with 40 trailing blank rows from capture-pane still sees spinner",
      screen: working + Array(repeating: "", count: 40), command: "claude", wants: .working)
check("fresh pane padded with 40 trailing blank rows still sees folder-trust prompt",
      screen: askingFolderTrust + Array(repeating: "", count: 40), command: "claude", wants: .needsInput)

print("\n— what counts as an output repaint (`didOutputChange`) —")

func checkRepaint(_ name: String, from previous: [String], to current: [String],
                  kind: String? = "claude", wants: Bool)
{
    total += 1
    let got = ScreenAgentStrategy.didOutputChange(from: previous, to: current, kind: kind)
    if got == wants {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)\n      got \(got), wanted \(wants)")
    }
}

let basePane = [
    "   earlier line that scrolls off when the footer grows",
    "⏺ Finished updating the configuration.",
    "✻ Cooked for 16s · done 1:57 PM",
    "───────────────────────────────────────────────────────────────────────────────────",
    "❯\u{00A0}",
    "───────────────────────────────────────────────────────────────────────────────────",
    "  ~/Code/Flowy   main  |  Sonnet 5.5  ctx 13%                               14:57",
    "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent",
]

checkRepaint("status-line clock and quota tick does not count as agent output",
             from: basePane,
             to: Array(basePane.prefix(6)) + [
                 "  ~/Code/Flowy   main  |  Sonnet 5.5  ctx 14%                               14:58",
                 "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent",
             ],
             wants: false)

checkRepaint("typing or async ghost suggestion inside `❯` does not count as agent output",
             from: basePane,
             to: Array(basePane.prefix(4)) + [
                 "❯\u{00A0}跑完了吧？",
             ] + Array(basePane.suffix(3)),
             wants: false)

checkRepaint("multi-line draft growing the input box and clipping row 0 does not count",
             from: basePane,
             to: [
                 "⏺ Finished updating the configuration.",
                 "✻ Cooked for 16s · done 1:57 PM",
                 "───────────────────────────────────────────────────────────────────────────────────",
                 "❯\u{00A0}line one of draft",
                 "  line two of draft",
                 "───────────────────────────────────────────────────────────────────────────────────",
                 "  ~/Code/Flowy   main  |  Sonnet 5.5  ctx 13%                               14:57",
                 "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent",
             ],
             wants: false)

checkRepaint("background subagent timer ticking below `⏺ main` does not count",
             from: idleWithRunningSubagent,
             to: Array(idleWithRunningSubagent.dropLast()) + [
                 "  ◯ alice  Alice 复核 heldDelivery 改法                2m 45s · ↓ 12.1k tokens",
             ],
             wants: false)

checkRepaint("3-minute idle `※ recap:` and `new task? /clear` notice does not count",
             from: basePane,
             to: [
                 "✻ Cooked for 16s · done 1:57 PM",
                 "※ recap: 已按上次顺序跑完采样，14:03 后整理表格。",
                 "  new task? /clear to save 135.1k tokens · Update available! Run: brew upgrade claude-code",
                 "───────────────────────────────────────────────────────────────────────────────────",
                 "❯\u{00A0}",
                 "───────────────────────────────────────────────────────────────────────────────────",
                 "  ~/Code/Flowy   main  |  Sonnet 5.5  ctx 13%                               15:00",
                 "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent",
             ],
             wants: false)

checkRepaint("`⏺ Compacted while idle` does not count as a running turn",
             from: basePane,
             to: [
                 "  ⎿  Skills restored (minitool-zip-builder)",
                 "⏺ Compacted while idle, before the prompt cache expired",
                 "                                           Update available! Run: brew upgrade claude-code",
                 "───────────────────────────────────────────────────────────────────────────────────",
                 "❯\u{00A0}",
                 "───────────────────────────────────────────────────────────────────────────────────",
                 "  ~/Code/Flowy   main  |  Opus 5.5  ctx 0%                                  15:05",
                 "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent",
             ],
             wants: false)

checkRepaint("column resize (input-box rule width changed) does not count",
             from: basePane,
             to: [
                 "  earlier line that scrolls off",
                 "  when the footer grows",
                 "⏺ Finished updating the configuration.",
                 "✻ Cooked for 16s · done 1:57 PM",
                 "──────────────────────────────────────────────────",
                 "❯\u{00A0}",
                 "──────────────────────────────────────────────────",
                 "  ~/Code/Flowy   main  |  Sonnet 5.5  ctx 13%",
             ],
             wants: false)

checkRepaint("row resize (`capture-pane` line count changed) does not count",
             from: basePane,
             to: basePane + ["", ""],
             wants: false)

checkRepaint("a fast <2s turn that already finished above the input box DOES count",
             from: basePane,
             to: [
                 "✻ Cooked for 16s · done 1:57 PM",
                 "❯ ping",
                 "⏺ pong",
                 "✻ Cooked for 1s · done 1:58 PM",
                 "───────────────────────────────────────────────────────────────────────────────────",
                 "❯\u{00A0}",
                 "───────────────────────────────────────────────────────────────────────────────────",
                 "  ~/Code/Flowy   main  |  Sonnet 5.5  ctx 14%                               14:58",
             ],
             wants: true)

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
