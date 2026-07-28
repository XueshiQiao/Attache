//
//  main.swift
//  AgentStateCheck
//
//  Checks `AgentDetector` against the values a `%subscription-changed` for
//  `AgentDetector.paneFormat` actually carries.
//
//  The half that matters is `isAgentCommand`. It is a heuristic over an
//  undocumented signal — Claude Code reporting its bare version as
//  `pane_current_command` — and every false positive puts a live-agent dot on a
//  row where nothing is running. A false negative only costs a missing dot.
//  So the cases lean on things that look like versions and are not.
//
//  swiftc -O -o /tmp/agentcheck TmuxGUI/Status/AgentState.swift \
//      Tools/AgentStateCheck/main.swift && /tmp/agentcheck
//

import Foundation

private var failures = 0
private var total = 0

private func check(_ name: String, _ problem: @autoclosure () -> String?) {
    total += 1
    if let problem = problem() {
        failures += 1
        print("FAIL  \(name)\n      \(problem)")
    } else {
        print("ok    \(name)")
    }
}

private func expect(_ actual: some Equatable, _ wanted: some Equatable) -> String? {
    "\(actual)" == "\(wanted)" ? nil : "got \(actual), wanted \(wanted)"
}

/// Build a subscription value the way tmux would.
private func value(state: String, kind: String, at: String, command: String) -> String {
    [state, kind, at, command].joined(separator: "\u{01}")
}

// MARK: - Which commands count as an agent

print("— is this pane running an agent —")
for command in ["2.1.220", "2.1", "0.0.1", "claude", "codex", "grok"] {
    check("`\(command)` is an agent", expect(AgentDetector.isAgentCommand(command), true))
}
for command in [
    "zsh", "bash", "lazygit", "htop", "vim", "node", "",
    // The ones a loose "has a digit and a dot" test would wrongly claim.
    "python3.12", "2.txt", "ruby2.7.1", "a.b.c", "1.2.3.4", "1..2", ".2.1", "2.1.",
    "v2.1.220", "2.1.220-beta",
] {
    check("`\(command)` is not an agent", expect(AgentDetector.isAgentCommand(command), false))
}

// MARK: - Parsing a subscription value

print("\n— parsing the subscription value —")

check("a hook-reported state is taken whole", {
    let badge = AgentDetector.badge(
        fromSubscriptionValue: value(state: "needs-input", kind: "claude", at: "1785247200", command: "2.1.220")
    )
    return expect(badge?.state?.rawValue ?? "nil", "needs-input")
        ?? expect(badge?.kind ?? "nil", "claude")
        ?? expect(badge?.since?.timeIntervalSince1970 ?? -1, 1785247200.0)
}())

check("an agent with no hook still gets a badge, with no state", {
    let badge = AgentDetector.badge(
        fromSubscriptionValue: value(state: "", kind: "", at: "", command: "2.1.220")
    )
    return expect(badge != nil, true)
        ?? expect(badge?.state == nil, true)
        // The kind is inferred from the command, so the tooltip still has a
        // word to use rather than saying "unknown agent".
        ?? expect(badge?.kind ?? "nil", "claude")
}())

check("a shell prompt gets no badge at all", {
    expect(AgentDetector.badge(
        fromSubscriptionValue: value(state: "", kind: "", at: "", command: "zsh")
    ) == nil, true)
}())

check("a stale state on a dead agent is ignored — the ^C case", {
    // The hook wrote `working` and the agent was killed before its exit hook
    // could run, so tmux still holds the option while the pane is back at a
    // prompt. This is the guard that stops a row spinning forever.
    expect(AgentDetector.badge(
        fromSubscriptionValue: value(state: "working", kind: "claude", at: "1785247200", command: "zsh")
    ) == nil, true)
}())

check("an unrecognised state is dropped rather than guessed at", {
    let badge = AgentDetector.badge(
        fromSubscriptionValue: value(state: "compacting", kind: "claude", at: "0", command: "2.1.220")
    )
    return expect(badge != nil, true) ?? expect(badge?.state == nil, true)
}())

check("a truncated value does not crash or half-parse", {
    expect(AgentDetector.badge(fromSubscriptionValue: "working\u{01}claude") == nil, true)
}())

check("an empty value is not an agent", {
    expect(AgentDetector.badge(fromSubscriptionValue: "") == nil, true)
}())

check("a kind the app has never heard of is kept, not overwritten", {
    let badge = AgentDetector.badge(
        fromSubscriptionValue: value(state: "working", kind: "some-new-agent", at: "0", command: "claude")
    )
    return expect(badge?.kind ?? "nil", "some-new-agent")
}())

// MARK: - Which pane speaks for the window

print("\n— aggregating panes onto one row —")

private let working = AgentBadge(state: .working, kind: "claude", since: nil)
private let needs = AgentBadge(state: .needsInput, kind: "claude", since: nil)
private let done = AgentBadge(state: .done, kind: "claude", since: nil)
private let bare = AgentBadge(state: nil, kind: "claude", since: nil)

check("blocked outranks working — the whole point of the badge", {
    expect(AgentBadge.moreUrgent(working, needs)?.state?.rawValue ?? "nil", "needs-input")
        ?? expect(AgentBadge.moreUrgent(needs, working)?.state?.rawValue ?? "nil", "needs-input")
}())
check("working outranks done", {
    expect(AgentBadge.moreUrgent(done, working)?.state?.rawValue ?? "nil", "working")
}())
check("done outranks a bare presence", {
    expect(AgentBadge.moreUrgent(bare, done)?.state?.rawValue ?? "nil", "done")
}())
check("anything outranks nothing", {
    expect(AgentBadge.moreUrgent(nil, bare)?.kind ?? "nil", "claude")
        ?? expect(AgentBadge.moreUrgent(bare, nil)?.kind ?? "nil", "claude")
        ?? expect(AgentBadge.moreUrgent(nil, nil) == nil, true)
}())

// MARK: - Result

print("")
if failures == 0 {
    print("\(total) cases, all passed")
} else {
    print("\(failures) of \(total) cases FAILED")
    exit(1)
}
