//
//  GrokQuota.swift
//  Attache
//

import Foundation

/// The weekly allowance `/usage` draws for a Grok account.
///
/// Grok does not publish a 5-hour window. `GET /v1/billing?format=credits` on
/// the CLI chat proxy returns one period, `USAGE_PERIOD_TYPE_WEEKLY`, and
/// `creditUsagePercent` is how much of that shared pool is spent. Chat, Build,
/// Imagine and the API draw from the same pool. A session's own token total
/// answers a different question and is not read here.
///
/// This is the request `x.ai/billing` makes in grok-build. The session is the
/// one `grok login` wrote to `~/.grok/auth.json`. When the access token has
/// lapsed, a new one is minted in memory and kept there. Writing it back
/// races the running `grok`, which owns that file — the same choice Codenotch
/// makes. A customer identity-provider entry in the same file is skipped:
/// that token is meant for a private proxy, and sending it to the public
/// billing host would hand it somewhere it was not issued for.
enum GrokQuota {
    private static let weeklyPeriod = "USAGE_PERIOD_TYPE_WEEKLY"
    private static let xaiIssuer = "https://auth.x.ai"
    private static let defaultProxyBase = "https://cli-chat-proxy.grok.com/v1"
    private static let tokenAuthHeader = "xai-grok-cli"

    private static let lock = NSLock()
    /// An access token minted by this process, and the refresh token it was
    /// minted from. A later `grok login` replaces the file's refresh token;
    /// a held access from the previous one must not outlive that.
    private static var held: HeldToken?

    private struct HeldToken {
        var access: String
        var refresh: String
        var expiresAt: Date
        var mintedFromRefresh: String
    }

    private struct SessionFile {
        var access: String
        var refresh: String
        var expiresAt: Date
        var clientID: String
        var userID: String
        var principalType: String?
        var principalID: String?
    }

    /// The last credits snapshot Grok itself wrote, if that week has not ended.
    ///
    /// Every prompt and every `/usage` appends `billing: fetched credits config`
    /// to `~/.grok/logs/unified.jsonl`. Reading the tail paints the rail before
    /// the network round trip, and it is the fallback when the live request
    /// cannot be signed.
    static func loggedUsage(now: Date = Date()) -> AccountUsage? {
        guard let data = logTail() else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var latest: AccountUsage?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("billing: fetched credits config"),
                  let data = String(line).data(using: .utf8),
                  let usage = parseCreditsPayload(data, now: now)
            else { continue }
            latest = usage
        }
        return latest
    }

    /// Live weekly allowance, or nil when nothing usable came back.
    ///
    /// Called off the main thread. One failed request does not clear a number
    /// the caller already has: the caller keeps its previous snapshot.
    ///
    /// A network failure is not a reason to refresh. Refreshing can rotate the
    /// refresh token, and this process does not write `auth.json` back, so a
    /// rotated token that never reaches the file is a login `grok` can no
    /// longer renew. The exchange runs when the access token is about to
    /// lapse, or when the billing host refused the one we sent.
    static func fetch(now: Date = Date()) -> AccountUsage? {
        guard var session = readSession() else { return nil }
        if session.expiresAt.timeIntervalSince(now) < 60 {
            guard let refreshed = refresh(session) else { return nil }
            apply(refreshed, to: &session)
        }
        switch billing(session: session, now: now) {
        case .value(let usage):
            return usage
        case .unavailable:
            return nil
        case .refused:
            guard let refreshed = refresh(session, force: true) else { return nil }
            apply(refreshed, to: &session)
            if case .value(let usage) = billing(session: session, now: now) { return usage }
            return nil
        }
    }

    private static func apply(_ token: HeldToken, to session: inout SessionFile) {
        session.access = token.access
        session.expiresAt = token.expiresAt
        session.refresh = token.refresh
    }

    /// `GET /v1/billing?format=credits`, or the same object wrapped as the
    /// `ctx` of a unified-log line.
    ///
    /// A weekly period that omits `creditUsagePercent` is 0%, not "this
    /// account is not metered". proto3 leaves the zero out, and a fresh week
    /// is exactly that payload. A period that has already ended is dropped:
    /// drawing last week's percentage until the next successful fetch would
    /// sit on a number the clock has already retired.
    static func parseCreditsPayload(_ data: Data, now: Date = Date()) -> AccountUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let body = (obj["ctx"] as? [String: Any]) ?? obj
        guard let config = body["config"] as? [String: Any] else { return nil }
        let period = config["currentPeriod"] as? [String: Any]
        if let kind = period?["type"] as? String, kind != weeklyPeriod { return nil }
        let endText = (period?["end"] as? String) ?? (config["billingPeriodEnd"] as? String)
        guard let endText, let end = parseTimestamp(endText), end > now else { return nil }
        let startText = (period?["start"] as? String) ?? (config["billingPeriodStart"] as? String)
        let length: TimeInterval
        if let startText, let start = parseTimestamp(startText), end > start {
            length = end.timeIntervalSince(start)
        } else {
            length = AccountUsage.sevenDayLength
        }
        let percent = creditPercent(config) ?? 0
        return AccountUsage(
            sevenDay: AccountUsage.Window(
                usedPercent: percent,
                resetsAt: end,
                length: length
            )
        )
    }

    // MARK: - Session

    private static func grokHome() -> URL {
        let env = ProcessInfo.processInfo.environment["GROK_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !env.isEmpty { return URL(fileURLWithPath: env, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
    }

    private static func readSession() -> SessionFile? {
        let url = grokHome().appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var best: SessionFile?
        for (key, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            let issuer = (entry["oidc_issuer"] as? String) ?? ""
            // The scope key is `issuer::client_id`. A customer identity
            // provider lives in this same file; its token is for a private
            // proxy. Either name naming something else is enough to skip it.
            // Splitting the key on the first colon is not that test: the
            // issuer itself is `https://…`, so the first field is `https`.
            let keyIsXAI = key.hasPrefix(xaiIssuer + "::")
            let issuerIsXAI = issuer == xaiIssuer
            guard keyIsXAI || issuerIsXAI else { continue }
            if !issuer.isEmpty, !issuerIsXAI { continue }
            if key.contains("::"), !keyIsXAI { continue }
            guard let access = nonEmpty(entry["key"]),
                  let refresh = nonEmpty(entry["refresh_token"]),
                  let clientID = nonEmpty(entry["oidc_client_id"]),
                  let userID = nonEmpty(entry["user_id"]),
                  let expText = nonEmpty(entry["expires_at"]),
                  let expiresAt = parseTimestamp(expText)
            else { continue }
            let session = SessionFile(
                access: access,
                refresh: refresh,
                expiresAt: expiresAt,
                clientID: clientID,
                userID: userID,
                principalType: nonEmpty(entry["principal_type"]),
                principalID: nonEmpty(entry["principal_id"])
            )
            if best == nil || session.expiresAt > best!.expiresAt { best = session }
        }
        return best
    }

    private static func refresh(_ session: SessionFile, force: Bool = false) -> HeldToken? {
        lock.lock()
        let cached = held
        lock.unlock()
        if !force,
           let cached,
           cached.mintedFromRefresh == session.refresh || cached.refresh == session.refresh,
           cached.expiresAt.timeIntervalSinceNow > 60
        {
            return cached
        }
        let refreshToken = (cached?.mintedFromRefresh == session.refresh) ? cached!.refresh : session.refresh
        guard let endpoint = discoverTokenEndpoint(),
              let minted = exchange(
                endpoint: endpoint,
                refreshToken: refreshToken,
                session: session,
                mintedFrom: session.refresh
              )
        else { return nil }
        lock.lock()
        held = minted
        lock.unlock()
        return minted
    }

    private static func discoverTokenEndpoint() -> String? {
        lock.lock()
        if let tokenEndpoint { lock.unlock(); return tokenEndpoint }
        lock.unlock()
        guard let url = URL(string: xaiIssuer + "/.well-known/openid-configuration"),
              let (data, response) = send(URLRequest(url: url), timeout: 15),
              (200..<300).contains(response.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpoint = nonEmpty(obj["token_endpoint"]),
              endpoint.hasPrefix("https://")
        else { return nil }
        lock.lock()
        tokenEndpoint = endpoint
        lock.unlock()
        return endpoint
    }

    private static var tokenEndpoint: String?

    private static func exchange(
        endpoint: String,
        refreshToken: String,
        session: SessionFile,
        mintedFrom: String
    ) -> HeldToken? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = [
            "grant_type=refresh_token",
            "refresh_token=" + formEncode(refreshToken),
            "client_id=" + formEncode(session.clientID),
        ]
        if let principalType = session.principalType {
            fields.append("principal_type=" + formEncode(principalType))
        }
        if let principalID = session.principalID {
            fields.append("principal_id=" + formEncode(principalID))
        }
        request.httpBody = fields.joined(separator: "&").data(using: .utf8)
        guard let (data, response) = send(request, timeout: 15),
              (200..<300).contains(response.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = nonEmpty(obj["access_token"])
        else { return nil }
        let expiresIn = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 0
        let expiresAt = expiresIn > 0
            ? Date().addingTimeInterval(expiresIn)
            : Date().addingTimeInterval(3600)
        let rotated = nonEmpty(obj["refresh_token"]) ?? refreshToken
        return HeldToken(
            access: access,
            refresh: rotated,
            expiresAt: expiresAt,
            mintedFromRefresh: mintedFrom
        )
    }

    // MARK: - Billing

    private enum BillingReply {
        case value(AccountUsage)
        case refused
        case unavailable
    }

    private static func billing(session: SessionFile, now: Date) -> BillingReply {
        let base = (ProcessInfo.processInfo.environment["GROK_CLI_CHAT_PROXY_BASE_URL"] ?? defaultProxyBase)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/billing?format=credits") else { return .unavailable }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.access)", forHTTPHeaderField: "Authorization")
        request.setValue(tokenAuthHeader, forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue(session.userID, forHTTPHeaderField: "x-userid")
        request.setValue(clientVersion(), forHTTPHeaderField: "x-grok-client-version")
        // Not the interactive TUI. grok-build sends `interactive` from the
        // pager and `headless` from a process that set itself so; a poll from
        // this app is the latter.
        request.setValue("headless", forHTTPHeaderField: "x-grok-client-mode")
        guard let (data, response) = send(request, timeout: 15) else { return .unavailable }
        // 401 is the documented refusal. 403 is the same outcome from a proxy
        // that does not want the token: the access token is no good, and one
        // refresh is the remedy. Anything else — a timeout, a 500, a body
        // this parser does not understand — leaves the refresh token alone.
        if response.statusCode == 401 || response.statusCode == 403 { return .refused }
        guard (200..<300).contains(response.statusCode),
              let usage = parseCreditsPayload(data, now: now)
        else { return .unavailable }
        return .value(usage)
    }

    private static func clientVersion() -> String {
        let url = grokHome().appendingPathComponent("version.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = nonEmpty(obj["version"])
        else { return "0.0.0" }
        return version
    }

    private static func logTail() -> Data? {
        let url = grokHome().appendingPathComponent("logs/unified.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 512 * 1024
        let start: UInt64 = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        guard start > 0, let newline = data.firstIndex(of: 0x0A) else { return data }
        return data.suffix(from: data.index(after: newline))
    }

    private static func creditPercent(_ config: [String: Any]) -> Int? {
        if let direct = number(config["creditUsagePercent"]) {
            return Int(direct.rounded())
        }
        // Some payloads omit the combined figure and list products instead.
        // Those rows are shares of the same weekly pool and add up to it.
        guard let rows = config["productUsage"] as? [[String: Any]] else { return nil }
        var sum = 0.0
        var saw = false
        for row in rows {
            guard let value = number(row["usagePercent"]) else { continue }
            sum += value
            saw = true
        }
        return saw ? Int(sum.rounded()) : nil
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        case let text as String:
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else {
                return nil
            }
            return value
        default:
            return nil
        }
    }

    private static func nonEmpty(_ any: Any?) -> String? {
        guard let text = any as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// RFC 3339, including the six-digit fraction auth.x.ai writes.
    ///
    /// `ISO8601DateFormatter` accepts `.979+00:00` and rejects `.262205Z` on
    /// the fraction width. Truncating to milliseconds parses both.
    static func parseTimestamp(_ text: String) -> Date? {
        func attempt(_ value: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        if let date = attempt(text) { return date }
        let collapsed = text.replacingOccurrences(
            of: #"\.(\d{3})\d+"#,
            with: ".$1",
            options: .regularExpression
        )
        return attempt(collapsed)
    }

    private static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func send(_ request: URLRequest, timeout: TimeInterval) -> (Data, HTTPURLResponse)? {
        var timed = request
        timed.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        var output: (Data, HTTPURLResponse)?
        let task = URLSession.shared.dataTask(with: timed) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse {
                output = (data, http)
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return output
    }
}
