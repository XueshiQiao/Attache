//
//  main.swift
//  StatusLineCheck
//
//  Checks the two decisions that stand between the status line wrapper and
//  somebody losing their status line: **is this command ours**, and **what do
//  we put back**.
//
//  This is the file with the same shape of danger as `TerminalReply` and
//  `TmuxRenameString`: every way it can be wrong is silent. A command wrongly
//  claimed as ours is overwritten and the original is gone. A missing recovery
//  record read as "there was nothing" deletes the user's whole `statusLine`
//  object. Neither produces an error, and neither is noticed until the next
//  time they look at their terminal.
//
//  So the half that matters is **everything that must be refused**. Both
//  findings this table was written for came from a review rather than from use,
//  and both are in here as the cases that used to pass wrongly.
//
//  swiftc -O -o /tmp/statuslinecheck TmuxGUI/Status/StatusLineRecovery.swift \
//      Tools/StatusLineCheck/main.swift && /tmp/statuslinecheck
//

import Foundation

private var failures = 0
private var total = 0

private func check(_ name: String, _ problem: @autoclosure () -> String?) {
    total += 1
    if let problem = problem() {
        failures += 1
        print("FAIL  \(name)\n      \(problem)")
    } else {
        print("ok    \(name)")
    }
}

private func expect(_ actual: some Equatable, _ wanted: some Equatable) -> String? {
    "\(actual)" == "\(wanted)" ? nil : "got \(actual), wanted \(wanted)"
}

private let home = "/Users/someone"
private let script = "\(home)/.claude/hooks/tmuxgui-statusline.sh"

private func classify(_ command: String?) -> StatusLineRecovery.Ownership {
    StatusLineRecovery.classify(command, scriptPath: script, home: home)
}

// MARK: - Is this command ours

print("— commands this app could have written —")

for command in [
    script,
    "sh \(script)",
    "bash \(script)",
    "/bin/sh \(script)",
    "/bin/bash \(script)",
    "  sh \(script)  ",
    "~/.claude/hooks/tmuxgui-statusline.sh",
    "sh ~/.claude/hooks/tmuxgui-statusline.sh",
] {
    check("`\(command)` is ours", expect(classify(command), StatusLineRecovery.Ownership.ours))
}

print("\n— somebody else's status line —")

for command in [
    "bash ~/.claude/coralline/statusline.sh",
    "npx ccstatusline@latest",
    "/usr/bin/python3 ~/bin/status.py",
    "printf hello",
] {
    check("`\(command)` is not ours", {
        expect(classify(command), StatusLineRecovery.Ownership.foreign(command))
    }())
}

check("no command at all is foreign(nil)", {
    expect(classify(nil), StatusLineRecovery.Ownership.foreign(nil))
        ?? expect(classify(""), StatusLineRecovery.Ownership.foreign(nil))
        ?? expect(classify("   "), StatusLineRecovery.Ownership.foreign(nil))
}())

print("\n— names our script but is not ours: refuse, never overwrite —")

// Found by review, 2026-07-29. Ownership used to be `command.contains(name)`,
// so every one of these read as ours: installing would have discarded the outer
// command, and uninstalling would have replaced it with a record older than it.
// Composition is the case the wrapper design is *for*, so getting it wrong here
// undoes the whole point.
for command in [
    "sh /Users/someone/other-tool/wrapper.sh --inner tmuxgui-statusline.sh",
    "bash -c 'date; sh ~/.claude/hooks/tmuxgui-statusline.sh'",
    "sh \(script) --extra-flag",
    "sh \(script) | tee /tmp/log",
    "OTHER=1 sh \(script)",
    "/opt/homebrew/bin/tmuxgui-statusline.sh",
] {
    check("`\(command)` is unrecognised", {
        expect(
            classify(command),
            StatusLineRecovery.Ownership.unrecognised(command.trimmingCharacters(in: .whitespaces))
        )
    }())
}

check("a home that is not a prefix does not produce a bogus ~ form", {
    // A machine where the script lives outside the home directory: the tilde
    // spelling must simply not be offered rather than be built wrong.
    let outside = "/opt/tmuxgui/tmuxgui-statusline.sh"
    let got = StatusLineRecovery.classify("sh \(outside)", scriptPath: outside, home: home)
    return expect(got, StatusLineRecovery.Ownership.ours)
}())

// MARK: - What do we put back

print("\n— the recovery record —")

private func recovery(_ text: String?) -> StatusLineRecovery.Recovery {
    StatusLineRecovery.recovery(from: text)
}

check("a missing file is unavailable, NOT none", {
    // The finding. `nil` meaning "no status line" is what deletes the user's
    // whole statusLine object — refreshInterval and all — on a missing file.
    expect(recovery(nil), StatusLineRecovery.Recovery.unavailable)
}())

for (name, text) in [
    ("an empty file", ""),
    ("comments only", "# hello\n# there\n"),
    ("a marker we do not know", "TMUXGUI_WRAPPED=maybe\nINNER=x\n"),
    ("command with no INNER", "TMUXGUI_WRAPPED=command\n"),
    ("command with an empty INNER", "TMUXGUI_WRAPPED=command\nINNER=\n"),
    ("INNER with no marker", "INNER=bash ~/x.sh\n"),
    ("the old sourced format", "INNER='bash ~/.claude/coralline/statusline.sh'\n"),
] {
    check("\(name) is unavailable", expect(recovery(text), StatusLineRecovery.Recovery.unavailable))
}

check("an explicit none is none", {
    expect(recovery("TMUXGUI_WRAPPED=none\nINNER=\n"), StatusLineRecovery.Recovery.none)
}())

check("a recorded command comes back exactly", {
    let inner = "bash ~/.claude/coralline/statusline.sh"
    return expect(
        recovery("TMUXGUI_WRAPPED=command\nINNER=\(inner)\n"),
        StatusLineRecovery.Recovery.command(inner)
    )
}())

print("\n— a command is arbitrary user text —")

// The old format quoted this into a file the wrapper *sourced*, so every one of
// these was a chance to mangle the command or to run something. Now it is the
// rest of the line and none of it means anything.
for inner in [
    "sh -c 'echo it'\"'\"'s fine'",
    #"jq -r '.model.display_name' | sed "s/'/-/g""#,
    "printf '%s' \"$(date)\"",
    "bash -c 'exit 0' # trailing comment",
    "printf 'a\\tb'",
    "python3 ~/bin/st.py --flag=\"a b\" 'c d'",
    "  leading and trailing spaces are kept  ",
    "echo TMUXGUI_WRAPPED=none",
] {
    check("round-trips: \(inner.prefix(38))…", {
        let text = StatusLineRecovery.config(.command(inner))
        return expect(recovery(text), StatusLineRecovery.Recovery.command(inner))
    }())
}

check("a command that mentions the marker cannot forge the record", {
    // `echo TMUXGUI_WRAPPED=none` above is the interesting half: it must be
    // restored as a command, not read as "there was nothing".
    let text = StatusLineRecovery.config(.command("echo TMUXGUI_WRAPPED=none"))
    return expect(recovery(text), StatusLineRecovery.Recovery.command("echo TMUXGUI_WRAPPED=none"))
}())

check("a second INNER line added by hand does not take over", {
    let text = "TMUXGUI_WRAPPED=command\nINNER=first\nINNER=second\n"
    return expect(recovery(text), StatusLineRecovery.Recovery.command("first"))
}())

check("writing none and reading it back is none", {
    expect(recovery(StatusLineRecovery.config(.none)), StatusLineRecovery.Recovery.none)
}())

check("writing unavailable degrades to none rather than to a lie", {
    // There is nothing truthful to write for `unavailable`, and "there was no
    // status line" is the only claim that cannot restore the wrong command.
    expect(recovery(StatusLineRecovery.config(.unavailable)), StatusLineRecovery.Recovery.none)
}())

print("\n— what cannot round-trip must be refused up front —")

check("a single-line command can round-trip", {
    expect(StatusLineRecovery.canRoundTrip("bash ~/x.sh"), true)
}())

for command in [
    "bash ~/x.sh\nrm -rf /tmp/nope",
    "line one\r\nline two",
    "trailing newline\n",
] {
    check("a command across lines is refused", {
        // Restoring a truncated shell command is worse than refusing: it still
        // runs, and it does something other than what was asked.
        expect(StatusLineRecovery.canRoundTrip(command), false)
    }())
}

// MARK: - Result

print("")
if failures == 0 {
    print("\(total) cases, all passed")
} else {
    print("\(failures) of \(total) cases FAILED")
    exit(1)
}
