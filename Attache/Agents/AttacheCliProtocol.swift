//
//  AttacheCliProtocol.swift
//  Attache
//

import Foundation

/// What attache-cli prints, read into values.
///
/// attache-cli (`cli/` in this repository) is the one reader of agents for
/// every client: it reads what each agent writes for itself — Claude Code's
/// session files and transcripts, Antigravity's transcripts and screen — and
/// prints JSON lines. This app, like the phone, only renders them. Nothing in
/// here knows where a transcript lives or what a Claude screen looks like;
/// when that knowledge seems to be needed, it belongs in the CLI, where both
/// clients get it. `cli/README.md` is the protocol.
///
/// The phone's reader of the same lines is `AttacheCli.kt` in AttacheAndroid,
/// and the two are meant to read alike.
nonisolated enum AttacheCliProtocol {
    /// The protocol this app speaks. attache-cli raises it only when something
    /// was removed or changed meaning; fields are only ever added within one.
    static let version = 2

    static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any]
        else { return nil }
        return object
    }
}

// MARK: - Agents

nonisolated enum AgentPhase: Int, Comparable, Sendable {
    // In the order the list shows them.
    case needsYou, working, done, idle

    static func < (a: AgentPhase, b: AgentPhase) -> Bool { a.rawValue < b.rawValue }

    init(word: String) {
        switch word {
        case "needs_you": self = .needsYou
        case "working": self = .working
        case "done": self = .done
        // `unknown` too: running, but nothing it writes says what it does.
        default: self = .idle
        }
    }
}

/// One agent in one pane, as `agents` prints it.
nonisolated struct AgentRow: Equatable, Sendable {
    let pane: String
    let session: String
    let window: String
    let windowName: String
    let path: String
    let title: String
    let kind: String
    let phase: AgentPhase
    /// attache-cli said `unknown`: running, but nothing it writes says what
    /// it is doing. `phase` reads it as idle; the rail tells the two apart.
    let isUnknown: Bool
    let since: Int?
    let conversation: String?
    let transcript: String?
    let model: String?

    /// The agents attache-cli reads a conversation for.
    var isFollowed: Bool { kind == "claude" || kind == "agy" }

    init?(_ o: [String: Any]) {
        guard let pane = o["pane"] as? String, TmuxIDs.isPane(pane) else { return nil }
        self.pane = pane
        session = o["session"] as? String ?? ""
        window = o["window"] as? String ?? ""
        windowName = o["window_name"] as? String ?? ""
        path = o["path"] as? String ?? ""
        title = o["title"] as? String ?? ""
        kind = o["kind"] as? String ?? ""
        phase = AgentPhase(word: o["state"] as? String ?? "")
        isUnknown = o["state"] as? String == "unknown"
        since = o["since"] as? Int
        conversation = o["conversation"] as? String
        transcript = o["transcript"] as? String
        model = o["model"] as? String
    }

    /// The `attache-cli seen` that turns this agent from Done to Idle, or nil
    /// when it is not Done or names no conversation to mark.
    var seenArguments: [String]? {
        guard phase == .done, let conversation, Self.isID(kind), Self.isID(conversation) else { return nil }
        return ["seen", kind, conversation]
    }

    private static func isID(_ s: String) -> Bool {
        (1...128).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func parse(_ objects: [[String: Any]]) -> [AgentRow] {
        // Within idle, a known idle before `unknown`: the rail ranks a
        // settled agent above one that says nothing, and a window's first row
        // is the one that speaks for it.
        objects.compactMap(AgentRow.init).sorted {
            if $0.phase != $1.phase { return $0.phase < $1.phase }
            if $0.isUnknown != $1.isUnknown { return !$0.isUnknown }
            return ($0.since ?? 0) > ($1.since ?? 0)
        }
    }
}

// MARK: - The screen

/// A Claude Code permission menu, as attache-cli reads it off the pane.
nonisolated struct ApprovalMenu: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let number: Int
        let label: String
        /// Why this answer needs a second click; nil when one is enough.
        let risk: String?
    }

    let subject: [String]
    let question: String
    let options: [Option]
    /// attache-cli's hash of the rows the menu was read from. An answer names
    /// it, and the host presses the digit only while that very menu is up.
    let fingerprint: String
}

/// A question Claude asked with `AskUserQuestion`: one question or several
/// (as tabs), each picked from a list or, as multiple choice, ticked; and the
/// last tab, where the answers are reviewed and submitted. attache-cli moves
/// the cursor to a row, looks again, and only then presses Enter.
nonisolated struct QuestionMenu: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let number: Int
        let label: String
        let description: String
        /// Answered by typing (`Type something.`, `Chat about this`): the
        /// terminal's.
        let typed: Bool
        /// A multiple choice's box is ticked.
        let checked: Bool
    }

    struct Tab: Equatable, Sendable {
        let title: String
        let answered: Bool
    }

    let header: String
    let question: String
    let tabs: [Tab]
    let multi: Bool
    /// The last tab of several: the answers given, Submit answers or Cancel.
    let review: Bool
    let answers: [(question: String, answer: String)]
    let options: [Option]
    /// A multiple choice's Submit row, which ends that question.
    let submitRow: Bool
    /// The question and its rows, not where the cursor is.
    let fingerprint: String

    static func == (a: QuestionMenu, b: QuestionMenu) -> Bool {
        a.fingerprint == b.fingerprint && a.options == b.options && a.tabs == b.tabs
    }

    init?(_ q: [String: Any]) {
        let fp = q["fingerprint"] as? String ?? ""
        let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> Option? in
            guard let n = o["number"] as? Int else { return nil }
            return Option(number: n, label: o["label"] as? String ?? "",
                          description: o["description"] as? String ?? "", typed: o["typed"] as? Bool ?? false,
                          checked: o["checked"] as? Bool ?? false)
        }
        guard AttacheCliInput.isFingerprint(fp), !options.isEmpty else { return nil }
        header = q["header"] as? String ?? ""
        question = q["question"] as? String ?? ""
        tabs = (q["tabs"] as? [[String: Any]] ?? []).map {
            Tab(title: $0["title"] as? String ?? "", answered: $0["answered"] as? Bool ?? false)
        }
        multi = q["multi"] as? Bool ?? false
        review = q["review"] as? Bool ?? false
        answers = (q["answers"] as? [[String: Any]] ?? []).map {
            (question: $0["question"] as? String ?? "", answer: $0["answer"] as? String ?? "")
        }
        submitRow = q["submit_row"] as? Bool ?? false
        self.options = options
        fingerprint = fp
    }
}

/// Claude's `✻ Jitterbugging… (13s · ↓ 649 tokens)` line.
nonisolated struct AgentActivity: Equatable, Sendable {
    let verb: String
    let detail: String?
}

/// What attache-cli read off a Claude pane; all empty on any other agent.
nonisolated struct ScreenReading: Equatable, Sendable {
    /// Claude's own input box is on screen.
    let prompt: Bool
    let approval: ApprovalMenu?
    /// The last rows of a panel or picker open over the input box.
    let panel: [String]?
    /// attache-cli's hash of `panel`: Enter, the key that chooses, names it
    /// and is pressed only on that very panel.
    let panelFingerprint: String?
    let question: QuestionMenu?
    let activity: AgentActivity?

    static let nothing = ScreenReading(prompt: false, approval: nil, panel: nil, panelFingerprint: nil,
                                       question: nil, activity: nil)

    init(prompt: Bool, approval: ApprovalMenu?, panel: [String]?, panelFingerprint: String?,
         question: QuestionMenu?, activity: AgentActivity?) {
        self.prompt = prompt
        self.approval = approval
        self.panel = panel
        self.panelFingerprint = panelFingerprint
        self.question = question
        self.activity = activity
    }

    init(_ o: [String: Any]) {
        prompt = o["prompt"] as? Bool ?? false
        approval = (o["approval"] as? [String: Any]).flatMap { a in
            let options = (a["options"] as? [[String: Any]] ?? []).compactMap { opt -> ApprovalMenu.Option? in
                guard let n = opt["number"] as? Int else { return nil }
                return .init(number: n, label: opt["label"] as? String ?? "", risk: opt["risk"] as? String)
            }
            let fingerprint = a["fingerprint"] as? String ?? ""
            guard !options.isEmpty, AttacheCliInput.isFingerprint(fingerprint) else { return nil }
            return ApprovalMenu(subject: a["subject"] as? [String] ?? [],
                                question: a["question"] as? String ?? "",
                                options: options, fingerprint: fingerprint)
        }
        panel = o["panel"] as? [String]
        panelFingerprint = (o["panel_fingerprint"] as? String).flatMap { AttacheCliInput.isFingerprint($0) ? $0 : nil }
        question = (o["question"] as? [String: Any]).flatMap(QuestionMenu.init)
        activity = (o["activity"] as? [String: Any]).flatMap { a in
            (a["verb"] as? String).map { AgentActivity(verb: $0, detail: a["detail"] as? String) }
        }
    }
}

// MARK: - Input

/// The keys and conditions `input` takes, and what it answered.
///
/// **A key always names the screen it is for**, and attache-cli reads the
/// screen again holding the pane, just before pressing it. What this app was
/// shown is a request, not a permission: by the time a click arrives the
/// screen can be another one, and a key in the wrong place can cost the
/// session its prompt cache — an Esc on the idle prompt is half of the two
/// that open Claude's rewind menu, a Tab there turns thinking on or off, and
/// a message typed into a picker ends with an Enter that chooses something.
nonisolated enum AttacheCliInput {
    enum Condition: Equatable {
        /// A digit, on the menu with this fingerprint.
        case approval(fingerprint: String)
        /// Arrows, Tab or Esc while a panel is open; with its fingerprint,
        /// Enter too, on that very panel only.
        case panel(fingerprint: String?)
        /// Esc, while the working line is up.
        case working

        var word: String {
            switch self {
            case .approval(let fp): "approval:\(fp)"
            case .panel(let fp?): "panel:\(fp)"
            case .panel(nil): "panel"
            case .working: "working"
            }
        }
    }

    static let panelKeys: Set<String> = ["Up", "Down", "Left", "Right", "Enter", "Escape", "Tab"]

    static func isAllowed(key: String, for condition: Condition) -> Bool {
        switch condition {
        case .approval: key.count == 1 && ("1"..."8").contains(key)
        case .panel(let fp): panelKeys.contains(key) && (key != "Enter" || fp != nil)
        case .working: key == "Escape"
        }
    }

    static func isFingerprint(_ s: String) -> Bool {
        s.count == 16 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    struct Result: Equatable {
        let sent: Bool
        let why: String?

        /// What `input` printed. A host that printed nothing — attache-cli
        /// missing, or one from before protocol 2 — sent nothing either.
        init(lines: [String]?) {
            guard let line = lines?.last, let o = AttacheCliProtocol.object(line) else {
                self.init(sent: false, why: "unreachable")
                return
            }
            self.init(sent: o["sent"] as? Bool ?? false, why: o["why"] as? String)
        }

        init(sent: Bool, why: String?) {
            self.sent = sent
            self.why = why
        }

        /// Why it was not sent, in words for a notice.
        var refusal: String {
            let reason = switch why {
            case "question": "Answer the question first"
            case "panel": "Close the panel first"
            case "no_prompt": "Claude's input box is not on screen"
            case "no_agent": "No agent runs in this pane"
            case "enter_withheld":
                "Something came up on screen as it was typed, so it was not sent; the text is in the box"
            case "panel_changed": "The panel changed"
            case "typed_answer": "That answer needs typing; answer it in the terminal"
            case "question_gone": "The question was answered already"
            case "question_changed": "The question changed"
            case "no_such_option": "That answer is not on the menu"
            case "panel_closed": "The panel has closed"
            case "not_working": "It has already stopped"
            case "not_claude": "Only Claude's screen can be answered from here"
            case "busy": "Another device is typing into this pane"
            case "unreachable": "attache-cli did not answer"
            default: "tmux did not take it"
            }
            return why == "enter_withheld" ? reason : reason + ", so nothing was sent"
        }
    }
}

// MARK: - Conversations

/// One row of a conversation, as `follow` sends it.
nonisolated enum ChatRow: Equatable, Sendable {
    struct DiffLine: Equatable, Sendable {
        /// `-`, `+`, ` ` or `…` (a gap).
        let mark: Character
        let text: String
    }

    case user(key: String, text: String, queued: Bool)
    case agent(key: String, text: String)
    case thinking(key: String, text: String)
    case tool(key: String, name: String, summary: String, detail: String,
              result: String?, isError: Bool, diff: [DiffLine])
    case output(key: String, text: String, isError: Bool, raw: String)
    case note(key: String, text: String)

    var key: String {
        switch self {
        case .user(let k, _, _), .agent(let k, _), .thinking(let k, _),
             .tool(let k, _, _, _, _, _, _), .output(let k, _, _, _), .note(let k, _):
            k
        }
    }

    /// nil for a row type this app does not know yet: attache-cli may add
    /// one within the protocol, and an unknown row is skipped, not an error.
    init?(_ o: [String: Any]) {
        guard let key = o["key"] as? String, !key.isEmpty else { return nil }
        let text = o["text"] as? String ?? ""
        switch o["type"] as? String {
        case "user": self = .user(key: key, text: text, queued: o["queued"] as? Bool ?? false)
        case "agent": self = .agent(key: key, text: text)
        case "thinking": self = .thinking(key: key, text: text)
        case "tool":
            let diff = (o["diff"] as? [[Any]] ?? []).compactMap { pair -> DiffLine? in
                guard pair.count == 2, let mark = (pair[0] as? String)?.first,
                      let line = pair[1] as? String else { return nil }
                return DiffLine(mark: mark, text: line)
            }
            self = .tool(key: key, name: o["name"] as? String ?? "",
                         summary: o["summary"] as? String ?? "",
                         detail: o["detail"] as? String ?? "",
                         result: o["result"] as? String,
                         isError: o["error"] as? Bool ?? false, diff: diff)
        case "output":
            self = .output(key: key, text: text, isError: o["error"] as? Bool ?? false,
                           raw: o["raw"] as? String ?? "")
        case "note": self = .note(key: key, text: text)
        default: return nil
        }
    }
}

/// What the header shows, as `follow` sends it in a `status` event.
nonisolated struct ChatStatus: Equatable, Sendable {
    struct Limit: Equatable, Sendable {
        let label: String
        let usedPercent: Int
        let resetsAt: Int?
    }

    let model: String?
    let effort: String?
    let contextPercent: Int?
    let contextTokens: Int?
    let contextWindow: Int?
    let costUSD: Double?
    let cacheWarm: Bool?
    let cacheExpiresAt: Int?
    let limits: [Limit]
    let version: String?

    init(_ o: [String: Any]) {
        model = o["model"] as? String
        effort = o["effort"] as? String
        contextPercent = o["context_percent"] as? Int
        contextTokens = o["context_tokens"] as? Int
        contextWindow = o["context_window"] as? Int
        costUSD = o["cost_usd"] as? Double
        cacheWarm = o["cache_warm"] as? Bool
        cacheExpiresAt = o["cache_expires_at"] as? Int
        limits = (o["limits"] as? [[String: Any]] ?? []).map {
            Limit(label: $0["label"] as? String ?? "", usedPercent: $0["used_percent"] as? Int ?? 0,
                  resetsAt: $0["resets_at"] as? Int)
        }
        version = o["version"] as? String
    }
}

nonisolated enum TmuxIDs {
    /// `%42`: the only form a pane reaches a command line in.
    static func isPane(_ s: String) -> Bool {
        s.count > 1 && s.first == "%" && s.dropFirst().allSatisfy(\.isASCIIDigit)
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
}
