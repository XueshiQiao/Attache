//
//  main.swift
//  RenameStringCheck
//
//  Cross-check for `TmuxRenameString`, in the same spirit as `Tools/ReplyCheck`.
//
//      swiftc -O -o /tmp/renamestringcheck \
//          TmuxGUI/Tmux/TmuxRenameString.swift Tools/RenameStringCheck/main.swift
//      /tmp/renamestringcheck
//
//  The half that matters is `passthrough`. This decides what never reaches the
//  pane's surface, which is the same power `TerminalReply` has over keystrokes
//  and the same way it shipped three defects in one day. A sequence that leaks
//  is the cosmetic bug this file exists to fix; a byte of real output that gets
//  eaten is worse than the bug, because it is silent and it is not recoverable.
//  So every stream that has no `ESC k` in it belongs in that list.
//
//  The expectations below are not invented. Each one that could be observed was
//  measured against tmux 3.6a on an isolated `-L` server, and the comment says
//  which.
//

import Foundation

func bytes(_ text: String) -> Data { Data(text.utf8) }

let esc = "\u{1b}"
let bel = "\u{07}"
let can = "\u{18}"
let sub = "\u{1a}"

/// One pane's worth of chunks, each with the time it arrived.
func strip(_ chunks: [(Data, UInt64)], pane: String = "%1") -> Data {
    var filter = TmuxRenameString()
    var out = Data()
    for (chunk, now) in chunks {
        out.append(filter.strip(paneID: pane, from: chunk, now: now))
    }
    return out
}

func strip(_ data: Data) -> Data { strip([(data, 0)]) }

// MARK: - Streams that must arrive byte for byte

let passthrough: [(String, Data)] = [
    ("nothing at all", Data()),
    ("plain text", bytes("hello world\r\n")),
    ("CJK text", bytes("你好，世界\r\n")),
    ("a lone escape in the middle", bytes("a\(esc)b")),
    ("bare ST, which is what a stripped sequence leaves behind", bytes("\(esc)\\")),
    ("CSI whose final byte is k", bytes("\(esc)[2k")),
    ("CSI ending in k after a parameter", bytes("\(esc)[1;2k")),
    ("SGR run of the kind a TUI emits", bytes("\(esc)[38;5;196m#\(esc)[0m\(esc)[1;31mX\(esc)[m")),
    ("cursor moves and erases", bytes("\(esc)[2J\(esc)[H\(esc)[10;40H\(esc)[K")),
    ("alternate screen in and out", bytes("\(esc)[?1049h\(esc)[?1049l")),
    ("bracketed paste markers", bytes("\(esc)[200~text\(esc)[201~")),
    // The terminfo-driven title. tmux-256color's tsl is `\E]0;`, so vim and
    // anything else that reads terminfo sends this rather than ESC k — and
    // Ghostty understands it. Eating it would break titles that work today.
    ("OSC 0 title, BEL terminated", bytes("\(esc)]0;a title\(bel)")),
    ("OSC 0 title, ST terminated", bytes("\(esc)]0;a title\(esc)\\")),
    ("OSC 7 working directory", bytes("\(esc)]7;file://host/tmp\(bel)")),
    ("OSC 52 clipboard", bytes("\(esc)]52;c;aGVsbG8=\(bel)")),
    ("OSC 133 prompt mark", bytes("\(esc)]133;A\(bel)")),
    ("DCS with a payload", bytes("\(esc)P1+r5463=787465726d\(esc)\\")),
    ("APC", bytes("\(esc)_Gf=24,s=10\(esc)\\")),
    ("ESC followed by every final Ghostty dispatches",
     bytes("\(esc)B\(esc)A\(esc)0\(esc)M\(esc)7\(esc)8\(esc)c\(esc)>\(esc)=\(esc)H\(esc)E\(esc)D")),
    ("shift out and shift in, tmux's line-drawing switch", Data([0x0e, 0x71, 0x71, 0x0f])),
    ("high bytes that are not valid UTF-8", Data([0xff, 0xfe, 0x80, 0x1b, 0x5b, 0x6d])),
    ("a K that is not a k", bytes("\(esc)K")),
    ("k with no escape in front", bytes("kkkk")),
    ("CAN and SUB on their own", bytes("a\(can)b\(sub)c")),
]

// MARK: - Streams with a rename string in them

let stripped: [(name: String, input: Data, expected: Data)] = [
    ("the plain shape, ST terminated",
     bytes("\(esc)ktitle\(esc)\\"),
     bytes("\(esc)\\")),

    // The bug as reported. oh-my-zsh sends the command name before running it
    // and the working directory before drawing the prompt.
    ("oh-my-zsh around one command",
     bytes("\(esc)kecho\(esc)\\hello wolrd\r\n\(esc)k~/Code/tmux-gui\(esc)\\"),
     bytes("\(esc)\\hello wolrd\r\n\(esc)\\")),

    // Measured: `printf 'A\ekBELTITLE\aB'; echo C` leaves `A` alone on screen.
    // BEL is content to tmux, not a terminator, and everything after it keeps
    // being swallowed until an escape byte.
    ("BEL does not terminate it",
     bytes("A\(esc)kBELTITLE\(bel)B\r\nC\r\n"),
     bytes("A")),

    // Measured: `printf 'X\ekCANT\030Y'; echo Z` shows XYZ.
    ("CAN ends it and passes through",
     bytes("X\(esc)kCANT\(can)Y\r\nZ"),
     bytes("X\(can)Y\r\nZ")),

    ("SUB ends it and passes through",
     bytes("X\(esc)kTITLE\(sub)Y"),
     bytes("X\(sub)Y")),

    // Measured: `printf '\ekFIRST\ekSECOND\e\\'` renames the window to SECOND,
    // so the second introducer restarts the string rather than being content.
    ("a second introducer restarts it",
     bytes("\(esc)kFIRST\(esc)kSECOND\(esc)\\"),
     bytes("\(esc)\\")),

    // Measured: `printf 'A\ekTITLE\e[7mB'` draws a reverse-video B, so the
    // escape that ends the string is reprocessed rather than consumed.
    ("any escape ends it and is reprocessed",
     bytes("A\(esc)kTITLE\(esc)[7mB"),
     bytes("A\(esc)[7mB")),

    ("an empty title",
     bytes("A\(esc)k\(esc)\\B"),
     bytes("A\(esc)\\B")),

    ("a title long enough to prove there is no cap",
     bytes("A\(esc)k" + String(repeating: "t", count: 100_000) + "\(esc)\\B"),
     bytes("A\(esc)\\B")),

    ("a title that is not ASCII",
     bytes("A\(esc)k你好世界\(esc)\\B"),
     bytes("A\(esc)\\B")),

    ("newlines inside the title are swallowed like anything else",
     bytes("A\(esc)kone\r\ntwo\(esc)\\B"),
     bytes("A\(esc)\\B")),

    ("two of them back to back",
     bytes("\(esc)ka\(esc)\\\(esc)kb\(esc)\\tail"),
     bytes("\(esc)\\\(esc)\\tail")),

    // Documented, deliberate, and not a defect to fix here. Inside tmux's DCS
    // passthrough the escapes are doubled, so `1B 1B 6B` appears as payload and
    // this three-state filter cannot tell it from an introducer; tmux does not
    // enter rename there. Three bytes go: the second escape of the pair, the
    // `k`, and the payload up to the next escape.
    //
    // Left alone on purpose. Tracking string state to get this right is exactly
    // the complexity that made `TerminalReply` the worst file in the project,
    // and Ghostty already handles this input worse without us — its parser takes
    // an escape anywhere, so the doubled escape unhooks the DCS, the `k` is an
    // unimplemented action, and the `X` is *drawn*. Eating it is the better of
    // two wrong answers.
    ("KNOWN: a doubled escape inside a DCS passthrough false-triggers",
     bytes("\(esc)Ptmux;\(esc)\(esc)kX\(esc)\\"),
     bytes("\(esc)Ptmux;\(esc)\(esc)\\")),
]

var failures = 0

func fail(_ message: String) {
    print("[-] \(message)")
    failures += 1
}

func show(_ data: Data) -> String {
    data.map { byte in
        switch byte {
        case 0x1b: return "<ESC>"
        case 0x07: return "<BEL>"
        case 0x18: return "<CAN>"
        case 0x1a: return "<SUB>"
        case 0x0d: return "<CR>"
        case 0x0a: return "<LF>"
        case 0x20 ... 0x7e: return String(UnicodeScalar(byte))
        default: return String(format: "<%02x>", byte)
        }
    }.joined()
}

// MARK: - 1. Nothing that is not a rename string may be touched

for (name, data) in passthrough {
    let got = strip(data)
    if got != data {
        fail("OUTPUT EATEN: \(name)\n      sent \(show(data))\n      got  \(show(got))")
    }
}

// MARK: - 2. Rename strings, and only rename strings, are removed

for (name, input, expected) in stripped {
    let got = strip(input)
    if got != expected {
        fail("\(name)\n      want \(show(expected))\n      got  \(show(got))")
    }
}

// MARK: - 3. A chunk boundary anywhere changes nothing
//
// tmux splits `%output` wherever its own buffer ends, so the sequence arrives
// cut at an arbitrary byte — including between the escape and the k, which is
// the split the whole `escape` state exists for.

for (name, input, expected) in stripped {
    let all = [UInt8](input)
    // 100k of `t` would make this quadratic for no extra coverage; the
    // interesting boundaries are all near the sequence.
    guard all.count < 400 else { continue }
    for cut in 0 ... all.count {
        let head = Data(all[0 ..< cut])
        let tail = Data(all[cut ..< all.count])
        let got = strip([(head, 0), (tail, 0)])
        if got != expected {
            fail("split at \(cut) of \(all.count) changed the result: \(name)"
                + "\n      want \(show(expected))\n      got  \(show(got))")
            break
        }
    }
}

// A byte at a time, which is the worst case a slow pty can produce.
for (name, input, expected) in stripped {
    let all = [UInt8](input)
    guard all.count < 400 else { continue }
    let got = strip(all.map { (Data([$0]), UInt64(0)) })
    if got != expected {
        fail("one byte per chunk changed the result: \(name)"
            + "\n      want \(show(expected))\n      got  \(show(got))")
    }
}

// MARK: - 4. The escape held across a boundary

do {
    // Split precisely between the two bytes of the introducer.
    let got = strip([(bytes("A\(esc)"), 0), (bytes("ktitle\(esc)\\B"), 0)])
    if got != bytes("A\(esc)\\B") {
        fail("an introducer split across chunks was not caught: got \(show(got))")
    }
}
do {
    // The same held escape, but the next chunk proves it was not ours.
    let got = strip([(bytes("A\(esc)"), 0), (bytes("[7mB"), 0)])
    if got != bytes("A\(esc)[7mB") {
        fail("a held escape that was not ours went missing: got \(show(got))")
    }
}
do {
    // A chunk that is nothing but an escape, then one that is nothing but a k.
    let got = strip([(bytes("\(esc)"), 0), (bytes("k"), 0), (bytes("t\(esc)\\"), 0)])
    if got != bytes("\(esc)\\") {
        fail("an introducer split three ways was not caught: got \(show(got))")
    }
}

// MARK: - 5. The deadline
//
// tmux arms a five-second timer on entry and resets its parser when it fires.
// Measured here as output resuming somewhere between three and seven seconds
// after an unterminated introducer.

do {
    let opener = (bytes("P\(esc)kUNTERMINATED"), UInt64(0))
    let later = bytes("AFTER\r\n")

    let inside = strip([opener, (later, TmuxRenameString.expiry - 1)])
    if inside != bytes("P") {
        fail("output before the deadline should still be swallowed: got \(show(inside))")
    }

    let after = strip([opener, (later, TmuxRenameString.expiry)])
    if after != bytes("PAFTER\r\n") {
        fail("output after the deadline should pass: got \(show(after))")
    }

    // A terminated sequence must not leave a deadline armed for the next one.
    let restarted = strip([
        (bytes("\(esc)ka\(esc)\\"), UInt64(0)),
        (bytes("\(esc)kb"), TmuxRenameString.expiry * 3),
        (bytes("swallowed"), TmuxRenameString.expiry * 3 + 1),
    ])
    if restarted != bytes("\(esc)\\") {
        fail("a fresh sequence inherited a stale deadline: got \(show(restarted))")
    }
}

// MARK: - 6. Panes do not see each other's state

do {
    var filter = TmuxRenameString()
    var one = Data(), two = Data()
    // %1 opens a sequence, %2 sends ordinary output through the middle of it.
    one.append(filter.strip(paneID: "%1", from: bytes("A\(esc)ktit"), now: 0))
    two.append(filter.strip(paneID: "%2", from: bytes("plain output"), now: 0))
    one.append(filter.strip(paneID: "%1", from: bytes("le\(esc)\\B"), now: 0))
    two.append(filter.strip(paneID: "%2", from: bytes(" more"), now: 0))

    if one != bytes("A\(esc)\\B") { fail("pane %1 was corrupted by pane %2: got \(show(one))") }
    if two != bytes("plain output more") { fail("pane %2 was swallowed by pane %1: got \(show(two))") }
}

// MARK: -

if failures == 0 {
    print("[+] \(passthrough.count) streams passed through untouched,"
        + " \(stripped.count) rename strings removed,"
        + " every chunk boundary and the deadline agree")
    exit(0)
}
print("[-] \(failures) failure(s)")
exit(1)
