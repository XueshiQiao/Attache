//
//  HostContext.swift
//  Attache
//

import Foundation

/// One (host, session) pair — the key everything session-scoped is stored
/// under once more than one machine's sessions share the rail. Session ids
/// are unique only within one server: `$1` exists on every machine.
nonisolated struct SessionKey: Hashable {
    let host: String
    let session: String

    /// One string, for call sites that already key by strings (the sidebar's
    /// entry ids, dictionary keys). `\u{01}` because a host name is validated
    /// against control characters and a session id matches `[$@%]\d+`.
    var composite: String { "\(host)\u{01}\(session)" }

    init(host: String, session: String) {
        self.host = host
        self.session = session
    }

    init?(composite: String) {
        let parts = composite.split(separator: "\u{01}", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        host = String(parts[0])
        session = String(parts[1])
    }
}

/// Everything the app holds for one machine whose tmux it shows: the
/// transport, the `TmuxServer`, and — for a remote host — the ssh pre-flight
/// and the helper channel. The local machine is a `HostContext` too, with
/// the remote pieces absent, so everything above this file iterates hosts
/// instead of special-casing "the" server.
@MainActor
final class HostContext {
    /// "local", or the `[[host]]` name. The first half of every `SessionKey`.
    static let localID = "local"

    let id: String
    let displayName: String
    let transport: TmuxTransport
    let server: TmuxServer
    /// nil on the local host: local features read the disk directly.
    let helper: RemoteHelper?
    let config: HostConfig?
    /// This machine's repositories, resolved and read on this machine. One
    /// service per host because both are caches over one file system, and
    /// paths collide across machines by design — `/Users/joey` exists
    /// everywhere.
    let gitStatus: GitStatusService
    /// Prompt-cache estimates for this machine's transcripts, read the same
    /// side of the wire the transcripts live on — a remote path that also
    /// exists locally is the wrong session with the right name.
    let cacheStatus: CacheStatusService
    /// Installs the agent hooks over there. nil locally — the local
    /// installers already exist and write through `FileManager`.
    let agentSetup: RemoteAgentSetup?
    private let preflight: SSHPreflight?

    /// What the rail's host row says.
    enum State: Equatable {
        case connecting
        case ready
        case down(String)
    }

    private(set) var state: State {
        didSet { if state != oldValue { onStateChange?() } }
    }

    var onStateChange: (() -> Void)?

    /// Set once by `retire()`, and checked on every path that could bring
    /// this host back to life. It exists because the ssh pre-flight is
    /// *shared* per ControlPath and its observers are append-only: a context
    /// replaced by an edit still hears the shared master come up, and
    /// without this flag its `probeTmux` would restart the helper and the
    /// server of a host the rail no longer lists — two live connections for
    /// one machine, one of them invisible.
    private(set) var retired = false

    /// False until `start()`. The other half of sharing a pre-flight: its
    /// `addObserver` delivers the *current* state at registration, so a
    /// replacement context built while its predecessor still holds the
    /// master up would probe immediately — against a master retirement is
    /// about to tear down. The failed probe then parks `state` on `.down`,
    /// and the guard in `probeAnswered` discards the real probe that
    /// follows reconnection: a reachable host stuck reading as down, found
    /// in review. Until `start()`, this context only listens.
    private var started = false

    /// Which `probeTmux` the next `probeAnswered` belongs to. Two probes
    /// can be in flight across a reconnect, and their answers can cross;
    /// only the latest may set the state. Also bumped whenever the
    /// pre-flight *leaves* `.up` and on `stop()`/`reconnect()`: a probe
    /// launched against a master that has since died must not hand back a
    /// `.ready` over a connection that is not there.
    private var probeGeneration = 0

    /// One retain on the shared pre-flight, held from `start()` to the
    /// first `stop()`. Tracked so the pair balances exactly once whatever
    /// path teardown takes — the count is shared across hosts on one
    /// master, and an unbalanced pair either strands the master or kills
    /// it under another host.
    private var preflightRetained = false

    /// The remote server's version, once probed. nil until known — and
    /// callers gate *loudly* on the definite no, not on the unknown.
    private(set) var tmuxVersion: TmuxVersion?
    /// False only when a probe *answered* with a version below 3.2. The rail
    /// badges stay quiet rather than wrong, and one warning notice says why.
    private(set) var supportsSubscriptions = true

    var isLocal: Bool { preflight == nil }

    // MARK: - Construction

    static func local(transport: TmuxTransport) -> HostContext {
        HostContext(
            id: localID, displayName: "This Mac", transport: transport,
            config: nil, preflight: nil, helper: nil, state: .ready
        )
    }

    static func remote(config: HostConfig, sshPath: String) -> HostContext {
        let target = SSHTarget(
            destination: config.destination,
            sshPath: sshPath,
            controlPath: Self.controlPath(destination: config.destination)
        )
        let transport = TmuxTransport(
            kind: .ssh(target), tmuxPath: config.tmuxPath, socket: config.socket
        )
        let helper = RemoteHelper(label: config.name) {
            transport.helperArgv(script: RemoteHelperScript.script)
        }
        return HostContext(
            id: config.name, displayName: config.name, transport: transport,
            config: config,
            // Shared per ControlPath: two blocks naming one machine ride one
            // master instead of unlinking each other's sockets.
            preflight: SSHPreflight.shared(target: target, label: config.name),
            helper: helper, state: .connecting
        )
    }

    private init(
        id: String, displayName: String, transport: TmuxTransport,
        config: HostConfig?, preflight: SSHPreflight?, helper: RemoteHelper?,
        state: State
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.config = config
        self.preflight = preflight
        self.helper = helper
        self.state = state
        gitStatus = GitStatusService(
            backend: helper.map { RemoteGitStatusBackend(helper: $0) } ?? LocalGitStatusBackend()
        )
        cacheStatus = helper.map { CacheStatusService(helper: $0) } ?? CacheStatusService()
        agentSetup = helper.map {
            RemoteAgentSetup(helper: $0, transport: transport, hostName: displayName)
        }
        server = TmuxServer(transport: transport)

        preflight?.addObserver { [weak self] preflightState in
            self?.preflightChanged(preflightState)
        }
    }

    /// `~/.config/attache/ssh/<destination>` — beside the settings file, not
    /// under `/tmp`, and 0700 because ssh refuses a ControlPath directory
    /// others can write.
    ///
    /// The app's own name rather than ssh's `%C` hash, and that difference is
    /// load-bearing: a master killed uncleanly leaves its socket file behind,
    /// a fresh `ControlMaster=yes` refuses to bind over it, and the only
    /// thing that can clear a socket is code that knows its path — which `%C`
    /// keeps secret by design. The destination is already validated
    /// (no whitespace, quotes or control characters, and `/` cannot appear in
    /// an ssh destination), so it is filesystem-safe verbatim; only a
    /// pathological length falls back to a digest, because `sun_path` caps at
    /// 104 bytes on macOS.
    static func controlPath(destination: String) -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/attache/ssh", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var name = destination
        if directory.path.utf8.count + 1 + name.utf8.count > 96 {
            // Stable, collision-resistant enough for socket naming, and with
            // a readable prefix so the directory stays diagnosable.
            let digest = destination.utf8.reduce(into: UInt64(1_099_511_628_211)) {
                $0 = ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }
            name = String(name.prefix(24)) + "-" + String(digest, radix: 16)
        }
        return directory.appendingPathComponent(name).path
    }

    // MARK: - Lifecycle

    func start() {
        // Idempotent, and not as a nicety: every unguarded call would
        // increment the shared pre-flight's retain count, and retirement
        // balances exactly one — a double start leaves the master running
        // after its last host is gone (Codex review, round 4).
        guard !retired, !started else { return }
        started = true
        if let preflight {
            preflightRetained = true
            preflight.start()
            // The observer's initial delivery arrived before `started` and
            // was dropped on purpose; ask again now. A master another host
            // already holds up delivers no transition on `start()`, so
            // without this a replacement context would sit connecting
            // forever under a healthy master.
            preflightChanged(preflight.state)
        } else {
            // The local host probes too: the version decides whether reply
            // blocks need the `\ooo` decode, and that is as true of a local
            // 3.5 as a remote one. AppDelegate has already proven a tmux
            // exists here, so the probe failing is news worth a notice.
            probeTmux()
        }
    }

    func stop() {
        // Anything still in flight answers to nobody now.
        probeGeneration &+= 1
        cacheStatus.stop()
        helper?.stop()
        // Exactly one decrement per start, however many times stop runs:
        // the count is shared with every other host on this master, and an
        // extra decrement here takes the master out from under *them*.
        if preflightRetained {
            preflightRetained = false
            preflight?.stop()
        }
        server.stop()
    }

    /// Take this host out of service for good — the settings said so, either
    /// by deleting its block or by replacing it with an edited one. `stop()`
    /// alone is not retirement: the shared pre-flight keeps this context on
    /// its observer list, and the flag is what makes every later callback a
    /// no-op. A retired context is never restarted; an edit builds a fresh
    /// one.
    func retire() {
        guard !retired else { return }
        retired = true
        stop()
    }

    /// The host row was clicked while down: skip the backoff and try now.
    func retry() {
        guard !retired else { return }
        preflight?.retryNow()
    }

    /// Tear this host's own machinery down and bring it up again, on request
    /// — the "Reconnect" menu item and nothing else. The shared ssh master is
    /// deliberately left alone: it may be carrying another host to the same
    /// machine, it has its own heartbeat for the case where it is the broken
    /// part, and `stop()`/`start()` on a master someone else holds would not
    /// cycle it anyway — the refcount just dips and returns with no observer
    /// ever hearing a change, which is exactly the silence that would leave
    /// this host stopped forever.
    func reconnect() {
        guard !retired, !isLocal else { return }
        probeGeneration &+= 1
        helper?.stop()
        server.stop()
        state = .connecting
        if let preflight, preflight.state == .up {
            probeTmux()
        } else {
            // Down: retry now instead of waiting out the backoff. Still
            // connecting: the pre-flight's own observer will land in
            // `preflightChanged` and probe from there.
            preflight?.retryNow()
        }
    }

    private func preflightChanged(_ preflightState: SSHPreflight.State) {
        guard !retired, started else { return }
        switch preflightState {
        case .idle:
            break
        case .connecting:
            // The master is gone or going; whatever a probe over the old
            // one answers is about a connection that no longer exists.
            probeGeneration &+= 1
            state = .connecting
        case .up:
            probeTmux()
        case .down(let reason):
            probeGeneration &+= 1
            // The mux refusal has a text all its own, and it must read as
            // what it is — the *host's* limit, not tmux going away.
            let said = reason.contains("refused by peer")
                ? "the host's ssh session limit (MaxSessions) is exhausted: \(reason)"
                : reason
            state = .down(said)
            server.stop()
            helper?.stop()
        }
    }

    /// One `tmux -V` between auth and attach. It answers two different
    /// questions: is there a tmux at `tmux_path` at all — the failure that
    /// must name its fix, because bare `tmux` is missing from most
    /// non-interactive PATHs — and is it new enough for subscriptions.
    private func probeTmux() {
        state = .connecting
        probeGeneration &+= 1
        let generation = probeGeneration
        let argv = transport.oneShotArgv(["-V"])
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            var answer = ""
            var problem = ""
            var status: Int32 = -1
            if (try? process.run()) != nil {
                answer = String(decoding: out.fileHandleForReading.readDataToEndOfFile(),
                                as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                problem = String(decoding: err.fileHandleForReading.readDataToEndOfFile(),
                                 as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                process.waitUntilExit()
                status = process.terminationStatus
            }
            DispatchQueue.main.async { [weak self] in
                self?.probeAnswered(
                    generation: generation, status: status, version: answer, problem: problem
                )
            }
        }
    }

    private func probeAnswered(generation: Int, status: Int32, version: String, problem: String) {
        guard !retired, generation == probeGeneration, case .connecting = state else { return }
        // Belt to the generation's braces: a remote host's result only
        // counts while the master it rode is still up. The local host has
        // no pre-flight and no such condition.
        if let preflight, preflight.state != .up { return }
        guard status == 0, let parsed = TmuxVersion.parse(version) ?? Self.masterBuild(version)
        else {
            let path = transport.tmuxPath
            if isLocal {
                // The rail draws no host tier for a lone local machine, so
                // this state has nowhere to be seen there — say it loudly.
                DiagnosticsCenter.shared.notice(AppNotice(
                    severity: .error,
                    title: "tmux stopped answering",
                    body: "\(path) -V failed" + (problem.isEmpty ? "" : ": \(problem)")
                ))
            }
            state = .down(
                "tmux did not answer at \"\(path)\" on \(displayName)"
                    + (problem.isEmpty ? "" : " — \(problem)")
                    + ". Set tmux_path for this host in ~/.config/attache.toml"
                    + " to where tmux is installed there."
            )
            return
        }
        tmuxVersion = parsed
        server.tmuxVersion = parsed
        if !parsed.supportsSubscriptions {
            supportsSubscriptions = false
            DiagnosticsCenter.shared.notice(AppNotice(
                severity: .warning,
                title: "\(displayName) runs tmux \(parsed.text)",
                body: "Live badges (activity, agent state, git paths) need tmux 3.2's"
                    + " subscriptions. Sessions and windows still work; the rail's"
                    + " decorations stay blank on this host."
            ))
        }
        state = .ready
        helper?.start()
        server.start()
    }

    /// `tmux master` and other unnumbered builds: newer than any release.
    private static func masterBuild(_ output: String) -> TmuxVersion? {
        output.hasPrefix("tmux ") ? TmuxVersion(major: 99, minor: 0) : nil
    }
}
