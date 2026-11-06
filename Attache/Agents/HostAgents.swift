//
//  HostAgents.swift
//  Attache
//

import Foundation

/// Every agent on one host, kept up to date by attache-cli.
///
/// One `agents --watch` per host for the whole app, started the first time
/// anything asks and kept while the app runs: attache-cli reads the host
/// every 1.5 s and sends the list only when it changed, so a window learns
/// that its agent started waiting without anyone polling.
@MainActor
final class HostAgents {
    private static var byHost: [String: HostAgents] = [:]

    static func shared(for transport: TmuxTransport) -> HostAgents {
        let key = transport.hostLabel
        if let existing = byHost[key], existing.link.transport == transport { return existing }
        let made = HostAgents(link: AttacheCliLink(transport: transport))
        byHost[key] = made
        return made
    }

    let link: AttacheCliLink
    private(set) var agents: [AgentRow] = []
    /// attache-cli is installed and answering.
    private(set) var isReady = false
    private(set) var failure: String?
    private var stream: AttacheCliStream?
    private var observers: [UUID: () -> Void] = [:]
    private var started = false
    private var retry = AttacheCliRetry()

    private init(link: AttacheCliLink) {
        self.link = link
    }

    /// Calls `observer` on every change until the token is dropped.
    func observe(_ observer: @escaping () -> Void) -> HostAgentsToken {
        let id = UUID()
        observers[id] = observer
        start()
        return HostAgentsToken { [weak self] in self?.observers[id] = nil }
    }

    /// The agent that speaks for a window: the most urgent of its panes,
    /// the order attache-cli's rows are already sorted in.
    func agent(inWindow windowID: String) -> AgentRow? {
        agents.first { $0.window == windowID }
    }

    private func start() {
        guard !started else { return }
        started = true
        AttacheCliInstaller.shared.ensure(link) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .ready:
                isReady = true
                failure = nil
                watch()
            case .failed(let why):
                failure = why
                notify()
                // A host not reachable yet (the ssh master still coming up,
                // a laptop asleep) is asked again, later each time.
                started = false
                DispatchQueue.main.asyncAfter(deadline: .now() + retry.next()) { [weak self] in
                    guard let self, !self.observers.isEmpty else { return }
                    self.start()
                }
            }
        }
    }

    private func watch() {
        stream?.cancel()
        stream = link.stream(["agents", "--watch"], onEvent: { [weak self] event in
            guard let self, event["t"] as? String == "agents" else { return }
            retry.reset()
            let rows = AgentRow.parse(event["agents"] as? [[String: Any]] ?? [])
            guard rows != agents else { return }
            agents = rows
            notify()
        }, onEnd: { [weak self] in
            // The host went away or attache-cli ended: ask again, later each
            // time it keeps failing, so a host that is down costs an ssh a
            // minute rather than one every three seconds.
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + retry.next()) { [weak self] in self?.watch() }
        })
    }

    private func notify() {
        for observer in observers.values { observer() }
    }
}

/// Stops an observation when it is released.
final class HostAgentsToken {
    private let cancel: () -> Void
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}

/// How long to wait before starting a stream again: 3 s, doubling to a
/// minute while it keeps ending with nothing said, back to 3 s once it says
/// something.
nonisolated struct AttacheCliRetry {
    private var delay: TimeInterval = 0

    mutating func next() -> TimeInterval {
        delay = delay == 0 ? 3 : min(delay * 2, 60)
        return delay
    }

    mutating func reset() { delay = 0 }
}
