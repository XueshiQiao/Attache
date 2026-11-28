//
//  Tags.swift
//  Attache
//

import Foundation

/// A name the person puts on a tmux window — "Follow up", "Daily" — so a
/// window worth coming back to stands apart from one that can be closed
/// when it is done.
///
/// Two halves, neither authored here. Which tags exist (id, name, colour)
/// is attache-cli's, in `~/.config/attache-tags.toml` on the host, so the
/// phone lists the same ones. Which window carries which is the window's own
/// tmux option `@attache_tags`, a comma-separated list of ids, so it goes
/// when the window goes and a plain `tmux show-options -w` agrees with the
/// rail. Only ids are ever written there, which is what lets this app set
/// the option through its control client without quoting anything.
nonisolated struct WindowTag: Equatable, Sendable {
    let id: String
    let name: String
    /// One of `TagCommands.colors`; anything else is drawn as the first.
    let color: String

    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String, TagCommands.isID(id),
              let name = o["name"] as? String, !name.isEmpty else { return nil }
        self.id = id
        self.name = name
        let color = o["color"] as? String ?? ""
        self.color = TagCommands.colors.contains(color) ? color : TagCommands.colors[0]
    }
}

nonisolated struct TagFailure: Error, Equatable {
    let message: String
}

/// The argv of each `attache-cli tag …`, the tmux commands that put tags on
/// a window, and how the answers read.
nonisolated enum TagCommands {
    static let list = ["tags"]

    /// The window option holding a window's tag ids.
    static let windowOption = "@attache_tags"
    /// The global option attache-cli sets anew on every change to the list.
    static let revisionOption = "@attache_tags_rev"

    /// The colour names attache-cli accepts, in the order a menu offers them.
    static let colors = ["gray", "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"]

    /// attache-cli's `safe_id`. A comma is not in it, so ids joined by commas
    /// split back into exactly the same ids.
    static func isID(_ s: String) -> Bool {
        (1...128).contains(s.count)
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func save(id: String?, name: String, color: String) -> [String]? {
        guard colors.contains(color), !name.isEmpty else { return nil }
        var argv = ["tag", "save"]
        if let id {
            guard isID(id) else { return nil }
            argv += ["--id", id]
        }
        return argv + ["--name", Data(name.utf8).base64EncodedString(), "--color", color]
    }

    static func remove(id: String) -> [String]? {
        isID(id) ? ["tag", "remove", id] : nil
    }

    /// The ids in a window option's value, in order, without repeats or
    /// anything that is not an id.
    static func ids(in value: String) -> [String] {
        var out = [String]()
        for id in value.split(separator: ",").map(String.init) where isID(id) && !out.contains(id) {
            out.append(id)
        }
        return out
    }

    /// The tmux command that makes `window` carry exactly `ids`; nil for
    /// anything that is not a window id. No tag at all unsets the option
    /// rather than leaving an empty one behind.
    static func setWindowTags(window: String, ids: [String]) -> String? {
        guard ProjectCommands.isTmuxID(window, "@") else { return nil }
        let kept = ids.filter(isID)
        if kept.isEmpty { return "set-option -wu -t \(window) \(windowOption)" }
        return "set-option -w -t \(window) \(windowOption) \(kept.joined(separator: ","))"
    }

    /// The `{"tags":[…]}` line that is the whole answer to `tags`; nil when
    /// there is none, which is an attache-cli from before tags, or a host
    /// that did not answer.
    static func parse(_ lines: [String]) -> [WindowTag]? {
        guard let object = lines.lazy.compactMap(AttacheCliProtocol.object).first(where: { $0["tags"] != nil }),
              let list = object["tags"] as? [[String: Any]] else { return nil }
        return list.compactMap(WindowTag.init)
    }

    /// The answer to a command that prints `{"<flag>":true,…}` or
    /// `{"<flag>":false,"why":…}`.
    static func answer(_ lines: [String]?, flag: String) -> Result<[String: Any], TagFailure> {
        guard let lines else {
            return .failure(TagFailure(message: "attache-cli did not answer on this host"))
        }
        guard let object = lines.lazy.compactMap(AttacheCliProtocol.object).first(where: { $0[flag] != nil }) else {
            return .failure(TagFailure(message: "attache-cli on this host does not know tags yet (it needs 0.3.22)"))
        }
        if object[flag] as? Bool == true { return .success(object) }
        return .failure(TagFailure(message: object["why"] as? String ?? "attache-cli refused"))
    }
}

/// One host's tags, as last read.
///
/// The rail draws every window's tags from this on every rebuild, so it is
/// read once when the host is first drawn and again only when told to: when
/// the host's `@attache_tags_rev` changes (any client's save or remove), when
/// a window names an id this list does not have, or when a change made here
/// lands. Nothing reads it on a timer.
@MainActor
final class HostTags {
    private static var byHost: [String: HostTags] = [:]

    static func shared(for transport: TmuxTransport) -> HostTags {
        let key = transport.hostLabel
        if let existing = byHost[key], existing.link.transport == transport { return existing }
        let made = HostTags(link: AttacheCliLink(transport: transport))
        byHost[key] = made
        return made
    }

    let link: AttacheCliLink
    private(set) var tags: [WindowTag] = []
    /// Called when a read changed the list, so the rail can redraw.
    var onChange: (() -> Void)?

    private var everRead = false
    private var reading = false
    /// Asked for while a read was already out. That read may have left
    /// before the change that prompted this one landed, so another read
    /// follows, and these wait for it.
    private var readAgain: [(Bool) -> Void]?
    /// The revision the last read was started for.
    private var revision: String?
    /// Ids already asked about once, so a window carrying an id that no
    /// longer exists anywhere does not start a read on every rebuild.
    private var askedAbout = Set<String>()

    private init(link: AttacheCliLink) {
        self.link = link
    }

    func tag(id: String) -> WindowTag? {
        tags.first { $0.id == id }
    }

    /// The tags `ids` name, in the list's order. Starts a read, once, when
    /// one of them is unknown: it was most likely made on another client.
    func resolve(_ ids: [String]) -> [WindowTag] {
        let unknown = ids.filter { tag(id: $0) == nil && !askedAbout.contains($0) }
        if !unknown.isEmpty, everRead {
            askedAbout.formUnion(unknown)
            refresh()
        }
        return tags.filter { ids.contains($0.id) }
    }

    /// What the rail calls on every rebuild with the host's
    /// `@attache_tags_rev`: reads the list the first time, and again whenever
    /// the revision moved.
    func note(revision: String?) {
        if everRead || reading, revision == self.revision { return }
        self.revision = revision
        refresh()
    }

    func refresh(then done: ((Bool) -> Void)? = nil) {
        guard !reading else {
            readAgain = (readAgain ?? []) + (done.map { [$0] } ?? [])
            return
        }
        reading = true
        run(TagCommands.list) { [weak self] lines in
            guard let self else { return }
            reading = false
            let read = lines.flatMap(TagCommands.parse)
            // A host that did not answer keeps the list it had: an empty
            // list would take every chip off the rail.
            if let read {
                everRead = true
                if read != tags {
                    tags = read
                    onChange?()
                }
            }
            done?(read != nil)
            if let waiting = readAgain {
                readAgain = nil
                refresh { ok in waiting.forEach { $0(ok) } }
            }
        }
    }

    func save(id: String?, name: String, color: String,
              completion: @escaping (Result<WindowTag, TagFailure>) -> Void) {
        guard let argv = TagCommands.save(id: id, name: name, color: color) else {
            return completion(.failure(TagFailure(message: "a tag needs a name and one of the colours")))
        }
        run(argv) { [weak self] lines in
            let answer = TagCommands.answer(lines, flag: "saved").flatMap { o in
                WindowTag(o).map(Result.success)
                    ?? .failure(TagFailure(message: "attache-cli answered without the tag"))
            }
            self?.refresh { _ in completion(answer) }
        }
    }

    func remove(id: String, completion: @escaping (Result<Void, TagFailure>) -> Void) {
        guard let argv = TagCommands.remove(id: id) else {
            return completion(.failure(TagFailure(message: "not a tag id")))
        }
        run(argv) { [weak self] lines in
            let answer = TagCommands.answer(lines, flag: "removed").map { _ in }
            self?.refresh { _ in completion(answer) }
        }
    }

    /// Through the installer first: the host may never have had attache-cli,
    /// or have one from before it knew tags.
    private func run(_ argv: [String], completion: @escaping @MainActor ([String]?) -> Void) {
        AttacheCliInstaller.shared.ensure(link) { [link] outcome in
            guard case .ready = outcome else { return completion(nil) }
            link.run(argv, completion: completion)
        }
    }
}
