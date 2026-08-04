//
//  TmuxChildRecord.swift
//  Attache
//

import Foundation

/// One `tmux -C attach` child this app spawned, and the rule for whether a
/// later run may kill it.
///
/// Split from `TmuxChildRegistry` for the reason `StatusLineRecovery` and
/// `TerminalReply` are their own files: this is the half whose failure is
/// silent and unrecoverable — a wrong answer here kills a process that belongs
/// to somebody else — so it is pure, imports nothing but Foundation, and
/// `Tools/ChildRegistryCheck` runs it against a table of real cases.
struct TmuxChildRecord: Equatable {
    /// The run that spawned the child. Two copies of this app can be running,
    /// and the second one's sweep must not collect the first one's children.
    let ownerPID: Int32
    let childPID: Int32
    /// When the child started, to the second, exactly as `ps -o lstart=` prints
    /// it — spaces collapsed to `_` so the record stays one space-separated
    /// line.
    ///
    /// **A pid is not an identity and this is what makes one.** See
    /// `shouldReclaim`: the command line alone cannot tell our dead child's
    /// reused pid from a *live* child of a second copy of this app, because both
    /// spawn byte-identical command lines against the same session ids. Pid plus
    /// start time can, because the pair is never reused.
    let startedAt: String
    /// The session id the child attached to — `$34`. For a child that is not
    /// a control client (the ssh master), a label like `ssh-master`.
    let sessionID: String

    /// The exact command line this app spawned, as `ps -o command=` prints it
    /// back. New records carry it; records from builds before ssh support do
    /// not, and fall back to the shape test in `shouldReclaim`. It exists
    /// because the shape test cannot survive ssh: `argv[0]` is `ssh`, `-C` is
    /// also ssh's compression flag, and the token after ssh's `-t` is a
    /// hostname — every clause either fails or, loosened, starts matching
    /// processes that are not ours. Byte equality has neither problem.
    let commandLine: String?

    /// `<owner> <child> <started> <session> [<command line…>]` — one line,
    /// hand-readable on purpose. After an incident this file is evidence, and
    /// evidence that needs a parser is evidence nobody reads. The command
    /// line is last because it is the one field that contains spaces.
    var line: String {
        "\(ownerPID) \(childPID) \(startedAt) \(sessionID)"
            + (commandLine.map { " \($0)" } ?? "")
    }

    static func parse(line: String) -> TmuxChildRecord? {
        let fields = line.split(separator: " ", maxSplits: 4)
        guard fields.count >= 4,
              let owner = Int32(fields[0]),
              let child = Int32(fields[1]),
              !fields[2].isEmpty, !fields[3].isEmpty
        else { return nil }
        return TmuxChildRecord(
            ownerPID: owner, childPID: child,
            startedAt: String(fields[2]), sessionID: String(fields[3]),
            commandLine: fields.count == 5 ? String(fields[4]) : nil
        )
    }

    /// What a live pid looks like right now, as far as this decision cares.
    /// Nil for any field that could not be read — and unreadable has to mean
    /// "do not kill", which nil already says.
    struct ChildFacts: Equatable {
        let commandLine: String
        /// Same form as `startedAt`.
        let startedAt: String
        let parentPID: Int32
    }

    /// Whether this record names a process this app may kill.
    ///
    /// Five things must hold, and each one closes a different way of being
    /// wrong. Four of them were in the first version; the start-time test was
    /// added after review found the hole it closes.
    ///
    /// 1. **The owning run is gone.** A live owner is still using its child.
    /// 2. **The facts are readable.** No command line, no kill.
    /// 3. **The command line is still the control client recorded**: `tmux`
    ///    (by whole path component, so `tmuxinator` cannot pass), in control
    ///    mode by the exact token `-C` (so iTerm2's `-CC` cannot), `attach`, and
    ///    the token after `-t` equal to *this* session id.
    /// 4. **The start time matches.** The command-line test defeats every
    ///    foreign process but not a second copy of *this app*: instance B's live
    ///    connection to `$2` has a command line identical to instance A's dead
    ///    one, so if A's recorded pid is later reused by B's child, everything
    ///    above passes and the kill lands on a live connection. It needs a pid
    ///    wrap while a stale record survives, which is rare and not impossible.
    ///    Pid plus start time is never reused, so comparing it closes the case
    ///    outright — and with it the other pid-reuse variant, a human's own
    ///    `tmux -C attach -t '$34'`, whose argv is indistinguishable from ours.
    /// 5. **The process is an orphan** — `PPID 1`. A child whose parent is still
    ///    alive is by definition not ours to collect, and on macOS a real orphan
    ///    is reparented to launchd. Redundant with (4) rather than load-bearing,
    ///    and kept because it is the thing actually meant: only orphans.
    func shouldReclaim(ownerIsAlive: Bool, child: ChildFacts?) -> Bool {
        guard !ownerIsAlive, let child else { return false }
        guard child.startedAt == startedAt else { return false }
        guard child.parentPID == 1 else { return false }

        // A record that knows its exact command line compares bytes and is
        // done — the only test that works for the ssh children, whose argv
        // defeats every clause of the shape test below (see `commandLine`).
        // Start time and orphanhood still gate above: the byte-identical
        // command of a second running copy of this app fails on those.
        if let commandLine {
            return child.commandLine == commandLine
        }

        let tokens = child.commandLine.split(separator: " ").map(String.init)
        guard tokens.contains("-C"), tokens.contains("attach") else { return false }
        guard let executable = tokens.first,
              executable.split(separator: "/").last == "tmux"
        else { return false }
        guard let target = tokens.firstIndex(of: "-t").map({ $0 + 1 }),
              target < tokens.count, tokens[target] == sessionID
        else { return false }
        return true
    }

    /// `ps -o lstart=` prints `Thu Jul 30 07:04:30 2026`. Spaces would break a
    /// space-separated line, so they collapse to `_`; the value is only ever
    /// compared to itself, never parsed back into a date.
    static func normalizeStart(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "_")
    }
}
