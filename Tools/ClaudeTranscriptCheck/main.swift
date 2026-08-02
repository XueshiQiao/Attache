//
//  main.swift
//  ClaudeTranscriptCheck
//
//  Cross-check for `ClaudeTranscript`, in the same spirit as
//  `Tools/LinkTargetCheck` and `Tools/RenameStringCheck`.
//
//      swiftc -O -o /tmp/transcriptcheck \
//          Attache/Conversation/AgentConversation.swift \
//          Attache/Conversation/ClaudeTranscript.swift \
//          Tools/ClaudeTranscriptCheck/main.swift
//      /tmp/transcriptcheck
//
//  This file decides what the person is shown of their own conversation, and
//  its two failure directions are not symmetric. A record wrongly kept is
//  noise: visible, annoying, reported in a minute. A record wrongly *dropped*
//  is silent — the outline is missing something they said and nothing on
//  screen says so. The keep/drop half of this table therefore matters more
//  than the classification half, in the same way `TerminalReply`'s keystrokes
//  matter more than its replies.
//
//  Every case here is a record shape counted in a real transcript, not one
//  invented to exercise a branch. The census (2026-08-01, four transcripts,
//  ~145 MB) is what the header of `ClaudeTranscript` records.
//

import Foundation

// MARK: - Harness

func record(_ json: String) -> [String: Any] {
    guard let data = json.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
        print("BROKEN CASE — not valid JSON: \(json.prefix(90))")
        exit(2)
    }
    return root
}

enum Expected {
    case dropped
    case user(String, interjection: Bool = false)
    case assistant(String, AgentMessage.Standing)
}

struct Case {
    let name: String
    let line: String
    let expect: Expected
}

func describe(_ message: AgentMessage?) -> String {
    guard let message else { return "dropped" }
    let who = message.author == .user ? "user" : "assistant"
    let mark = message.isInterjection ? " [interjection]" : ""
    let standing = message.standing == .finalReply ? "final" : "progress"
    return "\(who)/\(standing)\(mark) \(message.markdown.debugDescription)"
}

func matches(_ message: AgentMessage?, _ expected: Expected) -> Bool {
    switch (message, expected) {
    case (nil, .dropped):
        return true
    case let (.some(message), .user(text, interjection)):
        return message.author == .user
            && message.markdown == text
            && message.isInterjection == interjection
            && message.standing == .finalReply
    case let (.some(message), .assistant(text, standing)):
        return message.author == .assistant
            && message.markdown == text
            && message.standing == standing
    default:
        return false
    }
}

// MARK: - Keep or drop
//
// The half that matters. Each drop names the population it belongs to and how
// many of them one 40 MB transcript held.

let keepDrop: [Case] = [

    // ---- The person, plainly ----

    Case(
        name: "a prompt with string content",
        line: #"{"type":"user","uuid":"u1","timestamp":"2026-08-01T00:01:23.968Z","message":{"role":"user","content":"start the app now."}}"#,
        expect: .user("start the app now.")
    ),
    Case(
        name: "a prompt delivered as text blocks",
        line: #"{"type":"user","uuid":"u2","message":{"content":[{"type":"text","text":"看看。"}]}}"#,
        expect: .user("看看。")
    ),
    Case(
        name: "a prompt that came with an image keeps its text",
        line: #"{"type":"user","uuid":"u3","message":{"content":[{"type":"image","source":{}},{"type":"text","text":"why is this red?"}]}}"#,
        expect: .user("why is this red?")
    ),
    Case(
        name: "interrupting the agent is a turn, not noise",
        line: #"{"type":"user","uuid":"u4","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
        expect: .user("[Request interrupted by user]")
    ),
    Case(
        name: "leading and trailing whitespace comes off",
        line: #"{"type":"user","uuid":"u5","message":{"content":"\n  整体\n\n"}}"#,
        expect: .user("整体")
    ),

    // ---- Interjections: the trap this file exists for ----

    Case(
        name: "TRAP a message typed mid-turn is an attachment, not a user record",
        line: #"{"type":"attachment","uuid":"a1","timestamp":"2026-08-01T00:01:23.967Z","attachment":{"type":"queued_command","prompt":"好像少了一轮我的对话呀。","commandMode":"prompt","origin":{"kind":"human"}}}"#,
        expect: .user("好像少了一轮我的对话呀。", interjection: true)
    ),
    Case(
        name: "TRAP the same attachment type without origin.kind=human is a system notification",
        line: #"{"type":"attachment","uuid":"a2","attachment":{"type":"queued_command","prompt":"<task-notification><task-id>biq5</task-id></task-notification>","commandMode":"prompt"}}"#,
        expect: .dropped
    ),
    Case(
        name: "TRAP an agent-originated queued command is not the person either",
        line: #"{"type":"attachment","uuid":"a3","attachment":{"type":"queued_command","prompt":"continue","origin":{"kind":"agent"}}}"#,
        expect: .dropped
    ),
    Case(
        name: "an empty queued prompt yields nothing",
        line: #"{"type":"attachment","uuid":"a4","attachment":{"type":"queued_command","prompt":"   ","origin":{"kind":"human"}}}"#,
        expect: .dropped
    ),
    Case(
        name: "other attachment types are harness bookkeeping",
        line: #"{"type":"attachment","uuid":"a5","attachment":{"type":"task_reminder","content":"remember to..."}}"#,
        expect: .dropped
    ),

    // ---- The 180-record duplicate ----

    Case(
        name: "TRAP queue-operation carries the same text and must not double it (enqueue)",
        line: #"{"type":"queue-operation","operation":"enqueue","content":"好像少了一轮我的对话呀。","sessionId":"s1"}"#,
        expect: .dropped
    ),
    Case(
        name: "TRAP queue-operation remove, same text again",
        line: #"{"type":"queue-operation","operation":"remove","content":"好像少了一轮我的对话呀。","sessionId":"s1"}"#,
        expect: .dropped
    ),
    Case(
        name: "TRAP queue-operation popAll, a third copy",
        line: #"{"type":"queue-operation","operation":"popAll","content":"[Image #8] what the hell is this?","sessionId":"s1"}"#,
        expect: .dropped
    ),

    // ---- The 989-record majority ----

    Case(
        name: "TRAP a tool result is a user-role record and is not the user",
        line: #"{"type":"user","uuid":"u6","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
        expect: .dropped
    ),
    Case(
        name: "TRAP a tool result sitting beside text is still a tool result",
        line: #"{"type":"user","uuid":"u7","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"},{"type":"text","text":"see above"}]}}"#,
        expect: .dropped
    ),

    // ---- Written in the user's name by the harness ----

    Case(
        name: "a meta record is the harness talking, however user-shaped",
        line: #"{"type":"user","uuid":"u8","isMeta":true,"message":{"content":[{"type":"text","text":"Base directory for this skill: /tmp/skills/run"}]}}"#,
        expect: .dropped
    ),
    Case(
        name: "image dimension bookkeeping is not a prompt",
        line: #"{"type":"user","uuid":"u9","message":{"content":"[Image: original 3840x1974, displayed at 2000x1028.]"}}"#,
        expect: .dropped
    ),

    // ---- Slash commands ----
    //
    // Seen in a real transcript on 2026-08-01 and rendered as raw tags by the
    // first build, which put a wall of markup at the top of the outline.

    Case(
        name: "a slash command shows as what was typed, not as its tags",
        line: #"{"type":"user","uuid":"u11","message":{"content":"<command-name>/clear</command-name>\n            <command-message>clear</command-message>\n            <command-args></command-args>"}}"#,
        expect: .user("/clear")
    ),
    Case(
        name: "a slash command keeps its argument",
        line: #"{"type":"user","uuid":"u12","message":{"content":"<command-name>/model</command-name><command-message>model</command-message><command-args>opus</command-args>"}}"#,
        expect: .user("/model opus")
    ),
    Case(
        name: "TRAP the tags also arrive in the other order",
        line: #"{"type":"user","uuid":"u15","message":{"content":"<command-message>loop</command-message> <command-name>/loop</command-name> <command-args>5m</command-args>"}}"#,
        expect: .user("/loop 5m")
    ),
    Case(
        name: "prose that merely mentions a tag is left alone",
        line: #"{"type":"user","uuid":"u13","message":{"content":"the transcript has a <command-name> tag in it"}}"#,
        expect: .user("the transcript has a <command-name> tag in it")
    ),
    Case(
        name: "an unclosed command tag is shown as written rather than swallowed",
        line: #"{"type":"user","uuid":"u14","message":{"content":"<command-name>/clear"}}"#,
        expect: .user("<command-name>/clear")
    ),

    // ---- Wearing a user record without a person having said it ----
    //
    // Counted 2026-08-01 over three transcripts: 23 task notifications and 10
    // relayed agent messages against 106 real prompts. None carries `isMeta`,
    // so only the body tells them apart — and the first build showed every one
    // of them as something the owner had typed.

    Case(
        name: "TRAP a background task notification is not the person",
        line: #"{"type":"user","uuid":"u16","promptId":"p1","message":{"content":"<task-notification>\n<task-id>aaaa96b5</task-id>\n<summary>done</summary>\n</task-notification>"}}"#,
        expect: .dropped
    ),
    Case(
        name: "TRAP a message relayed from another agent is not the person",
        line: #"{"type":"user","uuid":"u17","promptId":"p2","message":{"content":"Another Claude session sent a message:\n<teammate-message teammate_id=\"Frank\">hello</teammate-message>"}}"#,
        expect: .dropped
    ),
    Case(
        name: "a system reminder is not the person",
        line: #"{"type":"user","uuid":"u18","message":{"content":"<system-reminder>the todo list is empty</system-reminder>"}}"#,
        expect: .dropped
    ),

    // ---- `!` shell commands ----
    //
    // Counted across all 408 transcripts on this machine 2026-08-01: 45
    // `<bash-input>` and 45 paired `<bash-stdout>…<bash-stderr>`. The command
    // is the person; its output is not. Both were being shown as prompts.

    Case(
        name: "TRAP a shell command's output is not the person",
        line: #"{"type":"user","uuid":"b1","message":{"content":"<bash-stdout>(Bash completed with no output)</bash-stdout><bash-stderr></bash-stderr>"}}"#,
        expect: .dropped
    ),
    Case(
        name: "TRAP output with real content is still not the person",
        line: #"{"type":"user","uuid":"b2","message":{"content":"<bash-stdout>total 48\ndrwxr-xr-x  3 joey  staff</bash-stdout><bash-stderr></bash-stderr>"}}"#,
        expect: .dropped
    ),
    Case(
        name: "a shell command the person typed shows as what they typed",
        line: #"{"type":"user","uuid":"b3","message":{"content":"<bash-input>open .</bash-input>"}}"#,
        expect: .user("!open .")
    ),
    Case(
        name: "a shell command with arguments keeps them",
        line: #"{"type":"user","uuid":"b4","message":{"content":"<bash-input>git log --oneline -5</bash-input>"}}"#,
        expect: .user("!git log --oneline -5")
    ),
    Case(
        name: "an empty shell command is nothing",
        line: #"{"type":"user","uuid":"b5","message":{"content":"<bash-input></bash-input>"}}"#,
        expect: .dropped
    ),

    // ---- Markup that IS the person ----
    //
    // The first build dropped every body starting with `<` that was not a
    // command, which deleted real questions about markup without a trace.
    // Found by review 2026-08-01. These are the cases that must survive.

    Case(
        name: "REGRESSION a question that opens with an HTML tag is the person asking",
        line: #"{"type":"user","uuid":"u20","message":{"content":"<div>Why does this layout break?</div>"}}"#,
        expect: .user("<div>Why does this layout break?</div>")
    ),
    Case(
        name: "REGRESSION a pasted XML snippet is still a prompt",
        line: #"{"type":"user","uuid":"u21","message":{"content":"<key>ENABLE_APP_SANDBOX</key> — 这个为什么必须是 NO？"}}"#,
        expect: .user("<key>ENABLE_APP_SANDBOX</key> — 这个为什么必须是 NO？")
    ),
    Case(
        name: "REGRESSION an unknown envelope shows as noise rather than eating a question",
        line: #"{"type":"user","uuid":"u22","message":{"content":"<some-future-thing>hello</some-future-thing>"}}"#,
        expect: .user("<some-future-thing>hello</some-future-thing>")
    ),
    Case(
        name: "a prompt that merely starts mid-sentence about agents is kept",
        line: #"{"type":"user","uuid":"u19","message":{"content":"Another Claude session would be overkill here."}}"#,
        expect: .user("Another Claude session would be overkill here.")
    ),

    // ---- Sub-agents ----

    Case(
        name: "a sub-agent's prompt belongs to the sub-agent, not the person",
        line: #"{"type":"user","uuid":"u10","isSidechain":true,"message":{"content":"search for the config loader"}}"#,
        expect: .dropped
    ),
    Case(
        name: "a sub-agent's reply likewise",
        line: #"{"type":"assistant","uuid":"s10","isSidechain":true,"message":{"stop_reason":"end_turn","content":[{"type":"text","text":"found it"}]}}"#,
        expect: .dropped
    ),

    // ---- The agent ----

    Case(
        name: "a reply with text is a message",
        line: #"{"type":"assistant","uuid":"s1","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"Build succeeded. Launching."}]}}"#,
        expect: .assistant("Build succeeded. Launching.", .progress)
    ),
    Case(
        name: "a record carrying only a tool call says nothing to the person",
        line: #"{"type":"assistant","uuid":"s2","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#,
        expect: .dropped
    ),
    Case(
        name: "a record carrying only thinking says nothing either",
        line: #"{"type":"assistant","uuid":"s3","message":{"stop_reason":"tool_use","content":[{"type":"thinking","thinking":"let me consider"}]}}"#,
        expect: .dropped
    ),
    Case(
        name: "text beside a tool call keeps the text",
        line: #"{"type":"assistant","uuid":"s4","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"Checking the layout."},{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}"#,
        expect: .assistant("Checking the layout.", .progress)
    ),

    // ---- Record types that are not messages at all ----

    Case(name: "system", line: #"{"type":"system","subtype":"hook","uuid":"x1"}"#, expect: .dropped),
    Case(name: "mode", line: #"{"type":"mode","mode":"normal","sessionId":"s"}"#, expect: .dropped),
    Case(name: "last-prompt", line: #"{"type":"last-prompt","leafUuid":"d5","sessionId":"s"}"#, expect: .dropped),
    Case(name: "file-history-snapshot", line: #"{"type":"file-history-snapshot","snapshot":{}}"#, expect: .dropped),
    Case(
        name: "an unknown future record type falls through rather than guessing",
        line: #"{"type":"telepathy","uuid":"z1","message":{"content":"hello"}}"#,
        expect: .dropped
    ),
]

// MARK: - Final reply or progress
//
// The classification half. Wrong here is cosmetic — the message is still shown,
// just in the wrong band — but it is what the whole outline is built on, and
// the rule was arrived at by measurement, so it gets a table too.

struct StandingCase {
    let name: String
    let body: String
    let stopReason: String?
    let expect: AgentMessage.Standing
}

let summary = """
研究完了，有一个**硬结论**必须先说：跳转到终端里对应位置，做不到。

**实测发现**

| 事 | 结果 |
|---|---|
| pane 能不能找到对话文件 | 能，而且现成 |
"""

let longNarration = """
数据形态很说明问题：22 条里只有 2 条提问、20 条回复，而回复里 17 条是「我要干嘛」的一句话，真正成段的长回复只有 3 条。这直接决定排版，所以先把这件事量清楚再动手，免得选错了方向还得推倒重来一次。
"""

let standingCases: [StandingCase] = [
    StandingCase(
        name: "end_turn settles it on its own, however short",
        body: "Done.",
        stopReason: "end_turn",
        expect: .finalReply
    ),
    StandingCase(
        name: "MEASURED a summary that kept working reads tool_use and is still final",
        body: summary,
        stopReason: "tool_use",
        expect: .finalReply
    ),
    StandingCase(
        name: "a one-line narration is progress",
        body: "先看下 PopBar 现在的 Action 抽象长什么样。",
        stopReason: "tool_use",
        expect: .progress
    ),
    StandingCase(
        name: "MEASURED length does not make it final — 1076 chars of plain prose is still progress",
        body: longNarration,
        stopReason: "tool_use",
        expect: .progress
    ),
    StandingCase(
        name: "one signal is not enough — a blank line alone is progress",
        body: "三条都记下了。\n\n那这东西实质上是一个阅读器。",
        stopReason: "tool_use",
        expect: .progress
    ),
    StandingCase(
        name: "MEASURED short but structured is final — 101 chars with two signals",
        body: "**要收**\n\n- user 纯文本\n- queued_command",
        stopReason: "tool_use",
        expect: .finalReply
    ),
    StandingCase(
        name: "a whole line in bold counts as a heading",
        body: "**做了什么**\n\n1. 重新构建\n2. 启动",
        stopReason: "tool_use",
        expect: .finalReply
    ),
    StandingCase(
        name: "a hash heading counts too",
        body: "## 实测结果\n\n跑通了。",
        stopReason: "tool_use",
        expect: .finalReply
    ),
    StandingCase(
        name: "bold used inline mid-sentence is not a heading",
        body: "这个 **不是** 标题，只是强调，而且整行还有别的字。",
        stopReason: "tool_use",
        expect: .progress
    ),
    StandingCase(
        name: "a hashtag without a space is not a heading",
        body: "#hashtag 不是标题\n\n第二段",
        stopReason: "tool_use",
        expect: .progress
    ),
    StandingCase(
        name: "a table plus paragraphs is final",
        body: "对照如下：\n\n| a | b |\n|---|---|\n| 1 | 2 |",
        stopReason: "tool_use",
        expect: .finalReply
    ),
    StandingCase(
        name: "a leading blank line is not a paragraph break",
        body: "\n只有一段话，前面那个空行是缩进留下的。",
        stopReason: "tool_use",
        expect: .progress
    ),
    StandingCase(
        name: "a numbered list plus a heading is final",
        body: "**下一步**\n1. 构建\n2. 启动\n3. 截图",
        stopReason: "tool_use",
        expect: .finalReply
    ),
    StandingCase(
        name: "no stop_reason at all falls back to structure",
        body: "**结论**\n\n- 做不到",
        stopReason: nil,
        expect: .finalReply
    ),
]

// MARK: - A whole file
//
// The single most valuable case in the file: one interjection, recorded the
// four ways Claude Code records it, must produce exactly one message.

let wholeFile = [
    #"{"type":"user","uuid":"u1","timestamp":"2026-07-31T23:36:24.216Z","sessionId":"sess-1","message":{"content":"start the app now."}}"#,
    #"{"type":"assistant","uuid":"s1","timestamp":"2026-07-31T23:36:39.622Z","sessionId":"sess-1","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"Building."}]}}"#,
    #"{"type":"user","uuid":"u2","sessionId":"sess-1","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"BUILD SUCCEEDED"}]}}"#,
    #"{"type":"queue-operation","operation":"enqueue","content":"另外这个 Agent Status 是什么？","sessionId":"sess-1"}"#,
    #"{"type":"queue-operation","operation":"remove","content":"另外这个 Agent Status 是什么？","sessionId":"sess-1"}"#,
    #"{"type":"attachment","uuid":"a1","timestamp":"2026-08-01T00:01:23.967Z","sessionId":"sess-1","attachment":{"type":"queued_command","prompt":"另外这个 Agent Status 是什么？","origin":{"kind":"human"}}}"#,
    #"{"type":"assistant","uuid":"s2","timestamp":"2026-08-01T00:02:24.000Z","sessionId":"sess-1","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"**Agent Status**\n\n它是一段 JSON。"}]}}"#,
    #"not json at all, a half-written line at the tail of a growing file"#,
    #""#,
]

// MARK: - Run

var failures = 0

for testCase in keepDrop {
    let actual = ClaudeTranscript.message(fromRecord: record(testCase.line))
    if !matches(actual, testCase.expect) {
        failures += 1
        print("FAIL  \(testCase.name)")
        print("      line     \(testCase.line.prefix(120))")
        print("      expected \(testCase.expect)")
        print("      actual   \(describe(actual))")
    }
}

for testCase in standingCases {
    let actual = ClaudeTranscript.standing(ofBody: testCase.body, stopReason: testCase.stopReason)
    if actual != testCase.expect {
        failures += 1
        print("FAIL  \(testCase.name)")
        print("      signals  \(ClaudeTranscript.structureSignals(in: testCase.body))")
        print("      expected \(testCase.expect)")
        print("      actual   \(actual)")
    }
}

let parsed = ClaudeTranscript.conversation(fromLines: wholeFile, fallbackID: "fallback")
var fileFailures = 0
func expect(_ condition: Bool, _ what: String) {
    if !condition { fileFailures += 1; print("FAIL  whole file — \(what)") }
}
expect(parsed.id == "sess-1", "session id should come from the records, got \(parsed.id)")
expect(parsed.agent == "claude", "agent should be claude, got \(parsed.agent)")
expect(parsed.messages.count == 4, "expected 4 messages, got \(parsed.messages.count): "
    + parsed.messages.map { $0.markdown.prefix(18) }.joined(separator: " | "))
let interjections = parsed.messages.filter(\.isInterjection)
expect(interjections.count == 1, "the interjection recorded four ways must appear once, got \(interjections.count)")
expect(parsed.messages.last?.standing == .finalReply, "the end_turn reply should be final")
expect(parsed.messages.first?.timestamp != nil, "timestamps should parse")
expect(parsed.title == "start the app now.", "title should be the first prompt, got \(parsed.title ?? "nil")")
failures += fileFailures

let total = keepDrop.count + standingCases.count + 7
if failures == 0 {
    print("ClaudeTranscriptCheck: \(total) cases, all pass")
} else {
    print("ClaudeTranscriptCheck: \(failures) failed out of \(total)")
    exit(1)
}
