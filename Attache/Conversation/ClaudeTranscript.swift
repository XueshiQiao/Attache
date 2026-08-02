//
//  ClaudeTranscript.swift
//  Attache
//

import Foundation

/// Reads a Claude Code transcript into the shape the sidebar draws.
///
/// **This file decides what the user is shown of their own conversation, so its
/// failures are asymmetric.** Letting a record through that is not really a
/// message puts noise in the outline — annoying, visible, fixable. *Dropping* a
/// real one is silent: the person sees a conversation missing something they
/// said and has no way to tell that it is missing. Every rule below therefore
/// errs toward keeping, and every exclusion is a record type that was counted
/// rather than assumed.
///
/// `Tools/ClaudeTranscriptCheck` is the table, and the cases in it were written
/// from a census of four real transcripts totalling ~145 MB (measured
/// 2026-08-01). Run it after touching anything here:
///
/// ```sh
/// swiftc -O -o /tmp/transcriptcheck Attache/Conversation/AgentConversation.swift \
///   Attache/Conversation/ClaudeTranscript.swift Tools/ClaudeTranscriptCheck/main.swift
/// /tmp/transcriptcheck
/// ```
///
/// ## The three traps, all measured
///
/// **A message typed while the agent is working is not `type: "user"`.** It
/// arrives as `type: "attachment"` with `attachment.type == "queued_command"`,
/// and the only thing separating it from a system notification wearing the same
/// type is `attachment.origin.kind == "human"`. In one 40 MB transcript there
/// were 36 `queued_command` attachments and only 7 of them were the person
/// speaking. Reading `type: "user"` alone loses every interjection — which is
/// exactly the class of message most worth having, because an interjection is
/// usually a correction.
///
/// **The same interjection is also recorded as `type: "queue-operation"`, two
/// to four times.** `enqueue`, then `remove` or `dequeue`, and `popAll` when
/// several are flushed at once — 180 such records in that same transcript
/// against 36 attachments. They carry the full text and look perfectly usable,
/// which is the trap. They are ignored here in favour of the attachment, which
/// appears exactly once and carries a `uuid`.
///
/// **The biggest population of `type: "user"` is not the user.** Tool results
/// come back as user-role records — 989 of them in that transcript against 104
/// real prompts. They are excluded on the content block type rather than on any
/// property of their text.
enum ClaudeTranscript {

    /// Parse whole transcript lines into a conversation.
    ///
    /// `id` comes from the records rather than from the file name: a transcript
    /// that was resumed carries its own session id, and the file it lives in
    /// can be renamed underneath us.
    static func conversation(fromLines lines: [String], fallbackID: String) -> AgentConversation {
        var messages = [AgentMessage]()
        var sessionID: String?
        messages.reserveCapacity(lines.count / 4)

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            if sessionID == nil { sessionID = string(root["sessionId"]) }
            if let message = message(fromRecord: root) { messages.append(message) }
        }

        return AgentConversation(
            id: sessionID ?? fallbackID,
            agent: "claude",
            title: messages.first(where: { $0.author == .user })?.markdown,
            messages: messages
        )
    }

    /// One record to at most one message.
    ///
    /// Deliberately total: every early return is a record kind that is *not* a
    /// message, and each one is named so that a future record type shows up as
    /// "fell through to nil" rather than as a wrong message.
    static func message(fromRecord root: [String: Any]) -> AgentMessage? {
        // A sub-agent's conversation is a conversation of its own and belongs
        // to whatever spawned it, not to the person. Claude Code puts the main
        // session's sidechain records in the same file.
        if root["isSidechain"] as? Bool == true { return nil }

        switch string(root["type"]) {
        case "attachment":
            return interjection(fromRecord: root)
        case "user":
            return userMessage(fromRecord: root)
        case "assistant":
            return assistantMessage(fromRecord: root)
        default:
            // `queue-operation` lands here, and so do `system`,
            // `file-history-snapshot`, `mode`, `permission-mode` and
            // `last-prompt`. None of them is a thing anybody said.
            return nil
        }
    }

    // MARK: - The person

    /// A prompt typed while the agent was mid-turn.
    private static func interjection(fromRecord root: [String: Any]) -> AgentMessage? {
        guard let attachment = root["attachment"] as? [String: Any],
              string(attachment["type"]) == "queued_command",
              // The whole test. Without it this also matches the
              // `<task-notification>` payloads the harness queues on the app's
              // own behalf, which are not the person speaking and would appear
              // in the outline as if they were.
              let origin = attachment["origin"] as? [String: Any],
              string(origin["kind"]) == "human"
        else { return nil }

        let prompt = trimmed(string(attachment["prompt"]))
        guard !prompt.isEmpty else { return nil }

        return AgentMessage(
            id: string(root["uuid"]) ?? "queued-\(prompt.hashValue)",
            author: .user,
            standing: .finalReply,
            markdown: prompt,
            timestamp: date(fromISO: string(root["timestamp"])),
            isInterjection: true
        )
    }

    private static func userMessage(fromRecord root: [String: Any]) -> AgentMessage? {
        // Skill preambles, image dimension notes and the rest of what the
        // harness writes in the user's name. Claude Code marks them itself, so
        // this needs no string matching on the content.
        if root["isMeta"] as? Bool == true { return nil }

        guard let message = root["message"] as? [String: Any] else { return nil }

        let text: String
        switch message["content"] {
        case let plain as String:
            text = plain
        case let blocks as [Any]:
            // A tool result is a user-role record and is the single largest
            // population in any transcript. One block of it disqualifies the
            // record; a prompt never carries one.
            if blocks.contains(where: { ($0 as? [String: Any]).map { string($0["type"]) == "tool_result" } ?? false }) {
                return nil
            }
            text = textBlocks(in: blocks)
        default:
            return nil
        }

        var body = trimmed(text)
        guard !body.isEmpty else { return nil }
        // The transcript records what was attached alongside a prompt as a
        // separate line in the user's name. It is machine bookkeeping —
        // dimensions and a source path — and reads as gibberish in an outline.
        if body.hasPrefix("[Image:") { return nil }

        // **Several things wear a user record without a person having said
        // them, and none of them is marked.** No `isMeta`, no sidechain flag —
        // same `promptId`, same `uuid`, same everything as a real prompt, so
        // the body is the only thing to go on. Counted across three transcripts
        // on 2026-08-01: 23 `<task-notification>`, 10 messages relayed from
        // another agent, 10 slash commands. Against 106 real prompts. The
        // first build showed all of them as things the person said, which is
        // wrong in the way that matters most here — the sidebar's whole claim
        // is that the blue blocks are *your* words.
        if body.hasPrefix(Self.relayedFromAnotherAgent) { return nil }
        // **Named envelopes only, never "starts with a tag".** The first build
        // dropped every body beginning with `<` that was not a command, and
        // that is the failure this file's whole preamble warns about: a person
        // asking `<div>why does this break?</div>` had their question silently
        // deleted. Dropping by name means an envelope this app has not met yet
        // shows up as noise — visible, reported, one line to fix — instead of
        // eating real questions. Found by review 2026-08-01.
        if Self.machineEnvelopes.contains(where: body.hasPrefix) { return nil }
        // Two envelopes are the person and are unwrapped rather than dropped,
        // because both are things they typed:
        //
        // - A slash command, recorded as three XML-ish tags **in either
        //   order** — `<command-name>` first in some records,
        //   `<command-message>` first in others. `/clear` is where a
        //   conversation ends, and deleting it leaves two stretches of
        //   conversation inexplicably not joined up.
        // - A shell command run with `!`, recorded as `<bash-input>`. Its
        //   *output* comes back separately and is machine text; the command is
        //   not.
        //
        // Both gated on the body starting with a tag, so prose merely quoting
        // one is left alone.
        if body.hasPrefix("<") {
            if let command = slashCommand(in: body) {
                body = command
            } else if let shell = shellCommand(in: body) {
                body = shell
            } else if body.hasPrefix("<bash-input>"), body.contains("</bash-input>") {
                // A complete envelope holding nothing. Not a prompt, and not
                // worth a row. An *unclosed* tag falls through instead and is
                // shown as written — that is a person typing about the tag,
                // not the harness recording a command.
                return nil
            }
        }

        return AgentMessage(
            id: string(root["uuid"]) ?? "user-\(body.hashValue)",
            author: .user,
            standing: .finalReply,
            markdown: body,
            timestamp: date(fromISO: string(root["timestamp"]))
        )
        // `[Request interrupted by user]` deliberately survives all of the
        // above. It is not noise: it is the person stopping the agent, which is
        // a real turn in the conversation and often the most important one on
        // the screen.
    }

    // MARK: - The agent

    private static func assistantMessage(fromRecord root: [String: Any]) -> AgentMessage? {
        guard let message = root["message"] as? [String: Any],
              let blocks = message["content"] as? [Any]
        else { return nil }

        let body = trimmed(textBlocks(in: blocks))
        // A record carrying only a tool call, or only thinking, says nothing to
        // the person. Claude Code splits one API response across several
        // records that share a `message.id`, so the text and the tool call it
        // ends with are usually different lines of the file.
        guard !body.isEmpty else { return nil }

        return AgentMessage(
            id: string(root["uuid"]) ?? "assistant-\(body.hashValue)",
            author: .assistant,
            standing: standing(ofBody: body, stopReason: string(message["stop_reason"])),
            markdown: body,
            timestamp: date(fromISO: string(root["timestamp"]))
        )
    }

    /// Whether a reply is the agent finishing a thought or narrating its way to
    /// one.
    ///
    /// **`stop_reason` alone is not enough, and finding that out is what this
    /// rule cost.** `end_turn` means the agent handed control back, so it is a
    /// final reply beyond argument — but the converse fails badly. Measured on
    /// one real conversation: **one** record carried `end_turn` while three
    /// others were unmistakably summaries (428, 590 and 892 characters, with
    /// headings and tables) and all three read `tool_use`, because the agent
    /// reported and then carried straight on working.
    ///
    /// So structure is the second signal, and it beats length outright. Over
    /// three transcripts of 34–40 MB the two populations separate cleanly by
    /// structure (final replies median 536 characters against 132 for progress)
    /// while *overlapping heavily* by length — the longest progress note ran
    /// 1076 characters and the shortest final reply 101. Any length threshold
    /// is therefore wrong somewhere, and this one is wrong nowhere on the
    /// conversation it was checked against: 5 final replies of 428–1046
    /// characters, 34 progress notes of 17–157, with an empty band between.
    ///
    /// Two of four signals, not one, because a single blank line appears in
    /// plenty of two-sentence progress notes.
    static func standing(ofBody body: String, stopReason: String?) -> AgentMessage.Standing {
        if stopReason == "end_turn" { return .finalReply }
        return structureSignals(in: body) >= 2 ? .finalReply : .progress
    }

    /// How many of the four block-level markdown structures appear.
    ///
    /// Scanned by hand rather than by regular expression: this runs over every
    /// reply in a file that can reach 40 MB, and it is the only per-message
    /// work that is not already bounded by JSON parsing.
    static func structureSignals(in body: String) -> Int {
        var hasBlankLine = false, hasHeading = false, hasList = false, hasTable = false
        var previousWasEmpty = false
        var isFirstLine = true

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.drop { $0 == " " || $0 == "\t" }

            if line.isEmpty {
                // A blank line only separates paragraphs if something came
                // before it; leading blanks are trimmed noise.
                if !isFirstLine { previousWasEmpty = true }
                isFirstLine = false
                continue
            }
            if previousWasEmpty { hasBlankLine = true; previousWasEmpty = false }
            isFirstLine = false

            if line.hasPrefix("#"), line.dropFirst(while: { $0 == "#" }).hasPrefix(" ") {
                hasHeading = true
            } else if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
                // A whole line in bold is how this codebase's own replies write
                // a heading, and dropping it would misfile most of them.
                hasHeading = true
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                hasList = true
            } else if let dot = line.firstIndex(of: "."),
                      line.startIndex < dot,
                      line[line.startIndex..<dot].allSatisfy(\.isNumber),
                      line[dot...].dropFirst().hasPrefix(" ") {
                hasList = true
            }

            if line.hasPrefix("|"), line.dropFirst().contains("|") { hasTable = true }
        }

        return [hasBlankLine, hasHeading, hasList, hasTable].filter { $0 }.count
    }

    /// The prefix the harness puts on a message relayed from another agent.
    static let relayedFromAnotherAgent = "Another Claude session sent a message"

    /// Machine-written bodies that arrive wearing a user record, by name.
    ///
    /// A list rather than a pattern, because the cost of the two mistakes is
    /// not the same: an envelope missing from here is noise in the outline,
    /// while a pattern loose enough to catch them all also catches a person
    /// asking about HTML.
    ///
    /// **Counted, not guessed.** Every tag-leading user record across all 408
    /// transcripts on this machine, 2026-08-01: `task-notification` 835,
    /// `command-name` 250, `local-command-stdout` 54, `bash-stdout` 45,
    /// `bash-input` 45, `command-message` 30. Two of those are the person and
    /// are handled elsewhere — a slash command, and a shell command typed with
    /// `!`. The rest are here.
    static let machineEnvelopes = [
        "<task-notification",
        "<system-reminder",
        "<local-command-stdout",
        "<local-command-stderr",
        // The output of a `!` command, paired as
        // `<bash-stdout>…</bash-stdout><bash-stderr>…</bash-stderr>`. The
        // person typed the command, not its output.
        "<bash-stdout",
        "<bash-stderr",
    ]

    /// `<command-name>/clear</command-name>…` to `/clear`, plus any argument.
    ///
    /// **Does not require the tags in a fixed order.** Both orders appear in
    /// real transcripts — `<command-name>` first in some records,
    /// `<command-message>` first in others — and matching only the first one
    /// left ten `/loop` invocations rendering as raw markup.
    ///
    /// Nil when there is no command tag at all, which is what makes the caller
    /// able to treat "starts with `<` and is not a command" as a record to
    /// drop.
    static func slashCommand(in body: String) -> String? {
        let name = tag("command-name", in: body)
        guard !name.isEmpty else { return nil }
        let args = tag("command-args", in: body)
        return args.isEmpty ? name : "\(name) \(args)"
    }

    /// `<bash-input>open .</bash-input>` to `!open .`
    ///
    /// The `!` is put back on because that is what the person typed and it is
    /// what distinguishes a shell command from a sentence beginning with a
    /// word like `open`.
    static func shellCommand(in body: String) -> String? {
        let command = tag("bash-input", in: body)
        return command.isEmpty ? nil : "!\(command)"
    }

    private static func tag(_ name: String, in body: String) -> String {
        guard let open = body.range(of: "<\(name)>"),
              let close = body.range(of: "</\(name)>"),
              open.upperBound <= close.lowerBound
        else { return "" }
        return body[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Reading values that came from outside

    private static func textBlocks(in blocks: [Any]) -> String {
        blocks.reduce(into: "") { result, block in
            guard let block = block as? [String: Any],
                  string(block["type"]) == "text",
                  let text = block["text"] as? String
            else { return }
            result += text
        }
    }

    private static func string(_ any: Any?) -> String? {
        any as? String
    }

    private static func trimmed(_ text: String?) -> String {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// ISO 8601 with fractional seconds, which is what the transcript writes.
    ///
    /// One formatter rather than one per call: this runs once per message and a
    /// fresh `ISO8601DateFormatter` costs more than the parse does.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func date(fromISO text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return isoFormatter.date(from: text) ?? isoFormatterNoFraction.date(from: text)
    }
}

private extension Substring {
    func dropFirst(while predicate: (Character) -> Bool) -> Substring {
        drop(while: predicate)
    }
}
