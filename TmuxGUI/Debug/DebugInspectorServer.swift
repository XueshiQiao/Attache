//
//  DebugInspectorServer.swift
//  TmuxGUI
//

#if DEBUG

    import Foundation
    import Network

    /// Serves `DebugInspector`'s dump over HTTP on the loopback interface.
    ///
    /// The project used to link a closed-source UI inspector whose companion
    /// app was the only thing that could read it — which made it useless to the
    /// agent that does the debugging here. This is the small version: plain
    /// `GET`, plain JSON, so it can be polled with `curl` while the app is being
    /// driven with `cliclick`.
    ///
    /// Off unless asked for, because a listening socket at every launch is
    /// exactly the cost that got the previous inspector removed. Set
    /// `TMUXGUI_INSPECT=1` in the environment, or turn it on in the Debug menu
    /// (which remembers the choice). Debug builds only.
    @MainActor
    final class DebugInspectorServer {
        static let shared = DebugInspectorServer()

        static let defaultPort: UInt16 = 47623
        private static let enabledKey = "debug.inspector.enabled"

        private var listener: NWListener?
        private(set) var port: UInt16?

        /// Whether the server should come up at launch.
        ///
        /// The environment variable wins when present, so a run started by an
        /// agent gets the endpoint without touching the user's defaults.
        static var isEnabledByDefault: Bool {
            if let raw = ProcessInfo.processInfo.environment["TMUXGUI_INSPECT"] {
                return raw == "1" || raw.lowercased() == "true"
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }

        static var isRememberedOn: Bool {
            get { UserDefaults.standard.bool(forKey: enabledKey) }
            set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
        }

        var isRunning: Bool { listener != nil }

        /// Port to bind. Overridable so two debug builds can run side by side.
        private static var configuredPort: UInt16 {
            guard let raw = ProcessInfo.processInfo.environment["TMUXGUI_INSPECT_PORT"],
                  let value = UInt16(raw), value > 0
            else { return defaultPort }
            return value
        }

        // MARK: - Lifecycle

        @discardableResult
        func start() -> String {
            guard listener == nil else { return "Inspector already on \(describeEndpoint())" }

            let port = Self.configuredPort
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                return "Inspector could not use port \(port)"
            }

            let parameters = NWParameters.tcp
            // Loopback only. Nothing here should ever be reachable off the
            // machine, and binding explicitly is stronger than filtering later.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            parameters.allowLocalEndpointReuse = true

            do {
                let listener = try NWListener(using: parameters)
                // Network hands its callbacks back on the queue below, but the
                // compiler cannot know that, so each one hops explicitly. A
                // debug endpoint can afford the extra turn.
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.accept(connection) }
                }
                listener.stateUpdateHandler = { state in
                    if case .failed(let error) = state {
                        // Through TmuxLog rather than NSLog: a listener that
                        // dies silently looks exactly like one that was never
                        // asked for, and stdout alone does not survive the app.
                        TmuxLog.lifecycle("inspector listener failed: \(error)")
                    }
                }
                listener.start(queue: .main)
                self.listener = listener
                self.port = port
                return "Inspector on \(describeEndpoint())"
            } catch {
                return "Inspector failed to start: \(error)"
            }
        }

        func stop() {
            listener?.cancel()
            listener = nil
            port = nil
        }

        private func describeEndpoint() -> String {
            let port = port ?? Self.configuredPort
            return "http://127.0.0.1:\(port)/ — also /views, /tmux, /settings, /window and /settings-window"
        }

        // MARK: - Requests

        private func accept(_ connection: NWConnection) {
            connection.start(queue: .main)
            receive(on: connection, accumulated: Data())
        }

        /// Read until the end of the request head. Every route is a `GET` with
        /// no body, so a blank line is the whole story; the 64 KB ceiling is
        /// there so a malformed client cannot make the app grow without bound.
        private func receive(on connection: NWConnection, accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] chunk, _, isComplete, error in
                var buffer = accumulated
                if let chunk { buffer.append(chunk) }
                let failed = error != nil || (isComplete && buffer.isEmpty)

                Task { @MainActor in
                    guard let self, !failed else {
                        connection.cancel()
                        return
                    }
                    if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                        self.respond(to: buffer[..<range.lowerBound], on: connection)
                    } else if buffer.count > 65536 || isComplete {
                        self.send(status: "400 Bad Request", body: Data("bad request\n".utf8),
                                  contentType: "text/plain", on: connection)
                    } else {
                        self.receive(on: connection, accumulated: buffer)
                    }
                }
            }
        }

        private func respond(to head: Data, on connection: NWConnection) {
            let requestLine = String(decoding: head, as: UTF8.self)
                .components(separatedBy: "\r\n").first ?? ""
            let fields = requestLine.split(separator: " ", omittingEmptySubsequences: true)

            guard fields.count >= 2, fields[0] == "GET" else {
                send(status: "405 Method Not Allowed", body: Data("only GET\n".utf8),
                     contentType: "text/plain", on: connection)
                return
            }

            let target = fields[1].split(separator: "?", maxSplits: 1)
            let path = String(target.first ?? "/")
            let query = target.count > 1 ? String(target[1]) : ""

            // The two routes that take parameters, and the two that write.
            if path == "/settings" {
                send(status: "200 OK", body: DebugInspector.settingsBody(query: query),
                     contentType: "application/json", on: connection)
                return
            }
            if path == "/window" {
                send(status: "200 OK", body: DebugInspector.resizeWindowBody(query: query),
                     contentType: "application/json", on: connection)
                return
            }
            if path == "/settings-window" {
                send(status: "200 OK", body: DebugInspector.settingsWindowBody(query: query),
                     contentType: "application/json", on: connection)
                return
            }

            guard let body = DebugInspector.body(forPath: path) else {
                send(
                    status: "404 Not Found",
                    body: Data("no such route. try /, /views, /tmux, /settings, /window or /settings-window\n".utf8),
                    contentType: "text/plain",
                    on: connection
                )
                return
            }
            send(status: "200 OK", body: body, contentType: "application/json", on: connection)
        }

        private func send(status: String, body: Data, contentType: String, on connection: NWConnection) {
            let head = """
            HTTP/1.1 \(status)\r
            Content-Type: \(contentType); charset=utf-8\r
            Content-Length: \(body.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r

            """
            connection.send(
                content: Data(head.utf8) + body,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

#endif
