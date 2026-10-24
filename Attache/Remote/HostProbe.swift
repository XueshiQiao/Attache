//
//  HostProbe.swift
//  Attache
//

import Foundation

/// The Test Connection button: one version probe over a one-shot ssh, run
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
        /// `mismatch` is set when the binary is not the running server's
        /// version — the app makes no control connection then, so this must
        /// not read as a plain success.
        case connected(TmuxVersion, foundAt: String?, mismatch: TmuxServer.VersionMismatch?)
        case failed(String)

        /// Drawn as a failure: a mismatch reached the machine, but the app
        /// will not connect to it.
        var isFailure: Bool {
            switch self {
            case .failed: true
            case .connected(_, _, let mismatch): mismatch != nil
            }
        }

        var message: String {
            switch self {
            case .connected(let version, let foundAt, let mismatch):
                if let mismatch {
                    return "Reached the machine, but its tmux server is \(mismatch.serverDescription) and"
                        + " \(foundAt ?? "tmux_path") is tmux \(mismatch.binary). tmux cannot attach"
                        + " a control client across versions, so the app will not connect until"
                        + " they match: restart the tmux server there (this ends every session"
                        + " on it), or point tmux path at a tmux of the server's version."
                }
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
        // Both the server and the binary are asked, because the binary has
        // to match the server (see `TmuxVersion`). Discovery's script does
        // both itself; a named path takes two one-shots, the second skipped
        // only for a failure `-V` would just repeat.
        let argv = discoverPath
            ? transport.execArgv(["sh", "-c", TmuxVersion.discoveryScript(socket: transport.socket)])
            : transport.oneShotArgv(TmuxVersion.serverQuery)
        let fallbackArgv: [String]? = discoverPath ? nil : transport.oneShotArgv(["-V"])
        TmuxLog.lifecycle("probing host \(config.name): \(argv.joined(separator: " "))")

        DispatchQueue.global(qos: .userInitiated).async {
            func ask(_ argv: [String]) -> (status: Int32, stdout: String, stderr: String)? {
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
                    return nil
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
                return (process.terminationStatus, stdout, stderr)
            }
            guard let first = ask(argv) else { return }
            // What the server said: `tmux X`, `incompatible`, or nothing.
            var serverAnswer: String?
            var reply = first
            if let fallbackArgv {
                if first.status == 0, TmuxVersion.parseServerAnswer(first.stdout) != nil {
                    serverAnswer = first.stdout
                } else if TmuxVersion.meansIncompatibleClient(first.stderr) {
                    serverAnswer = "incompatible"
                }
                if TmuxVersion.binaryMightAnswer(afterServerQueryExited: first.status) {
                    guard let binary = ask(fallbackArgv) else { return }
                    reply = binary
                }
            } else {
                serverAnswer = first.stdout.split(separator: "\n")
                    .first { $0.hasPrefix("server: ") }
                    .map { String($0.dropFirst("server: ".count)) }
            }
            let (status, stdout, stderr) = reply

            let outcome: Outcome
            // `-V` is always the last line — discovery prints the path and
            // the server's answer above it — and the path is the line that
            // is absolute.
            let stdoutLines = stdout.split(separator: "\n").map(String.init)
            let binaryLine = stdoutLines.last ?? ""
            let foundAt = discoverPath
                ? stdoutLines.dropLast().first(where: { $0.hasPrefix("/") })
                : nil
            // `parseServerAnswer` reads `-V`'s answer too, and is the one
            // place an unnumbered build and a pre-2.4 server are told apart.
            if status == 0, let binaryVersion = TmuxVersion.parseServerAnswer(binaryLine) {
                let binaryText = TmuxVersion.bareText(binaryLine)
                let fromServer = serverAnswer.flatMap { TmuxVersion.parseServerAnswer($0) }
                var mismatch: TmuxServer.VersionMismatch?
                if serverAnswer == "incompatible" {
                    mismatch = .init(server: nil, binary: binaryText)
                } else if let serverAnswer, fromServer != nil,
                          TmuxVersion.serverDiffers(
                              serverText: TmuxVersion.bareText(serverAnswer), binaryText: binaryText
                          )
                {
                    mismatch = .init(server: TmuxVersion.bareText(serverAnswer), binary: binaryText)
                }
                outcome = .connected(fromServer ?? binaryVersion, foundAt: foundAt, mismatch: mismatch)
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
