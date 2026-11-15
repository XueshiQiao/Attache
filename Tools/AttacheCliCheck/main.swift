// What attache-cli prints, read the way the app reads it, and the rules the
// app applies before it asks attache-cli to press anything.
//
//   swiftc -O -o /tmp/attachecliccheck Attache/Agents/AttacheCliProtocol.swift \
//     Attache/Agents/AgentChatModel.swift Attache/Agents/AttacheCliLink.swift \
//     Attache/Agents/HostAgents.swift Attache/Agents/AttacheCliInstaller.swift \
//     Attache/Agents/Projects.swift \
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
    // Narration is its own row, and says what it says the way a reply does.
    let narration = ChatRow(object(#"{"type":"narration","key":"n-1","text":"Built; now the fonts."}"#))
    check(narration == .narration(key: "n-1", text: "Built; now the fonts.") && narration?.said == "Built; now the fonts.",
          "a narration row")
    check(ChatRow(object(#"{"type":"thinking","key":"t","text":"x"}"#))?.said == nil, "thinking is not said")

    // `from` counts every row attache-cli sent, the unreadable ones too: an
    // unknown row in the middle must not shift what a later update replaces.
    do {
        let first = [object(#"{"type":"user","key":"u","text":"hi"}"#),
                     object(#"{"type":"future-kind","key":"f"}"#),
                     object(#"{"type":"agent","key":"a","text":"one"}"#)]
        var rows = AgentChatModel.splice([], from: 0, items: first, fresh: true)
        rows = AgentChatModel.splice(rows, from: 2, items: [object(#"{"type":"agent","key":"a","text":"one, two"}"#)],
                                     fresh: false)
        check(rows.compactMap { $0 } == [.user(key: "u", text: "hi", queued: false), .agent(key: "a", text: "one, two")],
              "an unknown row keeps its place for the next update")
    }
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

    // Projects. Only ids reach a command line as themselves; the folder
    // and the command, which are free text, go base64-encoded.
    let draft = ProjectDraft(name: "it's", path: "~/Code/x y", command: "cyolo; echo '$1'")
    check(ProjectCommands.save(id: nil, draft)
            == ["project", "save", "--name", "aXQncw==", "--path", "fi9Db2RlL3ggeQ==",
                "--command", "Y3lvbG87IGVjaG8gJyQxJw=="], "a save carries text as base64")
    check(ProjectCommands.save(id: nil, ProjectDraft(name: "n", path: "/p", command: ""))?.last == "=",
          "an empty command is still a word: ssh would drop an empty one")
    check(ProjectCommands.save(id: "3f9a1c0e", draft)?.prefix(4) == ["project", "save", "--id", "3f9a1c0e"],
          "an edit names the project")
    check(ProjectCommands.save(id: "a b", draft) == nil && ProjectCommands.remove(id: "x;rm") == nil,
          "an id that is not one never reaches a command line")
    check(ProjectCommands.open(id: "3f9a1c0e", session: "$12") == ["project", "open", "3f9a1c0e", "--session", "$12"],
          "open names the session by id")
    check(ProjectCommands.open(id: "3f9a1c0e", session: "Dev") == nil
            && ProjectCommands.open(id: "3f9a1c0e", session: "$1 ") == nil
            && ProjectCommands.open(id: "3f9a1c0e", session: "@1") == nil, "and by nothing else")
    check(ProjectCommands.draft(window: "@7") == ["project", "draft", "@7"]
            && ProjectCommands.draft(window: "$7") == nil, "a draft names a window by id")

    let listed = SavedProject.parse([
        #"{"id":"3f9a1c0e","name":"Paw","path":"~/p","command":"cyolo","exists":true}"#,
        #"{"id":"x0123","name":"Gone","path":"/gone","command":"","exists":false}"#,
        #"{"id":"bad id","name":"N","path":"/p"}"#, "not json",
    ])
    check(listed.map(\.id) == ["3f9a1c0e", "x0123"] && listed[0].command == "cyolo" && !listed[1].exists,
          "the list reads, and a row with an unusable id is left out")

    check(ProjectCommands.setCommands(["cyolo", "gemini"]) == ["project", "commands", "--set", "Y3lvbG8KZ2VtaW5p"]
            && ProjectCommands.setCommands([]).last == "=", "the commands list goes one a line, base64")
    check(ProjectCommands.commands(in: [#"{"id":"a","name":"n","path":"/p"}"#, #"{"commands":["cyolo","gemini"]}"#])
            == ["cyolo", "gemini"], "the list that ends `projects` reads")
    check(ProjectCommands.commands(in: [#"{"commands":false,"why":"x"}"#]) == nil
            && ProjectCommands.commands(in: ["Usage:"]) == nil, "a refusal and an older attache-cli hold no list")

    // A whole answer ends with the commands line; one without it (an ssh
    // that dropped, an attache-cli that failed: both print nothing) is not
    // "no projects", and must not replace the list the app holds.
    check(ProjectCommands.last([#"{"id":"a","name":"n","path":"/p"}"#, #"{"commands":["x"],"commands_why":"w"}"#])?["commands_why"] as? String == "w",
          "the last line is read, with why the list cannot be edited")
    check(ProjectCommands.last([]) == nil && ProjectCommands.last([#"{"id":"a","name":"n","path":"/p"}"#]) == nil,
          "an empty answer, or one cut short, is not a list")

    // A save is followed by a kill when the person asked for one, so only an
    // answer that says it happened counts as one.
    func saved(_ lines: [String]?) -> Bool {
        if case .success = ProjectCommands.answer(lines, flag: "saved") { return true }
        return false
    }
    check(saved([#"{"id":"a","saved":true}"#]), "saved")
    check(!saved([#"{"saved":false,"why":"the name is empty"}"#]), "refused")
    check(!saved(nil) && !saved([]) && !saved(["Usage:"]) && !saved([#"{"removed":true}"#]),
          "no answer, an older attache-cli, and another command's answer are not a save")
    if case .failure(let failure) = ProjectCommands.answer([#"{"saved":false,"why":"the name is empty"}"#], flag: "saved") {
        check(failure.message == "the name is empty", "the reason is attache-cli's own")
    } else {
        check(false, "a refusal carries its reason")
    }
}

// MARK: - Mermaid

do {
    // The smallest thing `answer` takes for a picture: a PNG signature.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    let b64 = png.base64EncodedString()
    check(MermaidCommand.answer([#"{"mermaid":true,"width":320.5,"height":200,"scale":2,"png":"\#(b64)"}"#])
        == .picture(png, width: 320.5, height: 200), "a drawn diagram is its PNG and its size in points")
    check(MermaidCommand.answer([#"{"mermaid":false,"why":"no Mermaid diagram in this source"}"#])
        == .refused("no Mermaid diagram in this source"), "a refusal carries attache-cli's reason")
    // The distinction the type exists for: none of these says anything about
    // the source, so none may be kept as "this diagram cannot be drawn".
    check(MermaidCommand.answer(nil) == .unanswered, "a command that could not run is no answer")
    check(MermaidCommand.answer([]) == .unanswered, "an attache-cli from before `mermaid` prints no line")
    check(MermaidCommand.answer(["Usage:", #"{"saved":true}"#]) == .unanswered, "another command's answer is no answer")
    check(MermaidCommand.answer([#"{"mermaid":true,"width":10,"height":10}"#]) == .unanswered, "drawn with no picture is no answer")
    check(MermaidCommand.answer([#"{"mermaid":true,"width":10,"height":10,"path":"/tmp/x.png"}"#]) == .unanswered,
          "a path, which is the phone's answer, is not a picture here")
    check(MermaidCommand.answer([#"{"mermaid":true,"width":10,"height":10,"png":"aGVsbG8="}"#]) == .unanswered,
          "bytes that are not a PNG are no answer")
    check(MermaidCommand.answer([#"{"mermaid":true,"width":0,"height":10,"png":"\#(b64)"}"#]) == .unanswered
        && MermaidCommand.answer([#"{"mermaid":true,"height":10,"png":"\#(b64)"}"#]) == .unanswered
        && MermaidCommand.answer([#"{"mermaid":true,"width":1e9,"height":10,"png":"\#(b64)"}"#]) == .unanswered,
          "a picture with no sane size is no answer")
    check(MermaidCommand.answer(["noise", #"{"mermaid":false,"why":"the renderer failed on this diagram"}"#])
        == .refused("the renderer failed on this diagram"), "a panic's refusal is read past noise")

    let argv = MermaidCommand.argv(source: "flowchart TD\n  A[\"每 5 分钟\"] --> B", dark: true, scale: 2)
    check(argv.map { Array($0.prefix(2)) + Array($0.dropFirst(3)) }
        == ["mermaid", "--source", "--scale", "2", "--inline", "--dark"], "argv, dark")
    check(argv.flatMap { Data(base64Encoded: $0[2]) }.map { String(decoding: $0, as: UTF8.self) }
        == "flowchart TD\n  A[\"每 5 分钟\"] --> B", "the source travels as base64 and reads back")
    check(MermaidCommand.argv(source: "flowchart TD", dark: false, scale: 3)?.last == "--inline", "argv, light")
    check(MermaidCommand.argv(source: "", dark: false, scale: 2) == nil, "nothing to draw is not asked")
    check(MermaidCommand.argv(source: "flowchart TD", dark: false, scale: 0) == nil
        && MermaidCommand.argv(source: "flowchart TD", dark: false, scale: 5) == nil, "a scale attache-cli refuses is not asked")
    check(MermaidCommand.argv(source: String(repeating: "x", count: MermaidCommand.maxSource + 1), dark: false, scale: 2) == nil,
          "a block past attache-cli's limit is not put on a command line")

    let key = MermaidCommand.key(source: "flowchart TD", dark: false, scale: 2)
    check(key.count == 64 && key == MermaidCommand.key(source: "flowchart TD", dark: false, scale: 2), "the key is stable")
    check(key != MermaidCommand.key(source: "flowchart TD", dark: true, scale: 2), "dark is another picture")
    check(key != MermaidCommand.key(source: "flowchart TD", dark: false, scale: 3), "another scale is another picture")
    check(key != MermaidCommand.key(source: "flowchart LR", dark: false, scale: 2), "another source is another picture")
}

print(failures == 0 ? "\(cases) cases, all pass" : "\(failures) of \(cases) cases fail")
exit(failures == 0 ? 0 : 1)
