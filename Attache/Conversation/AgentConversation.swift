//
//  AgentConversation.swift
//  Attache
//

import Foundation

/// One message in a coding agent's conversation, in the only shape the sidebar
/// knows how to draw.
///
/// **The vocabulary here is deliberately smaller than any one agent's.** Claude
/// Code's transcript carries thinking blocks, tool calls, tool results, image
/// attachments, hook payloads and queue bookkeeping; Codex carries two parallel
/// streams and its own reasoning records. None of that is here, because the
/// question this type answers is "what did the person and the agent *say* to
/// each other", and every agent has an answer to that while no two of them
/// agree on anything else. An implementation decides what becomes a message;
/// this decides only what a message looks like once it is one.
struct AgentMessage: Equatable, Identifiable {
    enum Author: Equatable {
        case user
        case assistant
    }

    /// Whether this is the agent finishing a thought or narrating its way to
    /// one — the distinction the outline is built on.
    ///
    /// **How it is decided is the implementation's business, and the three
    /// known agents decide it three different ways.** Codex writes it down:
    /// `agent_message.phase` is literally `commentary` or `final_answer`
    /// (measured 2026-08-01 across 12 rollout files on this machine — 63
    /// commentary, 19 final_answer, 32 older records with no phase at all).
    /// Claude Code publishes no such field and has to be read for it — see
    /// `ClaudeTranscript.standing`. An agent with no concept of it at all marks
    /// everything `.finalReply`, which degrades to "the outline lists
    /// everything" rather than to a wrong answer.
    ///
    /// A user's own message is always `.finalReply`. People do not narrate.
    enum Standing: Equatable {
        case finalReply
        case progress
    }

    /// Stable across snapshots, because that is what lets the view diff two
    /// snapshots instead of rebuilding — and what lets a row stay expanded
    /// while the conversation grows underneath it.
    ///
    /// The implementation picks it. Claude Code has a per-record `uuid` and
    /// uses that; an agent whose records carry no id has to synthesise one that
    /// survives a re-read of the same file, which is a real constraint on
    /// implementations and the reason this is a `String` rather than an index.
    let id: String
    let author: Author
    let standing: Standing
    /// Markdown source, as the agent wrote it. Not rendered, not stripped: the
    /// sidebar renders it, and a check tool comparing against a transcript has
    /// to see the same bytes the file holds.
    let markdown: String
    let timestamp: Date?
    /// The person typed this *while the agent was working* rather than in reply
    /// to it.
    ///
    /// Worth a field of its own because it reads completely differently — an
    /// interjection is usually a correction, and burying it in the flow as an
    /// ordinary turn loses the one thing that makes it interesting. Also
    /// because finding them at all took measurement: see `ClaudeTranscript`.
    let isInterjection: Bool

    init(
        id: String,
        author: Author,
        standing: Standing,
        markdown: String,
        timestamp: Date? = nil,
        isInterjection: Bool = false
    ) {
        self.id = id
        self.author = author
        self.standing = standing
        self.markdown = markdown
        self.timestamp = timestamp
        self.isInterjection = isInterjection
    }
}

/// One conversation, entire, as of one moment.
///
/// **A snapshot rather than a stream of edits, and that is a measured decision
/// rather than a simplification.** A delta protocol would oblige every
/// implementation to guarantee its source only ever grows. Two of the three
/// agents checked do: Claude Code and Codex both append JSONL. The third does
/// not — Gemini CLI rewrites the *entire* message array on every turn, one line
/// reading `{"$set":{"messages":[…]}}` (verified 2026-08-01 against
/// `~/.gemini/tmp/<project>/chats/session-*.jsonl` on this machine). Under a
/// delta contract that agent cannot be implemented correctly at all; under this
/// one it is the easy case.
///
/// Diffing is the view's job and it has `AgentMessage.id` to do it with.
struct AgentConversation: Equatable {
    /// Identity of the *conversation*, not of the pane or the file.
    ///
    /// When this changes the sidebar starts over rather than appending: the
    /// person ran `/clear`, resumed a different session, or quit the agent and
    /// started another one in the same pane. All three happen often enough that
    /// treating a new conversation as growth of the old one would show a
    /// stitched-together history that never existed.
    let id: String
    /// Which agent this came from, in `@agent_kind`'s vocabulary: `claude`,
    /// `codex`. Drawn in the header, and the reason the sidebar can say "this
    /// window is running something I cannot read" instead of going blank.
    let agent: String
    let title: String?
    let messages: [AgentMessage]

    init(id: String, agent: String, title: String? = nil, messages: [AgentMessage]) {
        self.id = id
        self.agent = agent
        self.title = title
        self.messages = messages
    }

    var isEmpty: Bool { messages.isEmpty }
}

// MARK: - Finding a conversation

/// What a pane knows about itself, as the conversation layer is allowed to see
/// it.
///
/// A read-only projection of what `TmuxSessionConnection` already subscribes to
/// rather than a reference to it, so `Attache/Conversation/` depends on strings
/// and never on the tmux layer. That direction matters: it keeps the whole
/// conversation layer testable with no tmux server and no screen, which is what
/// `Tools/ClaudeTranscriptCheck` relies on.
struct AgentPaneEvidence: Equatable {
    let paneID: String
    /// `@agent_kind` — `claude`, `codex`, or empty when nothing said.
    let kind: String
    /// `pane_current_command`. **The liveness check, and it is load-bearing
    /// here for the same reason it is in `AgentDetector`:** every value below
    /// is a tmux pane option, and a pane option outlives the process that wrote
    /// it. An agent killed with `^C` leaves its transcript path behind forever,
    /// and a sidebar that trusted it would present a conversation that ended
    /// hours ago as the live one.
    let currentCommand: String
    /// The raw `@agent_stat` value, unparsed. Claude Code's route to its own
    /// transcript path runs through here.
    let statusPayload: String
    /// A session id an agent's hook may have written to the pane directly, for
    /// agents that publish no status payload. Codex is expected to arrive this
    /// way.
    let sessionID: String
}

/// Where a conversation lives, in whatever terms its own provider needs.
///
/// `Equatable` on purpose: "has this pane's conversation changed" is then one
/// comparison per refresh rather than a file open. That check runs on every
/// tmux notification, so it has to be free.
struct AgentConversationLocator: Equatable {
    let agent: String
    /// Opaque to everything except the provider that made it. Claude Code puts
    /// a transcript path here; Codex would put a session id and glob for the
    /// file, because its file name carries a timestamp nothing else knows.
    let key: String
}

/// Turns pane evidence into a conversation, for one kind of agent.
///
/// **This is the whole extension point.** Adding an agent means adding one of
/// these plus one source; no view changes, and nothing in `Attache/UI/` learns
/// a second vocabulary. Whether that boundary is in the right place has one
/// concrete test — see the header comment on `ClaudeCodeConversationProvider`
/// for the shape a Codex implementation would take, worked out against real
/// rollout files rather than guessed.
protocol AgentConversationProvider {
    /// The `@agent_kind` value this provider answers for.
    var agent: String { get }

    /// `nil` when this evidence points at nothing this provider can read —
    /// a different agent, a dead process, or an agent of the right kind that
    /// has not said where its transcript is yet.
    ///
    /// May touch the disk; called off the main queue.
    func locate(_ evidence: AgentPaneEvidence) -> AgentConversationLocator?

    func makeSource(for locator: AgentConversationLocator) -> AgentConversationSource
}

/// A live conversation: pushes a whole snapshot whenever it changes.
protocol AgentConversationSource: AnyObject {
    /// Delivered on the main queue, first one as soon as there is anything to
    /// deliver. Nil-able so the view can drop it on teardown without the source
    /// having to know about the view's lifetime.
    var onSnapshot: ((AgentConversation) -> Void)? { get set }

    func start()
    func stop()
}
