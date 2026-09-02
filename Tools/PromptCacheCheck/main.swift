//
//  PromptCacheCheck
//
//  Exercises `PromptCacheEstimator` — the guess behind the rail's cache
//  chip — against transcript shapes measured in
//  ~/dotfiles/notes/claude-code-prompt-cache.md. Every case is one of that
//  document's paid-for pitfalls: the lifetime running from the *request*,
//  multi-record replies, sidechain and synthetic records, the truncated
//  first line of a tail window. The dollar cases are pinned to the doc's
//  real outage: a 704,278-token Fable 5 session whose cold resume was
//  measured at +$8.10 ~ +$13.39.
//
//      swiftc -O -o /tmp/promptcachecheck Attache/Status/PromptCache.swift \
//        Tools/PromptCacheCheck/main.swift
//      /tmp/promptcachecheck
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

func estimate(_ lines: [String], midFile: Bool = false, now: Date) -> PromptCacheEstimate? {
    PromptCacheEstimator.estimate(
        tail: Data((lines.joined(separator: "\n") + "\n").utf8),
        startsMidFile: midFile,
        now: now
    )
}

func ts(_ offset: TimeInterval) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: base.addingTimeInterval(offset))
}

let base = Date(timeIntervalSince1970: 1_756_800_000)

func user(_ offset: TimeInterval) -> String {
    #"{"type":"user","timestamp":"\#(ts(offset))","message":{"role":"user"}}"#
}

func assistant(
    _ offset: TimeInterval, id: String, model: String = "claude-fable-5",
    read: Int = 0, created: Int = 0, fresh: Int = 0,
    tier: String? = nil, sidechain: Bool = false
) -> String {
    let creation: String
    switch tier {
    case "5m": creation = #","cache_creation":{"ephemeral_5m_input_tokens":\#(created),"ephemeral_1h_input_tokens":0}"#
    case "1h": creation = #","cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":\#(created)}"#
    default: creation = ""
    }
    return #"{"type":"assistant","timestamp":"\#(ts(offset))","requestId":"\#(id)","isSidechain":\#(sidechain),"message":{"model":"\#(model)","usage":{"input_tokens":\#(fresh),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(created)\#(creation)}}}"#
}

// ── The doc's real outage, to the dollar ──
// 704,278 tokens of Fable 5 ($10/M): warm = ×0.1 = $0.70; cold spans the
// write multipliers, +$8.10 ~ +$13.39 over warm. The doc's tool printed
// exactly that range.
let now = base.addingTimeInterval(400)
var r = estimate([
    user(0),
    assistant(17, id: "r1", read: 0, created: 704_276, fresh: 2, tier: "5m"),
], now: now)
check("real outage: parses", r != nil)
if let r {
    check("real outage: context size", r.contextTokens == 704_278, "\(r.contextTokens)")
    check("real outage: tier 5m", r.tier == .fiveMinutes)
    check("real outage: warm ≈ $0.70", abs(r.resumeWarmUSD - 0.7043) < 0.001, "\(r.resumeWarmUSD)")
    check("real outage: extra lo ≈ $8.10", abs(r.resumeExtraLoUSD - 8.098) < 0.01, "\(r.resumeExtraLoUSD)")
    check("real outage: extra hi ≈ $13.38", abs(r.resumeExtraHiUSD - 13.381) < 0.01, "\(r.resumeExtraHiUSD)")
    // The clock runs from the *user message* (the entry before the reply),
    // not from the reply record 17 seconds later.
    check("lifetime starts at the request", r.lastRequestAt == base)
    check("expiry = start + 5m", r.expiresAt == base.addingTimeInterval(300))
    check("cold at now=+400s", !r.isWarm(now: now))
    check("was a miss", !r.lastHit)
}

// ── Warm, and the countdown signature buckets by the minute ──
r = estimate([
    user(0),
    assistant(10, id: "r1", read: 100_000, created: 151, fresh: 2, tier: "1h"),
], now: base.addingTimeInterval(60))
check("warm: hit recorded", r?.lastHit == true)
check("warm: 1h tier", r?.tier == .oneHour)
check("warm at +60s", r?.isWarm(now: base.addingTimeInterval(60)) == true)
check(
    "signature buckets minutes",
    r?.signature(now: base.addingTimeInterval(60)) == "warm/59"
        && r?.signature(now: base.addingTimeInterval(119)) == "warm/58"
        && r?.signature(now: base.addingTimeInterval(4000)) == "cold",
    "\(r?.signature(now: base.addingTimeInterval(119)) ?? "nil")"
)

// ── One reply, several records: first timestamp wins, last usage wins ──
r = estimate([
    user(0),
    assistant(20, id: "r1", read: 1000, created: 0, fresh: 1),
    assistant(95, id: "r1", read: 90_000, created: 500, fresh: 2, tier: "5m"),
], now: base.addingTimeInterval(100))
check("multi-record: start from the entry before the first record", r?.lastRequestAt == base)
check("multi-record: usage from the last record", r?.contextTokens == 90_502, "\(r?.contextTokens ?? -1)")

// ── Sidechain and synthetic records never speak for the main thread ──
r = estimate([
    user(0),
    assistant(10, id: "r1", read: 50_000, created: 10, fresh: 1, tier: "1h"),
    assistant(200, id: "r2", read: 9000, created: 0, fresh: 1, sidechain: true),
    #"{"type":"assistant","timestamp":"\#(ts(300))","requestId":"r3","isSidechain":false,"message":{"model":"<synthetic>","usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
], now: base.addingTimeInterval(310))
check("sidechain + synthetic skipped", r?.lastRequestAt == base && r?.contextTokens == 50_011,
      "\(String(describing: r?.contextTokens))")

// ── A tail cut mid-record drops its first line ──
let cut = [
    String(assistant(5, id: "r0", read: 1, created: 1, fresh: 1).dropFirst(40)),
    user(10),
    assistant(20, id: "r1", read: 7000, created: 0, fresh: 3, tier: "5m"),
]
r = estimate(cut, midFile: true, now: base.addingTimeInterval(30))
check("mid-file window: truncated first line dropped", r?.contextTokens == 7003, "\(String(describing: r?.contextTokens))")
check("mid-file window: start from surviving prior entry", r?.lastRequestAt == base.addingTimeInterval(10))

// ── No cache write anywhere: assume the subscriber default, 1 hour ──
r = estimate([user(0), assistant(5, id: "r1", read: 0, created: 0, fresh: 900)], now: base)
check("no writes: assumed 1h", r?.tier == .assumedOneHour)
check("assumed 1h still expires at +3600", r?.expiresAt == base.addingTimeInterval(3600))

// ── Nothing usable → nil, never a guess ──
check("empty tail", estimate([], now: base) == nil)
check("users only", estimate([user(0), user(5)], now: base) == nil)
check("sidechain only", estimate([user(0), assistant(5, id: "x", read: 1, sidechain: true)], now: base) == nil)

// ── Pricing: bracketed ids, dated ids, unknown models ──
check("bracket stripped", PromptCachePricing.price(forModel: "claude-opus-5[1m]") == 5.0)
check("dated id matches by prefix", PromptCachePricing.price(forModel: "claude-haiku-4-5-20251001") == 1.0)
check("unknown model → default", PromptCachePricing.price(forModel: "claude-next-9") == 5.0)
check("nil model → default", PromptCachePricing.price(forModel: nil) == 5.0)

// ── The wrapper-less fallback: encoding, and refusing ambiguity ──
check(
    "cwd encoding: slashes and dots both dash",
    TranscriptLocator.projectDirectoryName(forWorkingDirectory: "/Users/joey/.claude") == "-Users-joey--claude"
)
check(
    "cwd encoding: plain path",
    TranscriptLocator.projectDirectoryName(forWorkingDirectory: "/Users/joey/Code/tmux-gui") == "-Users-joey-Code-tmux-gui"
)
let lone = TranscriptLocator.chooseCandidate(
    [("a.jsonl", base), ("b.jsonl", base.addingTimeInterval(-7 * 3600))], now: base.addingTimeInterval(60)
)
check("one active session is the answer", lone == "a.jsonl", "\(String(describing: lone))")
let ambiguous = TranscriptLocator.chooseCandidate(
    [("a.jsonl", base), ("b.jsonl", base.addingTimeInterval(-60))], now: base.addingTimeInterval(60)
)
check("two active sessions are no answer", ambiguous == nil, "\(String(describing: ambiguous))")
check("no active sessions are no answer", TranscriptLocator.chooseCandidate([], now: base) == nil)

print(failures == 0 ? "\(cases) cases, all pass" : "\(failures) of \(cases) cases FAILED")
exit(failures == 0 ? 0 : 1)
