//
//  main.swift
//  LayoutCheck
//
//  Cross-checks TmuxLayout against a live tmux server: for every window it can
//  see, parse both of tmux's layout strings and compare the geometry the parser
//  derives for each pane with the geometry tmux itself reports via `list-panes`.
//  A parser that agrees with tmux on every pane of every window is the only
//  proof worth having — hand-written fixtures only test what the author already
//  believed.
//
//  Both layouts, because they are different answers and the app uses both.
//  `window_visible_layout` is what is on screen and what `list-panes` agrees
//  with; `window_layout` is what tmux would return to, and while a pane is
//  zoomed it describes that pane at a size nothing is rendering it at. So the
//  visible layout is checked against every pane, and the saved one against
//  every pane except the zoomed one — where its disagreement with `list-panes`
//  is the correct answer rather than a defect.
//
//  Build and run:
//      swiftc -O -o /tmp/layoutcheck \
//          Attache/Tmux/TmuxLayout.swift Tools/LayoutCheck/main.swift
//      /tmp/layoutcheck
//

import Foundation

/// Anything on this tool's own command line goes in front of every tmux
/// invocation, so `layoutcheck -L probe` checks a throwaway server instead of
/// whichever one the shell is attached to.
///
/// Worth having rather than a convenience: the zoomed case below cannot be
/// exercised without zooming a pane, and the server this normally runs against
/// is the user's, with real work in it. `-L` is the flag that picks a server;
/// `TMUX_TMPDIR` is not, and setting it alone is silently ignored.
let serverArguments = Array(CommandLine.arguments.dropFirst())

func tmux(_ arguments: [String]) -> String {
    let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else {
        FileHandle.standardError.write(Data("tmux not found\n".utf8))
        exit(2)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = serverArguments + arguments
    let pipe = Pipe()
    let errors = Pipe()
    process.standardOutput = pipe
    process.standardError = errors
    do {
        try process.run()
    } catch {
        FileHandle.standardError.write(Data("could not run tmux: \(error)\n".utf8))
        exit(2)
    }
    // stdout drained first, then stderr, which is only safe because tmux's
    // stderr here is bounded: a usage message or one `error connecting to …`
    // line, against a 64KB pipe buffer. A command that could fill that buffer
    // while this is blocked on stdout would deadlock, so anything added to this
    // tool that makes tmux talkative on stderr needs the two read concurrently.
    // Recorded rather than pre-solved because the failure would be an obvious
    // hang in a hand-run tool, not the silent wrong answer this file guards.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()

    // A failed query is not an empty server, and the difference has to be loud.
    // These were discarded — status and stderr both — so pointing this tool at a
    // socket that does not exist produced empty stdout, zero windows to walk, an
    // empty failure list, and a cheerful "✓ every pane agrees" on exit 0. That
    // is the single worst thing a cross-check can do: the run that verified
    // nothing is indistinguishable from the run that verified everything. Fatal
    // rather than counted, because every query here is one the whole check is
    // built on.
    guard process.terminationStatus == 0 else {
        let reason = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "tmux \((serverArguments + arguments).joined(separator: " "))"
            + " failed (status \(process.terminationStatus))"
            + (reason.isEmpty ? "" : ": \(reason)")
            + "\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(2)
    }
    return String(decoding: data, as: UTF8.self)
}

struct Failure {
    var window: String
    var detail: String
}

var checkedWindows = 0
var checkedZoomedWindows = 0
var skippedWindows = 0
/// Rows of tmux's reply this tool could not read. Should always be zero.
var unreadableRows = 0
/// Comparisons made, not panes seen: every pane is checked once per layout.
var checkedPanes = 0
var failures = [Failure]()

/// One window's numbers, all of them read in the same breath.
struct Window {
    var target = ""
    var savedText = ""
    var visibleText = ""
    var isZoomed = false
    var activePane: String?
    var panes = [String: TmuxLayoutFrame]()
}

// **One** query for the whole server, and that is deliberate. Window-scoped
// variables resolve against a pane's own window, so `list-panes -a` can carry
// the layouts and the zoom flag alongside the pane geometry — verified on 3.6a.
// Asking `list-windows` and then `list-panes` per window read two different
// instants: a pane zoomed between the two calls makes the layouts, the zoom flag
// and the geometry describe different moments, and the count rules below would
// report a disagreement that never existed. A cross-check that cries wolf is
// worse than no cross-check, because the next real failure gets waved off.
//
// `-a` covers every session on the server, so whatever shapes the user happens
// to have open all get exercised.
var byWindow = [String: Window]()
var windowOrder = [String]()
for line in tmux([
    "list-panes", "-a",
    "-F", [
        "#{session_name}:#{window_index}", "#{window_layout}", "#{window_visible_layout}",
        "#{window_zoomed_flag}", "#{pane_id}", "#{pane_width}", "#{pane_height}",
        "#{pane_left}", "#{pane_top}", "#{pane_active}",
    ].joined(separator: "\u{1}"),
]).split(separator: "\n") {
    // Empty fields kept, which matters: a tmux that does not have
    // `window_visible_layout` expands it to nothing, and dropping empties would
    // shift every field after it left, fail the count guard, and skip the
    // window — leaving a run that checked nothing at all printing ✓.
    let f = line.split(separator: "\u{1}", omittingEmptySubsequences: false)
    guard f.count >= 10,
          let width = Int(f[5]), let height = Int(f[6]),
          let left = Int(f[7]), let top = Int(f[8])
    else {
        // Counted, not merely skipped. A row this loop cannot read is a pane
        // that silently leaves the comparison, and a run that dropped every row
        // would print ✓ having checked nothing — the one result this file must
        // never produce. Nothing tmux emits should land here; that is exactly
        // why arriving here needs to be visible.
        unreadableRows += 1
        continue
    }

    let target = String(f[0])
    if byWindow[target] == nil {
        windowOrder.append(target)
        byWindow[target] = Window(
            target: target,
            savedText: String(f[1]),
            visibleText: String(f[2]),
            isZoomed: f[3] == "1"
        )
    }
    byWindow[target]?.panes[String(f[4])] =
        TmuxLayoutFrame(columns: width, rows: height, x: left, y: top)
    if f[9] == "1" { byWindow[target]?.activePane = String(f[4]) }
}

for target in windowOrder {
    guard let window = byWindow[target] else { continue }
    let windowTarget = window.target
    let expected = window.panes
    let activePane = window.activePane
    let isZoomed = window.isZoomed

    guard !window.visibleText.isEmpty else {
        skippedWindows += 1
        continue
    }

    let saved: TmuxLayoutNode
    let visible: TmuxLayoutNode
    do {
        saved = try TmuxLayout.parse(window.savedText)
        visible = try TmuxLayout.parse(window.visibleText)
    } catch {
        failures.append(Failure(
            window: windowTarget,
            detail: "parse failed: \(error) — saved \(window.savedText) / visible \(window.visibleText)"
        ))
        continue
    }
    checkedWindows += 1
    if isZoomed { checkedZoomedWindows += 1 }

    // The visible layout is the one on screen: every pane in it, at tmux's own
    // geometry. Zoomed, that is the single zoomed pane filling the window.
    let parsedVisible = visible.panes
    let expectedVisibleCount = isZoomed ? 1 : expected.count
    if parsedVisible.count != expectedVisibleCount {
        failures.append(Failure(
            window: windowTarget,
            detail: "visible pane count differs: parsed \(parsedVisible.count), expected \(expectedVisibleCount)"
                + (isZoomed ? " (window is zoomed, so exactly the zoomed pane)" : "")
        ))
    }
    if isZoomed, let activePane, parsedVisible.first?.id != activePane {
        failures.append(Failure(
            window: windowTarget,
            detail: "zoomed window shows \(parsedVisible.first?.id ?? "nothing") but tmux's active pane is \(activePane)"
        ))
    }

    // The saved layout has to list every pane, including the ones a zoom is
    // hiding — that is the whole reason the app keeps it. Its *geometry* is
    // tmux's only for the panes that are not zoomed.
    let parsedSaved = saved.panes
    if parsedSaved.count != expected.count {
        failures.append(Failure(
            window: windowTarget,
            detail: "saved pane count differs: parsed \(parsedSaved.count), tmux reports \(expected.count)"
        ))
    }

    for (source, parsed, skipping) in [
        ("visible", parsedVisible, nil as String?),
        ("saved", parsedSaved, isZoomed ? activePane : nil),
    ] {
        for (id, frame) in parsed {
            guard let truth = expected[id] else {
                failures.append(Failure(
                    window: windowTarget,
                    detail: "\(source) layout has a pane tmux does not: \(id)"
                ))
                continue
            }
            // Counted after the skip, not before. The zoomed pane's saved
            // geometry is the one thing here with no oracle, so counting it
            // would report a comparison that did not happen and overstate how
            // much of the zoom branch a run actually exercised.
            guard id != skipping else { continue }
            checkedPanes += 1
            if frame != truth {
                failures.append(Failure(
                    window: windowTarget,
                    detail: "\(source): \(id) geometry differs: parsed \(frame.columns)x\(frame.rows)@\(frame.x),\(frame.y) "
                        + "vs tmux \(truth.columns)x\(truth.rows)@\(truth.x),\(truth.y)"
                ))
            }
        }
    }
}

// A handful of shapes that a live server may not happen to contain.
let malformed = [
    "",
    "abc",
    "06dc",
    "06dc,",
    "06dc,100x50",
    "06dc,100x50,0",
    "06dc,100x50,0,0{",
    "06dc,100x50,0,0{50x50,0,0,1}",       // container with a single child
    "06dc,100x50,0,0{50x50,0,0,1,49x50,51,0,2}trailing",
    "06dc,100x50,0,0(50x50,0,0,1)",       // wrong bracket
]
for text in malformed {
    if let node = try? TmuxLayout.parse(text) {
        failures.append(Failure(window: "<malformed input>", detail: "should have thrown but parsed: \(text) → \(node.panes.count) panes"))
    }
}

// The zoomed count is printed rather than merely counted: a run over a server
// with none of them has not exercised the case this check was extended for, and
// "✓" would otherwise read as though it had.
print(
    "Checked \(checkedWindows) windows (\(checkedZoomedWindows) zoomed)"
        + " / \(checkedPanes) pane comparisons, plus \(malformed.count) malformed inputs"
)

// Anything that means "a window went unchecked" is a **failure**, not a footnote
// under a tick. Printing a skip line and then "✓ every pane agrees" is a
// contradiction the reader resolves in favour of the tick, and the whole value
// of this file is that its ✓ can be believed. None of these can happen against
// a tmux this project supports, which is precisely why each one is worth a red
// result rather than a note: reaching any of them means an assumption this tool
// rests on has stopped holding.
if unreadableRows > 0 {
    failures.append(Failure(
        window: "<tmux reply>",
        detail: "\(unreadableRows) row(s) could not be read — field count or geometry"
            + " was not what this tool expects, so those panes went unchecked"
    ))
}
if skippedWindows > 0 {
    failures.append(Failure(
        window: "<tmux server>",
        detail: "\(skippedWindows) window(s) skipped: this tmux has no"
            + " #{window_visible_layout}, so the layout the app draws from could not be checked"
    ))
}
// A run that read no window at all is not a pass, whatever the failure list
// says. Pointing this at the wrong socket is the ordinary way to get here, and
// it otherwise looks identical to a clean server.
if checkedWindows == 0 {
    failures.append(Failure(
        window: "<tmux server>",
        detail: "checked no windows at all — wrong server, or it has no windows"
    ))
}

if failures.isEmpty {
    print("✓ every pane agrees with the geometry tmux reports")
    exit(0)
}
for failure in failures {
    print("✗ \(failure.window): \(failure.detail)")
}
exit(1)
