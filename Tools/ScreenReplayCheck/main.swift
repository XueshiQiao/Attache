//
//  Tools/ScreenReplayCheck/main.swift
//
//  A case table over `TmuxScreenReplay.payload`, in the same shape as
//  `Tools/LayoutCheck` and `Tools/ReplyCheck`:
//
//      swiftc -O -o /tmp/replaycheck \
//        TmuxGUI/Tmux/TmuxPaneSnapshot.swift TmuxGUI/Tmux/TmuxScreenReplay.swift \
//        Tools/ScreenReplayCheck/main.swift
//      /tmp/replaycheck
//
//  This is the only part of a repaint that can be checked without a screen.
//  What the surface then *does* with these bytes is libghostty's business and
//  needs a running app and a pair of eyes; what they are is decidable here, and
//  every defect this file was written for is an off-by-one or a missing
//  sequence that a table catches.

import Foundation

// MARK: - Readable escapes

/// Renders a payload so a failure says what is wrong rather than printing 400
/// bytes of octal.
func describe(_ data: Data) -> String {
    var out = ""
    var index = data.startIndex
    while index < data.endIndex {
        let byte = data[index]
        switch byte {
        case 0x1b: out += "<ESC>"
        case 0x0d: out += "<CR>"
        case 0x0a: out += "<LF>"
        case 0x20 ... 0x7e: out.append(Character(UnicodeScalar(byte)))
        default: out += String(format: "<%02x>", byte)
        }
        index = data.index(after: index)
    }
    return out
}

func rows(_ text: [String]) -> [Data] { text.map { Data($0.utf8) } }

// MARK: - Cases

struct Case {
    let name: String
    let snapshot: TmuxPaneSnapshot
    let isFirstPaint: Bool
    /// The whole payload, written the way `describe` renders it.
    let expected: String
}

let cases: [Case] = [
    // The repaint. Erase the screen, write the rows, place the cursor — and
    // do not touch the scrollback, which holds history nothing here replaces.
    Case(
        name: "repaint: erase, rows, cursor — and no CSI 3 J",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: rows(["ab", "cd"]),
            cursor: TmuxPaneCursor(column: 0, row: 1)
        ),
        isFirstPaint: false,
        expected: "<ESC>[H<ESC>[2Jab<CR><LF>cd<ESC>[2;1H"
    ),
    // History supplied to a repaint is ignored rather than written. Nothing
    // asks for it, and writing it would stack a second copy of the scrollback
    // on every resize — the defect the `isFirstPaint` flag exists to prevent.
    Case(
        name: "repaint: history is not written even if handed over",
        snapshot: TmuxPaneSnapshot(
            history: rows(["old"]), screen: rows(["new"]),
            cursor: TmuxPaneCursor(column: 2, row: 0)
        ),
        isFirstPaint: false,
        expected: "<ESC>[H<ESC>[2Jnew<ESC>[1;3H"
    ),
    // The first paint. Scrollback erased, history written into it, separated
    // from the screen by exactly one CR LF, cursor placed last.
    Case(
        name: "first paint: scrollback erased, history, separator, screen, cursor",
        snapshot: TmuxPaneSnapshot(
            history: rows(["h1", "h2"]), screen: rows(["s1", "s2"]),
            cursor: TmuxPaneCursor(column: 3, row: 1)
        ),
        isFirstPaint: true,
        expected: "<ESC>[H<ESC>[2J<ESC>[3Jh1<CR><LF>h2<CR><LF>s1<CR><LF>s2<ESC>[2;4H"
    ),
    // A pane with nothing above the screen. The separator is what would put a
    // blank line into the scrollback if it went out unconditionally.
    Case(
        name: "first paint: no history means no separator",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: rows(["only"]),
            cursor: TmuxPaneCursor(column: 0, row: 0)
        ),
        isFirstPaint: true,
        expected: "<ESC>[H<ESC>[2J<ESC>[3Jonly<ESC>[1;1H"
    ),
    // tmux would not say where the cursor is. Everything else still goes, and
    // the cursor is left wherever the rows put it — the pre-existing
    // behaviour, and the reason the connection trims trailing blanks in this
    // case and only this case.
    Case(
        name: "no cursor: no CUP at the end",
        snapshot: TmuxPaneSnapshot(history: [], screen: rows(["x"]), cursor: nil),
        isFirstPaint: false,
        expected: "<ESC>[H<ESC>[2Jx"
    ),
    // Blank rows are rows. `capture-pane` returns one line per pane row, so a
    // screen with a prompt at the top and nothing below it is mostly empty
    // lines — and every one of them has to be written, because the cursor row
    // below is counted from the top of the block.
    Case(
        name: "blank rows are written, so the cursor row still means something",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: rows(["$", "", ""]),
            cursor: TmuxPaneCursor(column: 1, row: 0)
        ),
        isFirstPaint: false,
        expected: "<ESC>[H<ESC>[2J$<CR><LF><CR><LF><ESC>[1;2H"
    ),
    // tmux counts from zero and CUP counts from one. Getting this wrong is one
    // row and one column of drift, which is invisible on a shell prompt and
    // wrong on every full-screen program.
    Case(
        name: "cursor is one-based on the wire, zero-based from tmux",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: rows(["r"]),
            cursor: TmuxPaneCursor(column: 9, row: 2)
        ),
        isFirstPaint: false,
        expected: "<ESC>[H<ESC>[2Jr<ESC>[3;10H"
    ),
    // Bytes above 0x7f pass through untouched. The whole reason this path
    // takes `Data` rather than `String`: a round trip through `String`
    // replaces anything invalid with U+FFFD and there is no way back.
    Case(
        name: "raw bytes survive",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: [Data([0x41, 0xe9, 0xff, 0x42])], cursor: nil
        ),
        isFirstPaint: false,
        expected: "<ESC>[H<ESC>[2JA<e9><ff>B"
    ),
]

// MARK: - Run

var failures = [String]()
for testCase in cases {
    let produced = describe(TmuxScreenReplay.payload(
        for: testCase.snapshot, isFirstPaint: testCase.isFirstPaint
    ))
    guard produced == testCase.expected else {
        failures.append("""
          ✗ \(testCase.name)
              expected  \(testCase.expected)
              produced  \(produced)
        """)
        continue
    }
    print("  ✓ \(testCase.name)")
}

guard failures.isEmpty else {
    print("\n" + failures.joined(separator: "\n"))
    print("\n\(failures.count) of \(cases.count) cases failed")
    exit(1)
}
print("\n\(cases.count) cases, all agreeing")
