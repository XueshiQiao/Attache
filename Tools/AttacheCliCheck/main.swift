// What attache-cli prints, read the way the app reads it, and the rules the
// app applies before it asks attache-cli to press anything.
//
//   swiftc -O -o /tmp/attachecliccheck Attache/Agents/AttacheCliProtocol.swift \
//     Attache/Agents/AgentChatModel.swift Attache/Agents/AttacheCliLink.swift \
//     Attache/Agents/HostAgents.swift Attache/Agents/AttacheCliInstaller.swift \
//     Attache/Tmux/TmuxTransport.swift Attache/Tmux/TmuxSocket.swift \
//     Attache/Tmux/PipeRead.swift Tools/AttacheCliCheck/main.swift
//   /tmp/attachecliccheck
//
// The shapes are attache-cli 0.2.0's (`cli/README.md`); the phone's reader
// (`AttacheCliTest.kt`) checks the same lines.

import Foundation

var failures = 0
var cases = 0
func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
    cases += 1
    if !ok {
        failures += 1
        print("FAIL \(what) (line \(line))")
    }
}

func object(_ s: String) -> [String: Any] { AttacheCliProtocol.object(s)! }

MainActor.assumeIsolated {
    // Agents, sorted the way the list shows them: needs you first, newest first.
    let rows = AgentRow.parse([
        object(#"{"pane":"%1","window":"@1","kind":"claude","state":"idle","since":5}"#),
        object(#"{"pane":"%2","window":"@1","kind":"claude","state":"needs_you","since":1}"#),
        object(#"{"pane":"%3","window":"@2","kind":"agy","state":"working","since":9,"transcript":"/x/t.jsonl"}"#),
        object(#"{"pane":"%4","window":"@2","kind":"codex","state":"unknown"}"#),
        object(#"{"pane":"nope","kind":"claude","state":"idle"}"#),
    ])
    check(rows.map(\.pane) == ["%2", "%3", "%1", "%4"], "agents sort by phase then newest, bad pane ids dropped")
    check(rows.last?.phase == .idle, "`unknown` reads as idle")
    check(rows[1].isFollowed && !rows[3].isFollowed, "claude and agy are followed, codex is not")
    check(rows.last?.isUnknown == true && rows[2].isUnknown == false, "`unknown` stays apart from idle")
    let idleFirst = AgentRow.parse([
        object(#"{"pane":"%5","window":"@3","kind":"codex","state":"unknown"}"#),
        object(#"{"pane":"%6","window":"@3","kind":"claude","state":"idle"}"#),
    ])
    check(idleFirst.map(\.pane) == ["%6", "%5"], "a known idle speaks for the window before an unknown one")

    // Seen: only a Done agent, and only with a conversation that is a plain id.
    let seen = AgentRow.parse([
        object(#"{"pane":"%1","window":"@1","kind":"claude","state":"done","conversation":"c94cb7d8-1e11"}"#),
        object(#"{"pane":"%2","window":"@1","kind":"claude","state":"idle","conversation":"abc"}"#),
        object(#"{"pane":"%3","window":"@1","kind":"claude","state":"done"}"#),
        object(#"{"pane":"%4","window":"@1","kind":"claude","state":"done","conversation":"../etc"}"#),
    ])
    check(seen.map(\.seenArguments) == [["seen", "claude", "c94cb7d8-1e11"], nil, nil, nil],
          "seen is asked only for a Done agent with a plain conversation id")

    // The screen. A fingerprint that is not attache-cli's shape is no
    // fingerprint, and a menu without one cannot be answered.
    let menu = ScreenReading(object(#"{"prompt":false,"approval":{"subject":["Bash command"],"question":"Proceed?","fingerprint":"0123456789abcdef","options":[{"number":1,"label":"Yes","risk":null},{"number":2,"label":"Yes, always","risk":"stops asking"}]},"panel":null,"panel_fingerprint":null,"activity":null}"#))
    check(menu.approval?.options.map(\.number) == [1, 2], "a menu's options")
    check(menu.approval?.options[1].risk == "stops asking", "a risky answer says why")
    check(ScreenReading(object(#"{"approval":{"fingerprint":"XYZ","options":[{"number":1,"label":"Yes"}]}}"#)).approval == nil,
          "a menu with a malformed fingerprint is no menu")
    let panel = ScreenReading(object(#"{"prompt":false,"panel":["Usage","Esc to exit"],"panel_fingerprint":"00000000000000ff"}"#))
    check(panel.panel == ["Usage", "Esc to exit"] && panel.panelFingerprint == "00000000000000ff", "a panel and its fingerprint")
    let working = ScreenReading(object(#"{"prompt":true,"activity":{"verb":"Pondering…","detail":"2m 4s"}}"#))
    check(working.activity == AgentActivity(verb: "Pondering…", detail: "2m 4s"), "the working line")

    // Keys: each names its screen, Enter on a panel only with the panel's
    // fingerprint, Esc only to stop a turn.
    typealias C = AttacheCliInput.Condition
    check(AttacheCliInput.isAllowed(key: "2", for: .approval(fingerprint: "0123456789abcdef")), "a digit on a menu")
    check(!AttacheCliInput.isAllowed(key: "Enter", for: .approval(fingerprint: "0123456789abcdef")), "no Enter after a digit")
    check(!AttacheCliInput.isAllowed(key: "9", for: .approval(fingerprint: "0123456789abcdef")), "only 1-8")
    check(!AttacheCliInput.isAllowed(key: "Enter", for: .panel(fingerprint: nil)), "Enter on a panel names it")
    check(AttacheCliInput.isAllowed(key: "Enter", for: .panel(fingerprint: "00000000000000ff")), "Enter on that panel")
    check(AttacheCliInput.isAllowed(key: "Tab", for: .panel(fingerprint: nil)), "Tab moves within a panel")
    check(!AttacheCliInput.isAllowed(key: "Tab", for: .working), "only Esc stops a turn")
    check(C.panel(fingerprint: "00000000000000ff").word == "panel:00000000000000ff" && C.working.word == "working",
          "conditions as attache-cli reads them")

    // What `input` answered. Nothing printed is nothing sent.
    check(AttacheCliInput.Result(lines: [#"{"sent":true}"#]) == .init(sent: true, why: nil), "sent")
    check(AttacheCliInput.Result(lines: [#"{"sent":false,"why":"panel_closed"}"#]).why == "panel_closed", "refused")
    check(AttacheCliInput.Result(lines: []) == .init(sent: false, why: "unreachable"), "nothing printed")
    check(AttacheCliInput.Result(lines: nil) == .init(sent: false, why: "unreachable"), "could not run")
    check(AttacheCliInput.Result(sent: false, why: "enter_withheld").refusal.contains("the text is in the box"),
          "a withheld Enter says where the text went")

    // Rows. An unknown type is skipped, not an error: attache-cli may add one.
    let tool = ChatRow(object(#"{"type":"tool","key":"a-0","name":"Edit","summary":"a.kt","detail":"/x/a.kt","result":null,"error":false,"diff":[["-","val x = 1"],["+","val x = 2"],["…",""]]}"#))
    if case .tool(_, let name, _, _, let result, _, let diff)? = tool {
        check(name == "Edit" && result == nil && diff.map(\.mark) == ["-", "+", "…"], "a tool step and its diff")
    } else {
        check(false, "a tool step")
    }
    check(ChatRow(object(#"{"type":"future-kind","key":"z"}"#)) == nil, "an unknown row")
    check(ChatRow(object(#"{"type":"user","key":"","text":"x"}"#)) == nil, "a row without a key")

    // A sent message is confirmed only by a prompt after the row it was
    // sent after: a second `/context` is not confirmed by the first.
    let earlier: [ChatRow] = [.user(key: "u1", text: "/context", queued: false), .agent(key: "a1", text: "ok")]
    let sent = PendingMessage(id: 1, text: "/context", sentAt: Date(), anchorKey: "a1")
    check(!sent.isConfirmed(by: earlier), "an earlier identical prompt does not confirm")
    check(sent.isConfirmed(by: earlier + [.user(key: "u2", text: "/context", queued: false)]), "a later one does")

    check(AgentChatModel.isFollowable("/Users/j/.claude/projects/x/s.jsonl"), "a transcript path")
    check(!AgentChatModel.isFollowable("x.jsonl") && !AgentChatModel.isFollowable("/x/s.jsonl\n"),
          "relative paths and control characters never reach a command line")

    // JSON lines split anywhere, including inside a character.
    var lines = JSONLines()
    let bytes = Data("{\"t\":\"items\",\"text\":\"中文\"}\n{\"t\":\"status\"}\n".utf8)
    let cut = Data("{\"t\":\"items\",\"text\":\"中".utf8).count - 1
    check(lines.feed(bytes.prefix(cut)).isEmpty, "half a line is no line")
    check(lines.feed(bytes.suffix(from: cut)) == ["{\"t\":\"items\",\"text\":\"中文\"}", "{\"t\":\"status\"}"],
          "the rest arrives whole")
}

print(failures == 0 ? "\(cases) cases, all pass" : "\(failures) of \(cases) cases fail")
exit(failures == 0 ? 0 : 1)
