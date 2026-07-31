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
        FileManager.default.homeDirectoryForCurrentUser
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
        guard overrideURL == nil else { return true }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: defaultURL.path),
              manager.fileExists(atPath: legacyURL.path) else { return true }
        try? manager.createDirectory(
            at: defaultURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try manager.copyItem(at: legacyURL, to: defaultURL)
            return true
        } catch {
            // Loud, and the caller stops. A swallowed failure here used to hand
            // control to the plist migration below, which — on a machine that
            // moved to the TOML file long ago and so has almost nothing left in
            // its plist — would write a nearly empty `attache.toml`. Every later
            // launch then sees a destination that exists, skips this, and the
            // user's real settings are gone with nothing to say so.
            TmuxLog.lifecycle(
                "could not copy \(legacyURL.path) to \(defaultURL.path): \(error)"
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
    private func reload() {
        // Before the read, not at launch: `reload` is the one path every read
        // and every write goes through, so there is no order of operations that
        // can reach the file ahead of the rename.
        Self.adoptLegacyFileIfNeeded()
        guard let text = try? String(contentsOf: Self.url, encoding: .utf8) else {
            // No file yet. Everything answers with its default until something
            // is written, and the first write creates the file.
            return
        }
        lines = text.components(separatedBy: "\n")
        parse()
    }

    private func parse() {
        values = [:]
        quickActions = []
        var pendingAction: (title: String?, command: String?)?

        func commitPendingAction() {
            guard let pending = pendingAction else { return }
            pendingAction = nil
            guard let title = pending.title, let command = pending.command else { return }
            quickActions.append(QuickAction(title: title, command: command))
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "[[quick_action]]" {
                commitPendingAction()
                pendingAction = (nil, nil)
                continue
            }
            // Any other table header ends the array-of-tables run.
            if line.hasPrefix("[") {
                commitPendingAction()
                continue
            }
            guard let (key, value) = Self.splitAssignment(line) else { continue }
            if pendingAction != nil {
                if key == "title" { pendingAction?.title = value as? String }
                if key == "command" { pendingAction?.command = value as? String }
            } else {
                values[key] = value
            }
        }
        commitPendingAction()
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
        var insideQuickAction = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { insideQuickAction = trimmed == "[[quick_action]]" }
            // A `title` inside a `[[quick_action]]` block is not the top-level
            // `title` this is looking for. Without this the first block's line
            // would be rewritten by an unrelated setting that happened to share
            // a name.
            if !insideQuickAction, !replaced, !trimmed.hasPrefix("#"),
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
    private func flush() {
        let text = lines.joined(separator: "\n")
        let url = Self.url
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            TmuxLog.lifecycle("could not write \(url.path): \(error)")
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
