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

// MARK: - Seen, which is what retires a finished agent

print("\n— the unread model —")

private func badge(_ state: AgentState?, since: TimeInterval?, seen: TimeInterval?) -> AgentBadge {
    var b = AgentBadge(state: state, kind: "claude",
                       since: since.map { Date(timeIntervalSince1970: $0) })
    b.seenAt = seen.map { Date(timeIntervalSince1970: $0) }
    return b
}

check("a finished agent nobody has looked at stays news", {
    expect(badge(.done, since: 1000, seen: nil).isSettled, false)
}())
check("looked at after it finished — retired", {
    expect(badge(.done, since: 1000, seen: 2000).isSettled, true)
}())
check("looked at BEFORE it finished — still news", {
    // The case a naive "has a seen timestamp" test gets wrong: you were in that
    // window, left, and it finished after you went.
    expect(badge(.done, since: 2000, seen: 1000).isSettled, false)
}())
check("a working agent is never retired by looking at it", {
    expect(badge(.working, since: 1000, seen: 2000).isSettled, false)
}())
check("**a blocked agent is never retired by looking at it**", {
    // The failure that matters most: "needs you" must not be hidden because
    // the row was clicked. Only `done` is retirable.
    expect(badge(.needsInput, since: 1000, seen: 2000).isSettled, false)
}())
check("no timestamp at all cannot be retired", {
    // Regression guard for a real defect. The screen strategy produces badges
    // with no `since`; comparing a seen-timestamp against `distantPast` made
    // *any* click settle the mark permanently, so a window clicked once never
    // showed green again however many turns finished afterwards. The connection
    // stamps the transition now — but if that ever stops, this is the shape the
    // bug takes, and it must not silently pass.
    expect(badge(.done, since: nil, seen: 2000).isSettled, true)
}())

check("two finished panes: the window speaks for the later one", {
    // The bug this pins: pane A finished long ago and was seen; pane B finished
    // just now. If the window inherits A's timestamp it reports itself read,
    // and B finishing is lost with no way back.
    let old = badge(.done, since: 1000, seen: nil)
    let fresh = badge(.done, since: 5000, seen: nil)
    return expect(AgentBadge.moreUrgent(old, fresh)?.since?.timeIntervalSince1970 ?? -1, 5000.0)
        // Order must not matter — the reduce feeds them in `paneIDs` order.
        ?? expect(AgentBadge.moreUrgent(fresh, old)?.since?.timeIntervalSince1970 ?? -1, 5000.0)
}())

check("and the window is then correctly unread", {
    var old = badge(.done, since: 1000, seen: nil)
    let fresh = badge(.done, since: 5000, seen: nil)
    var winner = AgentBadge.moreUrgent(old, fresh)!
    // The window's seen-mark is stamped after the reduce, as the connection does.
    winner.seenAt = Date(timeIntervalSince1970: 2000)
    old.seenAt = Date(timeIntervalSince1970: 2000)
    return expect(winner.isSettled, false) ?? expect(old.isSettled, true)
}())

check("a tie between ranks still prefers urgency over recency", {
    // Recency only breaks ties. A blocked pane outranks a done one however old.
    let blockedLongAgo = badge(.needsInput, since: 1000, seen: nil)
    let doneJustNow = badge(.done, since: 9000, seen: nil)
    return expect(AgentBadge.moreUrgent(blockedLongAgo, doneJustNow)?.state?.rawValue ?? "nil",
                  "needs-input")
}())

// MARK: - Result

print("")
if failures == 0 {
    print("\(total) cases, all passed")
} else {
    print("\(failures) of \(total) cases FAILED")
    exit(1)
}
