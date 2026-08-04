//
//  RemoteLinkResolver.swift
//  Attache
//

import Foundation

/// ⌘-click against a remote pane: the same decision table, fed differently.
///
/// Requirement zero (issue #5): the *local* existence check must be
/// unreachable for a remote pane. Two machines with the same layout make the
/// local check answer `.file` for a path that names a different file here —
/// the wrong-file hazard in a helpful disguise. So the candidates `resolve`
/// could probe are enumerated up front (`TerminalLinkTarget.candidatePaths`,
/// pure), classified on the pane's machine in **one** helper round trip, and
/// the unchanged decision table runs against the answers as a lookup —
/// `Tools/LinkTargetCheck` asserts the enumeration covers every probe.
@MainActor
enum RemoteLinkResolver {
    /// `~` cannot be expanded for another machine without knowing its home;
    /// candidates built against this sentinel are refused rather than probed,
    /// because a wrong expansion is a real path on the wrong machine.
    private static let unknownHome = "\u{01}unknown-home\u{01}"

    /// nil means "could not ask" — the caller says so instead of `missing`.
    static func resolve(
        raw: String, cwd: String?, helper: RemoteHelper,
        completion: @escaping @MainActor (TerminalLinkTarget?) -> Void
    ) {
        let candidates = TerminalLinkTarget.candidatePaths(raw, cwd: cwd, home: unknownHome)
        guard !candidates.contains(where: { $0.contains(unknownHome) }) else {
            return completion(.unsupported)
        }
        guard !candidates.isEmpty else {
            // A URL, or a relative path with no directory to resolve against:
            // no disk is involved, the pure table answers alone.
            return completion(TerminalLinkTarget.resolve(
                raw, cwd: cwd, home: unknownHome, existence: { _ in .absent }
            ))
        }
        helper.classify(paths: candidates) { outcome in
            switch outcome {
            case .answered(let kinds):
                var table = [String: TerminalLinkTarget.Existence]()
                for (path, kind) in zip(candidates, kinds) {
                    table[path] = switch kind {
                    case .file: .file
                    case .directory: .directory
                    case .missing: .absent
                    }
                }
                completion(TerminalLinkTarget.resolve(
                    raw, cwd: cwd, home: unknownHome, existence: { table[$0] ?? .absent }
                ))
            case .absent, .unavailable:
                completion(nil)
            }
        }
    }
}

/// What a resolved remote file or directory opens *with*: the
/// `remote_open_command` template, or a `code` CLI found locally, or an
/// honest refusal that names the knob.
///
/// The rejected designs are worth a line each (issue #5's research): opening
/// the same-named local path is the wrong-file hazard again; copying to a
/// temp file and Quick Looking hands the person an editable copy whose edits
/// vanish — a data-loss shape; `sftp://` has no Finder support to lean on.
@MainActor
enum RemoteOpener {
    /// `%h` → the ssh destination and `%p` → the remote path, **both
    /// substituted already shell-quoted**: the template is the user's own
    /// `/bin/sh -c` line, and while the destination is validated, validation
    /// refuses quotes and whitespace, not `$(…)` or `;` — quoting is what
    /// makes each placeholder exactly one word whatever it holds.
    static func open(
        path: String, host: String, destination: String, template: String?,
        status: @escaping @MainActor (String) -> Void
    ) {
        guard let command = template ?? defaultTemplate() else {
            status(
                "Attaché: no way to open a file on \(host) — set remote_open_command"
                    + " in its [[host]] block in ~/.config/attache.toml"
            )
            return
        }
        let line = command
            .replacingOccurrences(of: "%h", with: TmuxTransport.shellQuote(destination))
            .replacingOccurrences(of: "%p", with: TmuxTransport.shellQuote(path))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            let said = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                status("Attaché: remote open failed — \(said.isEmpty ? line : said)")
            }
        }
        do {
            try process.run()
            TmuxLog.lifecycle("remote open on \(host): \(line)")
        } catch {
            status("Attaché: remote open would not start — \(error.localizedDescription)")
        }
    }

    /// A VS Code (or fork) CLI on this machine gets a working default; the
    /// invocation is web-sourced, so anyone it fails for has the template
    /// knob. Probed once per run.
    private static var probedDefault: String??

    private static func defaultTemplate() -> String? {
        if let probedDefault { return probedDefault }
        let candidates = [
            "/opt/homebrew/bin/code", "/usr/local/bin/code",
            "/opt/homebrew/bin/cursor", "/usr/local/bin/cursor",
        ]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        let template = found.map {
            "\(TmuxTransport.shellQuote($0)) --remote ssh-remote+%h %p"
        }
        probedDefault = .some(template)
        return template
    }
}
