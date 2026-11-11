//
//  Workspaces.swift
//  Attache
//

import Foundation

/// A folder and the command to start in it, saved on the host so a window can
/// be closed and made again with one click.
///
/// They are attache-cli's, like everything else in this folder: the file
/// (`~/.config/attache-workspaces.toml` on the host), the reading and writing
/// of it, and the opening. That is what lets the phone show the same list,
/// and what keeps the folder and the command — the person's own free text —
/// off every command line this app builds: a workspace is named here by its
/// id, and attache-cli hands the text to tmux on the host itself.
///
/// It is not a preference of this app and so not in `SettingsFile`: the
/// folder is a folder on *that* machine, and a remote host's workspaces are
/// meaningless in this Mac's `attache.toml`.
nonisolated struct SavedWorkspace: Equatable, Sendable {
    let id: String
    let name: String
    let path: String
    let command: String
    /// The folder was there when the list was read. Opening asks again.
    let exists: Bool

    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String, WorkspaceCommands.isID(id),
              let name = o["name"] as? String, let path = o["path"] as? String else { return nil }
        self.id = id
        self.name = name
        self.path = path
        command = o["command"] as? String ?? ""
        exists = o["exists"] as? Bool ?? true
    }

    static func parse(_ lines: [String]) -> [SavedWorkspace] {
        lines.compactMap(AttacheCliProtocol.object).compactMap(SavedWorkspace.init)
    }
}

/// What the save form starts from and hands back.
nonisolated struct WorkspaceDraft: Equatable, Sendable {
    var name: String
    var path: String
    var command: String
}

nonisolated struct WorkspaceFailure: Error, Equatable {
    let message: String
}

/// The argv of each `attache-cli workspace …`, and how its one-line answer
/// reads. Every id is checked before it reaches a command line; the three
/// pieces of free text go base64-encoded, as `rename`'s name does.
nonisolated enum WorkspaceCommands {
    static let list = ["workspaces"]

    /// What attache-cli accepts as a workspace id: its `safe_id`.
    static func isID(_ s: String) -> Bool {
        (1...128).contains(s.count)
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// `$3`, `@12`.
    static func isTmuxID(_ s: String, _ sigil: Character) -> Bool {
        s.count > 1 && s.first == sigil && s.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func save(id: String?, _ draft: WorkspaceDraft) -> [String]? {
        var argv = ["workspace", "save"]
        if let id {
            guard isID(id) else { return nil }
            argv += ["--id", id]
        }
        // "=" is the base64 of nothing. An empty command is an ordinary
        // thing to save, and an empty word does not survive ssh, which joins
        // the argv with spaces for the remote shell to split again.
        func encoded(_ text: String) -> String {
            text.isEmpty ? "=" : Data(text.utf8).base64EncodedString()
        }
        return argv + ["--name", encoded(draft.name), "--path", encoded(draft.path),
                       "--command", encoded(draft.command)]
    }

    static func remove(id: String) -> [String]? {
        isID(id) ? ["workspace", "remove", id] : nil
    }

    static func open(id: String, session: String) -> [String]? {
        isID(id) && isTmuxID(session, "$") ? ["workspace", "open", id, "--session", session] : nil
    }

    static func draft(window: String) -> [String]? {
        isTmuxID(window, "@") ? ["workspace", "draft", window] : nil
    }

    /// The answer to a command that prints `{"<flag>":true,…}` or
    /// `{"<flag>":false,"why":…}`. Anything else — no line at all, an older
    /// attache-cli printing its usage — is a failure that says so, never a
    /// success: a save believed to have happened is followed by a kill.
    static func answer(_ lines: [String]?, flag: String) -> Result<[String: Any], WorkspaceFailure> {
        guard let lines else {
            return .failure(WorkspaceFailure(message: "attache-cli did not answer on this host"))
        }
        guard let object = lines.lazy.compactMap(AttacheCliProtocol.object).first(where: { $0[flag] != nil }) else {
            return .failure(WorkspaceFailure(
                message: "attache-cli on this host does not know workspaces yet (it needs 0.3.10)"))
        }
        if object[flag] as? Bool == true { return .success(object) }
        return .failure(WorkspaceFailure(message: object["why"] as? String ?? "attache-cli refused"))
    }
}

/// One host's saved workspaces, as last read.
///
/// A cache, and deliberately a thin one: a menu has to be built the moment it
/// is asked for, so it is built from the last list and a fresh read is
/// started for the next time. Every change made here reads the list again
/// when it lands; one made on the phone or by hand shows the second time the
/// menu opens.
@MainActor
final class HostWorkspaces {
    private static var byHost: [String: HostWorkspaces] = [:]

    static func shared(for transport: TmuxTransport) -> HostWorkspaces {
        let key = transport.hostLabel
        if let existing = byHost[key], existing.link.transport == transport { return existing }
        let made = HostWorkspaces(link: AttacheCliLink(transport: transport))
        byHost[key] = made
        return made
    }

    let link: AttacheCliLink
    private(set) var workspaces: [SavedWorkspace] = []
    private var reading = false
    /// Asked for while a read was already out. That read may have left
    /// before the change that prompted this one landed, so its answer
    /// cannot stand for it: another read follows, and these wait for that.
    private var readAgain: [() -> Void]?

    private init(link: AttacheCliLink) {
        self.link = link
    }

    /// attache-cli reaches tmux by the default socket only, so on a server
    /// chosen with `tmux_socket` an `open --session $3` would land in
    /// whatever `$3` is on the *default* server. Refused rather than risked.
    private var reachesThisServer: Bool { link.transport.socket == .standard }

    private static let wrongSocket = WorkspaceFailure(
        message: "workspaces work on the default tmux socket only, and tmux_socket names another")

    private static let badID = WorkspaceFailure(message: "not a workspace, session or window id")

    func refresh(then done: (() -> Void)? = nil) {
        guard !reading else {
            readAgain = (readAgain ?? []) + (done.map { [$0] } ?? [])
            return
        }
        reading = true
        run(WorkspaceCommands.list) { [weak self] lines in
            guard let self else { return }
            reading = false
            // A host that did not answer keeps the list it had: an empty
            // menu would read as "everything was deleted".
            if let lines { workspaces = SavedWorkspace.parse(lines) }
            done?()
            if let waiting = readAgain {
                readAgain = nil
                refresh { waiting.forEach { $0() } }
            }
        }
    }

    func draft(window: String, completion: @escaping (Result<WorkspaceDraft, WorkspaceFailure>) -> Void) {
        guard reachesThisServer else { return completion(.failure(Self.wrongSocket)) }
        guard let argv = WorkspaceCommands.draft(window: window) else { return completion(.failure(Self.badID)) }
        run(argv) { lines in
            completion(WorkspaceCommands.answer(lines, flag: "draft").map { o in
                WorkspaceDraft(name: o["name"] as? String ?? "", path: o["path"] as? String ?? "",
                               command: o["command"] as? String ?? "")
            })
        }
    }

    func save(id: String?, _ draft: WorkspaceDraft,
              completion: @escaping (Result<Void, WorkspaceFailure>) -> Void) {
        guard let argv = WorkspaceCommands.save(id: id, draft) else { return completion(.failure(Self.badID)) }
        run(argv) { [weak self] lines in
            let answer = WorkspaceCommands.answer(lines, flag: "saved").map { _ in }
            self?.refresh { completion(answer) }
        }
    }

    func remove(id: String, completion: @escaping (Result<Void, WorkspaceFailure>) -> Void) {
        guard let argv = WorkspaceCommands.remove(id: id) else { return completion(.failure(Self.badID)) }
        run(argv) { [weak self] lines in
            let answer = WorkspaceCommands.answer(lines, flag: "removed").map { _ in }
            self?.refresh { completion(answer) }
        }
    }

    /// Makes the window. tmux selects it and says so on the control
    /// connection like any other new window; nothing is drawn from this
    /// answer.
    func open(id: String, session: String,
              completion: @escaping (Result<Void, WorkspaceFailure>) -> Void) {
        guard reachesThisServer else { return completion(.failure(Self.wrongSocket)) }
        guard let argv = WorkspaceCommands.open(id: id, session: session) else { return completion(.failure(Self.badID)) }
        run(argv) { lines in
            completion(WorkspaceCommands.answer(lines, flag: "opened").map { _ in })
        }
    }

    /// Through the installer first: the host may never have had attache-cli,
    /// or have one from before it knew workspaces.
    private func run(_ argv: [String], completion: @escaping @MainActor ([String]?) -> Void) {
        AttacheCliInstaller.shared.ensure(link) { [link] outcome in
            guard case .ready = outcome else { return completion(nil) }
            link.run(argv, completion: completion)
        }
    }
}
