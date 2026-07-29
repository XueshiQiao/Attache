//
//  main.swift
//  AgentStatsCheck
//
//  Checks `AgentStats.parse` against the JSON Claude Code actually hands its
//  status line, and against the shapes it is going to hand it one day.
//
//  This parser decides what numbers a person reads off the rail and then plans
//  around — how much context is left, what the session has cost, whether the
//  five-hour window is about to run out. A parser that guesses is worse than
//  one that gives up: a blank field reads as "not known yet", and a confident
//  0% reads as "you have all of it left".
//
//  So the half that matters here is **everything that must come back nil**.
//  The captured payload from a fresh session carries `"used_percentage": null`,
//  and the obvious reading of that key — is it present — yields 0.
//
//  swiftc -O -o /tmp/statscheck TmuxGUI/Status/AgentStats.swift \
//      Tools/AgentStatsCheck/main.swift && /tmp/statscheck
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

private func describe(_ value: Int?) -> String { value.map(String.init) ?? "nil" }
private func describe(_ value: String?) -> String { value ?? "nil" }

// MARK: - The payload as captured

// Verbatim from Claude Code 2.1.220 on 2026-07-29, ids replaced. This is the
// fresh-session case: a real payload in which almost every context field is
// null, which is the shape that breaks a naive parser.
private let freshSession = """
{"session_id":"S","transcript_path":"/tmp/t.jsonl",\
"cwd":"/private/tmp/proj","effort":{"level":"xhigh"},\
"model":{"id":"claude-opus-5[1m]","display_name":"Opus 5 (1M context)"},\
"workspace":{"current_dir":"/private/tmp/proj","project_dir":"/private/tmp/proj","added_dirs":[]},\
"version":"2.1.220","output_style":{"name":"default"},\
"cost":{"total_cost_usd":0,"total_duration_ms":56786,"total_api_duration_ms":0,\
"total_lines_added":0,"total_lines_removed":0},\
"context_window":{"total_input_tokens":0,"total_output_tokens":0,\
"context_window_size":1000000,"current_usage":null,"used_percentage":null,\
"remaining_percentage":null},\
"exceeds_200k_tokens":false,"fast_mode":false,"thinking":{"enabled":true},\
"rate_limits":{"five_hour":{"used_percentage":69,"resets_at":1785294000},\
"seven_day":{"used_percentage":31,"resets_at":1785708000}}}
"""

// The same session once it has done some work.
private let workingSession = """
{"model":{"display_name":"Sonnet 5"},\
"effort":{"level":"medium"},"output_style":{"name":"Explanatory"},\
"cost":{"total_cost_usd":2.1437,"total_duration_ms":3847221,\
"total_lines_added":312,"total_lines_removed":87},\
"context_window":{"total_input_tokens":812344,"total_output_tokens":41233,\
"context_window_size":200000,"used_percentage":34.6},\
"rate_limits":{"five_hour":{"used_percentage":63,"resets_at":1785294000},\
"seven_day":{"used_percentage":31,"resets_at":1785708000}}}
"""

print("— the payload as captured, fresh session —")

check("it parses at all", expect(AgentStats.parse(freshSession) != nil, true))

private let fresh = AgentStats.parse(freshSession)!

check("model comes through in full", expect(describe(fresh.model), "Opus 5 (1M context)"))
check("model is shortened for the row", expect(describe(fresh.shortModel), "Opus 5"))
check(
    "a null used_percentage is nil, NOT zero",
    expect(describe(fresh.contextPercent), "nil")
)
check("the window size still comes through", expect(describe(fresh.contextWindowSize), "1000000"))
check(
    "no tokens sent yet means no token count",
    expect(describe(fresh.contextTokens), "nil")
)
check("a zero cost is zero, not nil", expect(describe(fresh.costCents), "0"))
check("effort", expect(describe(fresh.effort), "xhigh"))
check("output style", expect(describe(fresh.outputStyle), "default"))
check("five-hour usage", expect(describe(fresh.usage?.fiveHour?.usedPercent), "69"))
check("weekly usage", expect(describe(fresh.usage?.sevenDay?.usedPercent), "31"))
check(
    "resets_at is read as epoch seconds",
    expect(fresh.usage?.fiveHour?.resetsAt.timeIntervalSince1970 ?? -1, 1785294000.0)
)
check(
    "a fresh session has nothing for the row to draw",
    // Cost is 0 and known, so it is not empty — the row shows $0.00, which is
    // true, rather than nothing, which would read as "no agent here".
    expect(fresh.isEmpty, false)
)

print("\n— the same session once it has done work —")

private let working = AgentStats.parse(workingSession)!

check("context rounds to a whole percent", expect(describe(working.contextPercent), "35"))
check("cost rounds to cents", expect(describe(working.costCents), "214"))
check("cost renders", expect(describe(working.costText), "$2.14"))
check("lines added", expect(describe(working.linesAdded), "312"))
check("lines removed", expect(describe(working.linesRemoved), "87"))
check("tokens are summed", expect(describe(working.contextTokens), "853577"))
check("a model with no bracket is unchanged", expect(describe(working.shortModel), "Sonnet 5"))

print("\n— rounding is what stops the rail rebuilding every five seconds —")

check("34.4 and 34.6 are not the same percent", {
    let a = AgentStats.parse(#"{"context_window":{"used_percentage":34.4}}"#)
    let b = AgentStats.parse(#"{"context_window":{"used_percentage":34.6}}"#)
    return expect(a?.contextPercent == b?.contextPercent, false)
}())

check("34.61 and 34.64 are", {
    let a = AgentStats.parse(#"{"context_window":{"used_percentage":34.61}}"#)
    let b = AgentStats.parse(#"{"context_window":{"used_percentage":34.64}}"#)
    return expect(a == b, true)
}())

check("a cost that moves by a fraction of a cent does not change the value", {
    let a = AgentStats.parse(#"{"cost":{"total_cost_usd":2.14370}}"#)
    let b = AgentStats.parse(#"{"cost":{"total_cost_usd":2.14374}}"#)
    return expect(a == b, true)
}())

// MARK: - Nothing at all

print("\n— input that is not a payload —")

for (name, raw) in [
    ("an empty option", ""),
    ("whitespace", "   "),
    ("not JSON", "hello"),
    ("a truncated payload", #"{"model":{"display_name":"Opus"#),
    ("a JSON array", "[1,2,3]"),
    ("a JSON string", "\"hello\""),
    ("a JSON number", "42"),
    ("JSON null", "null"),
    ("an escaped octal run that is not JSON", "\\033[38;5;196m"),
] {
    check("\(name) parses to nothing", expect(AgentStats.parse(raw) == nil, true))
}

check("an empty object parses, and holds nothing", {
    guard let stats = AgentStats.parse("{}") else { return "got nil, wanted an empty AgentStats" }
    return expect(stats.isEmpty, true) ?? expect(stats.usage == nil, true)
}())

check("a newer Claude Code's unknown keys are ignored, not fatal", {
    let raw = #"{"model":{"display_name":"Opus 5"},"brand_new_field":{"a":[1,2]},"quota":7}"#
    return expect(describe(AgentStats.parse(raw)?.shortModel), "Opus 5")
}())

// MARK: - Values that must not become numbers

print("\n— a bool is not a number —")

check("fast_mode read as a percentage would be 0%; it must be nil", {
    // The guard this exercises is real: in Foundation a JSON bool arrives as an
    // NSNumber whose doubleValue is 0 or 1, so without a type check a wrong key
    // yields a confident number.
    let raw = #"{"context_window":{"used_percentage":false},"cost":{"total_cost_usd":true}}"#
    guard let stats = AgentStats.parse(raw) else { return "got nil, wanted an AgentStats" }
    return expect(describe(stats.contextPercent), "nil")
        ?? expect(describe(stats.costCents), "nil")
}())

check("a numeric string is still a number", {
    let raw = #"{"context_window":{"used_percentage":"34"},"cost":{"total_cost_usd":"2.14"}}"#
    guard let stats = AgentStats.parse(raw) else { return "got nil, wanted an AgentStats" }
    return expect(describe(stats.contextPercent), "34") ?? expect(describe(stats.costCents), "214")
}())

check("a non-numeric string is not", {
    let raw = #"{"context_window":{"used_percentage":"lots"}}"#
    return expect(describe(AgentStats.parse(raw)?.contextPercent), "nil")
}())

print("\n— numbers that would take the process down —")

for (name, raw) in [
    ("a digit run past Int64", #"{"cost":{"total_lines_added":99999999999999999999999999}}"#),
    ("a huge exponent", #"{"cost":{"total_lines_added":1e400}}"#),
    ("a negative exponent", #"{"cost":{"total_lines_added":-1e400}}"#),
] {
    check("\(name) yields nil rather than trapping", {
        // Reaching this line at all is most of the test: an unguarded
        // `Int(someDouble)` traps and takes the app with it.
        expect(describe(AgentStats.parse(raw)?.linesAdded), "nil")
    }())
}

// Found by review, 2026-07-29, and it took the process down rather than
// producing a wrong number. `total_cost_usd` was the one numeric field that
// did not go through the bounded helper: it was scaled to cents first and
// converted afterwards, so a value that is *finite* on its own — 1e308 is a
// perfectly ordinary JSON number — became infinity on the way to cents and
// trapped. The same shape as the digit run that killed `TerminalReply`.
for (name, raw) in [
    ("a cost that overflows only after scaling to cents", #"{"cost":{"total_cost_usd":1e308}}"#),
    ("a cost past Int range but finite", #"{"cost":{"total_cost_usd":1e30}}"#),
    ("a cost of infinity", #"{"cost":{"total_cost_usd":1e400}}"#),
] {
    check("\(name) yields nil rather than trapping", {
        expect(describe(AgentStats.parse(raw)?.costCents), "nil")
    }())
}

check("a negative cost is refused rather than shown", {
    // There is no such thing, so it is a field that means something else.
    expect(describe(AgentStats.parse(#"{"cost":{"total_cost_usd":-3}}"#)?.costCents), "nil")
}())

check("the largest plausible cost still parses", {
    expect(describe(AgentStats.parse(#"{"cost":{"total_cost_usd":99999.99}}"#)?.costCents), "9999999")
}())

check("a percentage over 100 is kept, not clamped", {
    // Being over the limit happens, and rounding it to 100 hides it.
    let raw = #"{"rate_limits":{"five_hour":{"used_percentage":140,"resets_at":1785294000}}}"#
    return expect(describe(AgentStats.parse(raw)?.usage?.fiveHour?.usedPercent), "140")
}())

check("a negative percentage is floored at zero", {
    let raw = #"{"context_window":{"used_percentage":-5}}"#
    return expect(describe(AgentStats.parse(raw)?.contextPercent), "0")
}())

print("\n— a reset time that cannot be one —")

for (name, seconds) in [
    ("zero", "0"),
    ("a small number that is probably a duration", "18000"),
    ("milliseconds mistaken for seconds", "1785294000000"),
] {
    check("\(name) is refused", {
        let raw = #"{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":\#(seconds)}}}"#
        return expect(AgentStats.parse(raw)?.usage == nil, true)
    }())
}

// MARK: - The burn mark

print("\n— how far through the window the clock is —")

private func fiveHour(resetsIn seconds: TimeInterval, now: Date) -> AccountUsage.Window {
    AccountUsage.Window(
        usedPercent: 50,
        resetsAt: now.addingTimeInterval(seconds),
        length: AccountUsage.fiveHourLength
    )
}

private let now = Date(timeIntervalSince1970: 1_785_290_000)

check("a window that just opened is at 0", {
    expect(fiveHour(resetsIn: 18000, now: now).elapsedFraction(now: now), 0.0)
}())
check("halfway through is 0.5", {
    expect(fiveHour(resetsIn: 9000, now: now).elapsedFraction(now: now), 0.5)
}())
check("a window that has passed clamps to 1", {
    expect(fiveHour(resetsIn: -600, now: now).elapsedFraction(now: now), 1.0)
}())
check("a reset further out than the window clamps to 0", {
    expect(fiveHour(resetsIn: 99999, now: now).elapsedFraction(now: now), 0.0)
}())

check("countdown reads in hours and minutes", {
    expect(fiveHour(resetsIn: 4800, now: now).countdown(now: now), "1h20m")
}())
check("countdown reads in days and hours past a day", {
    expect(
        AccountUsage.Window(
            usedPercent: 31, resetsAt: now.addingTimeInterval(410_400),
            length: AccountUsage.sevenDayLength
        ).countdown(now: now),
        "4d18h"
    )
}())
check("countdown under an hour is minutes", {
    expect(fiveHour(resetsIn: 720, now: now).countdown(now: now), "12m")
}())
check("countdown past the reset says so", {
    expect(fiveHour(resetsIn: -1, now: now).countdown(now: now), "now")
}())

// MARK: - Which snapshot to believe

print("\n— every session writes the same account numbers —")

private func usage(percent: Int, resets: TimeInterval) -> AccountUsage {
    AccountUsage(
        fiveHour: AccountUsage.Window(
            usedPercent: percent,
            resetsAt: Date(timeIntervalSince1970: resets),
            length: AccountUsage.fiveHourLength
        ),
        sevenDay: nil
    )
}

check("a later window beats an earlier one", {
    let old = usage(percent: 90, resets: 1_785_200_000)
    let new = usage(percent: 12, resets: 1_785_294_000)
    return expect(describe(AccountUsage.fresher(old, new)?.fiveHour?.usedPercent), "12")
        ?? expect(describe(AccountUsage.fresher(new, old)?.fiveHour?.usedPercent), "12")
}())

check("inside one window the higher reading is the later one", {
    let earlier = usage(percent: 40, resets: 1_785_294_000)
    let later = usage(percent: 63, resets: 1_785_294_000)
    return expect(describe(AccountUsage.fresher(earlier, later)?.fiveHour?.usedPercent), "63")
        ?? expect(describe(AccountUsage.fresher(later, earlier)?.fiveHour?.usedPercent), "63")
}())

check("nothing on one side keeps the other", {
    let known = usage(percent: 63, resets: 1_785_294_000)
    return expect(describe(AccountUsage.fresher(known, nil)?.fiveHour?.usedPercent), "63")
        ?? expect(describe(AccountUsage.fresher(nil, known)?.fiveHour?.usedPercent), "63")
        ?? expect(AccountUsage.fresher(nil, nil) == nil, true)
}())

// MARK: - Result

print("")
if failures == 0 {
    print("\(total) cases, all passed")
} else {
    print("\(failures) of \(total) cases FAILED")
    exit(1)
}
