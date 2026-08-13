//
//  main.swift
//  TerminfoCheck
//
//  Cross-check for `GhosttyTerminfo`, in the same spirit as
//  `Tools/LinkTargetCheck`.
//
//      swiftc -O -o /tmp/terminfocheck \
//          Attache/UI/GhosttyTerminfo.swift Tools/TerminfoCheck/main.swift
//      /tmp/terminfocheck
//
//  This file decides what `TERM` the program in a pane is told it is talking
//  to, and the two ways of being wrong are not symmetrical. Leaving
//  `xterm-ghostty` in place when nothing can look it up is a pane that never
//  attaches — tmux prints one line and exits, and the rail goes on working, so
//  the app reads as alive with dead panes in it. Pinning `xterm-256color` when
//  the real entry was there is a terminal with fewer capabilities and nothing
//  else. So the cases below care most about the first: a directory that is
//  named and empty must always come back with the fallback.
//
//  The file system is injected, so every case runs with no disk and the
//  answers do not depend on the machine running them.
//

import Foundation

let ghosttyResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
/// What Ghostty.app really ships, measured 2026-08-09:
/// `/Applications/Ghostty.app/Contents/Resources/terminfo/78/xterm-ghostty`.
let shippedEntry = "/Applications/Ghostty.app/Contents/Resources/terminfo/78/xterm-ghostty"

struct Case {
    let name: String
    let resources: String?
    /// Files that exist on this fixture's disk.
    var files: Set<String> = []
    let expect: GhosttyTerminfo.Decision
}

func pin(_ missingFrom: String) -> GhosttyTerminfo.Decision {
    GhosttyTerminfo.Decision(term: GhosttyTerminfo.fallbackTerm, missingFrom: missingFrom)
}

let cases: [Case] = [
    // MARK: - The healthy machine

    Case(
        name: "Ghostty installed where the variable says, hex bucket",
        resources: ghosttyResources,
        files: [shippedEntry],
        expect: .leaveAlone
    ),
    Case(
        name: "entry written by tic into the letter bucket",
        resources: ghosttyResources,
        files: ["/Applications/Ghostty.app/Contents/Resources/terminfo/x/xterm-ghostty"],
        expect: .leaveAlone
    ),
    // The case an earlier draft got wrong, kept as the record of why. An
    // entry sitting somewhere libghostty does not export must NOT certify the
    // directory it does export: a stale or half-finished copy in that spot
    // would leave `xterm-ghostty` selected with `TERMINFO` pointed at nothing,
    // which is the dead pane this file exists to prevent.
    Case(
        name: "an entry nested inside the resources directory certifies nothing",
        resources: ghosttyResources,
        files: [
            "/Applications/Ghostty.app/Contents/Resources/ghostty/terminfo/78/xterm-ghostty",
        ],
        expect: pin("/Applications/Ghostty.app/Contents/Resources/terminfo")
    ),

    // MARK: - The defect this file exists for

    Case(
        name: "Ghostty uninstalled, variable still names it",
        resources: ghosttyResources,
        files: [],
        expect: pin("/Applications/Ghostty.app/Contents/Resources/terminfo")
    ),
    Case(
        name: "Ghostty moved to a new directory",
        resources: "/Users/joey/Applications/Ghostty.app/Contents/Resources/ghostty",
        files: [shippedEntry],
        expect: pin("/Users/joey/Applications/Ghostty.app/Contents/Resources/terminfo")
    ),
    Case(
        name: "terminfo directory is there but holds only other terminals",
        resources: ghosttyResources,
        files: [
            "/Applications/Ghostty.app/Contents/Resources/terminfo/78/xterm-256color",
            "/Applications/Ghostty.app/Contents/Resources/terminfo/74/tmux-256color",
        ],
        expect: pin("/Applications/Ghostty.app/Contents/Resources/terminfo")
    ),

    // MARK: - Nothing useful in the variable
    //
    // Absent is a Finder launch, and libghostty picks `xterm-256color` itself
    // there — so there is nothing to pin and, just as important, nothing to
    // tell anyone about: `missingFrom` stays nil so an ordinary launch cannot
    // raise a notice. Present-and-empty takes the same branch, and that was
    // measured rather than assumed to follow: launched with
    // `GHOSTTY_RESOURCES_DIR=` and no `TERMINFO`, the surface's child had
    // `TERM=xterm-256color` and the attach succeeded.
    //
    // Whitespace is deliberately *not* in that group. It is a real path to
    // anything reading the variable, nothing measured says libghostty treats
    // it as absent, and reading it as absent because it looks empty to a
    // human is a guess — so it goes down the validate-and-pin road like any
    // other value.

    Case(name: "variable absent", resources: nil, expect: .leaveAlone),
    Case(name: "variable present and empty", resources: "", expect: .leaveAlone),
    Case(name: "variable is whitespace — a path, not an absence", resources: "   ",
         expect: pin("/terminfo")),

    // MARK: - Shapes the variable can arrive in

    Case(
        name: "trailing slash",
        resources: ghosttyResources + "/",
        files: [shippedEntry],
        expect: .leaveAlone
    ),
    Case(
        name: "several trailing slashes",
        resources: ghosttyResources + "///",
        files: [shippedEntry],
        expect: .leaveAlone
    ),
    Case(
        name: "a resources directory at the root has no parent to climb to",
        resources: "/",
        files: [],
        expect: pin("/terminfo")
    ),
    Case(
        name: "one component below the root",
        resources: "/ghostty",
        files: ["/terminfo/78/xterm-ghostty"],
        expect: .leaveAlone
    ),
]

var failures = 0

for testCase in cases {
    let actual = GhosttyTerminfo.decide(resourcesDirectory: testCase.resources) {
        testCase.files.contains($0)
    }
    if actual != testCase.expect {
        failures += 1
        print("FAIL  \(testCase.name)")
        print("      resources \(testCase.resources.map { $0.debugDescription } ?? "nil")")
        print("      expected  \(testCase.expect)")
        print("      actual    \(actual)")
    }
}

// Every path the decision consults has to be one `candidateEntryPaths` lists,
// or the list is not the description of the lookup it claims to be — the same
// coverage assertion `LinkTargetCheck` makes, and for the same reason: the
// list is what a reader consults to find out where the app looked.
var coverageFailures = 0
for testCase in cases {
    guard let resources = testCase.resources else { continue }
    var asked: [String] = []
    _ = GhosttyTerminfo.decide(resourcesDirectory: resources) { path in
        asked.append(path)
        return testCase.files.contains(path)
    }
    let listed = GhosttyTerminfo.candidateEntryPaths(resourcesDirectory: resources)
    let uncovered = asked.filter { !listed.contains($0) }
    if !uncovered.isEmpty {
        coverageFailures += 1
        print("FAIL  \(testCase.name) — probes candidateEntryPaths does not list: \(uncovered)")
    }
}

// The one thing a caller must never be able to do: pin a term without being
// able to say where it looked. `missingFrom` is what the notice quotes, and a
// notice naming nothing is worse than none.
var pairingFailures = 0
for testCase in cases {
    let actual = GhosttyTerminfo.decide(resourcesDirectory: testCase.resources) {
        testCase.files.contains($0)
    }
    if (actual.term == nil) != (actual.missingFrom == nil) {
        pairingFailures += 1
        print("FAIL  \(testCase.name) — term and missingFrom disagree: \(actual)")
    }
}

// The fallback has to be a name ncurses ships, not a second private one.
var nameFailures = 0
if GhosttyTerminfo.fallbackTerm != "xterm-256color" {
    nameFailures += 1
    print("FAIL  fallback term is \(GhosttyTerminfo.fallbackTerm), which is not the ncurses one")
}

// MARK: - Taking the variable over
//
// The rule with teeth: after this runs, `GHOSTTY_RESOURCES_DIR` must name
// something inside this app's own bundle or nothing at all. It must never be
// left holding the value it was inherited with, because that value points into
// Ghostty.app and restoring it is the dependency this whole change removes —
// and it would be restored only on the machines where something was already
// wrong, which is the worst place for a silent fallback to live.

/// A whole inherited environment, not one variable: the app is launched from a
/// Ghostty shell, so *both* names arrive already pointing into Ghostty.app.
/// Checking only the write to `GHOSTTY_RESOURCES_DIR` is what let the second
/// one survive into every child this app spawns — measured on the running app,
/// its control-mode `tmux -C` had `TERMINFO` naming Ghostty.
let ghosttyResourcesInherited = "/Applications/Ghostty.app/Contents/Resources/ghostty"
let ghosttyTerminfoInherited = "/Applications/Ghostty.app/Contents/Resources/terminfo"
let ourResources = "/Applications/Attaché.app/Contents/Resources"
let ourEntry = "/Applications/Attaché.app/Contents/Resources/terminfo/78/xterm-ghostty"

struct AdoptCase {
    let name: String
    let bundleResources: String?
    var files: Set<String> = []
    /// Writes that quietly do nothing — what a failing `setenv` or `unsetenv`
    /// looks like from the caller's side. Per variable and per direction,
    /// because "only one of the two writes failed" is the case that produces
    /// the half-owned environment, and a single boolean cannot express it.
    var setsFail: Set<String> = []
    var removalsFail: Set<String> = []
    let expectTerm: String?
    /// The final environment. A missing key means the variable must be gone.
    let expectEnvironment: [String: String]
    var expectUnowned: String?
}

let adoptCases: [AdoptCase] = [
    AdoptCase(
        name: "bundled entry present — both variables point at our own bundle",
        bundleResources: ourResources,
        files: [ourEntry],
        expectTerm: nil,
        expectEnvironment: [
            "GHOSTTY_RESOURCES_DIR": "/Applications/Attaché.app/Contents/Resources/ghostty",
            "TERMINFO": "/Applications/Attaché.app/Contents/Resources/terminfo",
        ]
    ),
    AdoptCase(
        name: "bundled entry in the letter bucket counts too",
        bundleResources: ourResources,
        files: ["/Applications/Attaché.app/Contents/Resources/terminfo/x/xterm-ghostty"],
        expectTerm: nil,
        expectEnvironment: [
            "GHOSTTY_RESOURCES_DIR": "/Applications/Attaché.app/Contents/Resources/ghostty",
            "TERMINFO": "/Applications/Attaché.app/Contents/Resources/terminfo",
        ]
    ),
    AdoptCase(
        name: "incomplete bundle — both removed, neither left inherited",
        bundleResources: ourResources,
        files: [ghosttyTerminfoInherited + "/78/xterm-ghostty"],
        expectTerm: GhosttyTerminfo.fallbackTerm,
        expectEnvironment: [:]
    ),
    AdoptCase(
        name: "no bundle path at all — both still removed",
        bundleResources: nil,
        files: [ourEntry],
        expectTerm: GhosttyTerminfo.fallbackTerm,
        expectEnvironment: [:]
    ),
    AdoptCase(
        name: "empty bundle path — both still removed",
        bundleResources: "",
        files: [ourEntry],
        expectTerm: GhosttyTerminfo.fallbackTerm,
        expectEnvironment: [:]
    ),
    // setenv and unsetenv return a status and can fail. The failure that
    // matters leaves the *inherited* value in place — the one naming another
    // application — so a decision built from what was intended would report
    // success on exactly the machine where the invariant broke.
    AdoptCase(
        name: "nothing can be written at all — say so, do not report success",
        bundleResources: ourResources,
        files: [ourEntry],
        setsFail: [GhosttyTerminfo.resourcesVariable, GhosttyTerminfo.terminfoVariable],
        removalsFail: [GhosttyTerminfo.resourcesVariable, GhosttyTerminfo.terminfoVariable],
        expectTerm: GhosttyTerminfo.fallbackTerm,
        expectEnvironment: [
            "GHOSTTY_RESOURCES_DIR": ghosttyResourcesInherited,
            "TERMINFO": ghosttyTerminfoInherited,
        ],
        expectUnowned: "TERMINFO"
    ),
    AdoptCase(
        name: "a refused removal on the incomplete-bundle path is caught too",
        bundleResources: nil,
        removalsFail: [GhosttyTerminfo.terminfoVariable],
        expectTerm: GhosttyTerminfo.fallbackTerm,
        expectEnvironment: ["TERMINFO": ghosttyTerminfoInherited],
        expectUnowned: "TERMINFO"
    ),
    // The two cases the half-owned state comes from, one per variable. Both
    // must land on "neither is set" — never one of ours beside one of theirs.
    AdoptCase(
        name: "only the TERMINFO write fails — roll back to empty, not half-owned",
        bundleResources: ourResources,
        files: [ourEntry],
        setsFail: [GhosttyTerminfo.terminfoVariable],
        expectTerm: GhosttyTerminfo.fallbackTerm,
        expectEnvironment: [:],
        expectUnowned: "TERMINFO"
    ),
    AdoptCase(
        name: "only the resources write fails — roll back to empty, not half-owned",
        bundleResources: ourResources,
        files: [ourEntry],
        setsFail: [GhosttyTerminfo.resourcesVariable],
        expectTerm: GhosttyTerminfo.fallbackTerm,
        expectEnvironment: [:],
        expectUnowned: "GHOSTTY_RESOURCES_DIR"
    ),
]

var adoptFailures = 0
for testCase in adoptCases {
    var environment = [
        "GHOSTTY_RESOURCES_DIR": ghosttyResourcesInherited,
        "TERMINFO": ghosttyTerminfoInherited,
    ]
    let decision = GhosttyTerminfo.adoptOwnResources(
        bundleResourcePath: testCase.bundleResources,
        entryExists: { testCase.files.contains($0) },
        readVariable: { environment[$0] },
        setVariable: { name, value in
            if let value {
                guard !testCase.setsFail.contains(name) else { return }
                environment[name] = value
            } else {
                guard !testCase.removalsFail.contains(name) else { return }
                environment[name] = nil
            }
        }
    )
    if decision.term != testCase.expectTerm {
        adoptFailures += 1
        print("FAIL  \(testCase.name) — term \(decision.term ?? "nil")")
    }
    if decision.unownedVariable != testCase.expectUnowned {
        adoptFailures += 1
        print("FAIL  \(testCase.name) — unowned \(decision.unownedVariable ?? "nil")")
    }
    if environment != testCase.expectEnvironment {
        adoptFailures += 1
        print("FAIL  \(testCase.name) — final environment")
        print("      expected \(testCase.expectEnvironment)")
        print("      actual   \(environment)")
    }
    // The invariant no future case may weaken, asserted over the environment
    // as a whole rather than over one write: after a *successful* takeover
    // nothing anywhere may still name another application's bundle.
    if decision.unownedVariable == nil {
        for (name, value) in environment where value.contains("Ghostty.app") {
            adoptFailures += 1
            print("FAIL  \(testCase.name) — \(name) still names Ghostty.app: \(value)")
        }
    }
}

// MARK: - The shipped database against its own source
//
// Everything above runs on an injected file system, which is what makes it
// fast and machine-independent — and also what makes it blind to the one thing
// that cannot be reasoned about: the compiled entries in Resources/terminfo are
// *committed*, not built, so editing Resources/xterm-ghostty.terminfo without
// recompiling changes nothing at runtime and no amount of injected fixtures
// would notice. Release ships only the compiled form, so a source-only
// correction would be a fix that never reached a single pane.
//
// So this last part touches the real disk on purpose: compile the source into a
// temporary directory and compare, byte for byte, against what is committed.

var driftFailures = 0
let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sourcePath = root + "/Resources/xterm-ghostty.terminfo"
let committedDirectory = root + "/Resources/terminfo"

if !FileManager.default.fileExists(atPath: sourcePath) {
    driftFailures += 1
    print("FAIL  no terminfo source at \(sourcePath)")
    print("      run this from the repository root, or pass the root as argv[1]")
} else {
    let temporary = NSTemporaryDirectory() + "terminfocheck-tic"
    try? FileManager.default.removeItem(atPath: temporary)
    let tic = Process()
    tic.executableURL = URL(fileURLWithPath: "/usr/bin/tic")
    tic.arguments = ["-x", "-o", temporary, sourcePath]
    // tic warns on stderr about the description field even when it succeeds.
    tic.standardError = FileHandle.nullDevice
    tic.standardOutput = FileHandle.nullDevice
    do {
        try tic.run()
        tic.waitUntilExit()
        if tic.terminationStatus != 0 {
            driftFailures += 1
            print("FAIL  tic could not compile \(sourcePath) — status \(tic.terminationStatus)")
        }
    } catch {
        driftFailures += 1
        print("FAIL  could not run /usr/bin/tic: \(error)")
    }

    // Both entries, not just the one the app asks for by name: `ghostty` is an
    // alias in the same source, and an alias that stopped matching would be a
    // difference between this repository and the description it claims to be.
    let entries = ["78/xterm-ghostty", "67/ghostty"]
    for entry in entries {
        let built = temporary + "/" + entry
        let committed = committedDirectory + "/" + entry
        guard let a = FileManager.default.contents(atPath: built) else {
            driftFailures += 1
            print("FAIL  the source does not produce \(entry)")
            continue
        }
        guard let b = FileManager.default.contents(atPath: committed) else {
            driftFailures += 1
            print("FAIL  \(committed) is not committed, but the source produces it")
            continue
        }
        if a != b {
            driftFailures += 1
            print("FAIL  \(entry) differs from what the source compiles to")
            print("      recompile: tic -x -o Resources/terminfo Resources/xterm-ghostty.terminfo")
            print("      (or this machine's tic writes a different binary from the one that")
            print("       produced the committed files — check `tic -V` before assuming drift)")
        }
    }

    // And nothing else may be in there. A stray entry in the shipped database
    // is something no source in this repository accounts for, and it ends up
    // inside the app bundle because the whole directory is copied as one.
    //
    // The type comes from the file system rather than from the shape of the
    // name. An earlier version dropped directories by testing for a "/" in the
    // path, which also drops a stray file sitting *directly* in
    // Resources/terminfo — precisely the case this is here to catch. Symlinks
    // are rejected outright rather than followed: a link is not a terminfo
    // entry, and following one would let this pass while the bundle carried
    // something else entirely.
    let allowedDirectories = Set(entries.map { String($0.prefix(while: { $0 != "/" })) })
    var shipped: [String] = []
    if let walk = FileManager.default.enumerator(atPath: committedDirectory) {
        for case let name as String in walk where name != ".DS_Store" {
            let full = committedDirectory + "/" + name
            // `attributesOfItem` does not follow the final symlink, which is
            // what makes a link visible here as a link.
            let type = (try? FileManager.default.attributesOfItem(atPath: full))?[.type]
                as? FileAttributeType
            switch type {
            case .typeDirectory where allowedDirectories.contains(name):
                continue
            case .typeRegular:
                shipped.append(name)
            default:
                driftFailures += 1
                print("FAIL  Resources/terminfo/\(name) is a \(type?.rawValue ?? "unknown")"
                    + " — only the two compiled entries belong here")
            }
        }
    }
    if shipped.sorted() != entries.sorted() {
        driftFailures += 1
        print("FAIL  Resources/terminfo holds \(shipped.sorted()), expected \(entries.sorted())")
    }
    try? FileManager.default.removeItem(atPath: temporary)
}

let total = cases.count + adoptCases.count + 1
let failed = failures + coverageFailures + pairingFailures + nameFailures
    + adoptFailures + driftFailures
if failed == 0 {
    print("TerminfoCheck: \(total) cases, all pass (probe coverage included)")
} else {
    print("TerminfoCheck: \(failed) failed out of \(total)")
    exit(1)
}
