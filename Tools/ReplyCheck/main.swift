//
//  main.swift
//  ReplyCheck
//
//  Cross-check for `TerminalReply`, in the same spirit as `Tools/LayoutCheck`.
//
//      swiftc -O -o /tmp/replycheck \
//          Attache/Tmux/TerminalReply.swift Tools/ReplyCheck/main.swift
//      /tmp/replycheck
//
//  The half that matters is `keystrokes`. `TerminalReply` decides what never
//  reaches the user's pane, so a false positive there is a keystroke the app
//  silently ate — the one failure this code must not have. Every encoding a
//  key can produce belongs in that list.
//

import Foundation

let replies: [(String, Data)] = [
    ("SGR bare motion", Data("\u{1b}[<35;100;20M".utf8)),
    ("SGR bare motion, shift held", Data("\u{1b}[<39;100;20M".utf8)),
    ("SGR bare motion, two in one write", Data("\u{1b}[<35;1;1M\u{1b}[<35;2;1M".utf8)),
    ("X10 bare motion", Data([0x1b, 0x5b, 0x4d, 0x23 + 32, 0x21, 0x22])),
    ("X10 bare motion carrying an ESC byte", Data([0x1b, 0x5b, 0x4d, 0x23 + 32, 0x1b, 0x22])),
    ("urxvt bare motion (1015)", Data("\u{1b}[67;100;20M".utf8)),
    ("extended cursor position report (DECXCPR)", Data("\u{1b}[?57;190R".utf8)),
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
    ("shift-F3, byte-identical to a cursor position report", Data("\u{1b}[1;2R".utf8)),
    ("ctrl-F3", Data("\u{1b}[1;5R".utf8)),
    ("plain cursor position report — leaks, see TerminalReply", Data("\u{1b}[57;190R".utf8)),
    ("DCS terminated by BEL is not a complete reply", Data("\u{1b}P1+r5463\u{07}".utf8)),

    // Everything below is the user doing something with the mouse. Withholding
    // any of it is how scrolling died the first time round: a wheel turn is a
    // mouse report, so a filter that drops mouse reports drops scrolling.
    ("wheel up", Data("\u{1b}[<64;10;5M".utf8)),
    ("wheel down", Data("\u{1b}[<65;10;5M".utf8)),
    ("wheel down, ctrl held", Data("\u{1b}[<81;10;5M".utf8)),
    ("left press", Data("\u{1b}[<0;10;5M".utf8)),
    ("left release", Data("\u{1b}[<0;10;5m".utf8)),
    ("middle press", Data("\u{1b}[<1;10;5M".utf8)),
    ("right press", Data("\u{1b}[<2;10;5M".utf8)),
    ("drag with left held", Data("\u{1b}[<32;10;5M".utf8)),
    ("X10 left press", Data([0x1b, 0x5b, 0x4d, 0x20, 0x21, 0x22])),
    ("X10 wheel up", Data([0x1b, 0x5b, 0x4d, 0x60, 0x21, 0x22])),
    ("urxvt left press (1015)", Data("\u{1b}[32;100;20M".utf8)),

    // Long digit runs. These are not mouse reports; they are here because
    // accumulating them used to overflow and kill the process — Swift traps on
    // overflow in release builds too — and an unterminated one reached the
    // parameter scan before anything checked for a final byte.
    ("nineteen nines then a final byte", Data(("\u{1b}[" + String(repeating: "9", count: 19) + "m").utf8)),
    ("forty digits, no final byte at all", Data(("\u{1b}[" + String(repeating: "9", count: 40)).utf8)),
    ("long digit run inside a pasted line", Data(("hello \u{1b}[" + String(repeating: "1", count: 30) + "m world").utf8)),
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
