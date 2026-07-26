//
//  main.swift
//  ReplyCheck
//
//  Cross-check for `TerminalReply`, in the same spirit as `Tools/LayoutCheck`.
//
//      swiftc -O -o /tmp/replycheck \
//          TmuxGUI/Tmux/TerminalReply.swift Tools/ReplyCheck/main.swift
//      /tmp/replycheck
//
//  The half that matters is `keystrokes`. `TerminalReply` decides what never
//  reaches the user's pane, so a false positive there is a keystroke the app
//  silently ate — the one failure this code must not have. Every encoding a
//  key can produce belongs in that list.
//

import Foundation

let replies: [(String, Data)] = [
    ("SGR mouse press", Data("\u{1b}[<35;100;20M".utf8)),
    ("SGR mouse release", Data("\u{1b}[<0;5;5m".utf8)),
    ("SGR mouse, two in one write", Data("\u{1b}[<35;1;1M\u{1b}[<35;2;1M".utf8)),
    ("X10 mouse", Data([0x1b, 0x5b, 0x4d, 0x20, 0x21, 0x22])),
    ("X10 mouse carrying an ESC byte", Data([0x1b, 0x5b, 0x4d, 0x20, 0x1b, 0x22])),
    ("urxvt mouse (1015)", Data("\u{1b}[35;100;20M".utf8)),
    ("cursor position report", Data("\u{1b}[57;190R".utf8)),
    ("primary device attributes", Data("\u{1b}[?62;22;52c".utf8)),
    ("secondary device attributes", Data("\u{1b}[>1;4000;29c".utf8)),
    ("device status report", Data("\u{1b}[0n".utf8)),
    ("mode report (DECRPM)", Data("\u{1b}[?2026;2$y".utf8)),
    ("kitty keyboard flags report", Data("\u{1b}[?5u".utf8)),
    ("focus in", Data("\u{1b}[I".utf8)),
    ("focus out", Data("\u{1b}[O".utf8)),
    ("XTVERSION (DCS)", Data("\u{1b}P>|ghostty 1.2.3\u{1b}\\".utf8)),
    ("termcap query (DCS)", Data("\u{1b}P1+r5463=787465726d\u{1b}\\".utf8)),
    ("background colour (OSC, BEL)", Data("\u{1b}]11;rgb:1e1e/1e1e/2e2e\u{07}".utf8)),
    ("background colour (OSC, ST)", Data("\u{1b}]10;rgb:c0c0/c0c0/c0c0\u{1b}\\".utf8)),
]

let keystrokes: [(String, Data)] = [
    ("one letter", Data("a".utf8)),
    ("a word", Data("hello".utf8)),
    ("CJK text", Data("中文".utf8)),
    ("return", Data("\r".utf8)),
    ("ctrl-C", Data([0x03])),
    ("backspace", Data([0x7f])),
    ("escape alone", Data([0x1b])),
    ("alt-b", Data("\u{1b}b".utf8)),
    ("up arrow", Data("\u{1b}[A".utf8)),
    ("down arrow", Data("\u{1b}[B".utf8)),
    ("right arrow", Data("\u{1b}[C".utf8)),
    ("left arrow", Data("\u{1b}[D".utf8)),
    ("home", Data("\u{1b}[H".utf8)),
    ("end", Data("\u{1b}[F".utf8)),
    ("shift-up (modified arrow)", Data("\u{1b}[1;2A".utf8)),
    ("F1 via SS3", Data("\u{1b}OP".utf8)),
    ("F5", Data("\u{1b}[15~".utf8)),
    ("delete", Data("\u{1b}[3~".utf8)),
    ("kitty key press, no private marker", Data("\u{1b}[97;5u".utf8)),
    ("bracketed paste", Data("\u{1b}[200~some text\u{1b}[201~".utf8)),
    ("paste whose *contents* look like a mouse report",
     Data("\u{1b}[200~\u{1b}[<35;1;1M\u{1b}[201~".utf8)),
    ("a report followed by real input", Data("\u{1b}[<35;1;1Mls".utf8)),
    ("real input followed by a report", Data("ls\u{1b}[<35;1;1M".utf8)),
    ("truncated mouse report", Data("\u{1b}[<35;1".utf8)),
    ("truncated X10 mouse", Data([0x1b, 0x5b, 0x4d, 0x20])),
    ("unterminated DCS", Data("\u{1b}P>|ghostty".utf8)),
    ("nothing at all", Data()),
]

var failures = 0

for (name, data) in replies where !TerminalReply.isEntirelyReplies(data) {
    print("[-] leaked into the pane: \(name)")
    failures += 1
}

for (name, data) in keystrokes where TerminalReply.isEntirelyReplies(data) {
    print("[-] KEYSTROKE DROPPED: \(name)")
    failures += 1
}

if failures == 0 {
    print("[+] \(replies.count) replies withheld, \(keystrokes.count) inputs forwarded")
    exit(0)
}
print("[-] \(failures) failure(s)")
exit(1)
