//
//  AttacheCliInstaller.swift
//  Attache
//

import Foundation

/// Puts attache-cli on a host, the way the phone does, so neither client
/// depends on the other having been there first.
///
/// The app carries every build `cli/build-all.sh` makes (`dist/` in the
/// bundle, one folder per `uname -s`-`uname -m`, and `version.txt`). On first
/// use of a host it asks what is installed; it installs only when there is
/// nothing or something older — never over a newer one, which the phone or
/// a newer copy of this app may have put there — and then runs
/// `attache-cli setup`, which puts its status line into Claude Code's
/// settings (keeping the one that was there, which it runs).
///
/// The binary goes up beside its place and is moved in by rename, so an
/// agent running it (its status line does, every few seconds) never finds
/// half a binary.
@MainActor
final class AttacheCliInstaller {
    static let shared = AttacheCliInstaller()

    enum Outcome: Equatable {
        case ready(version: String)
        case failed(String)
    }

    private var outcomes: [String: Outcome] = [:]
    private var waiting: [String: [(Outcome) -> Void]] = [:]

    /// Calls `completion` once attache-cli is there (installed now or
    /// already), or with why not. Asked once per host per launch.
    func ensure(_ link: AttacheCliLink, completion: @escaping (Outcome) -> Void) {
        let key = link.transport.hostLabel
        if let done = outcomes[key], case .ready = done {
            completion(done)
            return
        }
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return
        }
        waiting[key] = [completion]
        install(link) { [weak self] outcome in
            guard let self else { return }
            self.outcomes[key] = outcome
            if case .failed(let why) = outcome { NSLog("%@", "attache-cli on \(key): \(why)") }
            let callers = self.waiting.removeValue(forKey: key) ?? []
            callers.forEach { $0(outcome) }
        }
    }

    // MARK: - Steps

    private func install(_ link: AttacheCliLink, completion: @escaping @MainActor (Outcome) -> Void) {
        guard let bundled = Self.bundledVersion else {
            completion(.failed("this build of the app carries no attache-cli (run cli/build-all.sh before building)"))
            return
        }
        let probe = #"printf 'OS:%s\nARCH:%s\nHAVE:%s\n' "$(uname -s)" "$(uname -m)" "$("$HOME/"# + AttacheCliLink.relativePath + #"" version 2>/dev/null)""#
        Self.sh(link.transport, probe, stdin: nil) { status, out in
            guard status == 0 else {
                completion(.failed("could not ask the host what it has"))
                return
            }
            let field = { (name: String) in
                out.split(separator: "\n").first { $0.hasPrefix(name + ":") }
                    .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) } ?? ""
            }
            let installed = AttacheCliProtocol.object(field("HAVE"))?["version"] as? String
            if let installed, !Self.isOlder(installed, than: bundled) {
                self.setup(link, version: installed, completion: completion)
                return
            }
            guard let build = Self.build(os: field("OS"), machine: field("ARCH")),
                  let binary = Self.bundledBinary(build) else {
                completion(.failed("no build for \(field("OS")) \(field("ARCH"))"))
                return
            }
            let place = #"d="$HOME/.local/bin"; t="$d/attache-cli.new.$$"; mkdir -p "$d" && cat > "$t" && chmod 755 "$t" && mv -f "$t" "$d/attache-cli" && "$d/attache-cli" version"#
            Self.sh(link.transport, place, stdin: binary) { status, out in
                guard status == 0, let v = AttacheCliProtocol.object(out.trimmingCharacters(in: .whitespacesAndNewlines)),
                      v["protocol"] != nil else {
                    completion(.failed("installing \(bundled) failed"))
                    return
                }
                NSLog("%@", "attache-cli \(bundled) installed on \(link.transport.hostLabel) (was \(installed ?? "none"))")
                self.setup(link, version: bundled, completion: completion)
            }
        }
    }

    private func setup(_ link: AttacheCliLink, version: String,
                       completion: @escaping @MainActor (Outcome) -> Void) {
        link.run(["setup"]) { lines in
            NSLog("%@", "attache-cli setup on \(link.transport.hostLabel): \(lines?.joined() ?? "no answer")")
            completion(.ready(version: version))
        }
    }

    // MARK: - The bundle

    nonisolated private static var distURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("dist", isDirectory: true)
    }

    nonisolated static var bundledVersion: String? {
        guard let url = distURL?.appendingPathComponent("version.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    nonisolated private static func bundledBinary(_ build: String) -> Data? {
        distURL.flatMap { try? Data(contentsOf: $0.appendingPathComponent("\(build)/attache-cli")) }
    }

    /// The build's folder for what `uname -s` and `uname -m` said, or nil
    /// when none fits — the phone's `AttacheCliBundle.buildFor`, rule for rule.
    nonisolated static func build(os: String, machine: String) -> String? {
        let arm: Bool
        switch machine.trimmingCharacters(in: .whitespaces).lowercased() {
        case "arm64", "aarch64": arm = true
        case "x86_64", "amd64": arm = false
        default: return nil
        }
        switch os.trimmingCharacters(in: .whitespaces).lowercased() {
        case "darwin": return arm ? "darwin-arm64" : "darwin-x86_64"
        case "linux": return arm ? "linux-aarch64" : "linux-x86_64"
        default: return nil
        }
    }

    /// Whether `a` is older than `b`, comparing `x.y.z` numerically.
    nonisolated static func isOlder(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let d = (i < x.count ? x[i] : 0) - (i < y.count ? y[i] : 0)
            if d != 0 { return d < 0 }
        }
        return false
    }

    /// One `sh -c` on the host, with optional stdin; the exit status and stdout.
    private static func sh(_ transport: TmuxTransport, _ script: String, stdin: Data?,
                           completion: @escaping @MainActor (Int32, String) -> Void) {
        let argv = transport.execArgv(["/bin/sh", "-c", script])
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            let out = Pipe(), input = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = input
            guard (try? process.run()) != nil else {
                DispatchQueue.main.async { completion(-1, "") }
                return
            }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: deadline)
            DispatchQueue.global(qos: .utility).async {
                let handle = input.fileHandleForWriting
                if let stdin { try? handle.write(contentsOf: stdin) }
                try? handle.close()
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            let status = process.terminationStatus
            DispatchQueue.main.async { completion(status, String(decoding: data, as: UTF8.self)) }
        }
    }
}
