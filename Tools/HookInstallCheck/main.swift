//
//  main.swift
//  HookInstallCheck
//
//  Checks `AgentHookInstaller`'s merge against real settings files.
//
//  This is the highest-care code in the project: it edits a file that belongs
//  to another program and that several other tools have written into. On the
//  machine this was developed on, ~/.claude/settings.json carries hooks for
//  Otty, ccpet, code-rules-check and banned-word-reminder, plus statusLine,
//  permissions, enabledPlugins, env and more. Anything this drops is somebody's
//  working setup, gone silently.
//
//  So the cases are not about our own entries. They are about everything else
//  still being there afterwards.
//
//  The live half reads the real ~/.claude/settings.json **in memory only** and
//  never writes it — the merge functions are pure, which is why they exist
//  separately from `install()`.
//
//  swiftc -O -o /tmp/hookcheck Attache/Tmux/TmuxLog.swift \
//      Attache/Status/AgentHookInstaller.swift Tools/HookInstallCheck/main.swift \
//      && /tmp/hookcheck
//

import Foundation

var failures = 0
var total = 0

func check(_ name: String, _ problem: @autoclosure () -> String?) {
    total += 1
    if let problem = problem() {
        failures += 1
        print("FAIL  \(name)\n      \(problem)")
    } else {
        print("ok    \(name)")
    }
}

/// Order-independent structural comparison. `JSONSerialization` gives back
/// dictionaries, so `==` on `[String: Any]` is unavailable and comparing
/// serialised bytes would fail on key order alone.
func same(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x as [String: Any], y as [String: Any]):
        guard Set(x.keys) == Set(y.keys) else { return false }
        return x.keys.allSatisfy { same(x[$0], y[$0]) }
    case let (x as [Any], y as [Any]):
        guard x.count == y.count else { return false }
        return zip(x, y).allSatisfy { same($0, $1) }
    case let (x as String, y as String): return x == y
    case let (x as NSNumber, y as NSNumber): return x == y
    default: return false
    }
}

func json(_ text: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
}

let ourPath = AgentHookInstaller.scriptURL.path

// MARK: - A settings file shaped like a real one

let realistic = json("""
{
  "attribution": {"co_authored_by": false},
  "cleanupPeriodDays": 90,
  "env": {"SOME_TOKEN": "keep-me"},
  "model": "opus",
  "statusLine": {"command": "bash ~/.claude/statusline.sh", "refreshInterval": 5, "type": "command"},
  "permissions": {"allow": ["Bash(git:*)"], "deny": []},
  "someFutureKeyThisAppHasNeverHeardOf": {"nested": [1, 2, {"deep": true}]},
  "hooks": {
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": "/Applications/Otty.app/hook.sh processing"}]}
    ],
    "Stop": [
      {"matcher": "*", "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/code-rules-check.sh"},
        {"type": "command", "command": "bash /Users/joey/Code/ccpet/scripts/ccpet-notify.sh"}
      ]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/banned-word-reminder.sh"}]}
    ]
  }
}
""")

let merged = AgentHookInstaller.merge(intoSettings: realistic)

check("every top-level key this app does not know about survives untouched", {
    for key in realistic.keys where key != "hooks" {
        if !same(realistic[key], merged[key]) { return "`\(key)` changed" }
    }
    return realistic.keys.contains("someFutureKeyThisAppHasNeverHeardOf")
        && merged.keys.contains("someFutureKeyThisAppHasNeverHeardOf")
        ? nil : "the unknown key vanished"
}())

check("another tool's hook in an event we also use is kept", {
    let groups = (merged["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
    let commands = groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    guard commands.contains(where: { $0.contains("Otty.app") }) else { return "Otty's PreToolUse hook was lost" }
    guard commands.contains(where: { $0.contains(ourPath) }) else { return "ours was not added" }
    return nil
}())

check("a group's `matcher` — a key we never write — survives", {
    let groups = (merged["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
    guard groups.contains(where: { ($0["matcher"] as? String) == "*" }) else {
        return "the matcher key was dropped"
    }
    return nil
}())

check("two commands sharing one group both survive", {
    let groups = (merged["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
    let shared = groups.first { ($0["hooks"] as? [[String: Any]])?.count ?? 0 >= 2 }
    guard let entries = shared?["hooks"] as? [[String: Any]], entries.count == 2 else {
        return "the two-command group was altered"
    }
    return nil
}())

check("every event we care about got exactly one of ours", {
    let hooks = merged["hooks"] as! [String: Any]
    for (event, _, _) in AgentHookInstaller.events {
        let groups = (hooks[event] as? [[String: Any]]) ?? []
        let mine = groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }
            .filter { ($0["command"] as? String)?.contains(ourPath) == true }
        // Notification carries two of ours on purpose — one matcher for the
        // kinds that mean "blocked", one for the idle nudge.
        let wanted = AgentHookInstaller.events.filter { $0.event == event }.count
        if mine.count != wanted { return "\(event) has \(mine.count) of ours, wanted \(wanted)" }
    }
    return nil
}())

check("installing twice installs once — the button is idempotent", {
    let twice = AgentHookInstaller.merge(intoSettings: merged)
    return same(merged, twice) ? nil : "a second merge changed the file"
}())

check("uninstall returns the file to exactly what it was", {
    let restored = AgentHookInstaller.unmerge(fromSettings: merged)
    return same(realistic, restored) ? nil : "uninstall did not round-trip"
}())

check("uninstall leaves other tools' entries in a shared group alone", {
    let restored = AgentHookInstaller.unmerge(fromSettings: merged)
    let groups = (restored["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
    let commands = groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    guard commands.contains(where: { $0.contains("ccpet") }),
          commands.contains(where: { $0.contains("code-rules-check") })
    else { return "another tool's Stop hooks were removed with ours" }
    return nil
}())

check("an event that only ever had ours is removed, not left empty", {
    let restored = AgentHookInstaller.unmerge(fromSettings: merged)
    let hooks = restored["hooks"] as! [String: Any]
    return hooks["SessionEnd"] == nil ? nil : "SessionEnd was left behind as an empty array"
}())

check("a settings file with no hooks key at all", {
    let bare = json(#"{"model": "opus"}"#)
    let out = AgentHookInstaller.merge(intoSettings: bare)
    guard (out["model"] as? String) == "opus" else { return "model was lost" }
    guard (out["hooks"] as? [String: Any])?.count == Set(AgentHookInstaller.events.map(\.event)).count
    else { return "not every event was added" }
    return same(AgentHookInstaller.unmerge(fromSettings: out), bare) ? nil : "did not round-trip"
}())

check("a completely empty settings file", {
    let out = AgentHookInstaller.merge(intoSettings: [:])
    let back = AgentHookInstaller.unmerge(fromSettings: out)
    return back.isEmpty ? nil : "an empty file did not come back empty, got \(back.keys.sorted())"
}())

check("a hook entry that is not a dictionary does not crash the merge", {
    let odd = json(#"{"hooks": {"Stop": ["a bare string a future version might use"]}}"#)
    _ = AgentHookInstaller.merge(intoSettings: odd)
    return nil
}())

// MARK: - Shapes it must refuse rather than overwrite

print("\n— shapes it refuses to touch —")

func refuses(_ text: String) -> String? {
    do {
        try AgentHookInstaller.validateShape(json(text))
        return "it accepted a shape it does not understand — merge would have overwritten it"
    } catch { return nil }
}

check("`hooks` as an array rather than an object",
      refuses(#"{"hooks": ["something"]}"#))
check("an event holding a bare string",
      refuses(#"{"hooks": {"Stop": ["a bare string a future schema might use"]}}"#))
check("an event holding a number",
      refuses(#"{"hooks": {"Stop": [42]}}"#))
check("an event that is not a list at all",
      refuses(#"{"hooks": {"Stop": {"not": "a list"}}}"#))
check("a shape it does understand is accepted", {
    do { try AgentHookInstaller.validateShape(realistic); return nil }
    catch { return "it refused a normal file: \(error)" }
}())
check("no hooks key at all is accepted", {
    do { try AgentHookInstaller.validateShape(json(#"{"model":"opus"}"#)); return nil }
    catch { return "it refused a file with no hooks" }
}())

// MARK: - Symlinked settings — the dotfiles case

print("\n— a settings file that is a symlink —")

check("the write target resolves through a symlink", {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("attache-symcheck-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: tmp)
    try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let real = tmp.appendingPathComponent("real.json")
    let link = tmp.appendingPathComponent("link.json")
    try! Data(#"{"a":1}"#.utf8).write(to: real)
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    // The property the installer relies on: resolving reaches the real file, so
    // an atomic write replaces *that* instead of severing the link.
    guard link.resolvingSymlinksInPath().path == real.resolvingSymlinksInPath().path else {
        return "resolvingSymlinksInPath did not reach the target"
    }
    // And the property the backup relies on: copying bytes is a snapshot,
    // whereas FileManager.copyItem on a link would copy the link.
    let snapshot = try! Data(contentsOf: link.resolvingSymlinksInPath())
    try! Data(#"{"a":2}"#.utf8).write(to: real)
    return snapshot == Data(#"{"a":1}"#.utf8)
        ? nil : "a byte copy was not a snapshot"
}())

// MARK: - Against the real file, read only

print("\n— against the real ~/.claude/settings.json (read only) —")

let realURL = AgentHookInstaller.settingsURL
if let data = try? Data(contentsOf: realURL),
   let real = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
{
    // Normalised first, because this file is a moving target: once the hook is
    // installed, `merge` is a no-op and `unmerge` legitimately does not return
    // the file it was handed. A check that only holds before the feature is
    // used is a check that stops working the moment anyone uses it — which is
    // exactly what happened the first time this ran after a real install.
    // `pristine` is the file as it would be with our entries absent, and every
    // assertion below is against that.
    let pristine = AgentHookInstaller.unmerge(fromSettings: real)
    let alreadyInstalled = !same(pristine, real)

    print("      \(real.keys.count) top-level keys, "
        + "\((real["hooks"] as? [String: Any])?.keys.count ?? 0) hook events"
        + (alreadyInstalled ? ", our hook is currently installed" : ", our hook is not installed"))

    let liveMerged = AgentHookInstaller.merge(intoSettings: pristine)

    // Idempotency of the *operation*, not of the live file's current contents.
    // The installed version can legitimately be older than this build — the
    // event list changes — so `merge(live) == live` is not a property that
    // should hold. `merge(merge(x)) == merge(x)` is, and it is the one that
    // actually protects against duplicate entries.
    check("real file: merging twice is the same as merging once", {
        let once = AgentHookInstaller.merge(intoSettings: real)
        return same(AgentHookInstaller.merge(intoSettings: once), once)
            ? nil : "a second merge changed the file"
    }())

    check("real file: every key outside `hooks` is byte-for-byte the same object", {
        for key in pristine.keys where key != "hooks" {
            if !same(pristine[key], liveMerged[key]) { return "`\(key)` changed" }
        }
        return nil
    }())

    check("real file: no existing hook command is lost", {
        func commands(_ settings: [String: Any]) -> Set<String> {
            guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
            return Set(hooks.values.flatMap { value -> [String] in
                guard let groups = value as? [[String: Any]] else { return [] }
                return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
            })
        }
        let lost = commands(pristine).subtracting(commands(liveMerged))
        return lost.isEmpty ? nil : "lost \(lost.count): \(lost.first ?? "")"
    }())

    check("real file: uninstall round-trips to the pristine file", {
        same(pristine, AgentHookInstaller.unmerge(fromSettings: liveMerged)) ? nil : "did not round-trip"
    }())
} else {
    print("      (no readable settings file here — the live checks were skipped)")
}

print("")
if failures == 0 {
    print("\(total) cases, all passed")
} else {
    print("\(failures) of \(total) cases FAILED")
    exit(1)
}
