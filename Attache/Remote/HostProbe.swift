//
//  HostProbe.swift
//  Attache
//

import Foundation

/// The Test Connection button: one `tmux -V` over a one-shot ssh, run
/// against a draft that may never have been saved. It answers the two
/// questions a new `[[host]]` block gets wrong most — can ssh reach the
/// machine without a prompt, and is there a tmux at `tmux_path` — with the
/// tool's own words rather than a spinner that times out into silence.
///
/// The connection carries `BatchMode=yes` like every data connection in the
/// app, so a host that would ask for a password fails fast here instead of
/// hanging a pipe later; that is the honest preview, because the app can
/// never type a password either. The draft's ControlPath is the same one a
/// saved host would use — an existing master for that destination speeds the
/// probe up, and a missing one just means a direct connection.
@MainActor
enum HostProbe {
    enum Outcome {
        /// `foundAt` is the path discovery resolved, when it ran — what the
        /// editor writes into the tmux path field so the person never has
        /// to. nil when the draft already named a path.
        case connected(TmuxVersion, foundAt: String?)
        case failed(String)

        var message: String {
            switch self {
            case .connected(let version, let foundAt):
                var text = "Connected — tmux \(version.text)"
                if let foundAt { text += ", found at \(foundAt)" }
                if !version.supportsSubscriptions {
                    text += ". Below 3.2, so the rail's live badges stay blank on this host."
                }
                return text
            case .failed(let reason):
                return reason
            }
        }
    }

    /// Where tmux lives when the draft does not say: `command -v` first —
    /// the conventional ask, honoured whenever the remote shell's PATH has
    /// tmux at all — then the places package managers put it, because a
    /// non-interactive ssh shell usually has none of them on its PATH.
    /// Verified against the mini 2026-08-25: `command -v` came up empty and
    /// `/opt/homebrew/bin/tmux` answered. **No single quotes**: the script
    /// travels as one shell word through `TmuxTransport.shellQuote`, whose
    /// totality is the same promise `RemoteHelperScript` keeps.
    private static let discoveryScript = """
    p=""
    if command -v tmux >/dev/null 2>&1; then p=$(command -v tmux); fi
    if [ -z "$p" ]; then
      for d in /opt/homebrew/bin /usr/local/bin /usr/bin /home/linuxbrew/.linuxbrew/bin /usr/pkg/bin /snap/bin; do
        if [ -x "$d/tmux" ]; then p="$d/tmux"; break; fi
      done
    fi
    if [ -z "$p" ]; then echo tmux-not-found >&2; exit 127; fi
    echo "$p"
    exec "$p" -V
    """

    /// A probe that outlives this wait is killed rather than joined: ssh's
    /// own ConnectTimeout covers the network, so what this guards against is
    /// a remote shell that hangs after auth.
    private nonisolated static let deadline: TimeInterval = 20

    /// `discoverPath` is set when the draft's tmux path field is empty: the
    /// probe then finds tmux itself and reports where, instead of running
    /// bare `tmux` into the "command not found" every Homebrew machine
    /// answers — the person should never be the one typing a path a shell
    /// one-liner can find.
    static func run(
        config: HostConfig, sshPath: String, discoverPath: Bool = false,
        completion: @escaping @MainActor (Outcome) -> Void
    ) {
        let target = SSHTarget(
            destination: config.destination,
            sshPath: sshPath,
            controlPath: HostContext.controlPath(destination: config.destination)
        )
        let transport = TmuxTransport(
            kind: .ssh(target), tmuxPath: config.tmuxPath, socket: config.socket
        )
        let argv = discoverPath
            ? transport.execArgv(["sh", "-c", discoveryScript])
            : transport.oneShotArgv(["-V"])
        TmuxLog.lifecycle("probing host \(config.name): \(argv.joined(separator: " "))")

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    completion(.failed("ssh would not start: \(error.localizedDescription)"))
                }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                if process.isRunning { process.terminate() }
            }
            // Blocking reads on a worker queue, like `probeTmux`: the child
            // exits or is terminated above, and either way both pipes close.
            let stdout = String(
                decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = String(
                decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            process.waitUntilExit()
            let status = process.terminationStatus

            let outcome: Outcome
            // In discovery mode stdout is two lines — the path, then the
            // version — so the version is always the last line and the path
            // is anything absolute above it.
            let stdoutLines = stdout.split(separator: "\n").map(String.init)
            let versionLine = stdoutLines.last ?? ""
            let foundAt = discoverPath
                ? stdoutLines.dropLast().first(where: { $0.hasPrefix("/") })
                : nil
            if status == 0, let version = TmuxVersion.parse(versionLine) {
                outcome = .connected(version, foundAt: foundAt)
            } else if status == 0, versionLine.hasPrefix("tmux ") {
                // An unnumbered master build — newer than any release, the
                // same reading `HostContext.masterBuild` applies.
                outcome = .connected(TmuxVersion(major: 99, minor: 0), foundAt: foundAt)
            } else if discoverPath, stderr.contains("tmux-not-found") {
                outcome = .failed(
                    "tmux was not found on that machine — command -v and the usual "
                        + "install places all came up empty. If it lives somewhere "
                        + "unusual, set tmux path by hand."
                )
            } else if stderr.localizedCaseInsensitiveContains("not found") {
                // The commonest failure by far: a non-interactive shell with
                // no Homebrew on its PATH. Name the fix, not just the fact.
                outcome = .failed(
                    "tmux did not answer at \"\(config.tmuxPath)\" — \(stderr). "
                        + "Set tmux path to where tmux is installed on that machine."
                )
            } else {
                let said = [stderr, stdout].first { !$0.isEmpty }
                    ?? "ssh exited with status \(status)"
                outcome = .failed(said)
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
