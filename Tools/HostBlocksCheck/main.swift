//
//  HostBlocksCheck
//
//  Exercises `SettingsFile.saveHostBlock` / `removeHostBlock` — the write
//  path under the Hosts settings page — against real files on a scratch
//  path. What it protects is the file's contract: the config is the user's,
//  hand-edited and possibly in a dotfiles repository, so an edit that loses
//  a comment, re-encodes an unknown key, eats an inline `# note`, or slowly
//  inflates blank lines is data loss, not formatting.
//
//  Every case asserts the file's exact bytes, because "roughly right" is how
//  the first version of the settings cache ate a hand-written comment. The
//  adversarial half came out of a Codex review of the first version of this
//  writer: inline comment suffixes, empty and nameless blocks, a block
//  removed under the editor, and a disk that refuses the write.
//
//      swiftc -O -o /tmp/hostblockscheck Attache/Tmux/TmuxLog.swift \
//        Attache/Settings/QuickAction.swift Attache/Settings/SettingsFile.swift \
//        Tools/HostBlocksCheck/main.swift
//      /tmp/hostblockscheck
//

import Foundation

@MainActor
func runAllCases() {
    var failures = 0
    var cases = 0

    // One scratch path for the whole run, set before the first SettingsFile
    // touches the environment: ProcessInfo may cache `environment`, so the
    // override cannot be re-pointed between cases — the file's *contents*
    // change per case instead.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hostblockscheck-\(getpid())")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("attache.toml")
    let legacyFile = directory.appendingPathComponent("tmux-gui.toml")
    setenv("ATTACHE_CONFIG", file.path, 1)
    // The scratch stand-in for the TmuxGUI-era file. Setting it is what
    // re-enables legacy adoption under ATTACHE_CONFIG, between these two
    // scratch paths and nothing else — the resurrection cases below are
    // unreachable without it.
    setenv("ATTACHE_LEGACY_CONFIG", legacyFile.path, 1)

    func fresh(_ input: String?, legacy: String? = nil) -> SettingsFile {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: legacyFile)
        if let input { try! input.write(to: file, atomically: true, encoding: .utf8) }
        if let legacy { try! legacy.write(to: legacyFile, atomically: true, encoding: .utf8) }
        return SettingsFile()
    }

    func disk() -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? "<no file>"
    }

    func check(_ name: String, _ got: String, _ expect: String) {
        cases += 1
        if got == expect { return }
        failures += 1
        print("FAIL \(name)")
        print("  expected:\n\(expect.split(separator: "\n", omittingEmptySubsequences: false).map { "    |\($0)" }.joined(separator: "\n"))")
        print("  got:\n\(got.split(separator: "\n", omittingEmptySubsequences: false).map { "    |\($0)" }.joined(separator: "\n"))")
    }

    func expectTrue(_ name: String, _ condition: Bool, _ detail: String = "") {
        cases += 1
        if condition { return }
        failures += 1
        print("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    func fields(_ pairs: (String, String)...) -> [(key: String, value: String)] {
        pairs.map { (key: $0.0, value: $0.1) }
    }

    // ── The real-world shape: the owner's actual file, one value edited ──
    let real = """
    appearance = "light"
    window_opacity = 0.58

    # 我手写的动作
    [[quick_action]]
    title = "Toggle"
    command = "set status"

    # The Mac mini downstairs
    [[host]]
    name = "mini"
    ssh = "joey@192.168.8.68"
    tmux_path = "/opt/homebrew/bin/tmux"
    """ + "\n"

    var settings = fresh(real)
    var refused = settings.saveHostBlock(named: "mini", fields: fields(
        ("name", "mini"), ("ssh", "joey@192.168.8.68"), ("tmux_path", "/usr/local/bin/tmux")
    ))
    expectTrue("edit reports success", refused == nil, refused ?? "")
    check("edit one value in place", disk(), real.replacingOccurrences(
        of: "/opt/homebrew/bin/tmux", with: "/usr/local/bin/tmux"
    ))

    // ── A no-op save is byte-identical ──
    settings = fresh(real)
    settings.saveHostBlock(named: "mini", fields: fields(
        ("name", "mini"), ("ssh", "joey@192.168.8.68"), ("tmux_path", "/opt/homebrew/bin/tmux")
    ))
    check("no-op save is byte-identical", disk(), real)

    // ── Inline comment suffixes and indentation survive ──
    // The neighbour line's comment must survive an edit of a *different*
    // field, and the edited line's own comment must survive the new value.
    let commented = """
    [[host]]
    name = "a"
      ssh = "u@a"   # through the bastion
    tmux_path = "/old"  # slow disk
    """ + "\n"

    settings = fresh(commented)
    settings.saveHostBlock(named: "a", fields: fields(
        ("name", "a"), ("ssh", "u@a"), ("tmux_path", "/new")
    ))
    check("inline comments and indentation survive", disk(), """
    [[host]]
    name = "a"
      ssh = "u@a"   # through the bastion
    tmux_path = "/new"  # slow disk
    """ + "\n")

    // ── Unknown keys and interior comments ride along byte for byte ──
    let unknownKeys = """
    [[host]]
    name = "a"
    # keep the socket cold
    retries = 3
    ssh = "u@a"
    experimental_flag = true
    """ + "\n"

    settings = fresh(unknownKeys)
    settings.saveHostBlock(named: "a", fields: fields(("name", "a"), ("ssh", "u@b")))
    check("unknown keys byte-identical, order kept", disk(), """
    [[host]]
    name = "a"
    # keep the socket cold
    retries = 3
    ssh = "u@b"
    experimental_flag = true
    """ + "\n")

    // ── Add the first host: with settings above, with no trailing
    //    newline, and with no file at all ──
    settings = fresh("appearance = \"light\"\n")
    settings.saveHostBlock(named: nil, fields: fields(("name", "mini"), ("ssh", "joey@mini")))
    check("first host appends after a blank", disk(), """
    appearance = "light"

    [[host]]
    name = "mini"
    ssh = "joey@mini"
    """ + "\n")

    settings = fresh("appearance = \"light\"")
    settings.saveHostBlock(named: nil, fields: fields(("name", "mini"), ("ssh", "joey@mini")))
    check("missing trailing newline is repaired", disk(), """
    appearance = "light"

    [[host]]
    name = "mini"
    ssh = "joey@mini"
    """ + "\n")

    settings = fresh(nil)
    settings.saveHostBlock(named: nil, fields: fields(("name", "mini"), ("ssh", "joey@mini")))
    check("no file yet", disk(), """
    [[host]]
    name = "mini"
    ssh = "joey@mini"
    """ + "\n")

    // ── Add a second host; the first is untouched to the byte ──
    settings = fresh(real)
    settings.saveHostBlock(named: nil, fields: fields(("name", "vm"), ("ssh", "joey@vm")))
    check("second host lands after the first", disk(), real + """

    [[host]]
    name = "vm"
    ssh = "joey@vm"
    """ + "\n")

    // ── Remove: a note below the block survives ──
    settings = fresh("""
    [[host]]
    name = "a"
    ssh = "u@a"

    # note at the end of the file
    """ + "\n")
    refused = settings.removeHostBlock(named: "a")
    expectTrue("remove reports success", refused == nil, refused ?? "")
    check("removal keeps trailing note", disk(), "# note at the end of the file\n")

    // ── Remove the first of two; the second stays byte-identical ──
    settings = fresh("""
    # fleet
    [[host]]
    name = "a"
    ssh = "u@a"

    [[host]]
    name = "b"
    ssh = "u@b"
    """ + "\n")
    settings.removeHostBlock(named: "a")
    check("remove first, keep second", disk(), """
    # fleet

    [[host]]
    name = "b"
    ssh = "u@b"
    """ + "\n")

    // ── Removing an absent host is success and changes nothing ──
    settings = fresh(real)
    refused = settings.removeHostBlock(named: "ghost")
    expectTrue("removing an absent host is a no-op", refused == nil, refused ?? "")
    check("absent removal leaves the file alone", disk(), real)

    // ── Clearing an optional field drops its line ──
    settings = fresh("""
    [[host]]
    name = "a"
    ssh = "u@a"
    tmux_socket = "dev"
    """ + "\n")
    settings.saveHostBlock(named: "a", fields: fields(("name", "a"), ("ssh", "u@a")))
    check("cleared field's line is dropped", disk(), """
    [[host]]
    name = "a"
    ssh = "u@a"
    """ + "\n")

    // ── A managed key duplicated by hand collapses to one line ──
    settings = fresh("""
    [[host]]
    name = "a"
    ssh = "u@a"
    ssh = "u@stale"
    """ + "\n")
    settings.saveHostBlock(named: "a", fields: fields(("name", "a"), ("ssh", "u@new")))
    check("duplicate managed key collapses", disk(), """
    [[host]]
    name = "a"
    ssh = "u@new"
    """ + "\n")

    // ── Empty and nameless blocks are invisible and indestructible ──
    // The parser skips them, so no index arithmetic may ever land an edit
    // on one; matching by name is what makes that structural.
    let withEmpty = """
    [[host]]

    [[host]]
    ssh = "orphan@nowhere"

    [[host]]
    name = "b"
    ssh = "u@b"
    """ + "\n"

    settings = fresh(withEmpty)
    settings.saveHostBlock(named: "b", fields: fields(("name", "b"), ("ssh", "u@b2")))
    check("empty and nameless blocks untouched", disk(),
          withEmpty.replacingOccurrences(of: "u@b\"", with: "u@b2\""))

    // ── Editing a host that vanished is refused, and the file unharmed ──
    settings = fresh(real)
    refused = settings.saveHostBlock(named: "ghost", fields: fields(("name", "ghost"), ("ssh", "u@g")))
    expectTrue("vanished host refused", refused?.contains("no longer in") == true, refused ?? "nil")
    check("refused edit leaves the file alone", disk(), real)

    // ── A rename is a value edit on the name line, in place ──
    settings = fresh(real)
    settings.saveHostBlock(named: "mini", fields: fields(
        ("name", "mini2"), ("ssh", "joey@192.168.8.68"), ("tmux_path", "/opt/homebrew/bin/tmux")
    ))
    check("rename edits the name line in place", disk(), real.replacingOccurrences(
        of: "name = \"mini\"", with: "name = \"mini2\""
    ))

    // ── A write that fails is reported, and nothing pretends otherwise ──
    // The directory is made read-only, which is what breaks an atomic
    // write (it lands as create-then-rename); the file itself stays
    // readable, so the rollback can resynchronise from it.
    settings = fresh(real)
    chmod(directory.path, 0o555)
    refused = settings.saveHostBlock(named: "mini", fields: fields(
        ("name", "mini"), ("ssh", "joey@192.168.8.68"), ("tmux_path", "/nowhere")
    ))
    chmod(directory.path, 0o755)
    expectTrue("failed write is reported", refused?.contains("could not write") == true, refused ?? "nil")
    check("failed write leaves the disk alone", disk(), real)
    expectTrue(
        "failed write resyncs the cache with the disk",
        settings.hostTables.first?["tmux_path"] == "/opt/homebrew/bin/tmux",
        "\(settings.hostTables)"
    )

    // ── Duplicate name lines resolve the way the parser reads them ──
    // parse() answers the *last* assignment for a duplicated key, so block A
    // here is the host "actual", not "victim" — and editing "victim" must
    // land on block B. A scanner that kept A's first name line resolved
    // "victim" to A and overwrote the wrong host.
    let duplicateNames = """
    [[host]]
    name = "victim"
    name = "actual"
    ssh = "u@a"

    [[host]]
    name = "victim"
    ssh = "u@b"
    """ + "\n"

    settings = fresh(duplicateNames)
    settings.saveHostBlock(named: "victim", fields: fields(("name", "victim"), ("ssh", "u@b2")))
    check("duplicated name lines: the parser's reading wins", disk(),
          duplicateNames.replacingOccurrences(of: "u@b\"", with: "u@b2\""))

    settings = fresh(duplicateNames)
    settings.saveHostBlock(named: "actual", fields: fields(("name", "actual"), ("ssh", "u@a2")))
    check("editing the block collapses its duplicate name lines", disk(), """
    [[host]]
    name = "actual"
    ssh = "u@a2"

    [[host]]
    name = "victim"
    ssh = "u@b"
    """ + "\n")

    // ── Uniqueness is enforced by the write itself, on its own read ──
    settings = fresh(real)
    refused = settings.saveHostBlock(named: nil, fields: fields(("name", "mini"), ("ssh", "u@x")))
    expectTrue("adding a taken name is refused", refused?.contains("already named") == true, refused ?? "nil")
    check("refused duplicate add leaves the file alone", disk(), real)

    settings = fresh(real + """

    [[host]]
    name = "vm"
    ssh = "joey@vm"
    """ + "\n")
    refused = settings.saveHostBlock(named: "vm", fields: fields(("name", "mini"), ("ssh", "joey@vm")))
    expectTrue("renaming onto a taken name is refused", refused?.contains("already named") == true, refused ?? "nil")

    // ── A file that exists but cannot be read stops the edit cold ──
    // Proceeding on the cache would overwrite whatever the unreadable file
    // really holds with a stale copy of itself.
    settings = fresh(real)
    _ = settings.hostTables // warm the cache, so staleness is on offer
    chmod(file.path, 0o000)
    refused = settings.saveHostBlock(named: "mini", fields: fields(
        ("name", "mini"), ("ssh", "joey@192.168.8.68"), ("tmux_path", "/nowhere")
    ))
    chmod(file.path, 0o644)
    expectTrue("unreadable file refuses the edit", refused?.contains("could not read") == true, refused ?? "nil")
    check("unreadable file is left untouched", disk(), real)

    // ── A file deleted after the cache warmed up stays deleted ──
    // The failure this hunts: a host edit resurrecting the whole cached
    // document — every setting and block of a file the user removed on
    // purpose. A confirmed-missing file is an *empty* document to the host
    // editor: adds create a file holding only what was added, edits and
    // removals of things that are no longer anywhere say so.
    settings = fresh(real)
    _ = settings.hostTables // warm the cache
    try? FileManager.default.removeItem(at: file)
    settings.saveHostBlock(named: nil, fields: fields(("name", "fresh"), ("ssh", "u@f")))
    check("add after deletion starts from an empty document", disk(), """
    [[host]]
    name = "fresh"
    ssh = "u@f"
    """ + "\n")

    settings = fresh(real)
    _ = settings.hostTables
    try? FileManager.default.removeItem(at: file)
    refused = settings.saveHostBlock(named: "mini", fields: fields(
        ("name", "mini"), ("ssh", "joey@192.168.8.68")
    ))
    expectTrue(
        "edit after deletion is refused, not resurrected",
        refused?.contains("no longer in") == true, refused ?? "nil"
    )
    expectTrue(
        "refused edit leaves the file deleted",
        !FileManager.default.fileExists(atPath: file.path), "file was recreated"
    )

    settings = fresh(real)
    _ = settings.hostTables
    try? FileManager.default.removeItem(at: file)
    refused = settings.removeHostBlock(named: "mini")
    expectTrue("remove after deletion is a no-op", refused == nil, refused ?? "")
    expectTrue(
        "no-op removal leaves the file deleted",
        !FileManager.default.fileExists(atPath: file.path), "file was recreated"
    )

    // ── Legacy adoption: once at first touch, never on a later reload ──
    // A migrated install keeps ~/.config/tmux-gui.toml on disk on purpose.
    // First touch with no active file must still adopt it; but once the
    // active file has been seen, deleting it means *deleted* — a host edit
    // re-running adoption would resurrect every pre-rename setting, one
    // layer beneath the missing-file handling (Codex review, round 4).
    let legacyContent = """
    appearance = "dark"

    [[host]]
    name = "old-machine"
    ssh = "joey@old"
    """ + "\n"

    settings = fresh(nil, legacy: legacyContent)
    settings.saveHostBlock(named: nil, fields: fields(("name", "fresh"), ("ssh", "u@f")))
    check("first touch still adopts the legacy file", disk(), legacyContent + """

    [[host]]
    name = "fresh"
    ssh = "u@f"
    """ + "\n")

    settings = fresh(real, legacy: legacyContent)
    _ = settings.hostTables // the active file has now been seen
    try? FileManager.default.removeItem(at: file)
    settings.saveHostBlock(named: nil, fields: fields(("name", "fresh"), ("ssh", "u@f")))
    check("deletion after first load does not re-adopt", disk(), """
    [[host]]
    name = "fresh"
    ssh = "u@f"
    """ + "\n")

    // ── An unreadable-then-deleted active file does not re-arm adoption ──
    // Unreadable means the path exists, and existence is what retires the
    // legacy migration — otherwise this sequence resurrected the old file.
    settings = fresh(real, legacy: legacyContent)
    chmod(file.path, 0o000)
    _ = settings.refreshHostEditView() // observes the unreadable-but-present file
    chmod(file.path, 0o644)
    try? FileManager.default.removeItem(at: file)
    settings.saveHostBlock(named: nil, fields: fields(("name", "fresh"), ("ssh", "u@f")))
    check("unreadable-then-deleted file does not re-adopt", disk(), """
    [[host]]
    name = "fresh"
    ssh = "u@f"
    """ + "\n")

    // ── The validation read uses host-edit semantics too ──
    // Warm cache, delete the file, re-add a name the deleted file held:
    // refreshHostEditView must clear the cache so the duplicate check runs
    // against the disk, not against the ghost of the deleted document.
    settings = fresh(real)
    _ = settings.hostTables
    try? FileManager.default.removeItem(at: file)
    refused = settings.refreshHostEditView()
    expectTrue("host-edit refresh accepts a missing file", refused == nil, refused ?? "")
    expectTrue(
        "host-edit refresh empties the cached tables",
        settings.hostTables.isEmpty, "\(settings.hostTables)"
    )
    refused = settings.saveHostBlock(named: nil, fields: fields(
        ("name", "mini"), ("ssh", "joey@192.168.8.68")
    ))
    expectTrue("re-adding a deleted file's name succeeds", refused == nil, refused ?? "")
    check("the re-added host is the whole new file", disk(), """
    [[host]]
    name = "mini"
    ssh = "joey@192.168.8.68"
    """ + "\n")

    // ── A top-level write after a host edit lands at the top level ──
    settings = fresh(real)
    settings.saveHostBlock(named: "mini", fields: fields(
        ("name", "mini"), ("ssh", "joey@192.168.8.68"), ("tmux_path", "/opt/homebrew/bin/tmux")
    ))
    settings.set("dark", forKey: "appearance")
    check("top-level set stays out of the blocks", disk(), real.replacingOccurrences(
        of: "appearance = \"light\"", with: "appearance = \"dark\""
    ))

    // ── The parsed tables agree with the disk right after a write ──
    settings = fresh(real)
    settings.saveHostBlock(named: nil, fields: fields(("name", "vm"), ("ssh", "joey@vm")))
    let tables = settings.hostTables
    expectTrue(
        "parsed tables agree after write",
        tables.count == 2 && tables[0]["name"] == "mini" && tables[1]["name"] == "vm",
        "\(tables)"
    )

    // ── Quoting round-trips through the writer and the parser ──
    settings = fresh(nil)
    settings.saveHostBlock(named: nil, fields: fields(
        ("name", "q"), ("ssh", "u@h"), ("git_tool_command", "lazygit --path \"x\"")
    ))
    expectTrue(
        "quoted value round-trips",
        settings.hostTables.first?["git_tool_command"] == "lazygit --path \"x\"",
        "\(settings.hostTables)"
    )

    try? FileManager.default.removeItem(at: directory)
    print(failures == 0 ? "\(cases) cases, all pass" : "\(failures) of \(cases) cases FAILED")
    exit(failures == 0 ? 0 : 1)
}

// The process main thread is the main actor's thread; say so rather than
// assume top-level isolation rules, which have shifted between Swift modes.
MainActor.assumeIsolated { runAllCases() }
