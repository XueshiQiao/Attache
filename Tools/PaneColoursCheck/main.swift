//
//  main.swift
//  PaneColoursCheck
//
//  Cross-check for `TmuxPaneColours`, against a real tmux rather than a
//  fixture — tmux is the oracle for anything protocol-shaped.
//
//      swiftc -O -o /tmp/panecolourscheck Attache/Tmux/TmuxCommand.swift \
//          Attache/Tmux/TmuxPaneColours.swift Attache/Tmux/TmuxVersion.swift \
//          Tools/PaneColoursCheck/main.swift
//      /tmp/panecolourscheck
//
//  What it refuses to take on faith is the quoting and what tmux does with
//  it. The report goes through tmux's own command parser, which turns `\033`
//  into ESC only inside double quotes, and then through its OSC 10/11 parser;
//  a command that looks right and parses to nothing is answered with no
//  error at all, and the pane goes on being told black. So every live case
//  runs a program in a pane that asks, exactly as Claude Code does, and
//  compares the bytes it is answered with.
//
//  The server is a private one on `-L attache-panecolours-check`, given on
//  every command, and killed at the end. Never the user's: their panes have
//  agents running in them.
//

import Foundation

var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("  ok \(name)")
    } else {
        failures += 1
        print("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

// MARK: - Rendering

check("rejects a non-hex colour", TmuxPaneColours(foreground: "zzzzzz", background: "fafafa") == nil)
check("rejects a short colour", TmuxPaneColours(foreground: "fff", background: "fafafa") == nil)
check("rejects a quote smuggled into a colour",
      TmuxPaneColours(foreground: "fa\"afa", background: "fafafa") == nil)
check("rejects fullwidth hex digits",
      TmuxPaneColours(foreground: "ｆａｆａｆａ", background: "fafafa") == nil)
check("accepts a leading #", TmuxPaneColours(foreground: "#383A42", background: "fafafa")?.foreground == "383a42")
check("xcolor doubles each channel", TmuxPaneColours.xcolor("0a1b2c") == "rgb:0a0a/1b1b/2c2c")

let light = TmuxPaneColours(foreground: "383a42", background: "fafafa")!
let dark = TmuxPaneColours(foreground: "dcdfe4", background: "282c34")!
check("one command per colour", light.reportCommands(paneID: "%3").count == 2)
for bad in ["3", "%", "%3 ", "%3;kill-server", "@3", "%３"] {
    check("rejects pane id \(bad.debugDescription)", light.reportCommands(paneID: bad).isEmpty)
}

// MARK: - Live server

let socket = "attache-panecolours-check"
let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("panecolourscheck-\(getpid())")
try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

@discardableResult
func tmux(_ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["tmux", "-L", socket, "-f", "/dev/null"] + arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try! process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A program that does what a theme-following TUI does: turn on theme
/// notifications (2031), ask for both colours and the theme, then keep
/// recording whatever the terminal sends. `delay` is how long it takes to
/// start asking: a report sent after the pane appeared lands in it.
///
/// Timed by a count of reads rather than `date +%s`, which has one-second
/// resolution: started at x.99 it ends the loop before the first read and the
/// case fails on an empty file. Each `dd` returns after 0.1s of silence
/// (`time 1`), so `tenths` reads are at least that many tenths of a second.
let probe = scratch.appendingPathComponent("probe.sh")
try! """
#!/bin/sh
out="$1"; tenths="$2"; delay="$3"
old=$(stty -g)
stty raw -echo min 0 time 1
sleep "$delay"
printf '\\033[?2031h\\033]10;?\\033\\\\\\033]11;?\\033\\\\\\033[?996n'
: > "$out.part"
i=0
while [ $i -lt "$tenths" ]; do dd bs=1 count=100 2>/dev/null >> "$out.part"; i=$((i + 1)); done
stty "$old"
mv "$out.part" "$out"
""".write(to: probe, atomically: true, encoding: .utf8)
chmod(probe.path, 0o755)

/// A control client over a pipe, like the app's.
final class ControlClient {
    let process = Process()
    let input = Pipe()
    init(session: String) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "-L", socket, "-f", "/dev/null", "-C", "attach", "-t", session]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try! process.run()
    }
    func send(_ command: String) {
        input.fileHandleForWriting.write(Data((command + "\n").utf8))
    }
    func close() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

/// For the shell command line `new-window` hands to `sh -c`.
func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Run the probe in a fresh pane and return what it heard, as text with ESC
/// shown as `^[`.
func heard(
    in session: String, recordFor seconds: Double, askingAfter delay: Double = 0,
    during: (String) -> Void = { _ in }
) -> String {
    let file = scratch.appendingPathComponent("heard-\(UUID().uuidString)")
    let tenths = Int((seconds * 10).rounded())
    let pane = tmux(["new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "\(session):",
                     "\(shellQuoted(probe.path)) \(shellQuoted(file.path)) \(tenths) \(delay); sleep 1"])
    during(pane)
    for _ in 0 ..< Int((seconds + delay + 5) * 10) {
        if let data = FileManager.default.contents(atPath: file.path) {
            return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{1b}", with: "^[")
        }
        usleep(100_000)
    }
    return "<probe never finished>"
}

/// What the app's connection does on a colour change: report, then read the
/// global `window-style` and send `reassertWindowStyle`'s command for it.
/// The read goes over a separate client here, which is fine: it is the
/// write's ordering after the reports that matters, and both of those go
/// over `control`.
func reportAndAnnounce(_ colours: TmuxPaneColours, pane: String) {
    for command in colours.reportCommands(paneID: pane) { control.send(command) }
    let current = tmux(["show-options", "-gwv", "window-style"])
    guard let command = TmuxPaneColours.reassertWindowStyle(currentValue: current) else {
        check("reassert accepts \(current.debugDescription)", false); return
    }
    control.send(command)
}

/// Every `997` the probe heard, in order: "1n" dark, "2n" light.
func themeReports(_ heard: String) -> [String] {
    heard.components(separatedBy: "[?997;").dropFirst().map { String($0.prefix(2)) }
}

check("reassert refuses a newline", TmuxPaneColours.reassertWindowStyle(currentValue: "fg=red\nbg=blue") == nil)
check("reassert refuses a tab", TmuxPaneColours.reassertWindowStyle(currentValue: "fg=red\tbg=blue") == nil)
check("reassert refuses DEL", TmuxPaneColours.reassertWindowStyle(currentValue: "fg=red\u{7f}") == nil)

tmux(["kill-server"])
tmux(["new-session", "-d", "-s", "check", "-x", "80", "-y", "24"])
// The app's own parse of the server's own answer, so `next-3.6` and `master`
// read the way the app reads them.
let version = tmux(["display", "-p", "-t", "check", "#{version}"])
if version.isEmpty || TmuxVersion.parseServerAnswer("tmux \(version)").map({ !$0.supportsPaneColourReports }) == true {
    print("FAIL needs tmux ≥ 3.5 for refresh-client -r, found \(version.isEmpty ? "no server" : version)")
    tmux(["kill-server"])
    try? FileManager.default.removeItem(at: scratch)
    exit(1)
}

var control: ControlClient! = ControlClient(session: "check")
usleep(500_000)

// The instrument first: with nothing reported, a control client is answered
// as black and dark. If this stops failing, tmux changed and the premise of
// `TmuxPaneColours` needs measuring again.
let unreported = heard(in: "check", recordFor: 1)
check("unreported pane is told black", unreported.contains("]11;rgb:0000/0000/0000"), unreported)
check("unreported pane is told dark", unreported.contains("[?997;1n"), unreported)

// A global value with a space, `#`, braces and commas in it, so the write-back
// is checked byte for byte rather than on `default`. Set only now: a style
// with a background is what tmux answers with when nothing is reported, which
// would hide the black above.
let trickyStyle = "fg=#c0ffee bg=#{?pane_active,blue,default},bold"
tmux(["set-option", "-gw", "window-style", trickyStyle])
tmux(["set-option", "-w", "-t", "check:", "window-style", "fg=red"])

// Reported before the program asks. The delay stands in for start-up time.
let reportedFirst = heard(in: "check", recordFor: 1, askingAfter: 0.5) { pane in
    for command in light.reportCommands(paneID: pane) { control.send(command) }
}
check("reported pane is told the background", reportedFirst.contains("]11;rgb:fafa/fafa/fafa"), reportedFirst)
check("reported pane is told the foreground", reportedFirst.contains("]10;rgb:3838/3a3a/4242"), reportedFirst)
check("reported pane is told light", reportedFirst.contains("[?997;2n"), reportedFirst)

// Asked before the report landed — a fast program in a new pane, or any
// program over ssh. It is told black and dark, tmux clears the pane's theme
// flag, and the report alone never sets it again: only the announcement that
// follows a new pane's report gets it out of dark.
let askedFirst = heard(in: "check", recordFor: 2.5) { pane in
    usleep(800_000)
    reportAndAnnounce(light, pane: pane)
}
check("program that asked first is told dark at once", themeReports(askedFirst).first == "1n", askedFirst)
check("program that asked first hears light once reported", themeReports(askedFirst).last == "2n", askedFirst)

// A program already running when the scheme changes.
let flipped = heard(in: "check", recordFor: 4) { pane in
    usleep(800_000)
    reportAndAnnounce(light, pane: pane)
    usleep(1_200_000)
    reportAndAnnounce(dark, pane: pane)
}
let afterFlip = themeReports(flipped)
// Light first, or a pane that was never reported — told dark all along —
// would pass the second half.
check("running program hears light, then the flip to dark",
      afterFlip.contains("2n") && afterFlip.last == "1n", flipped)
check("global window-style unchanged, byte for byte",
      tmux(["show-options", "-gwv", "window-style"]) == trickyStyle,
      tmux(["show-options", "-gwv", "window-style"]))
check("window-level window-style unchanged",
      tmux(["show-options", "-wv", "-t", "check:", "window-style"]) == "fg=red")

control.close()
tmux(["kill-server"])
try? FileManager.default.removeItem(at: scratch)

if failures == 0 {
    print("all pass")
    exit(0)
} else {
    print("\(failures) failure(s)")
    exit(1)
}
