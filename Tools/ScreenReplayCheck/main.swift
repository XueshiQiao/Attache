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

/// Every mode off, a full-screen scroll region and a default cursor — the
/// state a freshly started shell is in. Cases override the one field they are
/// about, so a case reads as the difference it is testing.
func modes(
    rows screenRows: Int = 3,
    alternateScreen: Bool = false, cursorVisible: Bool = true, wrap: Bool = true,
    insert: Bool = false, origin: Bool = false,
    applicationCursorKeys: Bool = false, applicationKeypad: Bool = false,
    mouseStandard: Bool = false, mouseButton: Bool = false, mouseAll: Bool = false,
    mouseSGR: Bool = false, mouseUTF8: Bool = false,
    scrollRegionUpper: Int = 0, scrollRegionLower: Int? = nil,
    cursorShape: String = "default", cursorBlinking: Bool = false
) -> TmuxPaneModes {
    TmuxPaneModes(
        alternateScreen: alternateScreen, cursorVisible: cursorVisible, wrap: wrap,
        insert: insert, origin: origin,
        applicationCursorKeys: applicationCursorKeys, applicationKeypad: applicationKeypad,
        mouseStandard: mouseStandard, mouseButton: mouseButton, mouseAll: mouseAll,
        mouseSGR: mouseSGR, mouseUTF8: mouseUTF8,
        scrollRegionUpper: scrollRegionUpper,
        scrollRegionLower: scrollRegionLower ?? (screenRows - 1),
        cursorShape: cursorShape, cursorBlinking: cursorBlinking
    )
}

/// The reset that goes out before any row is written, so the CR LFs between
/// rows cannot scroll inside a region the previous program left behind.
let neutral = "<ESC>[r<ESC>[?6l<ESC>[?7h<ESC>[4l"

/// What `modes()` with no arguments renders as, for the cases that are not
/// about the modes at all.
let quietModes3 =
    "<ESC>[1;3r<ESC>[?6l<ESC>[?25h<ESC>[?7h<ESC>[4l<ESC>[?1l<ESC>>"
    + "<ESC>[?1000l<ESC>[?1002l<ESC>[?1003l<ESC>[?1006l<ESC>[?1005l<ESC>[0 q<ESC>[?12l"

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
            cursor: TmuxPaneCursor(column: 0, row: 1), modes: nil
        ),
        isFirstPaint: false,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2Jab<CR><LF>cd<ESC>[2;1H"
    ),
    // History supplied to a repaint is ignored rather than written. Nothing
    // asks for it, and writing it would stack a second copy of the scrollback
    // on every resize — the defect the `isFirstPaint` flag exists to prevent.
    Case(
        name: "repaint: history is not written even if handed over",
        snapshot: TmuxPaneSnapshot(
            history: rows(["old"]), screen: rows(["new"]),
            cursor: TmuxPaneCursor(column: 2, row: 0), modes: nil
        ),
        isFirstPaint: false,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2Jnew<ESC>[1;3H"
    ),
    // The first paint. Scrollback erased, history written into it, separated
    // from the screen by exactly one CR LF, cursor placed last.
    Case(
        name: "first paint: scrollback erased, history, separator, screen, cursor",
        snapshot: TmuxPaneSnapshot(
            history: rows(["h1", "h2"]), screen: rows(["s1", "s2"]),
            cursor: TmuxPaneCursor(column: 3, row: 1), modes: nil
        ),
        isFirstPaint: true,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2J<ESC>[3Jh1<CR><LF>h2<CR><LF>s1<CR><LF>s2<ESC>[2;4H"
    ),
    // A pane with nothing above the screen. The separator is what would put a
    // blank line into the scrollback if it went out unconditionally.
    Case(
        name: "first paint: no history means no separator",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: rows(["only"]),
            cursor: TmuxPaneCursor(column: 0, row: 0), modes: nil
        ),
        isFirstPaint: true,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2J<ESC>[3Jonly<ESC>[1;1H"
    ),
    // tmux would not say where the cursor is. Everything else still goes, and
    // the cursor is left wherever the rows put it — the pre-existing
    // behaviour, and the reason the connection trims trailing blanks in this
    // case and only this case.
    Case(
        name: "no cursor: no CUP at the end",
        snapshot: TmuxPaneSnapshot(history: [], screen: rows(["x"]), cursor: nil, modes: nil),
        isFirstPaint: false,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2Jx"
    ),
    // Blank rows are rows. `capture-pane` returns one line per pane row, so a
    // screen with a prompt at the top and nothing below it is mostly empty
    // lines — and every one of them has to be written, because the cursor row
    // below is counted from the top of the block.
    Case(
        name: "blank rows are written, so the cursor row still means something",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: rows(["$", "", ""]),
            cursor: TmuxPaneCursor(column: 1, row: 0), modes: nil
        ),
        isFirstPaint: false,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2J$<CR><LF><CR><LF><ESC>[1;2H"
    ),
    // tmux counts from zero and CUP counts from one. Getting this wrong is one
    // row and one column of drift, which is invisible on a shell prompt and
    // wrong on every full-screen program.
    Case(
        name: "cursor is one-based on the wire, zero-based from tmux",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: rows(["r"]),
            cursor: TmuxPaneCursor(column: 9, row: 2), modes: nil
        ),
        isFirstPaint: false,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2Jr<ESC>[3;10H"
    ),
    // Bytes above 0x7f pass through untouched. The whole reason this path
    // takes `Data` rather than `String`: a round trip through `String`
    // replaces anything invalid with U+FFFD and there is no way back.
    Case(
        name: "raw bytes survive",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: [Data([0x41, 0xe9, 0xff, 0x42])], cursor: nil, modes: nil
        ),
        isFirstPaint: false,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2JA<e9><ff>B"
    ),
    // A quiet shell. Every mode goes out with a value whether it is on or off:
    // a mode left unmentioned is whatever the *previous* program left the
    // surface in, which is the whole defect.
    Case(
        name: "modes: a quiet pane still states every mode",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: rows(["a", "b", "c"]),
            cursor: TmuxPaneCursor(column: 0, row: 0), modes: modes()
        ),
        isFirstPaint: false,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2Ja<CR><LF>b<CR><LF>c"
            + quietModes3 + "<ESC>[1;1H"
    ),
    // `less --mouse`: alternate screen, SGR mouse, application cursor keys and
    // keypad, and a scroll region one row short of the screen. This is the
    // measured state from tmux 3.6a that the whole item came from.
    Case(
        name: "modes: less --mouse, on a repaint",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: rows(["L1", "L2", "L3"]),
            cursor: TmuxPaneCursor(column: 0, row: 2),
            modes: modes(
                alternateScreen: true, applicationCursorKeys: true, applicationKeypad: true,
                mouseStandard: true, mouseSGR: true, scrollRegionLower: 1
            )
        ),
        isFirstPaint: false,
        expected: "<ESC>[?1049h" + neutral + "<ESC>[H<ESC>[2JL1<CR><LF>L2<CR><LF>L3"
            + "<ESC>[1;2r<ESC>[?6l<ESC>[?25h<ESC>[?7h<ESC>[4l<ESC>[?1h<ESC>="
            + "<ESC>[?1000h<ESC>[?1002l<ESC>[?1003l<ESC>[?1006h<ESC>[?1005l"
            + "<ESC>[0 q<ESC>[?12l<ESC>[3;1H"
    ),
    // The first paint of an alternate-screen pane. The history belongs to the
    // *primary* buffer — measured: the history range returns the primary
    // screen's scrollback and the plain capture returns the alternate screen —
    // so the switch happens between the two, and the alternate buffer is
    // cleared on the way in.
    Case(
        name: "first paint: history to the primary buffer, screen to the alternate one",
        snapshot: TmuxPaneSnapshot(
            history: rows(["past"]), screen: rows(["vim"]),
            cursor: TmuxPaneCursor(column: 0, row: 0),
            modes: modes(rows: 1, alternateScreen: true)
        ),
        isFirstPaint: true,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2J<ESC>[3Jpast<CR><LF>"
            + "<ESC>[?1049h" + neutral + "<ESC>[H<ESC>[2Jvim"
            + "<ESC>[1;1r<ESC>[?6l<ESC>[?25h<ESC>[?7h<ESC>[4l<ESC>[?1l<ESC>>"
            + "<ESC>[?1000l<ESC>[?1002l<ESC>[?1003l<ESC>[?1006l<ESC>[?1005l"
            + "<ESC>[0 q<ESC>[?12l<ESC>[1;1H"
    ),
    // A program that has *exited* since the last paint needs the switch back
    // as much as one that just started needs the switch in. Without it,
    // quitting vim leaves the surface showing an alternate screen libghostty
    // never saved anything into.
    Case(
        name: "modes: leaving the alternate screen is stated, not assumed",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: rows(["$"]),
            cursor: TmuxPaneCursor(column: 1, row: 0),
            modes: modes(rows: 1, alternateScreen: false)
        ),
        isFirstPaint: false,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2J$"
            + "<ESC>[1;1r<ESC>[?6l<ESC>[?25h<ESC>[?7h<ESC>[4l<ESC>[?1l<ESC>>"
            + "<ESC>[?1000l<ESC>[?1002l<ESC>[?1003l<ESC>[?1006l<ESC>[?1005l"
            + "<ESC>[0 q<ESC>[?12l<ESC>[1;2H"
    ),
    // Origin mode. tmux reports the cursor's *screen* row — measured — and CUP
    // under origin mode counts from the top of the scroll region, so row 4
    // inside a region starting at row 3 has to go out as row 2. Sending tmux's
    // number straight through is three rows of silent drift.
    Case(
        name: "modes: origin mode converts the cursor row",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: rows(["x"]),
            cursor: TmuxPaneCursor(column: 4, row: 4),
            modes: modes(origin: true, scrollRegionUpper: 3, scrollRegionLower: 8)
        ),
        isFirstPaint: false,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2Jx"
            + "<ESC>[4;9r<ESC>[?6h<ESC>[?25h<ESC>[?7h<ESC>[4l<ESC>[?1l<ESC>>"
            + "<ESC>[?1000l<ESC>[?1002l<ESC>[?1003l<ESC>[?1006l<ESC>[?1005l"
            + "<ESC>[0 q<ESC>[?12l<ESC>[2;5H"
    ),
    // The cursor shape mapping, measured against DECSCUSR on 3.6a. A blinking
    // bar is 5; the same shape steady is 6.
    Case(
        name: "modes: a blinking bar cursor is DECSCUSR 5",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: rows(["y"]),
            cursor: TmuxPaneCursor(column: 0, row: 0),
            modes: modes(rows: 1, cursorVisible: false, cursorShape: "bar", cursorBlinking: true)
        ),
        isFirstPaint: false,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2Jy"
            + "<ESC>[1;1r<ESC>[?6l<ESC>[?25l<ESC>[?7h<ESC>[4l<ESC>[?1l<ESC>>"
            + "<ESC>[?1000l<ESC>[?1002l<ESC>[?1003l<ESC>[?1006l<ESC>[?1005l"
            + "<ESC>[5 q<ESC>[?12h<ESC>[1;1H"
    ),
    // A shape word this build has never heard of. Leaving the shape alone is
    // the one answer that cannot be wrong; guessing a number would put a bar
    // cursor on a program that asked for something else.
    Case(
        name: "modes: an unknown cursor shape falls back to default",
        snapshot: TmuxPaneSnapshot(
            history: [], screen: rows(["z"]), cursor: nil,
            modes: modes(rows: 1, cursorShape: "hollow-block-from-a-future-tmux")
        ),
        isFirstPaint: false,
        expected: "<ESC>[?1049l" + neutral + "<ESC>[H<ESC>[2Jz"
            + "<ESC>[1;1r<ESC>[?6l<ESC>[?25h<ESC>[?7h<ESC>[4l<ESC>[?1l<ESC>>"
            + "<ESC>[?1000l<ESC>[?1002l<ESC>[?1003l<ESC>[?1006l<ESC>[?1005l"
            + "<ESC>[0 q<ESC>[?12l"
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