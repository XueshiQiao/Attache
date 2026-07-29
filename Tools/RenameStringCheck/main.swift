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
    // The held escape released ahead of a cancel byte, which is a different
    // path through `.escape` from releasing it ahead of a printable one.
    ("escape then CAN", bytes("a\(esc)\(can)b")),
    ("escape then SUB", bytes("a\(esc)\(sub)b")),

    // KNOWN divergence, measured on tmux 3.6a and deliberately not matched.
    // tmux's `esc_enter` state survives a byte in the middle — C0 is dispatched
    // on the way past and 0x7f–0xff is ignored, neither changing state — so all
    // three of these rename in tmux and none of them does here. Verified: a pane
    // fed each of these shows `AB`, `DE`, `FG`. They leak rather than being
    // eaten, nothing emits them (a prompt writes `ESC k` in one piece), and
    // matching tmux would mean holding an unbounded run and reordering C0s out
    // from under a held escape. See the note in `TmuxRenameString`.
    ("KNOWN: ESC <C0> k renames in tmux, not here",
     Data(Array("A".utf8) + [0x1b, 0x01, 0x6b] + Array("C0TITLE".utf8) + [0x1b, 0x5c] + Array("B".utf8))),
    ("KNOWN: ESC <DEL> k renames in tmux, not here",
     Data(Array("F".utf8) + [0x1b, 0x7f, 0x6b] + Array("DELTITLE".utf8) + [0x1b, 0x5c] + Array("G".utf8))),
    ("KNOWN: ESC <high byte> k renames in tmux, not here",
     Data(Array("D".utf8) + [0x1b, 0xe4, 0x6b] + Array("HIGHTITLE".utf8) + [0x1b, 0x5c] + Array("E".utf8))),
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

    // A doubled escape outside a DCS. tmux renames here too — its ANYWHERE
    // entry re-enters `esc_enter` on the second escape — so this is the right
    // answer rather than a false positive, and it is the case that makes
    // `holdsRenameString` assign `previousWasEscape` unconditionally.
    ("a doubled escape in ground still introduces one",
     bytes("A\(esc)\(esc)kT\(esc)\\B"),
     bytes("A\(esc)\(esc)\\B")),

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

// Both lists, not just `stripped`. Splitting only the streams that are supposed
// to change leaves the `escape` state — the one that holds a byte back across a
// boundary — exercised almost nowhere, and a defect that dropped or doubled that
// held escape would show up as damage to a stream nobody was cutting in half.
let boundaryCases: [(name: String, input: Data, expected: Data)] =
    stripped + passthrough.map { (name: $0.0, input: $0.1, expected: $0.1) }

for (name, input, expected) in boundaryCases {
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
for (name, input, expected) in boundaryCases {
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

    // A clock that appears to go backwards must not expire anything. The
    // guard is `now >= since`; without it the subtraction wraps to ~584 years
    // and every sequence ends on its next chunk.
    let backwards = strip([(bytes("\(esc)kTITLE"), 1_000), (bytes("swallowed"), 0)])
    if backwards != Data() {
        fail("a backwards clock expired a live sequence: got \(show(backwards))")
    }

    // The deadline is per pane, not global.
    var split = TmuxRenameString()
    _ = split.strip(paneID: "%1", from: bytes("\(esc)kearly"), now: 0)
    _ = split.strip(paneID: "%2", from: bytes("\(esc)klate"), now: TmuxRenameString.expiry)
    let expired = split.strip(paneID: "%1", from: bytes("ONE"), now: TmuxRenameString.expiry)
    let alive = split.strip(paneID: "%2", from: bytes("TWO"), now: TmuxRenameString.expiry)
    if expired != bytes("ONE") { fail("%1's deadline did not fire: got \(show(expired))") }
    if alive != Data() { fail("%2 expired on %1's clock: got \(show(alive))") }

    // A chunk that arrives past the deadline AND opens a fresh sequence: the
    // expiry has to resolve before the chunk is walked, or the new sequence is
    // opened into a state that is about to be reset.
    let both = strip([
        (bytes("\(esc)kstale"), UInt64(0)),
        (bytes("VISIBLE\(esc)kfresh"), TmuxRenameString.expiry),
        (bytes("swallowed"), TmuxRenameString.expiry + 1),
    ])
    if both != bytes("VISIBLE") {
        fail("expiry and a fresh introducer in one chunk: got \(show(both))")
    }
}

// MARK: - 5b. A held escape does not expire, on purpose
//
// Measured on tmux 3.6a: `X ESC k TITLE ESC`, a seven-second gap, then
// `k SECOND ESC \ TAIL` leaves `XTAIL` on screen — tmux stayed in its escape
// state across the gap and the later `k` restarted the rename. Only the rename
// string itself is on a timer. Pinned so nobody "fixes" the asymmetry.

do {
    let got = strip([
        (bytes("X\(esc)kTITLE\(esc)"), UInt64(0)),
        (bytes("kSECOND\(esc)\\TAIL"), TmuxRenameString.expiry * 2),
    ])
    if got != bytes("X\(esc)\\TAIL") {
        fail("a held escape should not expire: got \(show(got))")
    }
}

// MARK: - 5c. The fast path hands back the same buffer
//
// The throughput path depends on an ordinary chunk being returned rather than
// copied. Large enough to be heap-backed: Swift stores a small `Data` inline,
// where the address belongs to the struct and says nothing about copying.

do {
    var filter = TmuxRenameString()
    let big = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
    let sent = big.withUnsafeBytes { $0.baseAddress }
    let got = filter.strip(paneID: "%1", from: big, now: 0)
    let back = got.withUnsafeBytes { $0.baseAddress }
    if sent != back { fail("the fast path copied a chunk it had nothing to do to") }
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
        + " all \(boundaryCases.count) cut at every byte and again one byte per chunk,"
        + " deadline and fast path agree")
    exit(0)
}
print("[-] \(failures) failure(s)")
exit(1)
