//
//  AgentStats.swift
//  Attache
//

import Foundation

/// What a Claude Code session says about itself, as the rail needs to draw it.
///
/// The source is the JSON object Claude Code hands its status line on stdin,
/// written verbatim into the pane option `@agent_stat` by
/// `AgentStatusLineInstaller`'s wrapper and parsed here. It is the only place
/// Claude Code publishes cost, context and rate limits — the hook payloads
/// `AgentHookInstaller` registers for carry a session id, a working directory
/// and a tool name, and nothing else.
///
/// **The wrapper deliberately parses nothing.** Extracting fields in shell
/// needs `jq` or `python3`, and whichever one it needed would be a machine
/// where this silently does not work. So the whole object crosses as text and a
/// real parser reads it here.
///
/// Every field is optional and every one of them is optional for a reason that
/// was measured rather than guessed — see `parse`.
struct AgentStats: Equatable {
    /// `model.display_name`, in full: `Opus 5 (1M context)`.
    var model: String?
    /// `context_window.used_percentage`, rounded to a whole percent.
    ///
    /// Nil is a real state and not a parse failure: a session that has not sent
    /// a message yet reports `null` here. Rounding is not cosmetic — it is what
    /// keeps the rail from rebuilding on every status line render, because
    /// `WindowDecoration` is `Equatable` and an unrounded percentage changes
    /// on every one of them.
    var contextPercent: Int?
    /// `context_window.context_window_size`, for the tooltip's `340k / 1M`.
    var contextWindowSize: Int?
    var contextTokens: Int?
    /// `cost.total_cost_usd`, in cents, for the same rounding reason.
    var costCents: Int?
    var linesAdded: Int?
    var linesRemoved: Int?
    var durationMS: Int?
    var effort: String?
    var outputStyle: String?
    /// Account-wide, so every session's payload carries the same pair. Kept
    /// here rather than in a place of its own because this is how it arrives;
    /// the footer picks the freshest of the ones it can see.
    var usage: AccountUsage?
    /// Account-wide Gemini quota when the pane's status line payload came from
    /// Antigravity (`quota.gemini-5h`, `quota.gemini-weekly`,
    /// `quota.gemini-argon-wtu-weekly`). Kept separate from `usage` so Claude
    /// and Gemini rate limits never overwrite each other.
    var geminiUsage: AccountUsage?

    /// Absolute path to this session's transcript, from `transcript_path`.
    ///
    /// **The whole reason the conversation sidebar needed no new mechanism.**
    /// Claude Code publishes it in the same payload as the cost and context
    /// numbers, so the link from a tmux pane to the file holding its
    /// conversation was already arriving on the control-mode connection and
    /// was simply not being read. `ClaudeCodeConversationProvider` is the
    /// consumer.
    ///
    /// Not part of `isEmpty`: a payload carrying only this says nothing a rail
    /// row could draw, and treating it as content would put an empty row under
    /// every window.
    var transcriptPath: String?
    /// `session_id`. Distinct from the transcript path because the path can be
    /// renamed underneath a running session, while this cannot.
    var sessionID: String?

    /// True when there is nothing a row could draw. A payload that parsed but
    /// holds only rate limits still says nothing about *this* window.
    var isEmpty: Bool {
        model == nil && contextPercent == nil && costCents == nil
    }

    /// The model name with its parenthetical dropped: `Opus 5 (1M context)`
    /// becomes `Opus 5`.
    ///
    /// The full name is nineteen characters and the rail is 168pt wide by
    /// default, which leaves about nineteen for the whole line. The part in
    /// brackets is the part that does not identify the model.
    var shortModel: String? {
        guard let model else { return nil }
        let cut = model.range(of: " (").map { model[..<$0.lowerBound] } ?? model[...]
        let trimmed = cut.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `$2.14`. Nil rather than `$0.00` when nothing is known.
    var costText: String? {
        guard let costCents else { return nil }
        return String(format: "$%.2f", Double(costCents) / 100)
    }
}

/// The rate-limit windows for one provider, and how far through each one the clock is.
struct AccountUsage: Equatable {
    struct Window: Equatable {
        /// 0 and above. Not clamped to 100: being over the limit is a thing
        /// that happens and rounding it down to 100 would hide it.
        var usedPercent: Int
        var resetsAt: Date
        /// How long the whole window is — 5 hours, or 7 days.
        var length: TimeInterval

        /// How much of the window's *time* has gone, 0...1.
        ///
        /// This is the whole point of the footer's vertical mark. Usage alone
        /// answers "how much have I spent"; only this answers "am I spending it
        /// faster than the clock", which is the question that decides whether
        /// to keep going.
        func elapsedFraction(now: Date = Date()) -> Double {
            let remaining = resetsAt.timeIntervalSince(now)
            guard length > 0 else { return 0 }
            return min(1, max(0, 1 - remaining / length))
        }

        /// `1h20m`, `4d18h`, `12m`, or `now` once it has passed.
        func countdown(now: Date = Date()) -> String {
            let remaining = Int(resetsAt.timeIntervalSince(now))
            guard remaining > 0 else { return "now" }
            let days = remaining / 86400
            let hours = (remaining % 86400) / 3600
            let minutes = (remaining % 3600) / 60
            if days > 0 { return "\(days)d\(hours)h" }
            if hours > 0 { return "\(hours)h\(minutes)m" }
            return "\(minutes)m"
        }
    }

    var fiveHour: Window?
    var sevenDay: Window?
    /// Separate weekly quota for Gemini 4 Argon on Google AI Pro plans
    /// (`gemini-argon-wtu-weekly`). Nil on Claude or when not applicable.
    var argonSevenDay: Window? = nil
    /// Claude & GPT 5-hour quota in Antigravity (`3p-5h`).
    var threePFiveHour: Window? = nil
    /// Claude & GPT weekly quota in Antigravity (`3p-weekly`).
    var threePSevenDay: Window? = nil

    static let fiveHourLength: TimeInterval = 5 * 3600
    static let sevenDayLength: TimeInterval = 7 * 86400

    var isEmpty: Bool {
        fiveHour == nil && sevenDay == nil && argonSevenDay == nil
            && threePFiveHour == nil && threePSevenDay == nil
    }

    /// Which of two snapshots to believe.
    ///
    /// Every open session writes the same account-wide numbers, and an idle one
    /// keeps re-writing the snapshot it took when it was last busy. Taking the
    /// last writer makes the footer jump between a current value and an old
    /// one. The window that resets *later* is the newer window; within the same
    /// window the higher usage is the later reading, because usage inside a
    /// window only goes up.
    ///
    /// The same rule coralline uses on its own cache, and for the same
    /// observed reason.
    static func fresher(_ a: AccountUsage?, _ b: AccountUsage?) -> AccountUsage? {
        guard let a else { return b }
        guard let b else { return a }
        if let aFive = a.fiveHour, let bFive = b.fiveHour {
            if aFive.resetsAt != bFive.resetsAt {
                return aFive.resetsAt > bFive.resetsAt ? a : b
            }
            return aFive.usedPercent >= bFive.usedPercent ? a : b
        }
        if a.fiveHour != nil { return a }
        if b.fiveHour != nil { return b }
        if let aWeek = a.sevenDay, let bWeek = b.sevenDay {
            if aWeek.resetsAt != bWeek.resetsAt {
                return aWeek.resetsAt > bWeek.resetsAt ? a : b
            }
            return aWeek.usedPercent >= bWeek.usedPercent ? a : b
        }
        return a.sevenDay != nil ? a : b
    }
}

// MARK: - Parsing

extension AgentStats {
    /// Parse one `@agent_stat` value.
    ///
    /// Nil means "there is nothing here" — an empty option, a value that is not
    /// JSON, or JSON that is not an object. It never means "this version is
    /// newer than I understand": unknown keys are ignored, so a Claude Code
    /// that adds fields keeps working against an app that has not been rebuilt.
    ///
    /// **Every tolerance below is a measured payload shape, not defensiveness
    /// for its own sake.** Captured from Claude Code 2.1.220 on 2026-07-29:
    ///
    /// - `used_percentage` is `null` — not absent — in a session that has not
    ///   sent a message yet, along with `current_usage` and
    ///   `remaining_percentage`. Reading only "is the key there" reports 0% for
    ///   every fresh session, and a wrong number is worse than no number.
    /// - `resets_at` is epoch seconds. A digit string is accepted too because
    ///   that costs one line and the alternative is finding out in a year.
    /// - Numbers arrive as JSON numbers. Strings are accepted for the same
    ///   reason.
    static func parse(_ raw: String) -> AgentStats? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let root = parsed as? [String: Any]
        else { return nil }

        var stats = AgentStats()

        if let model = root["model"] as? [String: Any] {
            stats.model = string(model["display_name"])
        }
        if let context = root["context_window"] as? [String: Any] {
            stats.contextPercent = int(context["used_percentage"]).map { max(0, $0) }
            stats.contextWindowSize = int(context["context_window_size"]).map { max(0, $0) }
            let input = int(context["total_input_tokens"]) ?? 0
            let output = int(context["total_output_tokens"]) ?? 0
            // Only meaningful once something has been sent; 0 + 0 is the fresh
            // session that already reports a null percentage.
            if input + output > 0 { stats.contextTokens = input + output }
        }
        if let cost = root["cost"] as? [String: Any] {
            stats.costCents = cents(cost["total_cost_usd"])
            stats.linesAdded = int(cost["total_lines_added"])
            stats.linesRemoved = int(cost["total_lines_removed"])
            stats.durationMS = int(cost["total_duration_ms"])
        }
        stats.effort = string((root["effort"] as? [String: Any])?["level"])
            ?? string((root["model"] as? [String: Any])?["effort"])
        stats.outputStyle = string((root["output_style"] as? [String: Any])?["name"])
        stats.transcriptPath = string(root["transcript_path"])
        stats.sessionID = string(root["session_id"])

        if let limits = root["rate_limits"] as? [String: Any] {
            var usage = AccountUsage()
            usage.fiveHour = window(limits["five_hour"], length: AccountUsage.fiveHourLength)
            usage.sevenDay = window(limits["seven_day"], length: AccountUsage.sevenDayLength)
            if !usage.isEmpty { stats.usage = usage }
        }

        if let quota = root["quota"] as? [String: Any] {
            stats.geminiUsage = AccountUsage.parseGeminiQuotaMap(quota)
        }

        return stats
    }

    private static func window(_ any: Any?, length: TimeInterval) -> AccountUsage.Window? {
        guard let object = any as? [String: Any],
              let percent = int(object["used_percentage"]),
              let seconds = double(object["resets_at"])
        else { return nil }
        // A reset time outside any plausible range is a field that means
        // something else. Drawing a bar from it would put the mark anywhere.
        guard seconds > 1_000_000_000, seconds < 100_000_000_000 else { return nil }
        return AccountUsage.Window(
            usedPercent: max(0, percent),
            resetsAt: Date(timeIntervalSince1970: seconds),
            length: length
        )
    }

    fileprivate static func geminiWindow(_ any: Any?, length: TimeInterval) -> AccountUsage.Window? {
        guard let object = any as? [String: Any] else { return nil }
        let rem = double(object["remaining_fraction"]) ?? double(object["remainingFraction"])
        guard let remaining = rem, remaining >= 0, remaining <= 1.5 else { return nil }
        let usedPercent = max(0, Int(((1.0 - min(1.0, remaining)) * 100.0).rounded()))
        let resetRaw = string(object["reset_time"]) ?? string(object["resetTime"])
        guard let resetStr = resetRaw, let resetDate = parseISO8601(resetStr) else { return nil }
        return AccountUsage.Window(
            usedPercent: usedPercent,
            resetsAt: resetDate,
            length: length
        )
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func string(_ any: Any?) -> String? {
        guard let text = any as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A JSON number or a numeric string. **Never a bool.**
    ///
    /// The payload carries `fast_mode` and `thinking.enabled`, and in
    /// Foundation a JSON bool arrives as an `NSNumber` that answers 1 or 0 to
    /// `doubleValue`. Without the type check, reading the wrong key would
    /// produce a confident `0%` rather than nothing at all.
    private static func double(_ any: Any?) -> Double? {
        switch any {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        case let text as String:
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)),
                  value.isFinite
            else { return nil }
            return value
        default:
            return nil
        }
    }

    /// Dollars to cents, refusing anything that cannot survive the trip.
    ///
    /// **The scaling is the dangerous part and it is why this is not `int()`.**
    /// `int()` bounds the value it is given; this one multiplies first, and a
    /// number that is perfectly finite on its own can stop being finite on the
    /// way to cents — `1e308` is an ordinary JSON number and `1e308 * 100` is
    /// infinity, which then trapped on the way to an `Int` and took the app
    /// with it. Found by review on 2026-07-29 and reproduced: the check tool
    /// exited on SIGTRAP with its output still in the buffer.
    ///
    /// That is the same defect as the digit run that killed `TerminalReply`,
    /// arrived at from the opposite direction — there by reading too many
    /// digits, here by doing arithmetic before the bounds check.
    ///
    /// A negative cost is refused rather than displayed: there is no such
    /// thing, so a field that holds one is a field that means something else.
    private static func cents(_ any: Any?) -> Int? {
        guard let dollars = double(any), dollars >= 0 else { return nil }
        let scaled = (dollars * 100).rounded()
        guard scaled.isFinite, scaled <= 9_007_199_254_740_992 else { return nil }
        return Int(scaled)
    }

    /// The same, rounded, and refusing anything that cannot be an `Int`.
    ///
    /// The bound is not theoretical. A digit run that overflowed on the way to
    /// an integer is one of the three defects `TerminalReply` shipped in a
    /// single day, and it killed the process rather than drawing something
    /// wrong. This is the same shape of input — a number from outside the app —
    /// so it gets the same guard.
    private static func int(_ any: Any?) -> Int? {
        guard let value = double(any) else { return nil }
        let rounded = value.rounded()
        guard rounded >= -9_007_199_254_740_992, rounded <= 9_007_199_254_740_992 else {
            return nil
        }
        return Int(rounded)
    }
}

extension AccountUsage {
    /// Window-by-window merge of two snapshots of the same account.
    ///
    /// Unlike `fresher`, which picks one snapshot whole, this keeps each
    /// window from whichever side read it more recently. Needed because the
    /// Gemini sources do not all carry the same buckets — the direct Cloud
    /// Code endpoint omits `gemini-argon-wtu-weekly` — and taking a whole
    /// snapshot from a source without Argon made the Argon gauge vanish the
    /// moment that source looked "newer". Windows whose reset has already
    /// passed are dropped, so a bucket that stops being reported cannot
    /// linger past its own window.
    static func merged(_ a: AccountUsage?, _ b: AccountUsage?, now: Date = Date()) -> AccountUsage? {
        func pick(_ x: Window?, _ y: Window?) -> Window? {
            let x = x.flatMap { $0.resetsAt > now ? $0 : nil }
            let y = y.flatMap { $0.resetsAt > now ? $0 : nil }
            guard let x else { return y }
            guard let y else { return x }
            if x.resetsAt != y.resetsAt { return x.resetsAt > y.resetsAt ? x : y }
            return x.usedPercent >= y.usedPercent ? x : y
        }
        var out = AccountUsage()
        out.fiveHour = pick(a?.fiveHour, b?.fiveHour)
        out.sevenDay = pick(a?.sevenDay, b?.sevenDay)
        out.argonSevenDay = pick(a?.argonSevenDay, b?.argonSevenDay)
        out.threePFiveHour = pick(a?.threePFiveHour, b?.threePFiveHour)
        out.threePSevenDay = pick(a?.threePSevenDay, b?.threePSevenDay)
        return out.isEmpty ? nil : out
    }

    /// Parses the `"quota"` dictionary from an Antigravity (`agy`) status-line JSON payload.
    static func parseGeminiQuotaMap(_ quota: [String: Any]) -> AccountUsage? {
        var usage = AccountUsage()
        usage.fiveHour = AgentStats.geminiWindow(
            quota["gemini-5h"], length: AccountUsage.fiveHourLength
        )
        usage.sevenDay = AgentStats.geminiWindow(
            quota["gemini-weekly"], length: AccountUsage.sevenDayLength
        )
        usage.argonSevenDay = AgentStats.geminiWindow(
            quota["gemini-argon-wtu-weekly"], length: AccountUsage.sevenDayLength
        )
        usage.threePFiveHour = AgentStats.geminiWindow(
            quota["3p-5h"], length: AccountUsage.fiveHourLength
        )
        usage.threePSevenDay = AgentStats.geminiWindow(
            quota["3p-weekly"], length: AccountUsage.sevenDayLength
        )
        return usage.isEmpty ? nil : usage
    }

    /// Parses any of the three Gemini quota JSON shapes:
    /// 1. `agy` status-line JSON (`root["quota"]`)
    /// 2. `agy --output-format json -p /usage` (`root["command"]["data"]["groups"]`)
    /// 3. Direct Cloud Code API `retrieveUserQuotaSummary` (`root["groups"]`)
    static func parseGeminiQuotaPayload(_ data: Data) -> AccountUsage? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let root = parsed as? [String: Any]
        else { return nil }

        if let quota = root["quota"] as? [String: Any],
           let usage = parseGeminiQuotaMap(quota)
        {
            return usage
        }

        let groups = ((root["command"] as? [String: Any])?["data"] as? [String: Any])?["groups"] as? [[String: Any]]
            ?? (root["groups"] as? [[String: Any]])
        guard let groups else { return nil }

        var byID = [String: Any]()
        for group in groups {
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
            for bucket in buckets {
                if let id = (bucket["id"] as? String) ?? (bucket["bucketId"] as? String) {
                    byID[id] = bucket
                }
            }
        }
        return parseGeminiQuotaMap(byID)
    }
}

