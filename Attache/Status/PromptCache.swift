//
//  PromptCache.swift
//  Attache
//

import Foundation

/// Whether a Claude Code session's prompt cache — Anthropic's server-side
/// cache of the conversation prefix — is still warm, and what resuming will
/// cost either way.
///
/// There is no API for this. Anthropic's documentation is explicit that the
/// cache cannot be queried; everything here is *estimated* from the local
/// transcript, the way `~/dotfiles/notes/claude-code-prompt-cache.md`
/// (2026-09-02, measured) lays out:
///
/// - The lifetime is 5 minutes or 1 hour, renewed in full every time the
///   cache is read, free.
/// - The clock runs from the moment a request is *sent* — not from the end
///   of its response.
/// - So: expiry ≈ the start of the last request + the TTL. The only fact is
///   after the fact: `cache_read_input_tokens > 0` on the next reply.
///
/// The stakes are what make the guess worth drawing: a 700k-token session
/// that went cold cost $13.71 to say "hello" into — 99.99% of it re-uploading
/// the conversation. Warm, the same message costs about seventy cents.
nonisolated struct PromptCacheEstimate: Equatable {
    enum Tier: String {
        case fiveMinutes = "5m"
        case oneHour = "1h"
        /// No cache write found in the window; the subscriber default is 1h.
        case assumedOneHour = "1h?"

        var seconds: TimeInterval {
            self == .fiveMinutes ? 300 : 3600
        }
    }

    var tier: Tier
    /// The approximated start of the last real request. The transcript does
    /// not record send times, so this is the timestamp of the last entry
    /// *before* that request's first record — usually the user message or
    /// tool result that triggered it. Using the reply's own timestamp would
    /// systematically overestimate the remaining time, and overestimating is
    /// the dangerous direction: the rail says warm while the money says cold.
    var lastRequestAt: Date
    var expiresAt: Date
    /// read + created + fresh of the last request — the size of what a cold
    /// resume re-uploads.
    var contextTokens: Int
    var model: String?
    /// Whether the last request actually hit the cache (the one hard fact).
    var lastHit: Bool
    var readTokens: Int
    var createdTokens: Int
    var freshTokens: Int

    /// What feeding this context in again costs, in USD. The cold side is a
    /// range on purpose: which tier the *next* request gets is unknowable
    /// before it is sent (`isUsingOverage` arrives in response headers and
    /// flips back and forth — measured flipping four times in 41 minutes),
    /// and predicting from the last tier has under-estimated by $4.90.
    var resumeWarmUSD: Double
    var resumeColdLoUSD: Double
    var resumeColdHiUSD: Double
    var resumeExtraLoUSD: Double { resumeColdLoUSD - resumeWarmUSD }
    var resumeExtraHiUSD: Double { resumeColdHiUSD - resumeWarmUSD }

    func remaining(now: Date) -> TimeInterval {
        expiresAt.timeIntervalSince(now)
    }

    func isWarm(now: Date) -> Bool {
        remaining(now: now) > 0
    }

    /// What the rail rebuild signature carries: coarse on purpose, minute
    /// granularity, so the countdown repaints once a minute instead of
    /// forcing a rebuild on every refresh — the same reasoning as
    /// `AgentBadge.isSettled`'s bucket and `AgentStats`' rounded percent.
    func signature(now: Date) -> String {
        let left = remaining(now: now)
        if left <= 0 { return "cold" }
        return "warm/\(Int(left / 60))"
    }
}

// MARK: - Pricing

/// Ported from `~/dotfiles/scripts/claude_cache_pricing.py`, which is the
/// authoritative copy — a price change lands there first and must be carried
/// here by hand. Numbers are Anthropic's list prices (USD per million input
/// tokens) and the official cache multipliers: reads at 0.1×, writes at
/// 1.25× (5-minute tier) or 2× (1-hour tier).
nonisolated enum PromptCachePricing {
    static let pricesPerMillion: [String: Double] = [
        "claude-fable-5": 10.0, "claude-mythos-5": 10.0,
        "claude-opus-5": 5.0, "claude-opus-4-8": 5.0,
        "claude-opus-4-7": 5.0, "claude-opus-4-6": 5.0,
        "claude-sonnet-5": 3.0, "claude-sonnet-4-6": 3.0,
        "claude-haiku-4-5": 1.0,
    ]
    static let defaultPricePerMillion = 5.0
    static let readMultiplier = 0.1
    static let writeMultiplier5m = 1.25
    static let writeMultiplier1h = 2.0

    /// `claude-opus-5[1m]` prices as `claude-opus-5` — the bracket names a
    /// context length, not a different price. Dated model ids
    /// (`claude-haiku-4-5-20251001`) match by prefix.
    static func price(forModel model: String?) -> Double {
        guard let model else { return defaultPricePerMillion }
        let bare = model.split(separator: "[").first.map(String.init) ?? model
        if let exact = pricesPerMillion[bare] { return exact }
        for (key, value) in pricesPerMillion where bare.hasPrefix(key) { return value }
        return defaultPricePerMillion
    }
}

// MARK: - Estimation

nonisolated enum PromptCacheEstimator {
    /// How much of a transcript's tail is read. A few hundred KB always
    /// contains the last request and the entry before it; single files reach
    /// 112 MB and the doc's own measurement shows a tail parse agreeing with
    /// a full parse on every one of 38 sessions compared.
    static let tailWindowBytes = 256 * 1024

    /// Estimate from a transcript's tail bytes.
    ///
    /// `startsMidFile` says the window begins somewhere inside the file, so
    /// the first line is (or may be) a truncated record and is dropped.
    ///
    /// Every rule below is one of the doc's paid-for pitfalls:
    /// - group multiple assistant records of one reply by `requestId`, first
    ///   record's timestamp wins, latest record's usage wins;
    /// - skip `isSidechain` records — subagents have their own cache tier;
    /// - skip `model == "<synthetic>"` — Claude Code's fake reply on API
    ///   errors never touched the network;
    /// - the request's start is approximated by the entry *before* it;
    /// - the tier is read from the last `cache_creation` split, not guessed.
    static func estimate(tail: Data, startsMidFile: Bool, now: Date = Date()) -> PromptCacheEstimate? {
        var window = tail
        if startsMidFile, let firstNewline = window.firstIndex(of: 0x0A) {
            window = window.subdata(in: window.index(after: firstNewline) ..< window.endIndex)
        }

        struct Request {
            var firstTS: Date
            var model: String?
            var usage: [String: Any]
        }
        var timestamps = [Date]()
        var requests = [String: Request]()
        var order = [String]()

        for line in window.split(separator: 0x0A) {
            guard !line.isEmpty,
                  let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else { continue }
            guard let ts = (root["timestamp"] as? String).flatMap(parseTimestamp) else { continue }
            timestamps.append(ts)
            guard (root["type"] as? String) == "assistant",
                  (root["isSidechain"] as? Bool) != true,
                  let message = root["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            let model = message["model"] as? String
            if model == "<synthetic>" { continue }
            let id = (root["requestId"] as? String) ?? (root["uuid"] as? String) ?? UUID().uuidString
            if var existing = requests[id] {
                existing.firstTS = min(existing.firstTS, ts)
                existing.usage = usage
                requests[id] = existing
            } else {
                requests[id] = Request(firstTS: ts, model: model, usage: usage)
                order.append(id)
            }
        }
        guard let lastID = order.last, let last = requests[lastID] else { return nil }

        // The tier, from the most recent request that wrote anything.
        var tier = PromptCacheEstimate.Tier.assumedOneHour
        for id in order.reversed() {
            guard let creation = requests[id]?.usage["cache_creation"] as? [String: Any] else { continue }
            if intValue(creation["ephemeral_1h_input_tokens"]) > 0 { tier = .oneHour; break }
            if intValue(creation["ephemeral_5m_input_tokens"]) > 0 { tier = .fiveMinutes; break }
        }

        // The entry strictly before the reply's first record approximates
        // when the request went out. Nothing before it in the window falls
        // back to the record itself — still the conservative direction once
        // the timestamps are sorted, since replies land after sends.
        let start = timestamps.sorted().last(where: { $0 < last.firstTS }) ?? last.firstTS

        let read = intValue(last.usage["cache_read_input_tokens"])
        let created = intValue(last.usage["cache_creation_input_tokens"])
        let fresh = intValue(last.usage["input_tokens"])
        let total = read + created + fresh

        let price = PromptCachePricing.price(forModel: last.model)
        let perToken = price / 1_000_000
        let warm = Double(total) * perToken * PromptCachePricing.readMultiplier
        let coldLo = Double(total) * perToken * PromptCachePricing.writeMultiplier5m
        let coldHi = Double(total) * perToken * PromptCachePricing.writeMultiplier1h

        return PromptCacheEstimate(
            tier: tier,
            lastRequestAt: start,
            expiresAt: start.addingTimeInterval(tier.seconds),
            contextTokens: total,
            model: last.model,
            lastHit: read > 0,
            readTokens: read,
            createdTokens: created,
            freshTokens: fresh,
            resumeWarmUSD: warm,
            resumeColdLoUSD: coldLo,
            resumeColdHiUSD: coldHi
        )
    }

    /// `2026-09-02T06:59:40.410Z`, with or without the fraction.
    private static func parseTimestamp(_ text: String) -> Date? {
        Self.fractional.date(from: text) ?? Self.whole.date(from: text)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func intValue(_ any: Any?) -> Int {
        switch any {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value <= 9_007_199_254_740_992 else { return 0 }
            return Int(value)
        default:
            return 0
        }
    }
}

// MARK: - Finding the transcript without anything installed

/// Where a pane's Claude Code transcript lives when nothing publishes the
/// path. The status line wrapper hands it over exactly (`AgentStats
/// .transcriptPath`), but the wrapper is an install and this feature must
/// not require one — so the fallback derives it from the two things tmux
/// already reports for free: the pane's working directory, and the fact
/// that an agent is running there.
nonisolated enum TranscriptLocator {
    /// `/Users/joey/Code/tmux-gui` → `-Users-joey-Code-tmux-gui`.
    ///
    /// Claude Code's encoding replaces both `/` and `.` with `-`, verified
    /// against the real directory names on this machine (`~/.claude` is
    /// `-Users-joey--claude` — the dot became a dash too).
    static func projectDirectoryName(forWorkingDirectory cwd: String) -> String {
        String(cwd.map { $0 == "/" || $0 == "." ? "-" : $0 })
    }

    /// Which of a project directory's sessions is the pane's agent, given
    /// each candidate's estimate. Only an *unambiguous* answer is one:
    /// exactly one session with a request in the recent window is that
    /// session; two agents in one repository with no wrapper installed are
    /// indistinguishable from out here, and a wrong attribution would put
    /// another session's dollar figure on this row. Empty is honest;
    /// wrong is invisible.
    static func chooseCandidate(
        _ candidates: [(path: String, lastRequestAt: Date)],
        now: Date,
        activeWithin: TimeInterval = 6 * 3600
    ) -> String? {
        let cutoff = now.addingTimeInterval(-activeWithin)
        let active = candidates.filter { $0.lastRequestAt > cutoff }
        guard active.count == 1 else { return nil }
        return active[0].path
    }
}
