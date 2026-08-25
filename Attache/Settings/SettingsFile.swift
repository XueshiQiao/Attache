//
//  SettingsFile.swift
//  Attache
//

import Foundation

/// Every preference, in `~/.config/tmux-gui.toml`.
///
/// It replaced `UserDefaults` for one reason, and it is worth writing down
/// because it is not a matter of taste: a plist is not a file the person who
/// owns these settings can read, edit, diff or back up. This one is, which
/// means it can also be put in a dotfiles repository, copied to another
/// machine, and — the case that prompted the change — *restored by hand* after
/// something deletes it.
///
/// **Writing is line-oriented, and that is the whole design.** The file is not
/// parsed into a model and regenerated; each `set` rewrites only the line
/// carrying that key and leaves every other byte alone. So comments the user
/// wrote, keys this build does not know, blank lines and ordering all survive a
/// write. Regenerating would be far less code and would quietly delete all of
/// it — and a config file the app rewrites in its own image is not one anybody
/// can keep notes in.
///
/// What is deliberately *not* here: window position and size. Those are
/// AppKit's, written to the app's plist by `setFrameAutosaveName`, and there is
/// no supported way to redirect them. The plist therefore still exists and
/// holds those and nothing else.
@MainActor
final class SettingsFile {
    static let shared = SettingsFile()

    /// `~/.config/attache.toml`, unless `ATTACHE_CONFIG` names somewhere else —
    /// which exists so a test can point at a scratch file instead of the file
    /// the person at the machine is using.
    ///
    /// `TMUXGUI_CONFIG` is still honoured, second. The app was called TmuxGUI
    /// until it was renamed, and that variable may be sitting in a shell profile
    /// or a script; dropping it would send those runs at the real file instead
    /// of the scratch one they asked for, silently.
    static var url: URL { overrideURL ?? defaultURL }

    /// The two names, in the order they are consulted.
    private static let overrideNames = ["ATTACHE_CONFIG", "TMUXGUI_CONFIG"]

    /// A scratch stand-in for the TmuxGUI-era file, and test-only, exactly
    /// like `ATTACHE_CONFIG`: legacy adoption is disabled under an active
    /// override *unless* the legacy path is overridden too, because a test
    /// that adopts the user's real `~/.config/tmux-gui.toml` into its
    /// scratch file has broken the very isolation the override grants. With
    /// both set, adoption runs between the two scratch paths — which is the
    /// only way `HostBlocksCheck` can exercise it at all.
    private static var legacyOverrideURL: URL? {
        guard let override = ProcessInfo.processInfo.environment["ATTACHE_LEGACY_CONFIG"],
              !override.isEmpty else { return nil }
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }

    /// Whatever an environment variable names, or nil when neither is set.
    private static var overrideURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        for name in overrideNames {
            if let override = environment[name], !override.isEmpty {
                return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            }
        }
        return nil
    }

    /// `~/.config/attache.toml` — the path when nothing overrides it.
    private static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/attache.toml")
    }

    /// The `UserDefaults` suite the app wrote before it was renamed. Read-only
    /// from here — see `migrateFromUserDefaultsIfNeeded`.
    static let legacyDefaultsDomain = "dev.xueshi.TmuxGUI"

    /// Where the settings lived when the app was called TmuxGUI.
    ///
    /// Kept because the file is the user's — hand-edited, possibly in a dotfiles
    /// repository — and a rename that silently starts from defaults is exactly
    /// the loss the move off `UserDefaults` was meant to end.
    static var legacyURL: URL {
        legacyOverrideURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tmux-gui.toml")
    }

    /// Copy the old file to the new name, once, if the new one is not there yet.
    ///
    /// A byte copy rather than a parse-and-rewrite, so comments, ordering, keys
    /// this build does not know and anything else the user put there arrive
    /// intact. The original is **left on disk**: it costs a few hundred bytes
    /// and it is the only copy of settings that were hand-written.
    /// **Only when nothing overrides the path**, and that is the whole of the
    /// subtlety. `ATTACHE_CONFIG` names a scratch file a test asked for
    /// *instead of* the one the person at the machine is using; copying their
    /// real settings into it is the opposite of the isolation it exists to give,
    /// and a test that meant to start from defaults would silently start from
    /// somebody's hand-written config. Keyed to `defaultURL` rather than `url`
    /// so an override cannot reach this at all.
    ///
    /// Returns `false` only in the one case a caller must not ignore: there *is*
    /// a legacy file and it could not be copied. Everything else — no legacy
    /// file, destination already there, an override in play — is `true`, meaning
    /// "nothing is owed here, carry on".
    @discardableResult
    private static func adoptLegacyFileIfNeeded() -> Bool {
        // Both overridden, or neither: those are the only two worlds where
        // source and destination belong to the same owner. A lone
        // ATTACHE_CONFIG must not adopt the user's real legacy file into a
        // scratch one — and a lone ATTACHE_LEGACY_CONFIG must not adopt a
        // scratch fixture into the user's real config, which an OR of the
        // two conditions quietly allowed (Codex review, round 5).
        guard (overrideURL == nil) == (legacyOverrideURL == nil) else { return true }
        // `url`, not `defaultURL`: with no override they are the same file,
        // and with both overrides set — the only way past the guard above —
        // source and destination are both scratch. Copying to `defaultURL`
        // here would aim a test's legacy fixture at the real config path of
        // whoever runs the check tool.
        let destination = url
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path),
              manager.fileExists(atPath: legacyURL.path) else { return true }
        try? manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try manager.copyItem(at: legacyURL, to: destination)
            return true
        } catch {
            // Loud, and the caller stops. A swallowed failure here used to hand
            // control to the plist migration below, which — on a machine that
            // moved to the TOML file long ago and so has almost nothing left in
            // its plist — would write a nearly empty `attache.toml`. Every later
            // launch then sees a destination that exists, skips this, and the
            // user's real settings are gone with nothing to say so.
            TmuxLog.lifecycle(
                "could not copy \(legacyURL.path) to \(destination.path): \(error)"
                    + " — leaving settings where they are rather than starting a new file"
            )
            return false
        }
    }

    /// Parsed scalars, by TOML key. `NSNumber` rather than `Int`/`Double`,
    /// because a hand-written `font_size = 14` is an integer and the code
    /// reading it wants a `Double` — `NSNumber` bridges to both, so a config
    /// the user typed cannot fall back to the default over a missing `.0`.
    private var values: [String: Any] = [:]
    private var quickActions: [QuickAction] = []
    /// `[[host]]` blocks, raw: one dictionary per block, every assignment in
    /// it, uninterpreted. File-only configuration — the app reads these and
    /// never writes them, on the same reasoning as `tmux_socket`: the person
    /// who reaches their tmux over ssh is the person who edits a TOML file
    /// without flinching. Validation lives in `HostConfig.parse`.
    ///
    /// Computed, because the first read of the session may come through here:
    /// a stored property answered `[]` until some *other* key had loaded the
    /// file, which is exactly the sometimes-empty answer a cache must never
    /// give.
    var hostTables: [[String: String]] {
        loadIfNeeded()
        return parsedHostTables
    }

    private var parsedHostTables: [[String: String]] = []
    /// The file exactly as it is on disk, kept so a write can edit one line of
    /// it rather than replace it.
    private var lines: [String] = []
    private var loaded = false

    // MARK: - Reading

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    /// Read the file again, discarding what was cached.
    ///
    /// Called before every write, and that is not an optimisation — it is what
    /// makes the line-oriented writing mean anything. The first version cached
    /// the file at launch and wrote from that copy, so a comment added while
    /// the app was running was deleted by the next settings change. Verified:
    /// a hand-written comment and an unknown key vanished when the font size
    /// was changed. The file is a few hundred bytes; reading it again costs
    /// nothing next to being the thing that eats the user's notes.
    ///
    /// What the read found. Three answers, not two, because two different
    /// callers need two different halves of the distinction: a *missing*
    /// file is the ordinary first launch, while a file that exists and
    /// cannot be read is a disk to stop trusting — and the host editor must
    /// also tell "missing" apart from "read fine", because a file deleted
    /// after the cache warmed up must not be resurrected from that cache by
    /// the next host edit (Codex review, round 3). The scalar writers keep
    /// their old shape and ignore all of it — for them the cache *is* the
    /// best available answer, and quietly recreating a deleted file has
    /// been their behaviour since the file existed.
    private enum ReadOutcome {
        case ok
        case missing
        case unreadable(String)
    }

    /// True once this process has seen the active file exist — read from
    /// disk, or created by a flush. From that point on, the file going
    /// missing means *deleted*, and the legacy adoption below must not run
    /// again: on a migrated install the TmuxGUI-era file is deliberately
    /// still on disk, and re-adopting it turned "the user deleted their
    /// config" into "every pre-rename setting quietly came back" — found in
    /// review, one layer beneath the missing-file fix it bypassed.
    private var activeFileHasExisted = false

    /// Read the file again, discarding what was cached — except on failure,
    /// where the cache is all there is.
    @discardableResult
    private func reload() -> ReadOutcome {
        // Before the read, not at launch: `reload` is the one path every read
        // and every write goes through, so there is no order of operations that
        // can reach the file ahead of the rename. Skipped once the active
        // file is known to have existed — adoption is a first-launch
        // migration, not something a mid-run deletion may retrigger.
        if !activeFileHasExisted, !Self.adoptLegacyFileIfNeeded() {
            // Legacy settings exist and could not be copied. For a host
            // edit this must be a hard stop: proceeding reads as "no file"
            // and the first write would strand the legacy settings forever.
            return .unreadable(
                "the settings from \(Self.legacyURL.path) could not be copied into place"
            )
        }
        do {
            let text = try String(contentsOf: Self.url, encoding: .utf8)
            lines = text.components(separatedBy: "\n")
            parse()
            activeFileHasExisted = true
            return .ok
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            // No file yet. Everything answers with its default until something
            // is written, and the first write creates the file.
            return .missing
        } catch {
            // Any failure other than not-found means the path *exists* —
            // that is why the read got far enough to fail — and existence
            // is what retires legacy adoption. Without this, an unreadable
            // active file followed by its deletion re-armed the adoption
            // and resurrected the legacy config after all.
            activeFileHasExisted = true
            TmuxLog.lifecycle("could not read \(Self.url.path): \(error)")
            return .unreadable(error.localizedDescription)
        }
    }

    /// The host editor's entry to `reload`: refuse an unreadable disk, and
    /// treat a *confirmed* missing file as the empty document it is. Without
    /// the reset, a config deleted while the app runs would come back from
    /// the cache on the next host edit — every setting and block of it.
    private func reloadForHostEdit() -> String? {
        switch reload() {
        case .ok:
            return nil
        case .missing:
            lines = []
            parse()
            return nil
        case .unreadable(let reason):
            // Proceeding on the cache here is not a degraded save, it is a
            // different action: writing a stale copy of the file over
            // whatever the unreadable file really holds.
            return "could not read \(Self.url.path): \(reason) — nothing was changed."
        }
    }

    private func parse() {
        values = [:]
        quickActions = []
        parsedHostTables = []
        var pendingAction: (title: String?, command: String?)?
        var pendingHost: [String: String]?
        // True from any table header this parser does not model. Its keys are
        // preserved on disk like everything else, but they must not be *read*:
        // before this flag existed, `[[host]] / name = "x"` defined a
        // top-level `name`, and three blocks collapsed into whichever came
        // last — table keys leaking into the flat namespace.
        var insideForeignTable = false

        func commitPending() {
            if let pending = pendingAction,
               let title = pending.title, let command = pending.command
            {
                quickActions.append(QuickAction(title: title, command: command))
            }
            pendingAction = nil
            if let host = pendingHost, !host.isEmpty { parsedHostTables.append(host) }
            pendingHost = nil
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "[[quick_action]]" {
                commitPending()
                insideForeignTable = false
                pendingAction = (nil, nil)
                continue
            }
            if line == "[[host]]" {
                commitPending()
                insideForeignTable = false
                pendingHost = [:]
                continue
            }
            // Any other table header ends the array-of-tables run.
            if line.hasPrefix("[") {
                commitPending()
                insideForeignTable = true
                continue
            }
            guard let (key, value) = Self.splitAssignment(line) else { continue }
            if pendingAction != nil {
                if key == "title" { pendingAction?.title = value as? String }
                if key == "command" { pendingAction?.command = value as? String }
            } else if pendingHost != nil {
                // Every key, not a known list: which keys mean something is
                // `HostConfig.parse`'s question, and an older build holding a
                // newer file must carry the ones it does not know rather than
                // flatten them away.
                pendingHost?[key] = (value as? String) ?? String(describing: value)
            } else if !insideForeignTable {
                values[key] = value
            }
        }
        commitPending()
    }

    /// `key = value` into the two halves, with the value converted to the
    /// closest Foundation type. Deliberately a subset of TOML: quoted strings,
    /// bare numbers, `true`/`false`. Anything else is left as a string, which
    /// is the harmless reading — a setting that cannot be understood falls back
    /// to its default rather than becoming a wrong value.
    private static func splitAssignment(_ line: String) -> (String, Any)? {
        // The comment has to go before the split, or a `#` inside a quoted
        // value would truncate it. Only an *unquoted* `#` starts a comment.
        var inQuotes = false
        var escaped = false
        var body = ""
        for character in line {
            if escaped { body.append(character); escaped = false; continue }
            if character == "\\", inQuotes { body.append(character); escaped = true; continue }
            if character == "\"" { inQuotes.toggle() }
            if character == "#", !inQuotes { break }
            body.append(character)
        }
        guard let equals = body.firstIndex(of: "=") else { return nil }
        let key = String(body[body.startIndex ..< equals]).trimmingCharacters(in: .whitespaces)
        let raw = String(body[body.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !raw.isEmpty else { return nil }
        return (key, decodeValue(raw))
    }

    private static func decodeValue(_ raw: String) -> Any {
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            let inner = String(raw.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if raw == "true" { return NSNumber(value: true) }
        if raw == "false" { return NSNumber(value: false) }
        if let int = Int(raw) { return NSNumber(value: int) }
        if let double = Double(raw) { return NSNumber(value: double) }
        return raw
    }

    // MARK: - The API `AppSettings` uses

    func object(forKey key: String) -> Any? {
        loadIfNeeded()
        return values[key]
    }

    func string(forKey key: String) -> String? {
        loadIfNeeded()
        return values[key] as? String
    }

    func set(_ value: Any?, forKey key: String) {
        loadIfNeeded()
        // Whatever is on disk right now, including anything edited by hand
        // since this app read it. See `reload`.
        reload()
        guard let value else {
            values.removeValue(forKey: key)
            writeLine(nil, forKey: key)
            return
        }
        let stored: Any = (value as? Bool).map { NSNumber(value: $0) }
            ?? (value as? Int).map { NSNumber(value: $0) }
            ?? (value as? Double).map { NSNumber(value: $0) }
            ?? value
        values[key] = stored
        writeLine(Self.encode(stored), forKey: key)
    }

    /// Quick Actions as `[[quick_action]]` blocks rather than a blob.
    ///
    /// The one setting that is a list, and the reason it is not stored the way
    /// the others are: as JSON in a string it would be the one line in this
    /// file nobody could hand-edit, in a file whose purpose is being
    /// hand-editable.
    var storedQuickActions: [QuickAction]? {
        loadIfNeeded()
        // An empty file has no blocks and no opinion; an emptied *list* is a
        // choice. The marker key tells them apart, exactly as the absent-key
        // check did when this lived in UserDefaults.
        guard values["quick_actions_edited"] != nil || !quickActions.isEmpty else { return nil }
        return quickActions
    }

    func setQuickActions(_ actions: [QuickAction]) {
        loadIfNeeded()
        reload()
        quickActions = actions
        set(true, forKey: "quick_actions_edited")
        rewriteQuickActionBlocks()
    }

    // MARK: - Host blocks

    /// The `[[host]]` keys the Hosts settings page manages. Everything else in
    /// a block — keys a newer build wrote, comments, blank lines — is carried
    /// through an edit **byte for byte**, never re-encoded: `retries = 3`
    /// re-encoded through `decodeValue`/`encode` would come back as a string,
    /// which is exactly the flattening the raw-carry contract forbids. The
    /// same is true *within* a managed line: only the value span is replaced,
    /// so `ssh = "u@h"  # via the bastion` keeps its indentation and its
    /// comment through an edit of the value beside them.
    static let hostManagedKeys = [
        "name", "ssh", "tmux_path", "tmux_socket", "git_tool_command", "remote_open_command",
    ]

    /// The host editor's read of the file, for the caller about to validate
    /// against `hostTables`: same semantics as the mutations themselves —
    /// a confirmed-missing file empties the cache, an unreadable one is the
    /// returned refusal. Anything softer re-creates the bug it replaced:
    /// validating against the cache of a deleted file refused to re-add a
    /// host name the disk no longer holds (Codex review, round 4).
    func refreshHostEditView() -> String? {
        loadIfNeeded()
        return reloadForHostEdit()
    }

    /// One `[[host]]` block as it sits in the file right now: its header
    /// line, the line after its last assignment, and the name it carries.
    /// Blocks are found by scanning the raw lines at the moment of the edit
    /// — never by an index computed earlier against another read of the
    /// file, which is how a concurrent hand edit turns "edit mini" into
    /// "overwrite whichever block sits where mini used to".
    private struct RawHostBlock {
        let header: Int
        /// One past the last assignment line. Trailing comments and blanks
        /// below that belong to the surrounding file, not to the block — so
        /// removing a block cannot eat a note somebody wrote under it.
        let end: Int
        let name: String?
    }

    private func scanHostBlocks() -> [RawHostBlock] {
        var blocks: [RawHostBlock] = []
        var header: Int?
        var lastAssignment: Int?
        var name: String?

        func close() {
            guard let opened = header else { return }
            blocks.append(RawHostBlock(
                header: opened, end: (lastAssignment ?? opened) + 1, name: name
            ))
            header = nil
            lastAssignment = nil
            name = nil
        }
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[[host]]" {
                close()
                header = index
                continue
            }
            guard header != nil else { continue }
            if trimmed.hasPrefix("[") {
                close()
                continue
            }
            if let (key, value) = Self.splitAssignment(trimmed) {
                lastAssignment = index
                if key == "name" {
                    // The *last* assignment wins, because that is what
                    // `parse` answers for a duplicated key — a scanner that
                    // kept the first would resolve "edit victim" to a block
                    // the parser calls something else, and overwrite it
                    // (Codex review). One semantics, everywhere.
                    name = ((value as? String) ?? String(describing: value))
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }
        close()
        return blocks
    }

    /// Write one host's managed fields into its block — `originalName` nil
    /// appends a new block instead. Everything is resolved against the file
    /// as it is on disk *now*, inside this one call: reload, find the block
    /// by name, edit in place, write. Blocks not named are not touched at
    /// all, empty or nameless ones included. Returns what went wrong — a
    /// vanished block, a failed write — or nil once the file is on disk.
    @discardableResult
    func saveHostBlock(
        named originalName: String?, fields: [(key: String, value: String)]
    ) -> String? {
        loadIfNeeded()
        if let refused = reloadForHostEdit() { return refused }
        let snapshot = lines
        let blocks = scanHostBlocks()

        // Uniqueness is asked of the same read the write acts on — asked any
        // earlier, another instance can slip a block in between the check
        // and the write, and the file ends up with two blocks one name, of
        // which `HostConfig.parseAll` will silently keep only the first.
        let newName = fields.first { $0.key == "name" }?
            .value.trimmingCharacters(in: .whitespaces)
        if let newName, newName != originalName,
           blocks.contains(where: { $0.name == newName })
        {
            return "Another host is already named \"\(newName)\"."
        }

        if let originalName {
            guard let block = blocks.first(where: { $0.name == originalName }) else {
                return "\"\(originalName)\" is no longer in \(Self.url.path) — "
                    + "it was removed while this editor was open."
            }
            var rebuilt: [String] = []
            var written = Set<String>()
            let managed = Set(Self.hostManagedKeys)
            let values = Dictionary(fields.map { ($0.key, $0.value) }) { first, _ in first }
            for raw in lines[(block.header + 1) ..< block.end] {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if let (key, old) = Self.splitAssignment(trimmed), managed.contains(key) {
                    // First occurrence carries the value, in place; a
                    // duplicate somebody wrote by hand is dropped rather
                    // than left to shadow it.
                    guard !written.contains(key) else { continue }
                    written.insert(key)
                    guard let value = values[key] else { continue }
                    if (old as? String) == value {
                        // Unchanged: the raw line survives byte for byte,
                        // odd spacing, inline comment and all.
                        rebuilt.append(raw)
                    } else {
                        rebuilt.append(Self.replacingValueSpan(in: raw, with: Self.encode(value)))
                    }
                } else {
                    rebuilt.append(raw)
                }
            }
            for (key, value) in fields where !written.contains(key) {
                rebuilt.append("\(key) = \(Self.encode(value))")
            }
            lines.replaceSubrange((block.header + 1) ..< block.end, with: rebuilt)
        } else {
            var block = ["[[host]]"]
            for (key, value) in fields { block.append("\(key) = \(Self.encode(value))") }
            // After the last existing block, else at the end of the file —
            // in front of the final empty element that carries the trailing
            // newline, not behind it.
            var at = blocks.last?.end ?? lines.count
            if at == lines.count, lines.last?.isEmpty == true { at -= 1 }
            // A blank line above the new block, except at the top of the
            // file or under a comment — a separator inserted between
            // somebody's note and what follows leaves the note pointing at
            // nothing, the same rule `writeLine` follows.
            if at > 0 {
                let above = lines[at - 1].trimmingCharacters(in: .whitespaces)
                if !above.isEmpty, !above.hasPrefix("#") { block.insert("", at: 0) }
            }
            lines.insert(contentsOf: block, at: at)
        }
        if lines.last?.isEmpty != true { lines.append("") }
        return flushHostEdit(rollbackTo: snapshot)
    }

    /// Delete one block by name. Absent is success — the block being gone is
    /// the state the caller asked for. The blank separator above the block
    /// goes with it, so repeated add/remove cannot pile blank lines up where
    /// blocks used to be.
    @discardableResult
    func removeHostBlock(named name: String) -> String? {
        loadIfNeeded()
        if let refused = reloadForHostEdit() { return refused }
        let snapshot = lines
        guard let block = scanHostBlocks().first(where: { $0.name == name }) else { return nil }
        var start = block.header
        if start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            start -= 1
        }
        lines.removeSubrange(start ..< block.end)
        // A block removed from the very top of the file leaves its former
        // separator as a leading blank; nothing above owns it, so it goes.
        while start == 0, lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        return flushHostEdit(rollbackTo: snapshot)
    }

    /// Replace only the value span of a `key = value  # comment` line,
    /// keeping the indentation, the spacing around `=`, and any unquoted
    /// comment suffix exactly as they were typed.
    private static func replacingValueSpan(in line: String, with encoded: String) -> String {
        guard let equals = line.firstIndex(of: "=") else { return line }
        var valueStart = line.index(after: equals)
        while valueStart < line.endIndex, line[valueStart] == " " || line[valueStart] == "\t" {
            valueStart = line.index(after: valueStart)
        }
        // The first unquoted `#` starts the comment — the same walk
        // `splitAssignment` does, kept as indices so the suffix survives.
        var commentStart = line.endIndex
        var inQuotes = false
        var escaped = false
        var index = valueStart
        while index < line.endIndex {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\", inQuotes {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == "#", !inQuotes {
                commentStart = index
                break
            }
            index = line.index(after: index)
        }
        var valueEnd = commentStart
        while valueEnd > valueStart {
            let before = line.index(before: valueEnd)
            if line[before] == " " || line[before] == "\t" { valueEnd = before } else { break }
        }
        return String(line[line.startIndex ..< valueStart]) + encoded + String(line[valueEnd...])
    }

    /// Land a host edit on disk, or undo it honestly. A failed write puts
    /// the lines back to the snapshot the edit was built on — in memory, not
    /// by reading the disk again, because a disk that just refused a write
    /// is not a disk to depend on for the rollback — and hands the reason
    /// up. The alternative was observed in review: the UI closes, the rail
    /// reconnects, and the disk still holds yesterday's block, so the whole
    /// change silently reverses on the next launch.
    private func flushHostEdit(rollbackTo snapshot: [String]) -> String? {
        if let failure = flush() {
            lines = snapshot
            parse()
            return "could not write \(Self.url.path): \(failure)"
        }
        // Every cached view of the file — `parsedHostTables` above all — is
        // rebuilt from the lines just written, so the next read agrees with
        // the disk without waiting for another reload.
        parse()
        return nil
    }

    private static func encode(_ value: Any) -> String {
        if let number = value as? NSNumber {
            // The Core Foundation type, not `as? Bool` — see the migration for
            // what that test does to a stored zero.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            if let int = number as? Int, Double(int) == number.doubleValue { return String(int) }
            return String(number.doubleValue)
        }
        let text = String(describing: value)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(text)\""
    }

    // MARK: - Writing

    /// Replace the line that assigns `key`, or append one. `value` of nil
    /// removes the assignment.
    private func writeLine(_ value: String?, forKey key: String) {
        var replaced = false
        var output: [String] = []
        var insideTable = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Sticky across *any* header, not a `[[quick_action]]` test: in
            // TOML there is no way back to the top level after a header, so
            // everything below the first one belongs to some table. The old
            // quick_action-only test let a top-level `set("name", …)` rewrite
            // the `name = …` inside the first `[[host]]` block — and this
            // guard is what makes a build that predates a table kind safe to
            // point at a file that carries one.
            if trimmed.hasPrefix("[") { insideTable = true }
            // A `title` inside a `[[quick_action]]` block is not the top-level
            // `title` this is looking for. Without this the first block's line
            // would be rewritten by an unrelated setting that happened to share
            // a name.
            if !insideTable, !replaced, !trimmed.hasPrefix("#"),
               let (found, _) = Self.splitAssignment(trimmed), found == key
            {
                replaced = true
                if let value { output.append("\(key) = \(value)") }
                continue
            }
            output.append(line)
        }
        if !replaced, let value {
            // **Before the first table header, not at the end**, and that is
            // correctness rather than tidiness: in TOML a `key = value` written
            // after `[[quick_action]]` belongs to *that table*, not to the top
            // level. Appending was also self-defeating — the scan above treats
            // everything after a header as part of it, so a key appended past
            // the blocks could never be found again and a second copy was
            // written on every change. Observed: two `debug_inspector_server`
            // lines after two clicks of one menu item.
            let firstHeader = output.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            if var at = firstHeader {
                // Back up over the comment lines directly above the header, so
                // a new key cannot land between somebody's note and the block
                // it was written about. Observed once: a flag inserted itself
                // between `# 我手写的动作` and the `[[quick_action]]` it
                // labelled, which leaves the comment pointing at nothing.
                while at > 0, output[at - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                    at -= 1
                }
                output.insert("\(key) = \(value)", at: at)
            } else {
                if !output.isEmpty, output.last?.trimmingCharacters(in: .whitespaces).isEmpty == false {
                    output.append("")
                }
                output.append("\(key) = \(value)")
            }
        }
        lines = output
        flush()
    }

    /// The array-of-tables cannot be edited a line at a time — the count
    /// changes — so every block is removed and the current set written back in
    /// one run, at the position the first block had. Everything outside the
    /// blocks, comments included, is untouched.
    private func rewriteQuickActionBlocks() {
        var output: [String] = []
        var insideBlock = false
        var insertionPoint: Int?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[[quick_action]]" {
                if insertionPoint == nil { insertionPoint = output.count }
                insideBlock = true
                continue
            }
            if insideBlock {
                // The block ends at the next header, or at a line that is not
                // one of its own assignments.
                if trimmed.hasPrefix("[") { insideBlock = false } else if trimmed.isEmpty { continue } else if let (key, _) = Self.splitAssignment(trimmed), key == "title" || key == "command" {
                    continue
                } else {
                    insideBlock = false
                }
            }
            output.append(line)
        }

        var block: [String] = []
        for action in quickActions {
            block.append("")
            block.append("[[quick_action]]")
            block.append("title = \(Self.encode(action.title))")
            block.append("command = \(Self.encode(action.command))")
        }
        let at = min(insertionPoint ?? output.count, output.count)
        output.insert(contentsOf: block, at: at)
        lines = output
        flush()
    }

    /// Write the whole file, atomically.
    ///
    /// `.atomic` because the alternative — truncate, then write — leaves an
    /// empty config file if anything goes wrong between the two, which for this
    /// file means every setting silently back to its default.
    ///
    /// The failure comes back as prose rather than being swallowed, because
    /// one caller must not ignore it: a host edit that never reached the disk
    /// has to be reported and rolled back, not applied to live connections.
    /// The scalar-setting writers keep their old fire-and-forget shape — the
    /// log line was always their only witness — so the result is discardable.
    @discardableResult
    private func flush() -> String? {
        let text = lines.joined(separator: "\n")
        let url = Self.url
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            // The write is how the file first comes to exist on a fresh
            // install, and existence is what retires legacy adoption.
            activeFileHasExisted = true
            return nil
        } catch {
            TmuxLog.lifecycle("could not write \(url.path): \(error)")
            return error.localizedDescription
        }
    }

    // MARK: - Migration

    /// Move the settings out of the app's plist the first time this build runs,
    /// then take this app's keys out of it.
    ///
    /// The window frames AppKit writes are left alone: they are not ours, there
    /// is no supported way to redirect them, and deleting them would only move
    /// the window on the next launch.
    ///
    /// Runs before anything reads a setting. If the TOML file already exists it
    /// does nothing at all — the file is the truth from then on, including when
    /// the user has edited it to say something the plist disagrees with.
    static func migrateFromUserDefaultsIfNeeded(keys: [String: String]) {
        // An override names a scratch file *instead of* the real one, and this
        // function's whole job is to create a file from settings found elsewhere
        // on the machine. Running it against an override is the same isolation
        // break `adoptLegacyFileIfNeeded` refuses, through a different door: a
        // run meant to start from defaults would come up holding the user's
        // real preferences.
        guard overrideURL == nil else { return }

        // The TmuxGUI-era file counts as "already migrated" — adopting it has to
        // happen before the existence test below, or a machine with settings
        // would be handed a fresh file full of defaults. And if there was one to
        // adopt and the copy failed, stop: writing a file here is what makes the
        // failure permanent.
        guard adoptLegacyFileIfNeeded() else { return }
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        // The legacy domain has to be named, not assumed. `UserDefaults.standard`
        // resolves against the current bundle identifier, which is
        // `me.xueshi.attache`, and the keys in `AppSettings.plistKeys` were
        // written under `dev.xueshi.TmuxGUI` — so `standard` alone can never see
        // them again. That matters for one machine in particular: one that ran a
        // TmuxGUI build old enough to predate the TOML file, and so has no
        // `~/.config/tmux-gui.toml` for `adoptLegacyFileIfNeeded` to carry
        // forward. Without this it starts from defaults and says nothing.
        //
        // Both are consulted, `standard` second, so this stays correct if the
        // identifier ever moves again.
        let domains = [UserDefaults(suiteName: legacyDefaultsDomain), .standard].compactMap { $0 }
        var carried: [(String, Any)] = []
        for (plistKey, tomlKey) in keys.sorted(by: { $0.value < $1.value }) {
            guard let value = domains.lazy.compactMap({ $0.object(forKey: plistKey) }).first
            else { continue }
            carried.append((tomlKey, value))
        }

        var text = """
        # Attaché settings.
        #
        # Yours to edit. The app rewrites only the lines it recognises, so
        # comments, ordering and anything else you put here survive.
        #
        # Window position and size are not here: AppKit writes those to
        # ~/Library/Preferences/me.xueshi.attache.plist and there is no way to
        # redirect them.

        """
        for (key, value) in carried {
            // `as? Bool` is the wrong test for a value that came out of
            // UserDefaults: everything numeric there is an `NSNumber`, and
            // `NSNumber(0) as? Bool` succeeds — it is `false`. That turned a
            // rail tint of 0 into `rail_extra_tint = false`, which then failed
            // to read back as a number and silently became the default. The
            // Core Foundation type is the only thing that tells a stored
            // boolean from a stored zero.
            let stored: Any = value
            // Quick Actions were a JSON blob in the plist. They are blocks at
            // the end of this file now, written by the app on the first change.
            if stored is Data { continue }
            text += "\(key) = \(encode(stored))\n"
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            TmuxLog.lifecycle("could not create \(url.path): \(error) — settings stay in the plist")
            return
        }

        // The keys used to be removed from the plist here, once the new file was
        // safely written. They are deliberately left alone now, and the rename is
        // why: that plist belongs to `dev.xueshi.TmuxGUI`, a bundle identifier
        // this app no longer uses and nothing now reads. Deleting out of it would
        // destroy the only surviving copy of settings somebody may have written
        // years ago, to tidy a file that costs a few hundred bytes and is already
        // inert — the same trade `adoptLegacyFileIfNeeded` makes for
        // `~/.config/tmux-gui.toml`, and the same reason.
        TmuxLog.lifecycle(
            "settings written to \(url.path) — \(carried.count) carried over from"
                + " \(legacyDefaultsDomain), which is left untouched"
        )
    }
}
