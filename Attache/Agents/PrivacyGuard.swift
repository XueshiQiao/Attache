//
//  PrivacyGuard.swift
//  Attache
//

import Combine
import Foundation

// The privacy guard keeps private values — IP addresses, email addresses,
// keys, words the owner names — out of every agent's conversation on a host.
// Like saved projects it is attache-cli's on that host, entirely: the rules
// (`~/.config/attache-guard.toml`), the vault of real values, the events,
// and the hooks or mod each agent runs. This file only names commands and
// reads their one-line answers, so the phone can do the same later and
// neither client depends on the other. Issue #43 has the design.

/// What a built-in detector is called in the rules file, with the words the
/// page shows for it.
nonisolated struct GuardDetector: Identifiable, Sendable {
    let id: String
    let title: String
    let example: String

    static let all: [GuardDetector] = [
        .init(id: "ipv4_public", title: "Public IPv4 addresses", example: "203.0.113.7"),
        .init(id: "ipv4_lan", title: "LAN IPv4 addresses", example: "10.x, 172.16–31.x, 192.168.x"),
        .init(id: "ipv4_tailscale", title: "Tailscale / CGNAT addresses", example: "100.64.x – 100.127.x"),
        .init(id: "ipv4_loopback", title: "Loopback", example: "127.0.0.1 — names no machine"),
        .init(id: "ipv6_global", title: "Global IPv6 addresses", example: "2001:db8::1"),
        .init(id: "ipv6_ula", title: "Private IPv6 (ULA, Tailscale)", example: "fd7a:…"),
        .init(id: "ipv6_link_local", title: "Link-local IPv6", example: "fe80::…"),
        .init(id: "mac", title: "MAC addresses", example: "3c:22:fb:12:34:56"),
        .init(id: "email", title: "Email addresses", example: "name@example.com"),
        .init(id: "phone", title: "Phone numbers", example: "+65 9123 4567, 138…"),
        .init(id: "secrets", title: "Keys and tokens", example: "sk-…, ghp_…, AKIA…, private keys"),
    ]
}

nonisolated enum GuardAction: String, Codable, CaseIterable, Sendable {
    case mask
    case maskOnly = "mask_only"
    case block

    var title: String {
        switch self {
        case .mask: "Mask, restore in commands"
        case .maskOnly: "Mask, never restore"
        case .block: "Withhold the whole message"
        }
    }
}

nonisolated struct GuardWord: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var text = ""
    var ignoreCase = true
    var enabled = true
    var action = GuardAction.mask

    enum CodingKeys: String, CodingKey {
        case text, ignoreCase = "ignore_case", enabled, action
    }

    /// The row's id is the page's, not the rule's: two rules are the same
    /// rule whatever rows they sit in.
    static func == (a: Self, b: Self) -> Bool {
        a.text == b.text && a.ignoreCase == b.ignoreCase && a.enabled == b.enabled && a.action == b.action
    }
}

nonisolated struct GuardPattern: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var pattern = ""
    var kind = "custom"
    var enabled = true
    var action = GuardAction.mask

    enum CodingKeys: String, CodingKey {
        case name, pattern, kind, enabled, action
    }

    static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.pattern == b.pattern && a.kind == b.kind && a.enabled == b.enabled && a.action == b.action
    }
}

/// The rules file, as attache-cli reads and writes it.
nonisolated struct GuardRules: Codable, Equatable, Sendable {
    var enabled = true
    var pausedUntil: Int = 0
    var allow: [String] = []
    var detect: [String: Bool] = [:]
    var words: [GuardWord] = []
    var patterns: [GuardPattern] = []

    enum CodingKeys: String, CodingKey {
        case enabled, pausedUntil = "paused_until", allow, detect, words = "word", patterns = "pattern"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        pausedUntil = try c.decodeIfPresent(Int.self, forKey: .pausedUntil) ?? 0
        allow = try c.decodeIfPresent([String].self, forKey: .allow) ?? []
        detect = try c.decodeIfPresent([String: Bool].self, forKey: .detect) ?? [:]
        words = try c.decodeIfPresent([GuardWord].self, forKey: .words) ?? []
        patterns = try c.decodeIfPresent([GuardPattern].self, forKey: .patterns) ?? []
    }

    func detects(_ id: String) -> Bool { detect[id] ?? (id != "ipv4_loopback") }

    /// These rules with the row ids of `old` where the rows line up, so a
    /// read-back after a save does not rebuild — and unfocus — the field
    /// being typed in.
    func keepingRowIDs(of old: GuardRules) -> GuardRules {
        var r = self
        for i in r.words.indices where i < old.words.count { r.words[i].id = old.words[i].id }
        for i in r.patterns.indices where i < old.patterns.count { r.patterns[i].id = old.patterns[i].id }
        return r
    }
}

nonisolated struct GuardAgentStatus: Identifiable, Equatable, Sendable {
    let id: String
    let present: Bool
    let installed: Bool
    let how: String?
    let current: Bool
    let note: String

    var title: String {
        switch id {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "agy": "Antigravity (agy)"
        default: id
        }
    }

    init?(_ o: [String: Any]) {
        guard let id = o["agent"] as? String else { return nil }
        self.id = id
        present = o["present"] as? Bool ?? false
        installed = o["installed"] as? Bool ?? false
        how = o["how"] as? String
        current = o["current"] as? Bool ?? true
        note = o["note"] as? String ?? ""
    }
}

nonisolated struct GuardEvent: Identifiable, Equatable, Sendable {
    let id: Int
    let date: Date
    let agent: String
    let action: String
    let kind: String
    let rule: String
    let token: String
    let count: Int
    let site: String

    init?(_ o: [String: Any], index: Int) {
        guard let token = o["token"] as? String, let action = o["action"] as? String else { return nil }
        id = index
        date = Date(timeIntervalSince1970: (o["ts"] as? Double) ?? 0)
        agent = o["agent"] as? String ?? ""
        self.action = action
        kind = o["kind"] as? String ?? ""
        rule = o["rule"] as? String ?? ""
        self.token = token
        count = o["n"] as? Int ?? 1
        site = o["where"] as? String ?? ""
    }
}

nonisolated struct GuardVaultEntry: Identifiable, Equatable, Sendable {
    var id: String { token }
    let token: String
    let kind: String
    let rule: String
    let masked: Bool
    let restore: Bool
    let first: Date

    init?(_ o: [String: Any]) {
        guard let token = o["token"] as? String else { return nil }
        self.token = token
        kind = o["kind"] as? String ?? ""
        rule = o["rule"] as? String ?? ""
        masked = o["masked"] as? Bool ?? true
        restore = o["restore"] as? Bool ?? true
        first = Date(timeIntervalSince1970: (o["first"] as? Double) ?? 0)
    }
}

nonisolated struct GuardTestHit: Equatable, Sendable {
    /// Byte offsets into the UTF-8 of the text that was tested.
    let start: Int
    let end: Int
    let kind: String
    let rule: String
    let verdict: String
}

nonisolated struct GuardTestResult: Equatable, Sendable {
    let hits: [GuardTestHit]
    let masked: String
    let blocked: Bool
    let errors: [String]
}

/// The argv of each `attache-cli guard …`. Free text goes base64-encoded, as
/// it does for projects; a placeholder is checked against its exact shape
/// before it reaches a command line.
nonisolated enum GuardCommands {
    static let agents = ["claude", "codex", "agy"]

    /// Variables an agent sets in the processes it starts; `guard reveal`
    /// refuses where one is set. This app is not an agent, but it may have
    /// been started from inside one (a developer running the build from a
    /// Claude Code shell), so they are taken out of attache-cli's
    /// environment here.
    static let agentMarks = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CODEX_SANDBOX", "CODEX_THREAD_ID",
                             "CODEX_MANAGED_BY_NPM", "_AGY_CMD", "AI_AGENT"]

    static func isToken(_ s: String) -> Bool {
        s.range(of: #"^⟦[a-z0-9]{1,12}:[0-9a-f]{6,20}⟧$"#, options: .regularExpression) != nil
    }

    static func base64(_ text: String) -> String {
        text.isEmpty ? "=" : Data(text.utf8).base64EncodedString()
    }

    static func json<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static let status = ["guard", "status"]
    static let rules = ["guard", "rules"]
    static let vault = ["guard", "vault"]
    static let clearEvents = ["guard", "events", "--clear"]
    static let forgetAll = ["guard", "vault", "--forget-all"]

    static func events(limit: Int) -> [String] { ["guard", "events", "--limit", String(limit)] }

    static func setRules(_ rules: GuardRules) -> [String]? {
        json(rules).map { ["guard", "rules", "--set", base64($0)] }
    }

    static func test(_ text: String, rules: GuardRules) -> [String]? {
        json(rules).map { ["guard", "test", "--text", base64(text), "--rules", base64($0)] }
    }

    static func reveal(_ tokens: [String]) -> [String]? {
        tokens.allSatisfy(isToken) && !tokens.isEmpty ? ["guard", "reveal"] + tokens : nil
    }

    static func forget(_ tokens: [String]) -> [String]? {
        tokens.allSatisfy(isToken) && !tokens.isEmpty ? ["guard", "vault", "--forget"] + tokens : nil
    }

    static func install(_ agent: String, remove: Bool = false) -> [String]? {
        agents.contains(agent) ? ["guard", remove ? "uninstall" : "install", agent] : nil
    }

    static func pause(minutes: Int) -> [String] { ["guard", "pause", String(max(0, minutes))] }

    // MARK: Reading answers

    static func object(_ lines: [String]?) -> [String: Any]? {
        lines?.lazy.compactMap(AttacheCliProtocol.object).first
    }

    static func parseRules(_ o: [String: Any]) -> GuardRules? {
        guard let r = o["rules"], !(r is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: r) else { return nil }
        return try? JSONDecoder().decode(GuardRules.self, from: data)
    }

    static func parseTest(_ o: [String: Any]) -> GuardTestResult? {
        guard let masked = o["masked"] as? String else { return nil }
        let hits = (o["hits"] as? [[String: Any]] ?? []).compactMap { h -> GuardTestHit? in
            guard let s = h["start"] as? Int, let e = h["end"] as? Int else { return nil }
            return GuardTestHit(start: s, end: e, kind: h["kind"] as? String ?? "",
                                rule: h["rule"] as? String ?? "", verdict: h["verdict"] as? String ?? "")
        }
        let errors = (o["errors"] as? [[String: Any]] ?? []).compactMap { $0["why"] as? String }
        return GuardTestResult(hits: hits, masked: masked, blocked: o["blocked"] as? Bool ?? false, errors: errors)
    }

    /// Placeholders in text, in order, each once.
    static func tokens(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"⟦[a-z0-9]{1,12}:[0-9a-f]{6,20}⟧"#) else { return [] }
        var seen = Set<String>()
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }.filter { seen.insert($0).inserted }
    }
}

/// One host's guard, as the settings page shows it: what was last read, and
/// the commands that change it. Every change reads back what attache-cli
/// then holds; nothing here is believed until the host says so.
@MainActor
final class HostGuard: ObservableObject {
    let link: AttacheCliLink

    @Published private(set) var agents: [GuardAgentStatus] = []
    @Published private(set) var active: Bool?
    @Published private(set) var pausedUntil: Date?
    /// The rules being edited. Saved shortly after each change.
    @Published var rules = GuardRules()
    @Published private(set) var loaded = false
    @Published private(set) var rulesPath = "~/.config/attache-guard.toml"
    @Published private(set) var patternErrors: [Int: String] = [:]
    @Published private(set) var events: [GuardEvent] = []
    @Published private(set) var vault: [GuardVaultEntry] = []
    /// Values shown on this screen after the owner asked for them.
    @Published private(set) var revealed: [String: String] = [:]
    @Published private(set) var problem: String?
    @Published private(set) var busyAgent: String?
    @Published private(set) var agentMessage: [String: String] = [:]

    /// A save waiting for typing to stop, and saves sent and not answered.
    /// While either exists, or the page holds edits not yet saved, a
    /// read-back must not replace what is on the page.
    private var saveWork: DispatchWorkItem?
    private var savesInFlight = 0
    private var savedRules: GuardRules?

    init(link: AttacheCliLink) {
        self.link = link
    }

    private func ask(_ argv: [String]?, _ done: @escaping @MainActor ([String: Any]?) -> Void) {
        guard let argv else { done(nil); return }
        link.run(argv) { lines in done(GuardCommands.object(lines)) }
    }

    func refreshAll() {
        refreshStatus()
        refreshRules()
        refreshEvents()
        refreshVault()
    }

    func refreshStatus() {
        ask(GuardCommands.status) { [weak self] o in
            guard let self else { return }
            guard let o else {
                problem = "attache-cli on this host did not answer, or is older than 0.3.19 and has no guard yet"
                return
            }
            agents = (o["agents"] as? [[String: Any]] ?? []).compactMap(GuardAgentStatus.init)
            active = o["active"] as? Bool
            let until = o["paused_until"] as? Double ?? 0
            let now = o["now"] as? Double ?? Date().timeIntervalSince1970
            pausedUntil = until > now ? Date(timeIntervalSince1970: until) : nil
            problem = (o["why"] as? String)
        }
    }

    func refreshRules() {
        ask(GuardCommands.rules) { [weak self] o in
            guard let self, let o else { return }
            if let path = o["path"] as? String { rulesPath = path }
            guard let parsed = GuardCommands.parseRules(o) else {
                problem = o["why"] as? String ?? "the rules could not be read"
                return
            }
            // An edit waiting to be saved, or on its way, wins over what
            // the host had.
            if saveWork == nil, savesInFlight == 0, savedRules == nil || rules == savedRules {
                rules = parsed.keepingRowIDs(of: rules)
                savedRules = rules
            }
            patternErrors = Dictionary(
                (o["errors"] as? [[String: Any]] ?? []).compactMap { e in
                    (e["pattern"] as? Int).map { ($0, e["why"] as? String ?? "invalid") }
                },
                uniquingKeysWith: { a, _ in a }
            )
            loaded = true
        }
    }

    func refreshEvents() {
        ask(GuardCommands.events(limit: 1000)) { [weak self] o in
            guard let self, let o else { return }
            let list = o["events"] as? [[String: Any]] ?? []
            events = list.enumerated().compactMap { GuardEvent($1, index: $0) }.reversed()
        }
    }

    func refreshVault() {
        ask(GuardCommands.vault) { [weak self] o in
            guard let self, let o else { return }
            vault = (o["entries"] as? [[String: Any]] ?? []).compactMap(GuardVaultEntry.init)
                .sorted { $0.first > $1.first }
        }
    }

    /// Called by the page on every edit; the write follows once typing stops.
    func rulesChanged() {
        guard loaded, rules != savedRules else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func saveNow() {
        let snapshot = rules
        saveWork = nil
        savesInFlight += 1
        ask(GuardCommands.setRules(snapshot)) { [weak self] o in
            guard let self else { return }
            savesInFlight -= 1
            if o?["saved"] as? Bool == true {
                savedRules = snapshot
                problem = nil
                refreshRules()
                refreshStatus()
            } else {
                problem = "Not saved: " + (o?["why"] as? String ?? "attache-cli did not answer")
            }
        }
    }

    func install(_ agent: String, remove: Bool = false) {
        guard busyAgent == nil else { return }
        busyAgent = agent
        ask(GuardCommands.install(agent, remove: remove)) { [weak self] o in
            guard let self else { return }
            busyAgent = nil
            agentMessage[agent] = (o?["done"] as? Bool == true)
                ? (o?["message"] as? String ?? "done")
                : "Failed: " + (o?["why"] as? String ?? "attache-cli did not answer")
            refreshStatus()
        }
    }

    func pause(minutes: Int) {
        ask(GuardCommands.pause(minutes: minutes)) { [weak self] _ in
            self?.refreshStatus()
            self?.refreshRules()
        }
    }

    func reveal(_ tokens: [String]) {
        let wanted = tokens.filter { revealed[$0] == nil }
        guard !wanted.isEmpty else { return }
        ask(GuardCommands.reveal(wanted)) { [weak self] o in
            guard let self else { return }
            for (k, v) in o?["values"] as? [String: String] ?? [:] { revealed[k] = v }
            if let why = o?["why"] as? String { problem = why }
        }
    }

    func hide(_ token: String) { revealed[token] = nil }

    /// "Stop masking this": the value joins the allowlist.
    func allow(_ token: String) {
        let add: (String) -> Void = { [weak self] value in
            guard let self, !rules.allow.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
            rules.allow.append(value)
            rulesChanged()
        }
        if let value = revealed[token] { add(value); return }
        ask(GuardCommands.reveal([token])) { o in
            if let value = (o?["values"] as? [String: String])?[token] { add(value) }
        }
    }

    /// "Mask this from now on": a value let through becomes a word rule, or
    /// leaves the allowlist if that is what let it through.
    func maskFromNow(_ token: String) {
        ask(GuardCommands.reveal([token])) { [weak self] o in
            guard let self, let value = (o?["values"] as? [String: String])?[token] else { return }
            let before = rules.allow.count
            rules.allow.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
            if rules.allow.count == before, !rules.words.contains(where: { $0.text == value }) {
                rules.words.append(GuardWord(text: value))
            }
            rulesChanged()
        }
    }

    func forget(_ tokens: [String]) {
        ask(GuardCommands.forget(tokens)) { [weak self] _ in self?.refreshVault() }
    }

    func forgetAll() {
        ask(GuardCommands.forgetAll) { [weak self] _ in self?.refreshVault() }
    }

    func clearEvents() {
        ask(GuardCommands.clearEvents) { [weak self] _ in self?.refreshEvents() }
    }

    func test(_ text: String, done: @escaping @MainActor (GuardTestResult?) -> Void) {
        ask(GuardCommands.test(text, rules: rules)) { o in done(o.flatMap(GuardCommands.parseTest)) }
    }
}
