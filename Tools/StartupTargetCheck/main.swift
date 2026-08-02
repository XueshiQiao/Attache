//
//  main.swift
//  StartupTargetCheck
//
//      swiftc -O -o /tmp/startupcheck \
//          Attache/Tmux/StartupTarget.swift Tools/StartupTargetCheck/main.swift
//      /tmp/startupcheck
//
//  This decides which session the app opens on, from a name the person typed
//  into a text file. Both directions matter: failing to match a session they
//  named leaves the app somewhere they did not ask for, and matching the
//  *wrong* one silently sends them to another project's windows.
//
//  The names below are the ones actually on this machine, including the
//  `Attaché` / `Attache` pair that CLAUDE.md warns is not interchangeable.
//

import Foundation

var failures = 0

func check(_ what: String, _ actual: String?, _ expected: String?) {
    guard actual != expected else { return }
    failures += 1
    print("FAIL  \(what)")
    print("      expected \(expected ?? "nil"), actual \(actual ?? "nil")")
}

let sessions: [(id: String, name: String)] = [
    ("$34", "_lazygit"),
    ("$4", "dev"),
    ("$7", "side"),
]

let windows: [(id: String, name: String)] = [
    ("@119", "Attache"),
    ("@8", "XTools"),
    ("@13", "dotfiles"),
    ("@2", "zsh"),
]

// MARK: - Ordinary matches

check("exact session name", StartupTarget.id(matching: "dev", in: sessions), "$4")
check("exact window name", StartupTarget.id(matching: "Attache", in: windows), "@119")
check("leading underscore is not special", StartupTarget.id(matching: "_lazygit", in: sessions), "$34")

// MARK: - Forgiving in the two ways a person actually types

check("case does not matter", StartupTarget.id(matching: "DEV", in: sessions), "$4")
check("case does not matter, window", StartupTarget.id(matching: "attache", in: windows), "@119")
check(
    "REGRESSION an accent typed from memory still matches — the app is Attaché, the window is Attache",
    StartupTarget.id(matching: "Attaché", in: windows), "@119"
)
check("surrounding whitespace is trimmed", StartupTarget.id(matching: "  dev  ", in: sessions), "$4")

// MARK: - No match falls back rather than guessing

check("a name that is not there", StartupTarget.id(matching: "nope", in: sessions), nil)
check("empty means unset", StartupTarget.id(matching: "", in: sessions), nil)
check("whitespace only means unset", StartupTarget.id(matching: "   ", in: sessions), nil)
check("no candidates at all", StartupTarget.id(matching: "dev", in: []), nil)
check("a prefix is not a match", StartupTarget.id(matching: "de", in: sessions), nil)
check("a superstring is not a match", StartupTarget.id(matching: "development", in: sessions), nil)

// MARK: - Ambiguity resolves to nothing
//
// Found by review 2026-08-02. Taking the first of several matches looks
// helpful and hides the problem: this machine has several windows called
// `zsh`, so `startup_window = "zsh"` would silently mean "the first one" with
// no way to ask for any other.

do {
    let manyZsh: [(id: String, name: String)] = [
        ("@2", "zsh"), ("@9", "editor"), ("@14", "zsh"), ("@21", "zsh"),
    ]
    check("REGRESSION three windows named zsh match nothing", StartupTarget.id(matching: "zsh", in: manyZsh), nil)
    check("a unique name beside them still works", StartupTarget.id(matching: "editor", in: manyZsh), "@9")
    if StartupTarget.miss(matching: "zsh", in: manyZsh) != .ambiguous(count: 3) {
        failures += 1
        print("FAIL  应报告为「有 3 个同名」，好让日志说清是重名而不是拼错")
    }
    if StartupTarget.miss(matching: "nope", in: manyZsh) != .noMatch {
        failures += 1
        print("FAIL  找不到应报告 noMatch")
    }
}

do {
    // Only differing by case: no exact match exists, and folding makes both
    // candidates equal, so there is no defensible pick.
    let bothCases: [(id: String, name: String)] = [("$1", "Dev"), ("$2", "dev")]
    check(
        "REGRESSION DEV against both Dev and dev is ambiguous",
        StartupTarget.id(matching: "DEV", in: bothCases), nil
    )
}

// MARK: - Exact beats folded
//
// Someone with both `dev` and `Dev` typed one of them on purpose.

do {
    let both: [(id: String, name: String)] = [("$1", "Dev"), ("$2", "dev")]
    check("exact wins over case-folded", StartupTarget.id(matching: "dev", in: both), "$2")
    check("and the other way round", StartupTarget.id(matching: "Dev", in: both), "$1")
}

// MARK: - A name is compared, never executed
//
// The whole reason CLAUDE.md forbids targeting tmux by name. A session called
// something shell-shaped must be matched or not matched and nothing else.

do {
    let hostile: [(id: String, name: String)] = [
        ("$9", "; kill-server #"),
        ("$4", "dev"),
    ]
    check(
        "a shell-shaped name still just matches",
        StartupTarget.id(matching: "; kill-server #", in: hostile), "$9"
    )
    check("and does not affect other lookups", StartupTarget.id(matching: "dev", in: hostile), "$4")
}

if failures == 0 {
    print("StartupTargetCheck: all cases pass")
} else {
    print("StartupTargetCheck: \(failures) failed")
    exit(1)
}
