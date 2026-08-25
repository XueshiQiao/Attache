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
        case connected(TmuxVersion)
        case failed(String)

        var message: String {
            switch self {
            case .connected(let version):
                var text = "Connected — tmux \(version.text)"
                if !version.supportsSubscriptions {
                    text += ". Below 3.2, so the rail's live badges stay blank on this host."
                }
                return text
            case .failed(let reason):
                return reason
            }
        }
    }

    /// A probe that outlives this wait is killed rather than joined: ssh's
    /// own ConnectTimeout covers the network, so what this guards against is
    /// a remote shell that hangs after auth.
    private nonisolated static let deadline: TimeInterval = 20

    static func run(
        config: HostConfig, sshPath: String,
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
        let argv = transport.oneShotArgv(["-V"])
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
            if status == 0, let version = TmuxVersion.parse(stdout) {
                outcome = .connected(version)
            } else if status == 0, stdout.hasPrefix("tmux ") {
                // An unnumbered master build — newer than any release, the
                // same reading `HostContext.masterBuild` applies.
                outcome = .connected(TmuxVersion(major: 99, minor: 0))
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
