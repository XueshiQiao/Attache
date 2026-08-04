//
//  RemoteAgentSetup.swift
//  Attache
//

import Foundation

/// Installs the agent hooks and the status-line wrapper on a remote host —
/// the same transforms the local installers use, with the file I/O crossing
/// ssh. Claude Code lives on the machine the agent runs on, so a remote pane
/// gets badges and a transcript only once *that* machine's
/// `~/.claude/settings.json` carries the entries.
///
/// What is reused and what is not, and why:
/// - `AgentHookInstaller.merge`/`unmerge`/`validateShape` run here verbatim,
///   against the remote file's JSON, with the *remote* script path — the
///   transforms were kept pure precisely so no second copy of "which entries
///   are ours" could drift.
/// - `StatusLineRecovery` classifies and records the remote status line the
///   same way it does the local one; the recovery record (the original
///   `statusLine` object, verbatim) travels *into the remote conf file*, so
///   an uninstall restores fields this build never understood.
/// - The write sequence is **one remote exec** per file: resolve the symlink
///   chain, recompute the content checksum and compare it against the one
///   taken from the read bytes, back up, write a temp file, `mv`. A
///   compare-and-swap on content, because any token sampled separately from
///   the bytes it protects is a lost-update window measured in RTTs.
///
/// Reads go over the helper channel; the guarded writes are one-shot execs
/// whose exit status is real (the same reason the remote paste is one).
@MainActor
final class RemoteAgentSetup {
    enum State: Equatable {
        case unknown
        case unreachable(String)
        case notInstalled
        /// Installed by an older build — the script stamp is behind.
        case needsUpdate
        case installed
        /// The remote settings hold something this build refuses to touch.
        case refused(String)
    }

    private(set) var hookState = State.unknown
    private(set) var statusLineState = State.unknown
    /// The remote status line command an install would wrap, when foreign.
    private(set) var statusLineWrapped: String?
    var onChange: (() -> Void)?

    private let helper: RemoteHelper
    private let transport: TmuxTransport
    private let hostName: String
    private var remoteHome: String?

    init(helper: RemoteHelper, transport: TmuxTransport, hostName: String) {
        self.helper = helper
        self.transport = transport
        self.hostName = hostName
    }

    // MARK: - Paths (all on the other machine)

    private func paths(home: String) -> (settings: String, hooks: String, hookScript: String,
                                         wrapper: String, minimal: String, conf: String)
    {
        let hooks = home + "/.claude/hooks"
        return (
            settings: home + "/.claude/settings.json",
            hooks: hooks,
            hookScript: hooks + "/tmuxgui-agent-state.sh",
            wrapper: hooks + "/tmuxgui-statusline.sh",
            minimal: hooks + "/tmuxgui-statusline-minimal.sh",
            conf: hooks + "/tmuxgui-statusline.conf"
        )
    }

    // MARK: - State

    /// Refresh both states in one sweep: HOME, settings.json, and the two
    /// script stamps, all over the helper. Called when the Settings window
    /// asks, not on any schedule — install state changes when somebody
    /// installs, not by itself.
    func refreshState() {
        helper.home { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .answered(let home):
                self.remoteHome = home
                self.readState(home: home)
            case .absent, .unavailable:
                self.hookState = .unreachable("can't reach \(self.hostName)")
                self.statusLineState = self.hookState
                self.onChange?()
            }
        }
    }

    private func readState(home: String) {
        let paths = paths(home: home)
        helper.read(path: paths.settings, maxBytes: 4 * 1024 * 1024) { [weak self] settingsOutcome in
            guard let self else { return }
            self.helper.read(path: paths.hookScript, maxBytes: 512) { [weak self] hookScript in
                guard let self else { return }
                self.helper.read(path: paths.wrapper, maxBytes: 512) { [weak self] wrapper in
                    guard let self else { return }
                    self.settle(
                        home: home, settings: settingsOutcome,
                        hookScript: hookScript, wrapper: wrapper
                    )
                }
            }
        }
    }

    private func settle(
        home: String,
        settings settingsOutcome: HelperOutcome<Data>,
        hookScript: HelperOutcome<Data>,
        wrapper: HelperOutcome<Data>
    ) {
        let paths = paths(home: home)
        let settings: [String: Any]
        switch settingsOutcome {
        case .unavailable(let reason):
            hookState = .unreachable(reason)
            statusLineState = hookState
            onChange?()
            return
        case .absent:
            settings = [:]
        case .answered(let data):
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                hookState = .refused("settings.json on \(hostName) is not valid JSON")
                statusLineState = hookState
                onChange?()
                return
            }
            settings = parsed
        }

        // Hooks: installed means the merged form is already what is there
        // *and* the script carries the current stamp.
        let merged = AgentHookInstaller.merge(intoSettings: settings, scriptPath: paths.hookScript)
        let entriesCurrent = AgentHookInstaller.same(merged, settings)
        let entriesPresent = settingsMentions(settings, path: paths.hookScript)
        switch (entriesPresent, entriesCurrent, stamp(of: hookScript)) {
        case (false, _, _):
            hookState = .notInstalled
        case (true, true, AgentHookInstaller.scriptVersion):
            hookState = .installed
        default:
            hookState = .needsUpdate
        }

        // Status line: classified by the same pure rules as the local file.
        let command = (settings["statusLine"] as? [String: Any])?["command"] as? String
        switch StatusLineRecovery.classify(command, scriptPath: paths.wrapper, home: home) {
        case .ours:
            statusLineState = stamp(of: wrapper) == AgentStatusLineInstaller.scriptVersion
                ? .installed : .needsUpdate
            statusLineWrapped = nil
        case .foreign(let raw):
            statusLineState = .notInstalled
            statusLineWrapped = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .unrecognised(let raw):
            statusLineState = .refused(
                "the status line on \(hostName) names our script but was edited: \(raw)"
            )
            statusLineWrapped = nil
        }
        onChange?()
    }

    private func settingsMentions(_ settings: [String: Any], path: String) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: settings) else { return false }
        return String(decoding: data, as: UTF8.self).contains(path)
    }

    /// `# attache-hook-version: N` out of a script's first bytes, or nil.
    private func stamp(of outcome: HelperOutcome<Data>) -> Int? {
        guard case .answered(let data) = outcome else { return nil }
        let head = String(decoding: data, as: UTF8.self)
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# attache-hook-version: ") {
                return Int(line.dropFirst("# attache-hook-version: ".count))
            }
        }
        return nil
    }

    // MARK: - Install / uninstall

    /// Everything in one action: both scripts, the conf, and one guarded
    /// settings write carrying the hooks *and* the status line. One action
    /// rather than two buttons because remotely the expensive, careful part
    /// is the settings write, and two buttons would do it twice.
    func install(completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        withCurrentSettings { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let (home, settings, token)):
                let paths = self.paths(home: home)
                do { try AgentHookInstaller.validateShape(settings) } catch {
                    return completion(.failure(error))
                }

                // The status line first, because it decides the conf file.
                let command = (settings["statusLine"] as? [String: Any])?["command"] as? String
                var recovery = StatusLineRecovery.Recovery(command: nil, original: nil)
                switch StatusLineRecovery.classify(
                    command, scriptPath: paths.wrapper, home: home
                ) {
                case .ours:
                    // Reinstalling over ourselves must not wrap our own
                    // wrapper; the conf on the host already holds the truth
                    // and is left alone by passing no INNER below.
                    recovery = .unavailable
                case .foreign:
                    recovery = StatusLineRecovery.Recovery(
                        command: command,
                        original: (settings["statusLine"] as? [String: Any]).flatMap {
                            object in
                            (try? JSONSerialization.data(withJSONObject: object))
                                .map { String(decoding: $0, as: UTF8.self) }
                        }
                    )
                case .unrecognised(let raw):
                    return completion(.failure(Failure.refused(
                        "the status line on \(self.hostName) names our script but was"
                            + " edited (\(raw)) — fix it there first"
                    )))
                }

                var merged = AgentHookInstaller.merge(
                    intoSettings: settings, scriptPath: paths.hookScript
                )
                merged["statusLine"] = [
                    "type": "command",
                    "command": AgentStatusLineInstaller.installedCommand(scriptPath: paths.wrapper),
                ]

                let writes: [(path: String, content: String, executable: Bool)] = [
                    (paths.hookScript, AgentHookInstaller.script, true),
                    (paths.wrapper, AgentStatusLineInstaller.script, true),
                    (paths.minimal, AgentStatusLineInstaller.minimalScript, true),
                ] + (recovery.isUnavailable
                    ? []
                    : [(paths.conf, StatusLineRecovery.config(recovery), false)])

                self.write(files: writes, home: home) { [weak self] writeError in
                    guard let self else { return }
                    if let writeError { return completion(.failure(writeError)) }
                    self.writeSettings(merged, to: paths.settings, expectedToken: token) { error in
                        if let error { return completion(.failure(error)) }
                        self.refreshState()
                        completion(.success(
                            "Installed on \(self.hostName). The previous settings.json was"
                                + " backed up beside itself. Agents already running there"
                                + " pick the hooks up on their next session."
                        ))
                    }
                }
            }
        }
    }

    func uninstall(completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        withCurrentSettings { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let (home, settings, token)):
                let paths = self.paths(home: home)
                do { try AgentHookInstaller.validateShape(settings) } catch {
                    return completion(.failure(error))
                }
                var cleaned = AgentHookInstaller.unmerge(
                    fromSettings: settings, scriptPath: paths.hookScript
                )

                let command = (settings["statusLine"] as? [String: Any])?["command"] as? String
                let ownership = StatusLineRecovery.classify(
                    command, scriptPath: paths.wrapper, home: home
                )
                if case .ours = ownership {
                    // Restore what the conf recorded — the original object,
                    // verbatim, fields this build never understood included.
                    self.helper.read(path: paths.conf, maxBytes: 64 * 1024) { [weak self] conf in
                        guard let self else { return }
                        var confText: String?
                        if case .answered(let data) = conf {
                            confText = String(decoding: data, as: UTF8.self)
                        }
                        let recovery = StatusLineRecovery.recovery(from: confText)
                        if recovery.isUnavailable {
                            return completion(.failure(Failure.refused(
                                "the recovery record on \(self.hostName)"
                                    + " (~/.claude/hooks/tmuxgui-statusline.conf) is missing"
                                    + " or unreadable — restore statusLine there by hand"
                            )))
                        }
                        // The whole recorded object goes back, not just the
                        // command — the same restore the local uninstall
                        // performs, for the same reason: a `statusLine` can
                        // hold fields this build never understood, and they
                        // are the user's.
                        if let data = recovery.original.map({ Data($0.utf8) }),
                           var original = (try? JSONSerialization.jsonObject(with: data))
                               as? [String: Any]
                        {
                            if let command = recovery.command {
                                original["command"] = command
                                if original["type"] == nil { original["type"] = "command" }
                            }
                            cleaned["statusLine"] = original
                        } else if let command = recovery.command {
                            cleaned["statusLine"] = ["type": "command", "command": command]
                        } else {
                            cleaned.removeValue(forKey: "statusLine")
                        }
                        self.writeSettings(cleaned, to: paths.settings, expectedToken: token) { error in
                            if let error { return completion(.failure(error)) }
                            self.refreshState()
                            completion(.success(
                                "Removed from \(self.hostName). The scripts are left in"
                                    + " ~/.claude/hooks/ and do nothing on their own."
                            ))
                        }
                    }
                    return
                }

                self.writeSettings(cleaned, to: paths.settings, expectedToken: token) { error in
                    if let error { return completion(.failure(error)) }
                    self.refreshState()
                    completion(.success("Removed the hooks from \(self.hostName)."))
                }
            }
        }
    }

    enum Failure: LocalizedError {
        case refused(String)
        case unreachable(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .refused(let text), .unreachable(let text), .writeFailed(let text): text
            }
        }
    }

    // MARK: - Remote I/O

    /// HOME, then settings.json — and the conflict token is the POSIX
    /// checksum of the *bytes that were read*, computed locally. There is no
    /// second remote question whose timing could pair old content with a new
    /// stamp: the write exec recomputes `cksum` over whatever is at the path
    /// then and refuses on any difference, which makes the whole flow a
    /// compare-and-swap on content. (The first version stamped an mtime in a
    /// separate exec after the read — the lost-update window Codex caught,
    /// and second-resolution mtimes hid same-second edits besides.)
    private func withCurrentSettings(
        _ completion: @escaping @MainActor (Result<(String, [String: Any], String), Failure>) -> Void
    ) {
        helper.home { [weak self] outcome in
            guard let self else { return }
            guard case .answered(let home) = outcome else {
                return completion(.failure(.unreachable("can't reach \(self.hostName)")))
            }
            self.remoteHome = home
            let settingsPath = self.paths(home: home).settings
            self.helper.read(path: settingsPath, maxBytes: 4 * 1024 * 1024) { [weak self] read in
                guard let self else { return }
                switch read {
                case .unavailable(let reason):
                    completion(.failure(.unreachable(reason)))
                case .absent:
                    completion(.success((home, [:], "-")))
                case .answered(let data):
                    guard let parsed = (try? JSONSerialization.jsonObject(with: data))
                        as? [String: Any]
                    else {
                        return completion(.failure(.refused(
                            "settings.json on \(self.hostName) is not valid JSON —"
                                + " nothing was touched"
                        )))
                    }
                    completion(.success((home, parsed, PosixChecksum.token(for: data))))
                }
            }
        }
    }

    /// Plain content writes: `mkdir -p`, temp file, `mv`, `chmod`. Idempotent
    /// and unguarded — these files are ours alone.
    private func write(
        files: [(path: String, content: String, executable: Bool)],
        home: String,
        completion: @escaping @MainActor (Failure?) -> Void
    ) {
        guard let file = files.first else { return completion(nil) }
        let rest = Array(files.dropFirst())
        let quoted = TmuxTransport.shellQuote(file.path)
        let directory = TmuxTransport.shellQuote((file.path as NSString).deletingLastPathComponent)
        let mode = file.executable ? "755" : "644"
        run(
            script: "mkdir -p \(directory) && cat > \(quoted).attache-tmp"
                + " && chmod \(mode) \(quoted).attache-tmp"
                + " && mv \(quoted).attache-tmp \(quoted)",
            stdin: Data(file.content.utf8)
        ) { [weak self] status, _, stderr in
            guard status == 0 else {
                return completion(.writeFailed(
                    "could not write \(file.path): \(stderr.isEmpty ? "exit \(status)" : stderr)"
                ))
            }
            self?.write(files: rest, home: home, completion: completion)
        }
    }

    /// The guarded settings write, as **one** remote exec: resolve the
    /// symlink chain, recompute the content checksum against the read's
    /// token, back the file up beside itself, then temp-file-and-rename the
    /// new JSON in. Any step failing aborts the rest, and a mismatch names
    /// itself.
    private func writeSettings(
        _ settings: [String: Any], to path: String, expectedToken: String,
        completion: @escaping @MainActor (Failure?) -> Void
    ) {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            return completion(.writeFailed("the merged settings could not be encoded"))
        }
        // No single quotes anywhere in the script text (it travels quoted);
        // the two interpolations are a shell-quoted path and a checksum
        // token matching ^[0-9]+ [0-9]+$ or - by construction. The details
        // that are not style: the temp file is born under umask 077 and then
        // given the original's mode, so a 0600 settings file neither turns
        // 0644 nor spends a moment world-readable; a symlink chain deeper
        // than eight refuses rather than letting mv sever the ninth link;
        // and the trap keeps a failed write from littering.
        let script = """
        set -e
        umask 077
        target=\(TmuxTransport.shellQuote(path))
        i=0
        while [ -h "$target" ] && [ "$i" -lt 8 ]; do
          link=$(readlink "$target")
          case "$link" in /*) target=$link ;; *) target=$(dirname "$target")/$link ;; esac
          i=$((i + 1))
        done
        if [ -h "$target" ]; then
          echo "CONFLICT: settings.json is a symlink chain deeper than 8 - nothing was written" >&2
          exit 4
        fi
        expected=\(TmuxTransport.shellQuote(expectedToken))
        mode=""
        if [ -e "$target" ]; then
          set -- $(cksum < "$target")
          actual="$1 $2"
          if [ "$actual" != "$expected" ]; then
            echo "CONFLICT: settings.json changed while this was being prepared - nothing was written" >&2
            exit 3
          fi
          mode=$(stat -f %Lp "$target" 2>/dev/null || stat -c %a "$target" 2>/dev/null)
          cp "$target" "$target.tmuxgui-backup-$(date +%Y%m%dT%H%M%S)-$$"
        elif [ "$expected" != "-" ]; then
          echo "CONFLICT: settings.json disappeared while this was being prepared - nothing was written" >&2
          exit 3
        fi
        mkdir -p "$(dirname "$target")"
        tmp="$target.attache-tmp.$$"
        trap "rm -f \\"$tmp\\"" EXIT
        cat > "$tmp"
        [ -n "$mode" ] && chmod "$mode" "$tmp"
        mv "$tmp" "$target"
        trap - EXIT
        """
        run(script: script, stdin: data) { status, _, stderr in
            guard status == 0 else {
                return completion(.writeFailed(
                    stderr.isEmpty ? "settings write exited \(status)" : stderr
                ))
            }
            TmuxLog.destructive("installed agent setup into \(path) (remote)")
            completion(nil)
        }
    }

    /// One `ssh host -- sh -c <script>` with optional stdin; the exit status
    /// is the whole point — see the control-mode `load-buffer` false-success
    /// the remote paste documents.
    private func run(
        script: String, stdin: Data?,
        completion: @escaping @MainActor (Int32, String, String) -> Void
    ) {
        let argv = transport.execArgv(["sh", "-c", script])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let input = Pipe()
        process.standardInput = input
        process.terminationHandler = { process in
            let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
            let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                completion(process.terminationStatus, out, err)
            }
        }
        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                completion(-1, "", "ssh would not start: \(error.localizedDescription)")
            }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let handle = input.fileHandleForWriting
            if let stdin { try? handle.write(contentsOf: stdin) }
            try? handle.close()
        }
    }
}
