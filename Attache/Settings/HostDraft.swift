//
//  HostDraft.swift
//  Attache
//

import Foundation

/// A `[[host]]` block as an editor holds it: every managed field a string,
/// empty meaning "not set". The UI edits one of these and hands it back whole;
/// nothing here is applied until `AppSettings.saveHost` validates it through
/// `HostConfig.parse` — the same parser the launch path trusts, so the editor
/// cannot write a block the app would then refuse to load.
nonisolated struct HostDraft: Equatable {
    var name = ""
    var ssh = ""
    var tmuxPath = ""
    var tmuxSocket = ""
    var gitToolCommand = ""
    var remoteOpenCommand = ""

    init() {}

    /// From a raw block, the way `SettingsFile.hostTables` hands them over.
    /// Unknown keys are deliberately absent here — the writer carries them
    /// through on its own, byte for byte, so a draft never has to know them.
    init(table: [String: String]) {
        func read(_ key: String) -> String {
            table[key]?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        name = read("name")
        ssh = read("ssh")
        tmuxPath = read("tmux_path")
        tmuxSocket = read("tmux_socket")
        gitToolCommand = read("git_tool_command")
        remoteOpenCommand = read("remote_open_command")
    }

    /// The managed fields with values, in the order a fresh block lists them.
    var fields: [(key: String, value: String)] {
        [
            ("name", name), ("ssh", ssh), ("tmux_path", tmuxPath),
            ("tmux_socket", tmuxSocket), ("git_tool_command", gitToolCommand),
            ("remote_open_command", remoteOpenCommand),
        ]
        .map { (key: $0.0, value: $0.1.trimmingCharacters(in: .whitespaces)) }
        .filter { !$0.value.isEmpty }
    }

    /// The same fields as `HostConfig.parse` reads them.
    var tableForValidation: [String: String] {
        Dictionary(fields.map { ($0.key, $0.value) }) { first, _ in first }
    }

    /// Why this draft cannot be saved, or nil. `otherNames` are the hosts the
    /// draft is *not* replacing — the duplicate test `HostConfig.parseAll`
    /// applies across blocks, asked before writing instead of after loading.
    func problem(otherNames: [String]) -> String? {
        switch HostConfig.parse(tableForValidation) {
        case .invalid(let reason):
            // The parser's reasons complete "A [[host]] block …"; an editor
            // speaks about the fields in front of the person instead.
            return "This host \(reason)."
        case .host(let config):
            if otherNames.contains(config.name) {
                return "Another host is already named \"\(config.name)\"."
            }
            return nil
        }
    }

    /// The validated config this draft describes, or nil while it has a
    /// problem. What the Test Connection probe runs against.
    var config: HostConfig? {
        if case .host(let config) = HostConfig.parse(tableForValidation) { return config }
        return nil
    }
}

extension AppSettings {
    /// The `[[host]]` drafts in file order — only the blocks the editor can
    /// address, which is the same set `HostConfig.parseAll` accepts plus any
    /// block that at least carries a usable name. Blocks with no name at all
    /// are invisible here and untouched on every save.
    @MainActor static var hostDrafts: [HostDraft] {
        SettingsFile.shared.hostTables
            .map { HostDraft(table: $0) }
            .filter { !$0.name.isEmpty }
    }

    /// Validate and write one host. `originalName` names the block being
    /// replaced, nil appends a new one. Returns what is wrong, or nil after
    /// the file is written and every open surface notified — the notification
    /// is what makes `MainViewController` reconcile connections, so a
    /// successful save *is* the apply.
    ///
    /// The file is re-read before validating, and `saveHostBlock` resolves
    /// the block by *name* against the same read — never by a position
    /// computed against an older one, which a hand edit or a second copy of
    /// the app would silently invalidate (Codex review). A write that fails
    /// comes back as the reason, with nothing notified: the disk did not
    /// change, so the connections must not either.
    @MainActor @discardableResult
    static func saveHost(_ draft: HostDraft, replacingName originalName: String?) -> String? {
        let file = SettingsFile.shared
        if let refused = file.refreshHostEditView() { return refused }
        var otherNames = file.hostTables
            .compactMap { $0["name"]?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let originalName, let index = otherNames.firstIndex(of: originalName) {
            otherNames.remove(at: index)
        }
        if let problem = draft.problem(otherNames: otherNames) { return problem }
        if let refused = file.saveHostBlock(named: originalName, fields: draft.fields) {
            return refused
        }
        notifyChanged()
        return nil
    }

    /// Delete one block by name. The confirmation lives with the caller —
    /// this only ever runs after the person has read what removal means.
    /// Returns the reason the file could not be written, or nil.
    @MainActor @discardableResult
    static func removeHost(named name: String) -> String? {
        TmuxLog.destructive(
            "removing [[host]] \"\(name)\" from \(SettingsFile.url.path) —"
                + " the app disconnects; tmux on that machine is untouched"
        )
        if let refused = SettingsFile.shared.removeHostBlock(named: name) { return refused }
        notifyChanged()
        return nil
    }
}
