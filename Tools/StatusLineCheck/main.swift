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

private func describe(_ value: String?) -> String { value ?? "nil" }

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
private func rec(command: String?, original: String?) -> StatusLineRecovery.Recovery {
    StatusLineRecovery.Recovery(command: command, original: original)
}

check("a missing file is unavailable, NOT none", {
    // Reading nil as "there was nothing" is what deletes a statusLine object
    // the user still had.
    expect(recovery(nil).isUnavailable, true)
}())

for (name, text) in [
    ("an empty file", ""),
    ("comments only", "# hello\n# there\n"),
    ("a marker we do not know", "TMUXGUI_WRAPPED=maybe\nINNER=x\nTMUXGUI_ORIGINAL=absent\n"),
    ("command with no INNER", "TMUXGUI_WRAPPED=command\nTMUXGUI_ORIGINAL=absent\n"),
    ("command with an empty INNER", "TMUXGUI_WRAPPED=command\nINNER=\nTMUXGUI_ORIGINAL=absent\n"),
    ("INNER with no marker", "INNER=bash ~/x.sh\n"),
    ("the old sourced format", "INNER='bash ~/.claude/coralline/statusline.sh'\n"),
    // Found by review: a record from the version that tracked only the command
    // cannot say whether the statusLine *object* existed, and guessing is what
    // deletes one. It must read as unavailable rather than as `none`.
    ("a record with no TMUXGUI_ORIGINAL line", "TMUXGUI_WRAPPED=none\nINNER=\n"),
    ("the same, carrying a command", "TMUXGUI_WRAPPED=command\nINNER=bash ~/x.sh\n"),
] {
    check("\(name) is unavailable", expect(recovery(text).isUnavailable, true))
}

check("an explicit none with no object is none, with no object", {
    let r = recovery("TMUXGUI_WRAPPED=none\nINNER=\nTMUXGUI_ORIGINAL=absent\n")
    return expect(r.isUnavailable, false)
        ?? expect(describe(r.command), "nil")
        ?? expect(describe(r.original), "nil")
}())

check("an object with no command round-trips both facts", {
    // The case the whole `original` field exists for: a settings file holding
    // `{"statusLine":{"refreshInterval":500}}`, which install preserves and
    // uninstall used to delete.
    let object = #"{"refreshInterval":500}"#
    let text = StatusLineRecovery.config(rec(command: nil, original: object))
    let r = recovery(text)
    return expect(describe(r.command), "nil") ?? expect(describe(r.original), object)
}())

check("a recorded command and object both come back exactly", {
    let inner = "bash ~/.claude/coralline/statusline.sh"
    let object = #"{"command":"bash ~/.claude/coralline/statusline.sh","refreshInterval":5,"type":"command"}"#
    let r = recovery(StatusLineRecovery.config(rec(command: inner, original: object)))
    return expect(describe(r.command), inner) ?? expect(describe(r.original), object)
}())

print("\n— a command is arbitrary user text —")

for inner in [
    "sh -c 'echo it'\"'\"'s fine'",
    #"jq -r '.model.display_name' | sed "s/'/-/g""#,
    "printf '%s' \"$(date)\"",
    "bash -c 'exit 0' # trailing comment",
    "printf 'a\\tb'",
    "python3 ~/bin/st.py --flag=\"a b\" 'c d'",
    "  leading and trailing spaces are kept  ",
    "echo TMUXGUI_WRAPPED=none",
    "echo TMUXGUI_ORIGINAL=absent",
] {
    check("round-trips: \(inner.prefix(34))…", {
        let text = StatusLineRecovery.config(rec(command: inner, original: nil))
        return expect(describe(recovery(text).command), inner)
    }())
}

check("a command that mentions a marker cannot forge the record", {
    let text = StatusLineRecovery.config(rec(command: "echo TMUXGUI_ORIGINAL=absent", original: #"{"a":1}"#))
    let r = recovery(text)
    return expect(describe(r.command), "echo TMUXGUI_ORIGINAL=absent")
        ?? expect(describe(r.original), #"{"a":1}"#)
}())

check("a second INNER line added by hand does not take over", {
    let text = "TMUXGUI_WRAPPED=command\nINNER=first\nINNER=second\nTMUXGUI_ORIGINAL=absent\n"
    return expect(describe(recovery(text).command), "first")
}())

check("writing unavailable degrades to none rather than to a lie", {
    let r = recovery(StatusLineRecovery.config(.unavailable))
    return expect(r.isUnavailable, false) ?? expect(describe(r.command), "nil")
}())

print("\n— what cannot round-trip must be refused up front —")

check("a single-line command can round-trip", {
    expect(StatusLineRecovery.canRoundTrip("bash ~/x.sh"), true)
}())

for value in [
    "bash ~/x.sh\nrm -rf /tmp/nope",
    "line one\r\nline two",
    "trailing newline\n",
    #"{"command":"a\#(String("\n"))b"}"#,
] {
    check("a value across lines is refused", expect(StatusLineRecovery.canRoundTrip(value), false))
}

print("\n— classify hands back the RAW command, not a tidied one —")

// Found by review. `classify` trims for the *comparison*, and returning the
// trimmed value meant `canRoundTrip` downstream was shown a command whose
// trailing newline had already been removed — so it passed, and the record
// restored something other than what was there.
for raw in ["echo ok\n", "  bash ~/x.sh  ", "bash ~/x.sh\nrm -rf /tmp/nope"] {
    check("raw survives classify: \(raw.debugDescription)", {
        guard case .foreign(let got) = classify(raw) else {
            return "got \(classify(raw)), wanted .foreign"
        }
        return expect(describe(got), raw)
    }())
}

check("a command made only of whitespace reads as no command", {
    // `command(in:)` treats it as absent before `classify` ever sees it, so
    // `foreign(nil)` keeps meaning exactly one thing. Nothing is lost by that:
    // the recorded object carries the field verbatim, and uninstall puts the
    // object back without stripping anything out of it.
    expect(classify("\n"), StatusLineRecovery.Ownership.foreign(nil))
}())

// MARK: - Result

print("")
if failures == 0 {
    print("\(total) cases, all passed")
} else {
    print("\(failures) of \(total) cases FAILED")
    exit(1)
}
