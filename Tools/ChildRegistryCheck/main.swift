//
//  ChildRegistryCheck/main.swift
//
//  Cross-check for `TmuxChildRecord.shouldReclaim`, which decides whether a
//  recorded pid may be killed. It is in the same class as `TerminalReply` and
//  `TmuxRenameString`: a false positive is silent and unrecoverable — it kills
//  a process belonging to somebody else — so the decision gets a table.
//
//  The command lines below are real. `/opt/homebrew/bin/tmux -C attach -t $34`
//  is this app's own, taken from `ps` on 2026-07-30; the `-CC` form is what
//  iTerm2's tmux integration spawns, and is the concrete reason a blind
//  "kill every orphaned control client" sweep is not allowed.
//
//  The two cases an independent review found missing are marked REVIEW below.
//  Both are pid reuse landing on a process whose *argv is identical to ours* —
//  a second copy of this app, and a human who typed the same command — and
//  neither is distinguishable by command line at all. They are why the record
//  carries a start time.
//
//    swiftc -O -o /tmp/childregistrycheck Attache/Tmux/TmuxChildRecord.swift \
//      Tools/ChildRegistryCheck/main.swift
//    /tmp/childregistrycheck
//

import Foundation

var failures = 0

/// The recorded child every case is judged against: pid 1234, started at a
/// known second, attached to `$34`.
let recordedStart = "Thu_Jul_30_07:04:30_2026"
let ours = "/opt/homebrew/bin/tmux -C attach -t $34"

func check(
    _ name: String,
    ownerIsAlive: Bool = false,
    commandLine: String? = ours,
    startedAt: String = recordedStart,
    parentPID: Int32 = 1,
    sessionID: String = "$34",
    expected: Bool
) {
    let record = TmuxChildRecord(
        ownerPID: 999, childPID: 1234, startedAt: recordedStart, sessionID: sessionID,
        commandLine: nil
    )
    let facts = commandLine.map {
        TmuxChildRecord.ChildFacts(
            commandLine: $0, startedAt: startedAt, parentPID: parentPID
        )
    }
    let got = record.shouldReclaim(ownerIsAlive: ownerIsAlive, child: facts)
    if got == expected {
        print("  ok    \(name)")
    } else {
        print("  FAIL  \(name) — expected \(expected), got \(got)")
        failures += 1
    }
}

print("— may reclaim —")
check("our own orphan: owner gone, start time matches, PPID 1", expected: true)
check("same, tmux installed somewhere else",
      commandLine: "/usr/local/bin/tmux -C attach -t $34", expected: true)
check("same, argument order swapped",
      commandLine: "/usr/bin/tmux -C -t $34 attach", expected: true)

print("— must not reclaim: the run is still using it —")
check("owner still alive", ownerIsAlive: true, expected: false)

print("— must not reclaim: cannot prove what the pid is —")
check("command line unreadable", commandLine: nil, expected: false)
check("command line empty", commandLine: "", expected: false)

print("— must not reclaim: pid now means something else —")
check("pid reused by an unrelated process",
      commandLine: "/bin/zsh -c 'sleep 999'", expected: false)
check("pid reused by the user's interactive tmux client",
      commandLine: "/opt/homebrew/bin/tmux attach -t $34", expected: false)
check("pid reused by a control client of a different session",
      commandLine: "/opt/homebrew/bin/tmux -C attach -t $99", expected: false)
check("control mode but no target at all",
      commandLine: "/opt/homebrew/bin/tmux -C attach", expected: false)
check("-t present but nothing after it",
      commandLine: "/opt/homebrew/bin/tmux -C attach -t", expected: false)

print("— must not reclaim: argv identical to ours, different process (REVIEW) —")
// A second copy of this app spawns exactly our command line against exactly our
// session ids. Only the start time can tell its live child from our dead one.
check("REVIEW pid reused by ANOTHER instance's live child, same session",
      startedAt: "Thu_Jul_30_09:12:01_2026", parentPID: 1, expected: false)
check("REVIEW same, and it is still parented to that live instance",
      startedAt: "Thu_Jul_30_09:12:01_2026", parentPID: 4242, expected: false)
// `-t '$34'` typed by a person puts the literal token `$34` in argv, so `ps`
// shows something indistinguishable from ours.
check("REVIEW a human's own tmux -C attach -t '$34', started later",
      startedAt: "Thu_Jul_30_06:00:00_2026", expected: false)
check("start time unknown but everything else matches",
      startedAt: "", expected: false)
check("PPID is not 1, so it is not an orphan", parentPID: 900, expected: false)

print("— must not reclaim: somebody else's control client —")
check("iTerm2's tmux integration (-CC, not -C)",
      commandLine: "/opt/homebrew/bin/tmux -CC attach -t $34", expected: false)
check("a tmux server, not a client",
      commandLine: "tmux: server (/private/tmp/tmux-501/default)", expected: false)
check("something merely named like tmux",
      commandLine: "/usr/local/bin/tmuxinator -C attach -t $34", expected: false)

print("— the start-time form is stable —")
for (raw, want) in [
    ("Thu Jul 30 07:04:30 2026", "Thu_Jul_30_07:04:30_2026"),
    ("  Thu Jul 30 07:04:30 2026\n", "Thu_Jul_30_07:04:30_2026"),
    ("Thu  Jul   30 07:04:30 2026", "Thu_Jul_30_07:04:30_2026"),
] {
    let got = TmuxChildRecord.normalizeStart(raw)
    if got == want {
        print("  ok    normalises \(raw.trimmingCharacters(in: .whitespacesAndNewlines))")
    } else {
        print("  FAIL  normalise: expected \(want), got \(got)")
        failures += 1
    }
}

// The v2 records: an exact command line, byte-compared. The ssh children are
// why — their argv defeats every clause of the shape test: argv[0] is `ssh`,
// `-C` doubles as ssh's compression flag, and the token after ssh's own `-t`
// is a hostname. The cases below hold the gates that must still gate.
print("— v2 records: exact command line —")
let sshCommand = "/usr/bin/ssh -T -o BatchMode=yes -o ControlMaster=no"
    + " -o ControlPath=/Users/me/.config/attache/ssh/mini -o ConnectTimeout=5"
    + " -- me@192.168.1.20 '/opt/homebrew/bin/tmux' '-L' 'attache-test' '-C' 'attach' '-t' '$0'"
let v2 = TmuxChildRecord(
    ownerPID: 999, childPID: 1234, startedAt: recordedStart, sessionID: "$0",
    commandLine: sshCommand
)
func checkV2(_ name: String, ownerIsAlive: Bool = false, commandLine: String = sshCommand,
             startedAt: String = recordedStart, parentPID: Int32 = 1, expected: Bool)
{
    let facts = TmuxChildRecord.ChildFacts(
        commandLine: commandLine, startedAt: startedAt, parentPID: parentPID
    )
    let got = v2.shouldReclaim(ownerIsAlive: ownerIsAlive, child: facts)
    if got == expected {
        print("  ok    \(name)")
    } else {
        print("  FAIL  \(name) — expected \(expected), got \(got)")
        failures += 1
    }
}
checkV2("an orphaned ssh control client with the exact recorded argv", expected: true)
checkV2("owner still alive", ownerIsAlive: true, expected: false)
checkV2("started at a different time (reused pid)",
        startedAt: "Thu_Jul_31_08:00:00_2026", expected: false)
checkV2("not an orphan", parentPID: 812, expected: false)
checkV2("same shape, different socket — someone else's connection",
        commandLine: sshCommand.replacingOccurrences(of: "attache-test", with: "work"),
        expected: false)
checkV2("an unrelated ssh -C that would fool a loosened shape test",
        commandLine: "/usr/bin/ssh -C me@192.168.1.20 -t attach.example.org tmux",
        expected: false)

if TmuxChildRecord.parse(line: v2.line) == v2 {
    print("  ok    a v2 line with spaces in the command round-trips")
} else {
    print("  FAIL  a v2 line with spaces in the command round-trips")
    failures += 1
}

print("— the file format round-trips —")
let entry = TmuxChildRecord(
    ownerPID: 42, childPID: 4242, startedAt: recordedStart, sessionID: "$7",
    commandLine: nil
)
if TmuxChildRecord.parse(line: entry.line) == entry {
    print("  ok    a written line parses back to the same record")
} else {
    print("  FAIL  a written line parses back to the same record")
    failures += 1
}
for bad in [
    "", "42", "42 4242", "42 4242 \(recordedStart)",
    // "…$7 extra" is deliberately NOT here any more: a fifth field is the
    // v2 format's command line, checked in its own section above.
    "x 4242 \(recordedStart) $7",
    // Three fields is the *old* format. It must be rejected rather than
    // half-read: a record without a start time cannot be judged safely.
    "42 4242 $7",
] {
    if TmuxChildRecord.parse(line: bad) == nil {
        print("  ok    rejects malformed line: \(bad.isEmpty ? "<empty>" : bad)")
    } else {
        print("  FAIL  accepted malformed line: \(bad)")
        failures += 1
    }
}

print(failures == 0 ? "\nChildRegistryCheck: all passed" : "\nChildRegistryCheck: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
