//
//  ExpectationCheck — the table in the design note, executed.
//
//  Compile with the one file it checks:
//    swiftc -O -o /tmp/expectationcheck TmuxGUI/Diagnostics/CommandExpectation.swift \
//      Tools/ExpectationCheck/main.swift
//    /tmp/expectationcheck
//
//  Same stance as ReplyCheck: the dangerous failure is not a missed anomaly,
//  it is a *false* one — an expectation that can never be met turns the
//  mechanism into noise and gets the whole surface ignored. So half of these
//  cases assert that commands with no observable effect derive nothing, and
//  that every derived expectation is judged met by the model state its own
//  command produces.
//

import Foundation

var failures = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        print("  ok  \(name)")
    } else {
        print("FAIL  \(name)")
        failures += 1
    }
}

// A two-window session: @1 (index 1, "build", panes %10 %11, %10 active),
// @2 (index 2, "logs", pane %20, zoomed would differ).
let facts = DiagnosticsFacts(
    activeWindowID: "@1",
    windows: [
        DiagnosticsWindowFacts(
            id: "@1", index: 1, name: "build", activePaneID: "%10",
            paneIDs: ["%10", "%11"],
            savedLayout: "l1", visibleLayout: "l1"
        ),
        DiagnosticsWindowFacts(
            id: "@2", index: 2, name: "logs", activePaneID: "%20",
            paneIDs: ["%20"],
            savedLayout: "l2", visibleLayout: "l2"
        ),
    ]
)

func factsChanging(
    active: String? = "@1",
    window1Panes: [String] = ["%10", "%11"],
    window1ActivePane: String = "%10",
    window1Visible: String = "l1",
    dropWindow2: Bool = false,
    extraWindow: Bool = false
) -> DiagnosticsFacts {
    var windows = [
        DiagnosticsWindowFacts(
            id: "@1", index: 1, name: "build", activePaneID: window1ActivePane,
            paneIDs: window1Panes, savedLayout: "l1", visibleLayout: window1Visible
        ),
    ]
    if !dropWindow2 {
        windows.append(DiagnosticsWindowFacts(
            id: "@2", index: 2, name: "logs", activePaneID: "%20",
            paneIDs: ["%20"], savedLayout: "l2", visibleLayout: "l2"
        ))
    }
    if extraWindow {
        windows.append(DiagnosticsWindowFacts(
            id: "@3", index: 3, name: "new", activePaneID: "%30",
            paneIDs: ["%30"], savedLayout: "l3", visibleLayout: "l3"
        ))
    }
    return DiagnosticsFacts(activeWindowID: active, windows: windows)
}

// ── select-window ────────────────────────────────────────────────────────────
if let e = CommandExpectation.derive(from: "select-window -t @2", facts: facts) {
    check("select-window derives", true)
    check("select-window pending while active is @1", e.isMet(facts) == false)
    check("select-window met when active becomes @2", e.isMet(factsChanging(active: "@2")) == true)
    check("select-window names the window for a person", e.subject == "window 2 · logs")
    check("select-window log tier is the fast one", e.logAfter == 0.3)
    check("select-window toast tier is 1.5s", e.toastAfter == 1.5)
} else {
    check("select-window derives", false)
}

// ── select-pane: judged against the pane's own window, not the active one ───
if let e = CommandExpectation.derive(from: "select-pane -t %11", facts: facts) {
    check("select-pane pending while %10 active", e.isMet(facts) == false)
    check(
        "select-pane met when its window reports it",
        e.isMet(factsChanging(window1ActivePane: "%11")) == true
    )
    check(
        "select-pane in a background window is not judged by the foreground one",
        CommandExpectation.derive(from: "select-pane -t %20", facts: facts)?.isMet(facts) == true
    )
    check(
        "select-pane whose pane vanishes is undecided, not met",
        e.isMet(factsChanging(window1Panes: ["%10"])) == nil
    )
} else {
    check("select-pane derives", false)
}

// ── split-window: baseline banked at derivation ─────────────────────────────
if let e = CommandExpectation.derive(from: "split-window -h -t %10 -c '#{pane_current_path}'", facts: facts) {
    check("split pending at the old pane count", e.isMet(facts) == false)
    check(
        "split met when the window grows",
        e.isMet(factsChanging(window1Panes: ["%10", "%11", "%12"])) == true
    )
    check(
        "split not met by a pane count that fell",
        e.isMet(factsChanging(window1Panes: ["%10"])) == false
    )
} else {
    check("split-window derives", false)
}
check(
    "split targeting an unknown pane derives nothing — no baseline, no honest check",
    CommandExpectation.derive(from: "split-window -h -t %99 -c '#{x}'", facts: facts) == nil
)

// ── kill-pane / kill-window ─────────────────────────────────────────────────
if let e = CommandExpectation.derive(from: "kill-pane -t %11", facts: facts) {
    check("kill-pane pending while the pane exists", e.isMet(facts) == false)
    check("kill-pane met when it is gone", e.isMet(factsChanging(window1Panes: ["%10"])) == true)
} else {
    check("kill-pane derives", false)
}
check(
    "kill-pane on a pane the model lacks derives nothing",
    CommandExpectation.derive(from: "kill-pane -t %99", facts: facts) == nil
)
if let e = CommandExpectation.derive(from: "kill-window -t @2", facts: facts) {
    check("kill-window met when the window leaves", e.isMet(factsChanging(dropWindow2: true)) == true)
} else {
    check("kill-window derives", false)
}

// ── new-window ──────────────────────────────────────────────────────────────
if let e = CommandExpectation.derive(from: "new-window -t $5", facts: facts) {
    check("new-window pending on the same id set", e.isMet(facts) == false)
    check("new-window met when the set changes", e.isMet(factsChanging(extraWindow: true)) == true)
} else {
    check("new-window derives", false)
}

// ── resize-pane, both forms ─────────────────────────────────────────────────
if let e = CommandExpectation.derive(from: "resize-pane -Z -t %10", facts: facts) {
    check("zoom pending while layouts agree", e.isMet(facts) == false)
    check(
        "zoom met when visible diverges from saved",
        e.isMet(factsChanging(window1Visible: "zoomed")) == true
    )
} else {
    check("resize-pane -Z derives", false)
}
if let e = CommandExpectation.derive(from: "resize-pane -t %10 -x 40", facts: facts) {
    check("resize pending while the layout holds", e.isMet(facts) == false)
    check(
        "resize met when the layout string moves",
        e.isMet(factsChanging(window1Visible: "l1b")) == true
    )
} else {
    check("resize-pane -x derives", false)
}

// ── Commands with no observable effect derive nothing ───────────────────────
for command in [
    "list-windows -t $2 -F '#{window_id}'",
    "capture-pane -p -t %10",
    "display-message -p -t %10 'x'",
    "send-keys -t %10 -H <3 bytes withheld>",
    "refresh-client -C 178x60",
    "set-option -w -t @1 @agent_seen 123",
    "move-window -b -d -s @2 -t $1:1",
    "select-window -t maybe-a-name", // not an id: a name could be stale
    "select-pane -L",                // no -t at all
] {
    check("derives nothing: \(command)", CommandExpectation.derive(from: command, facts: facts) == nil)
}

// ── Dedupe key collapses a click storm ──────────────────────────────────────
let first = CommandExpectation.derive(from: "select-pane -t %11", facts: facts)
let second = CommandExpectation.derive(from: "select-pane -t %11", facts: facts)
check("same intent, same dedupe key", first?.dedupeKey == second?.dedupeKey)
let other = CommandExpectation.derive(from: "select-pane -t %10", facts: facts)
check("different pane, different key", first?.dedupeKey != other?.dedupeKey)

print(failures == 0 ? "\nExpectationCheck: all passed" : "\nExpectationCheck: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
