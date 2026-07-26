//
//  main.swift
//  LayoutCheck
//
//  Cross-checks TmuxLayout against a live tmux server: for every window it can
//  see, parse `window_layout` and compare the geometry the parser derives for
//  each pane with the geometry tmux itself reports via `list-panes`. A parser
//  that agrees with tmux on every pane of every window is the only proof worth
//  having — hand-written fixtures only test what the author already believed.
//
//  Build and run:
//      swiftc -O -o /tmp/layoutcheck \
//          TmuxGUI/Tmux/TmuxLayout.swift Tools/LayoutCheck/main.swift
//      /tmp/layoutcheck
//

import Foundation

func tmux(_ arguments: [String]) -> String {
    let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else {
        FileHandle.standardError.write(Data("tmux not found\n".utf8))
        exit(2)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

struct Failure {
    var window: String
    var detail: String
}

var checkedWindows = 0
var checkedPanes = 0
var failures = [Failure]()

// `list-windows -a` covers every session on the server, so whatever shapes the
// user happens to have open all get exercised.
let windows = tmux(["list-windows", "-a", "-F", "#{session_name}:#{window_index}\u{1}#{window_layout}"])
    .split(separator: "\n")

for line in windows {
    let fields = line.split(separator: "\u{1}", maxSplits: 1)
    guard fields.count == 2 else { continue }
    let windowTarget = String(fields[0])
    let layoutText = String(fields[1])

    let root: TmuxLayoutNode
    do {
        root = try TmuxLayout.parse(layoutText)
    } catch {
        failures.append(Failure(window: windowTarget, detail: "parse failed: \(error) — \(layoutText)"))
        continue
    }
    checkedWindows += 1

    // tmux's own numbers for the same window.
    var expected = [String: TmuxLayoutFrame]()
    let paneLines = tmux([
        "list-panes", "-t", windowTarget,
        "-F", "#{pane_id}\u{1}#{pane_width}\u{1}#{pane_height}\u{1}#{pane_left}\u{1}#{pane_top}",
    ]).split(separator: "\n")
    for paneLine in paneLines {
        let parts = paneLine.split(separator: "\u{1}")
        guard parts.count == 5,
              let width = Int(parts[1]), let height = Int(parts[2]),
              let left = Int(parts[3]), let top = Int(parts[4])
        else { continue }
        expected[String(parts[0])] = TmuxLayoutFrame(columns: width, rows: height, x: left, y: top)
    }

    let parsed = root.panes
    if parsed.count != expected.count {
        failures.append(Failure(
            window: windowTarget,
            detail: "pane count differs: parsed \(parsed.count), tmux reports \(expected.count)"
        ))
    }

    for (id, frame) in parsed {
        checkedPanes += 1
        guard let truth = expected[id] else {
            failures.append(Failure(window: windowTarget, detail: "parsed a pane tmux does not have: \(id)"))
            continue
        }
        if frame != truth {
            failures.append(Failure(
                window: windowTarget,
                detail: "\(id) geometry differs: parsed \(frame.columns)x\(frame.rows)@\(frame.x),\(frame.y) "
                    + "vs tmux \(truth.columns)x\(truth.rows)@\(truth.x),\(truth.y)"
            ))
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

print("Checked \(checkedWindows) windows / \(checkedPanes) panes, plus \(malformed.count) malformed inputs")
if failures.isEmpty {
    print("✓ every pane agrees with the geometry tmux reports")
    exit(0)
}
for failure in failures {
    print("✗ \(failure.window): \(failure.detail)")
}
exit(1)
