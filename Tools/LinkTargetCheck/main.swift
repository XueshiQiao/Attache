//
//  main.swift
//  LinkTargetCheck
//
//  Cross-check for `TerminalLinkTarget`, in the same spirit as
//  `Tools/RenameStringCheck`.
//
//      swiftc -O -o /tmp/linktargetcheck \
//          TmuxGUI/UI/TerminalLinkTarget.swift Tools/LinkTargetCheck/main.swift
//      /tmp/linktargetcheck
//
//  This file decides what a ⌘-click on the terminal actually opens. libghostty
//  draws the underline and it matches on *shape alone* — it never asks the disk
//  whether the file is there — so everything between "the user clicked" and
//  "something opened" is here, and a mistake here opens the wrong thing on the
//  user's machine. The two directions fail differently: refusing a real path is
//  a click that does nothing, while accepting the wrong string hands an
//  arbitrary run of screen text to the system opener. The second is the one to
//  keep out, which is why schemes are an allow-list.
//
//  The file system is injected, so every case below runs with no disk and no
//  screen and the answers do not depend on the machine running them.
//

import Foundation

let home = "/Users/tester"

typealias Existence = TerminalLinkTarget.Existence

struct Case {
    let name: String
    let raw: String
    var cwd: String? = nil
    var fs: [String: Existence] = [:]
    let expect: TerminalLinkTarget
    /// Paths the resolver is expected to ask about, when the point of the case
    /// is *what* got looked up rather than what came back.
    var probed: [String]? = nil
}

func url(_ text: String) -> TerminalLinkTarget { .url(URL(string: text)!) }

let cases: [Case] = [
    // MARK: - Absolute paths

    Case(
        name: "absolute file",
        raw: "/Users/tester/Code/a.swift",
        fs: ["/Users/tester/Code/a.swift": .file],
        expect: .file("/Users/tester/Code/a.swift")
    ),
    Case(
        name: "absolute directory",
        raw: "/Users/tester/Code",
        fs: ["/Users/tester/Code": .directory],
        expect: .directory("/Users/tester/Code")
    ),
    Case(
        name: "absolute path that is not there is reported, not ignored",
        raw: "/Users/tester/gone.txt",
        expect: .missing("/Users/tester/gone.txt")
    ),

    // MARK: - Home

    Case(
        name: "tilde slash expands",
        raw: "~/Downloads/a.png",
        fs: ["/Users/tester/Downloads/a.png": .file],
        expect: .file("/Users/tester/Downloads/a.png")
    ),
    Case(
        name: "bare tilde is the home directory",
        raw: "~",
        fs: [home: .directory],
        expect: .directory(home)
    ),
    Case(
        // Another user's home. Guessing at where it lives is worse than not
        // acting, so this stays unsupported rather than becoming `/Users/root`.
        name: "tilde user is not guessed at",
        raw: "~root/.ssh",
        expect: .unsupported
    ),

    // MARK: - Relative paths need the pane's directory

    Case(
        name: "relative path resolves against the pane cwd",
        raw: "src/main.swift",
        cwd: "/Users/tester/Code/proj",
        fs: ["/Users/tester/Code/proj/src/main.swift": .file],
        expect: .file("/Users/tester/Code/proj/src/main.swift")
    ),
    Case(
        name: "dot-relative path resolves against the pane cwd",
        raw: "./Package.swift",
        cwd: "/Users/tester/Code/proj",
        fs: ["/Users/tester/Code/proj/Package.swift": .file],
        expect: .file("/Users/tester/Code/proj/Package.swift")
    ),
    Case(
        name: "parent-relative path collapses without touching the disk",
        raw: "../sibling/x.txt",
        cwd: "/Users/tester/Code/proj",
        fs: ["/Users/tester/Code/sibling/x.txt": .file],
        expect: .file("/Users/tester/Code/sibling/x.txt")
    ),
    Case(
        // The app's own working directory is never the one the user was
        // looking at, so a relative path with no pane to resolve against must
        // not fall back to it.
        name: "relative path with no cwd is not guessed against the app's own",
        raw: "src/main.swift",
        cwd: nil,
        expect: .unsupported
    ),
    Case(
        name: "trailing slash on the cwd does not double up",
        raw: "notes.md",
        cwd: "/Users/tester/",
        fs: ["/Users/tester/notes.md": .file],
        expect: .file("/Users/tester/notes.md")
    ),

    // MARK: - Schemes

    Case(name: "https goes to the opener", raw: "https://example.com/a", expect: url("https://example.com/a")),
    Case(name: "http goes to the opener", raw: "http://example.com", expect: url("http://example.com")),
    Case(name: "mailto goes to the opener", raw: "mailto:someone@example.com", expect: url("mailto:someone@example.com")),
    Case(
        name: "file: is a local path wearing a scheme",
        raw: "file:///Users/tester/Code/a.swift",
        fs: ["/Users/tester/Code/a.swift": .file],
        expect: .file("/Users/tester/Code/a.swift")
    ),
    Case(
        // Not on the allow-list. A click must not be able to reach an arbitrary
        // registered handler just because the screen held its scheme.
        name: "unknown scheme is refused",
        raw: "zoommtg://zoom.us/join?confno=1",
        expect: .unsupported
    ),
    Case(
        name: "javascript scheme is refused",
        raw: "javascript:alert(1)",
        expect: .unsupported
    ),

    // MARK: - What prose puts around a path

    Case(
        name: "wrapping parens come off",
        raw: "(/Users/tester/a.txt)",
        fs: ["/Users/tester/a.txt": .file],
        expect: .file("/Users/tester/a.txt")
    ),
    Case(
        // The opener is only dropped when the text has no matching one, so a
        // filename that really contains brackets survives.
        name: "brackets that belong to the filename stay",
        raw: "/Users/tester/a(1).txt",
        fs: ["/Users/tester/a(1).txt": .file],
        expect: .file("/Users/tester/a(1).txt")
    ),
    Case(
        name: "a full stop ending a sentence comes off",
        raw: "/Users/tester/a.txt.",
        fs: ["/Users/tester/a.txt": .file],
        expect: .file("/Users/tester/a.txt")
    ),
    Case(
        name: "a comma ending a list item comes off",
        raw: "/Users/tester/a.txt,",
        fs: ["/Users/tester/a.txt": .file],
        expect: .file("/Users/tester/a.txt")
    ),
    Case(
        name: "trailing whitespace comes off",
        raw: "  /Users/tester/a.txt  ",
        fs: ["/Users/tester/a.txt": .file],
        expect: .file("/Users/tester/a.txt")
    ),
    Case(
        name: "a path with a space in it is kept whole",
        raw: "/Users/tester/My Notes/a.txt",
        fs: ["/Users/tester/My Notes/a.txt": .file],
        expect: .file("/Users/tester/My Notes/a.txt")
    ),

    // MARK: - A command line is not a path, but the matcher cannot tell

    // libghostty allows spaces inside a path so that "My Notes" works, which
    // means a whole shell command line matches too. These pin the recovery:
    // trim a word at a time from the right, and only ever answer with a prefix
    // that exists.

    Case(
        name: "a shell command line falls back to the directory it starts with",
        raw: "/Users/tester/Code/proj && xcodebuild -project X.xcodeproj -scheme X",
        fs: ["/Users/tester/Code/proj": .directory],
        expect: .directory("/Users/tester/Code/proj")
    ),
    Case(
        name: "trailing prose comes off a word at a time",
        raw: "/Users/tester/Code/proj for details",
        fs: ["/Users/tester/Code/proj": .directory],
        expect: .directory("/Users/tester/Code/proj")
    ),
    Case(
        // The case the spaces are allowed *for*. The whole thing is there, so
        // nothing is trimmed.
        name: "a real path containing spaces is never trimmed",
        raw: "/Users/tester/My Notes/todo.txt",
        fs: ["/Users/tester/My Notes/todo.txt": .file],
        expect: .file("/Users/tester/My Notes/todo.txt")
    ),
    Case(
        // Both exist. The whole match has to win, or a directory called "My"
        // would swallow every path under it that has a space.
        name: "the whole match wins over a shorter prefix that also exists",
        raw: "/Users/tester/My Notes/todo.txt",
        fs: [
            "/Users/tester/My Notes/todo.txt": .file,
            "/Users/tester/My": .directory,
        ],
        expect: .file("/Users/tester/My Notes/todo.txt")
    ),
    Case(
        name: "the longest existing prefix wins, not the shortest",
        raw: "/Users/tester/a/b/c one two",
        fs: [
            "/Users/tester/a/b/c one": .directory,
            "/Users/tester/a/b/c": .directory,
        ],
        expect: .directory("/Users/tester/a/b/c one")
    ),
    Case(
        name: "the recovered prefix can be a file rather than a directory",
        raw: "/Users/tester/a.txt and then some",
        fs: ["/Users/tester/a.txt": .file],
        expect: .file("/Users/tester/a.txt")
    ),
    Case(
        name: "a relative match is trimmed the same way",
        raw: "src/main.swift and more",
        cwd: "/Users/tester/proj",
        fs: ["/Users/tester/proj/src/main.swift": .file],
        expect: .file("/Users/tester/proj/src/main.swift")
    ),
    Case(
        // Nothing at any length. The whole match is what gets reported, so the
        // message names what was actually clicked.
        name: "nothing exists at any length, so the whole match is reported",
        raw: "/Users/tester/nope && ls",
        expect: .missing("/Users/tester/nope && ls")
    ),

    // MARK: - Things that look like schemes and are not

    Case(
        // A grep result. The colon must not read as a scheme separator, or the
        // whole line becomes an unknown scheme and the click does nothing.
        name: "grep-style line suffix does not read as a scheme",
        raw: "/Users/tester/notes.md:42",
        expect: .missing("/Users/tester/notes.md:42"),
        probed: ["/Users/tester/notes.md:42"]
    ),
    Case(
        name: "empty string",
        raw: "",
        expect: .unsupported
    ),
    Case(
        name: "whitespace only",
        raw: "   ",
        expect: .unsupported
    ),
]

// MARK: - Run

var failures = 0
var probeFailures = 0

for testCase in cases {
    var asked: [String] = []
    let actual = TerminalLinkTarget.resolve(
        testCase.raw,
        cwd: testCase.cwd,
        home: home,
        existence: { path in
            asked.append(path)
            return testCase.fs[path] ?? .absent
        }
    )
    if actual != testCase.expect {
        failures += 1
        print("FAIL  \(testCase.name)")
        print("      input    \(testCase.raw.debugDescription) cwd=\(testCase.cwd ?? "nil")")
        print("      expected \(testCase.expect)")
        print("      actual   \(actual)")
    }
    if let probed = testCase.probed, asked != probed {
        probeFailures += 1
        print("FAIL  \(testCase.name) — looked up the wrong path")
        print("      expected \(probed)")
        print("      actual   \(asked)")
    }
}

let total = cases.count
if failures == 0, probeFailures == 0 {
    print("LinkTargetCheck: \(total) cases, all pass")
} else {
    print("LinkTargetCheck: \(failures + probeFailures) failed out of \(total)")
    exit(1)
}
