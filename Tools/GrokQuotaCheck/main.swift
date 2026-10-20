//
//  GrokQuotaCheck
//
//  The weekly pool the rail draws for a Grok account. The cases are the
//  payload shapes measured from `billing: fetched credits config` and from
//  the credits response itself: a normal week, a fresh week that omits the
//  percent (proto3 leaves the zero out), a monthly period that must not be
//  labelled Week, a week that has already ended, and the six-digit fraction
//  auth.x.ai writes on `expires_at`.
//
//      swiftc -O -o /tmp/grokquotacheck Attache/Status/AgentStats.swift \
//        Attache/Status/GrokQuota.swift Tools/GrokQuotaCheck/main.swift
//      /tmp/grokquotacheck
//

import Foundation

var failures = 0
var cases = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    if condition { return }
    failures += 1
    print("FAIL \(name)\(detail().isEmpty ? "" : " — \(detail())")")
}

let now = ISO8601DateFormatter().date(from: "2026-10-19T15:16:27Z")!
let weekEnd = "2026-10-20T02:41:47.979+00:00"
let weekStart = "2026-10-13T02:41:47.979+00:00"

func payload(_ json: String) -> AccountUsage? {
    GrokQuota.parseCreditsPayload(Data(json.utf8), now: now)
}

check("weekly percent is the bar", {
    guard let usage = payload("""
    {"config":{"creditUsagePercent":37,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\(weekStart)","end":"\(weekEnd)"}}}
    """) else { return false }
    guard usage.fiveHour == nil, usage.sevenDay?.usedPercent == 37 else { return false }
    let length = usage.sevenDay?.length ?? -1
    return abs(length - 7 * 86400) < 0.01
        && usage.sevenDay?.resetsAt == GrokQuota.parseTimestamp(weekEnd)
}())

check("a missing percent is zero, not unmetered", {
    payload("""
    {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\(weekStart)","end":"\(weekEnd)"}}}
    """)?.sevenDay?.usedPercent == 0
}())

check("an explicit zero stays zero beside product rows", {
    payload("""
    {"config":{"creditUsagePercent":0,"productUsage":[{"usagePercent":12}],"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"\(weekEnd)"}}}
    """)?.sevenDay?.usedPercent == 0
}())

check("product rows add up when the combined percent is absent", {
    payload("""
    {"config":{"productUsage":[{"usagePercent":10},{"usagePercent":4.6}],"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"\(weekEnd)"}}}
    """)?.sevenDay?.usedPercent == 15
}())

check("a boolean is not a percent", {
    payload("""
    {"config":{"creditUsagePercent":true,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"\(weekEnd)"}}}
    """)?.sevenDay?.usedPercent == 0
}())

check("a monthly period is not the week bar", {
    payload("""
    {"config":{"creditUsagePercent":10,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","end":"2026-11-13T02:41:47.979+00:00"}}}
    """) == nil
}())

check("a week that has ended is dropped", {
    payload("""
    {"config":{"creditUsagePercent":37,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-10-13T02:41:47.979+00:00"}}}
    """) == nil
}())

check("the unified-log line is the same object under ctx", {
    payload("""
    {"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":37.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\(weekStart)","end":"\(weekEnd)"}},"subscriptionTier":"SuperGrok"}}
    """)?.sevenDay?.usedPercent == 37
}())

check("a numeric string is a percent", {
    payload("""
    {"config":{"creditUsagePercent":"37.4","currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"\(weekEnd)"}}}
    """)?.sevenDay?.usedPercent == 37
}())

check("no start falls back to seven days", {
    payload("""
    {"config":{"creditUsagePercent":4,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"\(weekEnd)"}}}
    """)?.sevenDay?.length == AccountUsage.sevenDayLength
}())

check("six-digit auth expiry parses", {
    GrokQuota.parseTimestamp("2026-10-19T17:16:52.262205Z")
        == GrokQuota.parseTimestamp("2026-10-19T17:16:52.262Z")
}())

check("three-digit offset parses", {
    GrokQuota.parseTimestamp(weekEnd) != nil
}())

if failures == 0 {
    print("\(cases) cases, all pass")
} else {
    print("\(failures) of \(cases) failed")
}
exit(failures == 0 ? 0 : 1)
