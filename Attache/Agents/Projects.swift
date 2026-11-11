//
//  Projects.swift
//  Attache
//

import Foundation

/// A folder and the command to start in it, saved on the host so a window can
/// be closed and made again with one click.
///
/// They are attache-cli's, like everything else in this folder: the file
/// (`~/.config/attache-projects.toml` on the host), the reading and writing
/// of it, and the opening. That is what lets the phone show the same list,
/// and what keeps the folder and the command — the person's own free text —
/// off every command line this app builds: a project is named here by its
/// id, and attache-cli hands the text to tmux on the host itself.
///
/// It is not a preference of this app and so not in `SettingsFile`: the
/// folder is a folder on *that* machine, and a remote host's projects are
/// meaningless in this Mac's `attache.toml`.
nonisolated struct SavedProject: Equatable, Sendable {
    let id: String
    let name: String
    let path: String
    let command: String
    /// The folder was there when the list was read. Opening asks again.
    let exists: Bool

    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String, ProjectCommands.isID(id),
              let name = o["name"] as? String, let path = o["path"] as? String else { return nil }
        self.id = id
        self.name = name
        self.path = path
        command = o["command"] as? String ?? ""
        exists = o["exists"] as? Bool ?? true
    }

    static func parse(_ lines: [String]) -> [SavedProject] {
        lines.compactMap(AttacheCliProtocol.object).compactMap(SavedProject.init)
    }
}

/// What the save form starts from and hands back.
nonisolated struct ProjectDraft: Equatable, Sendable {
    var name: String
    var path: String
    var command: String
}

nonisolated struct ProjectFailure: Error, Equatable {
    let message: String
}

/// The argv of each `attache-cli project …`, and how its one-line answer
/// reads. Every id is checked before it reaches a command line; the three
/// pieces of free text go base64-encoded, as `rename`'s name does.
nonisolated enum ProjectCommands {
    static let list = ["projects"]

    /// What attache-cli accepts as a project id: its `safe_id`.
    static func isID(_ s: String) -> Bool {
        (1...128).contains(s.count)
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// `$3`, `@12`.
    static func isTmuxID(_ s: String, _ sigil: Character) -> Bool {
        s.count > 1 && s.first == sigil && s.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func save(id: String?, _ draft: ProjectDraft) -> [String]? {
        var argv = ["project", "save"]
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
        isID(id) ? ["project", "remove", id] : nil
    }

    static func open(id: String, session: String) -> [String]? {
        isID(id) && isTmuxID(session, "$") ? ["project", "open", id, "--session", session] : nil
    }

    /// Replaces the often-used commands: one a line, base64-encoded like the
    /// rest. "=" for none, for the reason `save` has.
    static func setCommands(_ commands: [String]) -> [String] {
        let text = commands.joined(separator: "\n")
        return ["project", "commands", "--set", text.isEmpty ? "=" : Data(text.utf8).base64EncodedString()]
    }

    /// The `{"commands":[…]}` line that ends `projects` and answers
    /// `project commands`; nil when there is none, which is an attache-cli
    /// from before the list existed, or a refusal.
    static func commands(in lines: [String]) -> [String]? {
        lines.lazy.compactMap(AttacheCliProtocol.object).compactMap { $0["commands"] as? [String] }.first
    }

    /// The line that ends every whole `projects` answer.
    static func last(_ lines: [String]) -> [String: Any]? {
        lines.last.flatMap(AttacheCliProtocol.object).flatMap { $0["commands"] != nil ? $0 : nil }
    }

    static func draft(window: String) -> [String]? {
        isTmuxID(window, "@") ? ["project", "draft", window] : nil
    }

    /// The answer to a command that prints `{"<flag>":true,…}` or
    /// `{"<flag>":false,"why":…}`. Anything else — no line at all, an older
    /// attache-cli printing its usage — is a failure that says so, never a
    /// success: a save believed to have happened is followed by a kill.
    static func answer(_ lines: [String]?, flag: String) -> Result<[String: Any], ProjectFailure> {
        guard let lines else {
            return .failure(ProjectFailure(message: "attache-cli did not answer on this host"))
        }
        guard let object = lines.lazy.compactMap(AttacheCliProtocol.object).first(where: { $0[flag] != nil }) else {
            return .failure(ProjectFailure(
                message: "attache-cli on this host does not know projects yet (it needs 0.3.13)"))
        }
        if object[flag] as? Bool == true { return .success(object) }
        return .failure(ProjectFailure(message: object["why"] as? String ?? "attache-cli refused"))
    }
}

/// One host's saved projects, as last read.
///
/// A cache, and deliberately a thin one: a menu has to be built the moment it
/// is asked for, so it is built from the last list and a fresh read is
/// started for the next time. Every change made here reads the list again
/// when it lands; one made on the phone or by hand shows the second time the
/// menu opens.
@MainActor
final class HostProjects {
    private static var byHost: [String: HostProjects] = [:]

    static func shared(for transport: TmuxTransport) -> HostProjects {
        let key = transport.hostLabel
        if let existing = byHost[key], existing.link.transport == transport { return existing }
        let made = HostProjects(link: AttacheCliLink(transport: transport))
        byHost[key] = made
        return made
    }

    let link: AttacheCliLink
    private(set) var projects: [SavedProject] = []
    /// The person's often-used commands, kept on the host beside the
    /// projects so the phone offers the same ones.
    private(set) var commands: [String] = []
    /// Why the list cannot be edited from here, when it cannot: the person
    /// wrote it in the file in a way attache-cli reads as theirs alone.
    private(set) var commandsRefusal: String?

    /// What the save form offers for a command: that list and nothing else,
    /// so the form and the list's editor always show the same commands.
    /// attache-cli fills it from the saved projects until the person writes
    /// one; mixing those in here as well made the form offer `cyolo` while
    /// the editor opened empty.
    var commandSuggestions: [String] { commands }
    private var reading = false
    /// Asked for while a read was already out. That read may have left
    /// before the change that prompted this one landed, so its answer
    /// cannot stand for it: another read follows, and these wait for that.
    private var readAgain: [(Bool) -> Void]?

    private init(link: AttacheCliLink) {
        self.link = link
    }

    /// attache-cli reaches tmux by the default socket only, so on a server
    /// chosen with `tmux_socket` an `open --session $3` would land in
    /// whatever `$3` is on the *default* server. Refused rather than risked.
    private var reachesThisServer: Bool { link.transport.socket == .standard }

    private static let wrongSocket = ProjectFailure(
        message: "projects work on the default tmux socket only, and tmux_socket names another")

    private static let badID = ProjectFailure(message: "not a project, session or window id")

    /// `done` hears whether the host answered with a whole list. Anything
    /// that goes on to *write* from what was read has to look at it.
    func refresh(then done: ((Bool) -> Void)? = nil) {
        guard !reading else {
            readAgain = (readAgain ?? []) + (done.map { [$0] } ?? [])
            return
        }
        reading = true
        run(ProjectCommands.list) { [weak self] lines in
            guard let self else { return }
            reading = false
            // A host that did not answer keeps the list it had: an empty
            // menu would read as "everything was deleted".
            //
            // "Answered" is the `{"commands":…}` line that ends every whole
            // answer, not merely some lines: `AttacheCliLink.run` hands back
            // an empty list for an ssh that dropped or an attache-cli that
            // exited with an error, and taking that for "nothing saved"
            // emptied the menu — and would have opened the commands editor
            // on a blank list for the person to save over the real one.
            let read = lines.flatMap(ProjectCommands.last)
            if let lines, let read {
                projects = SavedProject.parse(lines)
                commands = read["commands"] as? [String] ?? []
                commandsRefusal = read["commands_why"] as? String
            }
            done?(read != nil)
            if let waiting = readAgain {
                readAgain = nil
                refresh { ok in waiting.forEach { $0(ok) } }
            }
        }
    }

    func draft(window: String, completion: @escaping (Result<ProjectDraft, ProjectFailure>) -> Void) {
        guard reachesThisServer else { return completion(.failure(Self.wrongSocket)) }
        guard let argv = ProjectCommands.draft(window: window) else { return completion(.failure(Self.badID)) }
        run(argv) { lines in
            completion(ProjectCommands.answer(lines, flag: "draft").map { o in
                ProjectDraft(name: o["name"] as? String ?? "", path: o["path"] as? String ?? "",
                               command: o["command"] as? String ?? "")
            })
        }
    }

    func save(id: String?, _ draft: ProjectDraft,
              completion: @escaping (Result<Void, ProjectFailure>) -> Void) {
        guard let argv = ProjectCommands.save(id: id, draft) else { return completion(.failure(Self.badID)) }
        run(argv) { [weak self] lines in
            let answer = ProjectCommands.answer(lines, flag: "saved").map { _ in }
            self?.refresh { _ in completion(answer) }
        }
    }

    func remove(id: String, completion: @escaping (Result<Void, ProjectFailure>) -> Void) {
        guard let argv = ProjectCommands.remove(id: id) else { return completion(.failure(Self.badID)) }
        run(argv) { [weak self] lines in
            let answer = ProjectCommands.answer(lines, flag: "removed").map { _ in }
            self?.refresh { _ in completion(answer) }
        }
    }

    func setCommands(_ list: [String], completion: @escaping (Result<Void, ProjectFailure>) -> Void) {
        run(ProjectCommands.setCommands(list)) { [weak self] lines in
            // `commands` is the list on success and `false` on a refusal, so
            // the flag reader cannot be used: it wants a Bool.
            let answer: Result<Void, ProjectFailure>
            if let lines, ProjectCommands.commands(in: lines) != nil {
                answer = .success(())
            } else {
                answer = ProjectCommands.answer(lines, flag: "commands").map { _ in }
            }
            self?.refresh { _ in completion(answer) }
        }
    }

    /// Makes the window. tmux selects it and says so on the control
    /// connection like any other new window; nothing is drawn from this
    /// answer.
    func open(id: String, session: String,
              completion: @escaping (Result<Void, ProjectFailure>) -> Void) {
        guard reachesThisServer else { return completion(.failure(Self.wrongSocket)) }
        guard let argv = ProjectCommands.open(id: id, session: session) else { return completion(.failure(Self.badID)) }
        run(argv) { lines in
            completion(ProjectCommands.answer(lines, flag: "opened").map { _ in })
        }
    }

    /// Through the installer first: the host may never have had attache-cli,
    /// or have one from before it knew projects.
    private func run(_ argv: [String], completion: @escaping @MainActor ([String]?) -> Void) {
        AttacheCliInstaller.shared.ensure(link) { [link] outcome in
            guard case .ready = outcome else { return completion(nil) }
            link.run(argv, completion: completion)
        }
    }
}
