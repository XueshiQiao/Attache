//
//  main.swift
//  GitStatusCheck
//
//  Checks `GitStatus.parse` against captured `git status --porcelain=v2
//  --branch` output. Same shape as ReplyCheck and LayoutCheck: cases in a
//  table, a non-zero exit if any of them fails.
//
//  Every defect this parser can have is a misread status code, and a status
//  code is exactly what a fixture pins down. The half that matters most is the
//  staged/modified pair: they come from two characters in the same field, and
//  swapping them makes every row in the rail wrong in a way that looks
//  plausible.
//
//  swiftc -O -o /tmp/gitstatuscheck TmuxGUI/Status/GitStatus.swift \
//      Tools/GitStatusCheck/main.swift && /tmp/gitstatuscheck
//

import Foundation

private struct Case {
    let name: String
    let input: String
    let check: (GitSummary) -> String?
}

private func expect(
    _ label: String, _ actual: some Equatable, _ wanted: some Equatable
) -> String? {
    "\(actual)" == "\(wanted)" ? nil : "\(label): got \(actual), wanted \(wanted)"
}

private let epoch = Date(timeIntervalSince1970: 0)

private let cases: [Case] = [
    Case(
        name: "clean branch with upstream, nothing to push",
        input: """
        # branch.oid 0d2e81ee008fed90ad5972c1889e46af2c406500
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        """,
        check: { s in
            expect("branch", s.branch ?? "nil", "main")
                ?? expect("hasUpstream", s.hasUpstream, true)
                ?? expect("ahead", s.ahead, 0)
                ?? expect("behind", s.behind, 0)
                ?? expect("isClean", s.isClean, true)
        }
    ),

    Case(
        name: "ahead and behind are both read, and the signs are not part of the numbers",
        input: """
        # branch.oid abc1234
        # branch.head feature/thing
        # branch.upstream origin/feature/thing
        # branch.ab +12 -3
        """,
        check: { s in
            expect("ahead", s.ahead, 12) ?? expect("behind", s.behind, 3)
        }
    ),

    Case(
        name: "no upstream at all — not the same thing as +0 -0",
        input: """
        # branch.oid abc1234
        # branch.head local-only
        """,
        check: { s in
            expect("hasUpstream", s.hasUpstream, false)
                ?? expect("ahead", s.ahead, 0)
                ?? expect("behind", s.behind, 0)
                ?? expect("branch", s.branch ?? "nil", "local-only")
        }
    ),

    Case(
        name: "detached HEAD has no branch and keeps a short oid",
        input: """
        # branch.oid 0d2e81ee008fed90ad5972c1889e46af2c406500
        # branch.head (detached)
        """,
        check: { s in
            expect("branch is nil", s.branch == nil, true)
                ?? expect("detachedAt", s.detachedAt ?? "nil", "0d2e81e")
                ?? expect("displayRef", s.displayRef, "detached at 0d2e81e")
        }
    ),

    Case(
        name: "staged and modified come from the two halves of XY, in that order",
        input: """
        # branch.oid abc1234
        # branch.head main
        1 M. N... 100644 100644 100644 aaa bbb staged-only.txt
        1 .M N... 100644 100644 100644 aaa bbb modified-only.txt
        1 MM N... 100644 100644 100644 aaa bbb both.txt
        1 A. N... 000000 100644 100644 aaa bbb added.txt
        1 D. N... 100644 000000 000000 aaa bbb deleted-staged.txt
        1 .D N... 100644 100644 000000 aaa bbb deleted-worktree.txt
        """,
        check: { s in
            // staged: M., MM, A., D.  = 4
            // modified: .M, MM, .D    = 3
            expect("staged", s.staged, 4) ?? expect("modified", s.modified, 3)
        }
    ),

    Case(
        name: "a rename is one path, and its extra fields do not shift the status",
        input: """
        # branch.oid abc1234
        # branch.head main
        2 R. N... 100644 100644 100644 aaa bbb R100 new-name.txt\told-name.txt
        2 .R N... 100644 100644 100644 aaa bbb R096 other-new.txt\tother-old.txt
        """,
        check: { s in
            expect("staged", s.staged, 1)
                ?? expect("modified", s.modified, 1)
                ?? expect("untracked", s.untracked, 0)
        }
    ),

    Case(
        name: "untracked is counted but kept apart from the changed counts",
        input: """
        # branch.oid abc1234
        # branch.head main
        ? node_modules/a.js
        ? node_modules/b.js
        ? notes.md
        """,
        check: { s in
            expect("untracked", s.untracked, 3)
                ?? expect("staged", s.staged, 0)
                ?? expect("modified", s.modified, 0)
                // A tree with only untracked files is not clean, and a row that
                // drew a tick over three unadded files would be lying.
                ?? expect("isClean", s.isClean, false)
        }
    ),

    Case(
        name: "a conflicted merge is its own count, not a modification",
        input: """
        # branch.oid abc1234
        # branch.head main
        u UU N... 100644 100644 100644 100644 aaa bbb ccc conflicted.txt
        1 .M N... 100644 100644 100644 aaa bbb ordinary.txt
        """,
        check: { s in
            expect("conflicted", s.conflicted, 1)
                ?? expect("modified", s.modified, 1)
                ?? expect("staged", s.staged, 0)
        }
    ),

    Case(
        name: "an ignored line is not counted as anything",
        input: """
        # branch.oid abc1234
        # branch.head main
        ! build/output.o
        ! .DS_Store
        """,
        check: { s in
            expect("untracked", s.untracked, 0)
                ?? expect("staged", s.staged, 0)
                ?? expect("isClean", s.isClean, true)
        }
    ),

    Case(
        name: "a path containing spaces does not break the status field",
        input: """
        # branch.oid abc1234
        # branch.head main
        1 .M N... 100644 100644 100644 aaa bbb some file with spaces.txt
        ? another untracked file.md
        """,
        check: { s in
            expect("modified", s.modified, 1) ?? expect("untracked", s.untracked, 1)
        }
    ),

    Case(
        name: "a branch name containing a slash survives whole",
        input: """
        # branch.oid abc1234
        # branch.head release/2.4.1
        # branch.upstream origin/release/2.4.1
        # branch.ab +0 -2
        """,
        check: { s in
            expect("branch", s.branch ?? "nil", "release/2.4.1")
                ?? expect("behind", s.behind, 2)
        }
    ),

    Case(
        name: "an unborn branch has no oid to show",
        input: """
        # branch.oid (initial)
        # branch.head main
        """,
        check: { s in
            expect("detachedAt is nil", s.detachedAt == nil, true)
                ?? expect("branch", s.branch ?? "nil", "main")
                // Still a branch, so the row draws the name and not the oid.
                ?? expect("displayRef", s.displayRef, "main")
        }
    ),

    Case(
        name: "empty output parses to a clean unborn repo rather than crashing",
        input: "",
        check: { s in
            expect("isClean", s.isClean, true) ?? expect("displayRef", s.displayRef, "—")
        }
    ),
]

// MARK: - Run

var failures = 0
for testCase in cases {
    let summary = GitStatus.parse(porcelainV2: testCase.input, readAt: epoch, lastFetch: nil)
    if let problem = testCase.check(summary) {
        failures += 1
        print("FAIL  \(testCase.name)")
        print("      \(problem)")
    } else {
        print("ok    \(testCase.name)")
    }
}

print("")
if failures == 0 {
    print("\(cases.count) cases, all passed")
} else {
    print("\(failures) of \(cases.count) cases FAILED")
    exit(1)
}
