//
//  ClaudeCodeConversationProvider.swift
//  Attache
//

import Foundation

/// Finds and follows a Claude Code conversation.
///
/// **The route to the file already existed and nothing had to be installed for
/// it.** `AgentStatusLineInstaller`'s wrapper writes the JSON object Claude
/// Code hands its status line into the pane option `@agent_stat`, and that
/// object carries `transcript_path` — an absolute path to the JSONL this reads.
/// So the pane-to-conversation link costs one more field in `AgentStats` rather
/// than a new mechanism, and it keeps CLAUDE.md's opening rule intact: the
/// value lives in tmux and any `tmux attach` client can read it.
///
/// ## What a second implementation looks like
///
/// Recorded here because the shape of this file is the only evidence that the
/// protocol's boundary is in a useful place, and it was checked against real
/// data rather than imagined. Codex (CLI 0.146.0-alpha, measured 2026-08-01 on
/// this machine) would need:
///
/// - `locate` — the same job, different evidence. Codex publishes no status
///   payload, so a hook writes its session id to `@agent_session`
///   (`~/.codex/hooks.json` takes the same shape as Claude Code's, and its
///   stdin carries `session_id`), and locate globs
///   `~/.codex/sessions/YYYY/MM/DD/rollout-*-<id>.jsonl` because the file name
///   carries a timestamp nothing else knows.
/// - A parser with *different* traps. Its rollout files interleave two parallel
///   streams — `response_item` and `event_msg` — and **the same sentence
///   appears once in each**, so one stream has to be picked. That is Codex's
///   version of this file's `queue-operation` problem, and it is why
///   deduplication is not in the protocol.
/// - **No standing heuristic at all.** Codex writes `agent_message.phase`,
///   literally `commentary` or `final_answer`, so the thing that took
///   measurement here is a field lookup there. A protocol that demanded a
///   `stop_reason` would force that implementation to fabricate one.
///
/// Everything above is confined to two new files. This file, `ClaudeTranscript`
/// and every view stay untouched.
struct ClaudeCodeConversationProvider: AgentConversationProvider {
    let agent = "claude"

    /// Prefixed onto locator keys so one path on two machines is two
    /// locators; empty for the local machine, whose keys predate hosts.
    private let hostPrefix: String
    /// Whether the transcript is worth following. Local answers with a stat;
    /// remote answers `true` *optimistically*, because `locate` runs on the
    /// main actor by design (see `AgentConversationProvider`) and a round
    /// trip does not belong there — a remote path that turns out absent
    /// renders as the empty conversation its placeholder already covers.
    private let transcriptExists: (String) -> Bool
    private let sourceFactory: (String) -> AgentConversationSource

    /// The local machine's provider — the shape this file always had.
    init() {
        hostPrefix = ""
        transcriptExists = { FileManager.default.fileExists(atPath: $0) }
        sourceFactory = { ClaudeCodeConversationSource(path: $0) }
    }

    /// A remote machine's provider: same evidence, same parsing, but the
    /// bytes arrive over the helper channel and no local path is ever
    /// consulted — a transcript path that exists on both machines is the
    /// wrong conversation with the right name.
    init(remoteHostID: String, helper: RemoteHelper) {
        hostPrefix = remoteHostID + "\u{01}"
        transcriptExists = { _ in true }
        sourceFactory = { RemoteClaudeCodeConversationSource(helper: helper, path: $0) }
    }

    func locate(_ evidence: AgentPaneEvidence) -> AgentConversationLocator? {
        // **Liveness before anything else, and this is not defensive coding.**
        // Every field of the evidence is a tmux pane option, and a pane option
        // outlives the process that wrote it — an agent killed with `^C` never
        // runs its exit hook, so its transcript path sits on that pane until
        // something else overwrites it. Without this check the sidebar would
        // present a conversation that ended hours ago as the live one, with
        // nothing on screen saying otherwise. The same rule, for the same
        // reason, is why `AgentDetector.badge` reads the command.
        guard AgentDetector.isAgentCommand(evidence.currentCommand) else { return nil }

        let kind = evidence.kind.isEmpty
            ? AgentDetector.kind(ofCommand: evidence.currentCommand)
            : evidence.kind
        guard kind == agent else { return nil }

        guard let path = Self.transcriptPath(fromStatusPayload: evidence.statusPayload),
              transcriptExists(path)
        else { return nil }

        return AgentConversationLocator(agent: agent, key: hostPrefix + path)
    }

    func makeSource(for locator: AgentConversationLocator) -> AgentConversationSource {
        sourceFactory(String(locator.key.dropFirst(hostPrefix.count)))
    }

    /// Pull `transcript_path` out of the raw `@agent_stat` value.
    ///
    /// Its own function, and public to the file, because it is the single point
    /// where a Claude Code payload change would silently disconnect the
    /// sidebar. Returns nil rather than a guess for anything unexpected: an
    /// empty sidebar is a visible failure, a sidebar pointed at the wrong file
    /// is not.
    static func transcriptPath(fromStatusPayload payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let path = root["transcript_path"] as? String,
              !path.isEmpty
        else { return nil }
        return path
    }
}

// MARK: -

/// Follows one transcript file and pushes a whole conversation whenever it
/// grows.
///
/// Parsing is incremental — a byte offset, and only the new tail is decoded —
/// because these files reach 40 MB and an agent mid-turn appends several times
/// a second. Re-reading the whole thing per append would spend the turn
/// parsing. What is *published* is still a whole snapshot, because that is what
/// lets a source whose file was rewritten in place stay correct; see
/// `AgentConversation`.
/// The parsing half both sources share: JSONL lines in, a publishable
/// conversation out. Split from the byte transport because the local and
/// remote sources differ *only* in where bytes come from, and two copies of
/// the record parsing is how they drift.
private struct ClaudeConversationAccumulator {
    private(set) var messages = [AgentMessage]()
    private(set) var conversationID: String?

    mutating func reset() {
        messages.removeAll()
        conversationID = nil
    }

    mutating func append(line: Data) {
        guard !line.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { return }

        if conversationID == nil, let id = root["sessionId"] as? String, !id.isEmpty {
            conversationID = id
        }
        if let message = ClaudeTranscript.message(fromRecord: root) { messages.append(message) }
    }

    func snapshot(fallbackID: String) -> AgentConversation {
        AgentConversation(
            id: conversationID ?? fallbackID,
            agent: "claude",
            title: messages.first(where: { $0.author == .user })?.markdown,
            messages: messages
        )
    }
}

private final class ClaudeCodeConversationSource: AgentConversationSource {
    var onSnapshot: ((AgentConversation) -> Void)?

    private let path: String
    private let queue = DispatchQueue(label: "me.xueshi.attache.conversation", qos: .utility)
    private var monitor: ConversationFileMonitor?

    /// Where the reading has got to, and every rule about a file that changed
    /// underneath it. Its own type so that the replace, truncate and
    /// split-record cases can be checked with no disk — see
    /// `Tools/TranscriptTailCheck`.
    private var tail = TranscriptTail()
    private var accumulated = ClaudeConversationAccumulator()

    init(path: String) {
        self.path = path
    }

    func start() {
        let monitor = ConversationFileMonitor(path: path, queue: queue) { [weak self] in
            self?.readNewBytes()
        }
        self.monitor = monitor
        monitor.start()
    }

    func stop() {
        monitor?.stop()
        monitor = nil
        onSnapshot = nil
    }

    private func readNewBytes() {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        // `fstat` on the descriptor already open rather than `stat` on the
        // path: the path can be replaced between the open and the check, and
        // an identity taken that way would belong to a file this never read.
        var info = stat()
        let identity = fstat(handle.fileDescriptor, &info) == 0
            ? TranscriptTail.FileIdentity(
                device: UInt64(info.st_dev), inode: UInt64(info.st_ino)
            )
            : nil
        let size = (try? handle.seekToEnd()) ?? 0

        let step = tail.advance(size: size, identity: identity) { offset, count in
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            return try? handle.read(upToCount: count)
        }

        // Everything read before belongs to a file that is no longer at this
        // path. Dropping `conversationID` with the messages is deliberate: a
        // replacement is usually a different session, and keeping the old id
        // would make `ConversationController` treat it as growth and carry the
        // reader's open turns across into a conversation they never opened.
        if step.didReset { accumulated.reset() }
        for line in step.lines { accumulated.append(line: line) }

        // **Publish on a reset even with nothing to show.** A file truncated to
        // empty produces no lines, and a publish gated on having some would
        // never fire — leaving the sidebar displaying the whole conversation
        // that was just thrown away. Found by review 2026-08-01.
        guard step.didReset || !step.lines.isEmpty else { return }
        let snapshot = accumulated.snapshot(fallbackID: path)
        guard let onSnapshot else { return }
        DispatchQueue.main.async { onSnapshot(snapshot) }
    }
}

// MARK: -

/// The same transcript followed over the helper channel: one `STATTAIL` per
/// second while the rail is visible, `TranscriptTail` deciding what the
/// answer means exactly as it does locally — identity and reader are already
/// injected there, so the remote source is a ranged-read closure over the
/// fetched window and nothing else. **Not `tail -F`**, and that is measured,
/// not stylistic: an atomic replace and an in-place truncation both stream
/// through `tail -F` with no marker of any kind, which is precisely the
/// spliced-conversation defect `TranscriptTail`'s three reset tests exist to
/// prevent — and streaming would starve all three of input.
private final class RemoteClaudeCodeConversationSource: AgentConversationSource {
    var onSnapshot: ((AgentConversation) -> Void)?

    private let helper: RemoteHelper
    private let path: String
    private var tail = TranscriptTail()
    private var accumulated = ClaudeConversationAccumulator()
    private var timer: Timer?
    private var inFlight = false
    private var started = false

    init(helper: RemoteHelper, path: String) {
        self.helper = helper
        self.path = path
    }

    func start() {
        started = true
        poll()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        onSnapshot = nil
    }

    @MainActor private func poll() {
        guard started, !inFlight else { return }
        inFlight = true
        helper.statTail(path: path, fromOffset: tail.offset) { [weak self] outcome in
            guard let self, self.started else { return }
            self.inFlight = false
            guard case .answered(let answer) = outcome else {
                // Absent keeps the last snapshot, like a local file that went
                // away mid-look; unavailable is the channel's problem and the
                // host row is already saying so. Neither is "empty now".
                return
            }
            self.consume(answer)
        }
    }

    @MainActor private func consume(_ answer: RemoteStatTail) {
        let window = answer.bytes
        let windowStart = answer.start
        let step = tail.advance(
            size: answer.size,
            identity: TranscriptTail.FileIdentity(device: answer.device, inode: answer.inode)
        ) { offset, count in
            // Answer only from the fetched window. After a reset the tail
            // asks from 0, which an offset-anchored window cannot serve —
            // the nil sends it back empty-handed and the immediate re-poll
            // below fetches the file from the top.
            guard offset >= windowStart,
                  let from = Int(exactly: offset - windowStart), from <= window.count
            else { return nil }
            let take = min(count, window.count - from)
            return window.subdata(in: from ..< from + take)
        }

        if step.didReset { accumulated.reset() }
        for line in step.lines { accumulated.append(line: line) }

        if step.didReset, windowStart > 0 {
            // The file was replaced or truncated and the new content starts
            // before our window. Publish the reset so nothing stale stays on
            // screen, then go straight back for the bytes from zero.
            publish()
            inFlight = false
            poll()
            return
        }
        guard step.didReset || !step.lines.isEmpty else { return }
        publish()
    }

    @MainActor private func publish() {
        onSnapshot?(accumulated.snapshot(fallbackID: path))
    }
}
