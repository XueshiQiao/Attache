//
//  AgentChatModel.swift
//  Attache
//

import Foundation

/// A message this app typed that the transcript has not shown yet.
nonisolated struct PendingMessage: Equatable {
    let id: Int
    let text: String
    let sentAt: Date
    var unconfirmed = false
    /// The last row shown when it went out. The bubble is drawn right after
    /// that row, and only prompts after it can confirm it: drawn at the end
    /// instead, a message the transcript never confirmed stayed below
    /// everything said after it, and matched against the whole conversation,
    /// a second `/context` was confirmed at once by the first (both measured
    /// on the phone, 2026-11-05).
    let anchorKey: String?

    func isConfirmed(by rows: [ChatRow]) -> Bool {
        let anchor = anchorKey.flatMap { key in rows.firstIndex { $0.key == key } } ?? -1
        return rows.dropFirst(anchor + 1).contains { row in
            if case .user(_, let said, _) = row {
                return text.isEmpty || said.trimmingCharacters(in: .whitespacesAndNewlines).contains(text)
            }
            return false
        }
    }
}

/// One agent's conversation and everything a click can do to it.
///
/// Nothing here is authored by this app, the same as the phone's chat page:
/// the conversation is the agent's own transcript, followed by attache-cli;
/// what the agent is doing and what is on its screen come from attache-cli
/// too (`agents --watch --pane`), pushed when they change; and everything a
/// person does reaches the agent as keys into the same pane, which
/// attache-cli presses only after reading the screen again itself. So
/// `tmux attach` at another desk shows exactly what was done here.
@MainActor
final class AgentChatModel {
    enum TranscriptState { case loading, live, missing }

    let link: AttacheCliLink
    let pane: String

    private(set) var agent: AgentRow?
    /// The pane is still there, but no agent runs in it any more.
    private(set) var agentExited = false
    private(set) var paneGone = false
    private(set) var screen = ScreenReading.nothing
    private(set) var rows: [ChatRow] = []
    private(set) var status: ChatStatus?
    private(set) var transcriptState = TranscriptState.loading
    /// Reading began part-way into the file; older turns are not shown.
    private(set) var earlierNotLoaded = false
    private(set) var loadingEarlier = false
    private(set) var pending: [PendingMessage] = []
    /// The last thing worth telling the person, until shown.
    var notice: String?

    /// Called on every change; the view reads what it needs.
    var onChange: (() -> Void)?

    /// Whether the page is in front of the person: only then does an agent
    /// that finished count as seen.
    var isOnScreen = false {
        didSet { if isOnScreen { markSeen() } }
    }

    private var watch: AttacheCliStream?
    private var follow: AttacheCliStream?
    private var followedPath: String?
    private var historyStart: Int?
    private var before: Int?
    private var freshRead = true
    private var carryOver: [ChatRow] = []
    private var lastSlash: (command: String, at: Date)?
    private var nextPendingID = 1
    private var stopped = false
    /// Which stream is the current one. A cancelled stream still ends, and
    /// its end must not start another beside the one that replaced it.
    private var watchGeneration = 0
    private var followGeneration = 0
    private var watchRetry = AttacheCliRetry()
    private var followRetry = AttacheCliRetry()

    init(link: AttacheCliLink, pane: String, known: AgentRow? = nil) {
        precondition(TmuxIDs.isPane(pane))
        self.link = link
        self.pane = pane
        self.agent = known
    }

    func start() {
        stopped = false
        startWatch()
        if let path = agent?.transcript, let kind = agent?.kind { followTranscript(path, kind: kind) }
    }

    func stop() {
        stopped = true
        // A stream ended by this still ends, and its restart must not pass
        // for the current one's if the page is started again within the wait.
        watchGeneration += 1
        followGeneration += 1
        watch?.cancel()
        watch = nil
        follow?.cancel()
        follow = nil
    }

    // MARK: - What the agent is doing

    /// The approval dock, the working line and the panel dock follow the
    /// agent's phase as on the phone: a menu is answered only while Claude
    /// says it waits, and a panel is offered only while it neither waits nor
    /// works, which leaves the multi-question form to the terminal.
    var approval: ApprovalMenu? { agent?.phase == .needsYou ? screen.approval : nil }
    var question: QuestionMenu? { agent?.phase == .needsYou ? screen.question : nil }
    var activity: AgentActivity? { agent?.phase == .working ? screen.activity : nil }
    var panel: [String]? {
        guard let phase = agent?.phase, phase != .needsYou, phase != .working else { return nil }
        return screen.panel
    }

    var canType: Bool {
        !paneGone && !agentExited && agent != nil && agent?.phase != .needsYou && panel == nil
    }

    private func startWatch() {
        watch?.cancel()
        watchGeneration += 1
        let generation = watchGeneration
        watch = link.stream(["agents", "--watch", "--pane", pane], onEvent: { [weak self] event in
            guard let self, self.watchGeneration == generation else { return }
            self.watchRetry.reset()
            self.watched(event)
        }, onEnd: { [weak self] in
            // attache-cli ended on its own, or the host went away: ask again,
            // later each time it keeps failing, unless this page was closed.
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + watchRetry.next()) { [weak self] in
                guard let self, !self.stopped, self.watchGeneration == generation else { return }
                self.startWatch()
            }
        })
    }

    private func watched(_ event: [String: Any]) {
        switch event["t"] as? String {
        case "agents":
            let found = AgentRow.parse(event["agents"] as? [[String: Any]] ?? []).first
            if let found {
                agent = found
                agentExited = false
                paneGone = false
                if let path = found.transcript, found.isFollowed { followTranscript(path, kind: found.kind) }
                if found.transcript == nil, transcriptState == .loading { transcriptState = .missing }
                if found.phase == .done, isOnScreen { markSeen() }
                onChange?()
            } else {
                checkPaneStillThere()
            }
        case "screen":
            screen = ScreenReading(event)
            onChange?()
        default:
            break
        }
    }

    private func checkPaneStillThere() {
        let argv = link.transport.oneShotArgv(["display-message", "-p", "-t", pane, "#{pane_id}"])
        Self.runQuiet(argv) { [weak self] out in
            guard let self else { return }
            if out?.trimmingCharacters(in: .whitespacesAndNewlines) == self.pane {
                self.agentExited = true
            } else {
                self.paneGone = true
            }
            self.onChange?()
        }
    }

    // MARK: - The conversation

    private func followTranscript(_ path: String, kind: String) {
        guard Self.isFollowable(path), kind == "claude" || kind == "agy" else { return }
        guard path != followedPath || follow == nil else { return }
        // A `/clear` starts a new, empty file; the conversation just watched
        // stays above it with a divider.
        if let old = followedPath, old != path, let slash = lastSlash,
           slash.command == "/clear", Date().timeIntervalSince(slash.at) < 120, !rows.isEmpty {
            carryOver = rows + [.note(key: "clear-\(path)", text: "New conversation (/clear)")]
        } else if followedPath != path {
            carryOver = []
        }
        followedPath = path
        before = nil
        startFollow(path: path, kind: kind)
    }

    private func startFollow(path: String, kind: String) {
        follow?.cancel()
        followGeneration += 1
        let generation = followGeneration
        var args = ["follow", kind, path]
        if let before { args += ["--before", String(before)] }
        freshRead = true
        var fromHere: [ChatRow] = []
        follow = link.stream(args, onEvent: { [weak self] event in
            guard let self, self.followGeneration == generation else { return }
            self.followRetry.reset()
            switch event["t"] as? String {
            case "switched":
                // attache-cli follows the conversation into its new file and
                // says so with a fresh `hello`; a restart must start there.
                if let moved = event["path"] as? String, Self.isFollowable(moved) { self.followedPath = moved }
            case "waiting":
                if self.rows.isEmpty { self.transcriptState = .loading; self.onChange?() }
            case "hello":
                self.historyStart = event["start"] as? Int
                self.freshRead = true
            case "items":
                let from = event["from"] as? Int ?? 0
                let parsed = (event["items"] as? [[String: Any]] ?? []).compactMap(ChatRow.init)
                fromHere = self.freshRead ? parsed : Array(fromHere.prefix(from)) + parsed
                self.freshRead = false
                self.before = nil
                self.loadingEarlier = false
                self.publish(fromHere)
            case "status":
                self.status = ChatStatus(event)
                if !self.freshRead { self.onChange?() }
            default:
                break
            }
        }, onEnd: { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + followRetry.next()) { [weak self] in
                guard let self, !self.stopped, self.followGeneration == generation,
                      let current = self.followedPath else { return }
                if self.rows.isEmpty { self.transcriptState = .missing; self.onChange?() }
                self.startFollow(path: current, kind: kind)
            }
        })
    }

    private func publish(_ followed: [ChatRow]) {
        rows = carryOver + followed
        transcriptState = .live
        earlierNotLoaded = (historyStart ?? 0) > 0
        // A sent message is confirmed once the agent has written it down.
        pending.removeAll { $0.isConfirmed(by: rows) }
        onChange?()
    }

    /// Reads from further back: a new follow from before where this one
    /// started, which sends every row again with the earlier ones in front.
    func loadEarlier() {
        guard !loadingEarlier, let start = historyStart, start > 0,
              let path = followedPath, let kind = agent?.kind else { return }
        loadingEarlier = true
        before = start
        startFollow(path: path, kind: kind)
        onChange?()
    }

    static func isFollowable(_ path: String) -> Bool {
        path.hasPrefix("/") && path.hasSuffix(".jsonl") && path.utf8.count <= 4096
            && !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    // MARK: - What a click does

    /// Types `text` and Enter. attache-cli puts it in only if Claude's own
    /// input box is on screen with nothing over it.
    func send(_ text: String) {
        let words = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return }
        if agent?.phase == .needsYou {
            notice = "Answer the question first"
            onChange?()
            return
        }
        guard canType else {
            notice = panel != nil ? "Close the panel first" : "The agent is not there to take it"
            onChange?()
            return
        }
        if words.hasPrefix("/") {
            lastSlash = (String(words.prefix { $0 != " " }), Date())
        }
        let message = PendingMessage(id: nextPendingID, text: words, sentAt: Date(),
                                     anchorKey: rows.last?.key)
        nextPendingID += 1
        pending.append(message)
        onChange?()
        let b64 = Data(words.utf8).base64EncodedString()
        link.run(["input", pane, "--text", b64, "--enter"]) { [weak self] lines in
            guard let self else { return }
            let result = AttacheCliInput.Result(lines: lines)
            if !result.sent {
                self.pending.removeAll { $0.id == message.id }
                self.notice = result.refusal
                self.onChange?()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, let i = self.pending.firstIndex(where: { $0.id == message.id }) else { return }
                self.pending[i].unconfirmed = true
                self.onChange?()
            }
        }
    }

    /// Claude stops a turn on Esc. attache-cli presses it only while the
    /// working line is up: an Esc after the turn ended lands on the idle
    /// prompt, and two of those open the rewind menu.
    func interrupt() { press("Escape", .working) }

    /// Answers the menu by its number, on that very menu only. No Enter
    /// follows: Claude selects on the digit, and an Enter would submit the
    /// input box.
    func answer(_ option: ApprovalMenu.Option) {
        guard let menu = approval else { return }
        press(String(option.number), .approval(fingerprint: menu.fingerprint))
    }

    /// Picks an answer to the question Claude asked. attache-cli moves the
    /// cursor there with arrows, reads the screen again, and presses Enter
    /// only if the cursor arrived on that very question.
    func choose(_ option: QuestionMenu.Option) {
        guard let q = question, !option.typed else { return }
        link.run(["input", pane, "--choose", String(option.number), "--if", "question:\(q.fingerprint)"]) { [weak self] lines in
            guard let self else { return }
            let result = AttacheCliInput.Result(lines: lines)
            if !result.sent {
                self.notice = result.refusal
                self.onChange?()
            }
        }
    }

    /// One of a panel's keys, while it is still open. Enter chooses whatever
    /// is selected, so it names the panel the person was looking at.
    func panelKey(_ key: String) {
        if key == "Enter" {
            guard let fp = screen.panelFingerprint else {
                notice = "The panel is still being read, so nothing was sent"
                onChange?()
                return
            }
            press(key, .panel(fingerprint: fp))
        } else {
            press(key, .panel(fingerprint: nil))
        }
    }

    private func press(_ key: String, _ condition: AttacheCliInput.Condition) {
        guard AttacheCliInput.isAllowed(key: key, for: condition) else { return }
        link.run(["input", pane, "--key", key, "--if", condition.word]) { [weak self] lines in
            guard let self else { return }
            let result = AttacheCliInput.Result(lines: lines)
            if !result.sent {
                self.notice = result.refusal
                self.onChange?()
            }
        }
    }

    // MARK: - Files into the message

    /// Paths the agent can open for files on this Mac: the paths themselves
    /// when the agent runs here, copies in the host's `/tmp` when it runs
    /// elsewhere — a local path on another machine names nothing, or the
    /// wrong file.
    func stage(files: [URL], then insert: @escaping (String) -> Void) {
        guard !link.transport.pathsAreLocal else {
            insert(files.map { Self.shellToken($0.path) }.joined(separator: " ") + " ")
            return
        }
        var remote: [String?] = Array(repeating: nil, count: files.count)
        var problems: [String] = []
        let group = DispatchGroup()
        for (i, url) in files.enumerated() {
            // What cannot go is said, and why: a folder, or too large to copy.
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                problems.append("\(url.lastPathComponent) is a folder")
                continue
            }
            if (values?.fileSize ?? 0) > 50 * 1024 * 1024 {
                problems.append("\(url.lastPathComponent) is over 50 MB")
                continue
            }
            let name = url.lastPathComponent.filter { $0.isLetter || $0.isNumber || ".-_".contains($0) }
            let path = "/tmp/attache-paste-\(UUID().uuidString.prefix(8))-\(name.isEmpty ? "file" : name)"
            group.enter()
            upload(file: url, to: path) { ok in
                if ok { remote[i] = path } else { problems.append("\(url.lastPathComponent) could not be copied") }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            let paths = remote.compactMap { $0 }
            if !problems.isEmpty {
                self?.notice = problems.joined(separator: "; ")
                self?.onChange?()
            }
            if !paths.isEmpty { insert(paths.map(Self.shellToken).joined(separator: " ") + " ") }
        }
    }

    /// An image on the pasteboard with no file behind it (a screenshot):
    /// saved as a PNG where the agent runs, and its path typed.
    func stage(image png: Data, then insert: @escaping (String) -> Void) {
        let name = "attache-paste-\(UUID().uuidString.prefix(8)).png"
        if link.transport.pathsAreLocal {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
            do {
                try png.write(to: url)
                insert(Self.shellToken(url.path) + " ")
            } catch {
                notice = "The image could not be saved"
                onChange?()
            }
            return
        }
        let path = "/tmp/" + name
        upload(png, to: path) { [weak self] ok in
            if ok {
                insert(path + " ")
            } else {
                self?.notice = "The image could not be copied to the host"
                self?.onChange?()
            }
        }
    }

    /// A file's bytes, read off the main thread, to `path` on the host.
    private func upload(file url: URL, to path: String, completion: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [link] in
            guard let data = try? Data(contentsOf: url) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            Self.write(data, to: path, over: link, completion: completion)
        }
    }

    /// Writes `data` to `path` on the agent's machine, through ssh's stdin.
    private func upload(_ data: Data, to path: String, completion: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [link] in
            Self.write(data, to: path, over: link, completion: completion)
        }
    }

    nonisolated private static func write(_ data: Data, to path: String, over link: AttacheCliLink,
                                          completion: @escaping @MainActor (Bool) -> Void) {
        let argv = link.transport.execArgv(["/bin/sh", "-c", "cat > \"$1\"", "sh", path])
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else {
                try? input.fileHandleForWriting.close()
                try? input.fileHandleForReading.close()
                DispatchQueue.main.async { completion(false) }
                return
            }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: deadline)
            try? input.fileHandleForWriting.write(contentsOf: data)
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            deadline.cancel()
            let ok = process.terminationStatus == 0
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// A path as one word for the agent: bare when nothing in it needs
    /// quoting, single-quoted otherwise — the terminal's `PasteContent` rule.
    private static func shellToken(_ path: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/")
        if !path.isEmpty, path.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Done becomes Idle once the person has seen what the agent did.
    private func markSeen() {
        guard let agent, agent.phase == .done, let conversation = agent.conversation,
              Self.isID(agent.kind), Self.isID(conversation) else { return }
        link.run(["seen", agent.kind, conversation]) { _ in }
    }

    private static func isID(_ s: String) -> Bool {
        (1...128).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func runQuiet(_ argv: [String], completion: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            let text = process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
            DispatchQueue.main.async { completion(text) }
        }
    }
}
