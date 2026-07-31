//
//  DebugInspectorServer.swift
//  Attache
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
    ///
    /// **Who this is protected against.** Not the network: the listener binds
    /// to 127.0.0.1 and nothing off the machine can open a connection. Verified
    /// with `lsof -nP -iTCP:47623` against a running Debug build, which reports
    /// `TCP 127.0.0.1:47623 (LISTEN)` — the previous version of this comment
    /// asserted it without anyone having looked.
    ///
    /// The threat that binding does *not* answer is the browser, which runs on
    /// this machine and will issue a request on behalf of any page the user
    /// visits. Reads are left open to it — a cross-origin reply is unreadable
    /// and there is nothing here worth the friction. Writes are not: they take
    /// a `POST` carrying `X-Attache-Inspect`, a pair no page can produce
    /// without a preflight this server never answers. `Origin` is refused
    /// outright and `Host` must be the loopback address this was reached at,
    /// which is what closes DNS rebinding.
    ///
    /// **Anything else running as this user can still call it.** Loopback is
    /// not an authentication boundary and this has no credential. That is the
    /// deliberate line: the endpoint exists so an agent driving the app can
    /// read and steer it, and it only exists in Debug builds.
    @MainActor
    final class DebugInspectorServer {
        static let shared = DebugInspectorServer()

        static let defaultPort: UInt16 = 47623
        /// In `~/.config/tmux-gui.toml` like every other preference, not in the
        /// plist. It is a setting the user changes from a menu, so it belongs
        /// where the settings are — and "no app setting goes in the plist" is
        /// worth being able to state without an exception.
        private static let enabledKey = "debug_inspector_server"

        private var listener: NWListener?
        private(set) var port: UInt16?

        /// First of `names` that is set, or nil.
        ///
        /// The `TMUXGUI_` spellings are what these were called before the app
        /// was renamed, and they are still read because the callers are agent
        /// scripts and shell profiles this repository cannot see. A variable
        /// that quietly stops working leaves the run without an endpoint and
        /// nothing to explain it.
        private static func environmentValue(_ names: [String]) -> String? {
            let environment = ProcessInfo.processInfo.environment
            for name in names {
                if let value = environment[name], !value.isEmpty { return value }
            }
            return nil
        }

        /// Whether the server should come up at launch.
        ///
        /// The environment variable wins when present, so a run started by an
        /// agent gets the endpoint without touching the user's defaults.
        static var isEnabledByDefault: Bool {
            if let raw = environmentValue(["ATTACHE_INSPECT", "TMUXGUI_INSPECT"]) {
                return raw == "1" || raw.lowercased() == "true"
            }
            return SettingsFile.shared.object(forKey: enabledKey) as? Bool ?? false
        }

        static var isRememberedOn: Bool {
            get { SettingsFile.shared.object(forKey: enabledKey) as? Bool ?? false }
            set { SettingsFile.shared.set(newValue, forKey: enabledKey) }
        }

        var isRunning: Bool { listener != nil }

        /// Port to bind. Overridable so two debug builds can run side by side.
        private static var configuredPort: UInt16 {
            guard let raw = environmentValue(["ATTACHE_INSPECT_PORT", "TMUXGUI_INSPECT_PORT"]),
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
            return "Inspector http://127.0.0.1:\(port)"
                + " — GET /, /views, /tmux, /settings, /settings-window, and any"
                + " write route with no query. Changing something needs"
                + " POST -H '\(Self.writeHeader): 1':"
                + " /settings (?fontSize=18&darkTheme=Dracula&…),"
                + " /window (?size=1200x800&screen=primary&position=x,y),"
                + " /select (?session=name),"
                + " /shot (?path=….png&method=window|view&subview=Class)"
        }

        // MARK: - Requests

        private func accept(_ connection: NWConnection) {
            connection.start(queue: .main)
            receive(on: connection, accumulated: Data())
        }

        /// Read until the end of the request head. Every route takes its
        /// parameters in the query string, so the head is the whole story even
        /// for the writes, which are `POST`s — a body, if one is sent, is
        /// ignored and left unread. The 64 KB ceiling is there so a malformed
        /// client cannot make the app grow without bound.
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

        /// Routes that change something when given parameters: a setting, the
        /// window's frame, which session is shown, the grid's cell size. With
        /// an empty query each one only reports, so each one is still a read.
        private static let writeRoutes: Set<String> = [
            "/settings", "/window", "/select", "/paste",
        ]

        /// `/shot` is the exception: it writes a PNG whether or not it was told
        /// where, so there is no parameterless read of it.
        private static let alwaysWriteRoutes: Set<String> = ["/shot"]

        /// Header a write has to carry. Its value is irrelevant; its presence
        /// is the whole point. See `respond`.
        private static let writeHeader = "x-attache-inspect"

        /// What that header was called before the app was renamed. Accepted
        /// too, because the callers are agent scripts outside this repository
        /// and the failure is a 403 on a request that looks correct.
        private static let legacyWriteHeader = "x-tmuxgui-inspect"

        private static func carriesWriteHeader(_ headers: [String: String]) -> Bool {
            headers[writeHeader] != nil || headers[legacyWriteHeader] != nil
        }

        private func respond(to head: Data, on connection: NWConnection) {
            let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
            let fields = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: true)
            var headers = [String: String]()
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }

            guard fields.count >= 2, fields[0] == "GET" || fields[0] == "POST" else {
                send(status: "405 Method Not Allowed", body: Data("only GET and POST\n".utf8),
                     contentType: "text/plain", on: connection)
                return
            }
            let method = String(fields[0])

            let target = fields[1].split(separator: "?", maxSplits: 1)
            let path = String(target.first ?? "/")
            let query = target.count > 1 ? String(target[1]) : ""

            // Binding to loopback keeps this off the network — verified with
            // `lsof -nP -iTCP:47623`, which shows `127.0.0.1:47623 (LISTEN)`
            // rather than `*:47623`. What it does not keep out is the browser,
            // which is already on the machine: any page the user visits can
            // make their browser issue this request. A mutating `GET` needs
            // nothing but `<img src="http://127.0.0.1:47623/settings?fontSize=6">`
            // to fire — no script, no reply read, no consent. A font size that
            // small is destructive by this project's measure: it changes the
            // column count, and the app hands that straight to tmux.
            //
            // So a write must carry two things a cross-origin request cannot
            // produce. `POST` rules out `<img>`, `<script>` and every other
            // markup-only trigger. The custom header rules out the form that
            // can still POST across origins: setting a header makes the browser
            // preflight, and nothing here answers `OPTIONS`. Reads stay plain
            // `GET`s, because being reachable with a bare `curl` is what they
            // are for — and a reply nothing can read is not worth defending.
            let isWrite = Self.alwaysWriteRoutes.contains(path)
                || (Self.writeRoutes.contains(path) && !query.isEmpty)
            if isWrite, method != "POST" || !Self.carriesWriteHeader(headers) {
                send(
                    status: "405 Method Not Allowed",
                    body: Data("\(path) changes something: POST it with the \(Self.writeHeader) header\n".utf8),
                    contentType: "text/plain", on: connection
                )
                return
            }
            // Separately from the above: `Origin` is present on exactly the
            // requests a page made, and absent from the ones a terminal made.
            // Refusing it costs a real caller nothing.
            if headers["origin"] != nil {
                send(status: "403 Forbidden", body: Data("no cross-origin requests\n".utf8),
                     contentType: "text/plain", on: connection)
                return
            }
            // And a `Host` this listener could actually have been reached at.
            // A name that resolves to 127.0.0.1 is how DNS rebinding turns a
            // page's own origin into this one, and it arrives carrying that
            // name rather than the address.
            let port = self.port ?? Self.configuredPort
            if let host = headers["host"],
               host != "127.0.0.1:\(port)", host != "localhost:\(port)", host != "[::1]:\(port)"
            {
                send(status: "403 Forbidden", body: Data("unexpected Host\n".utf8),
                     contentType: "text/plain", on: connection)
                return
            }

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
            if path == "/select" {
                send(status: "200 OK", body: DebugInspector.selectBody(query: query),
                     contentType: "application/json", on: connection)
                return
            }
            if path == "/paste" {
                send(status: "200 OK", body: DebugInspector.pasteBody(query: query),
                     contentType: "application/json", on: connection)
                return
            }
            if path == "/shot" {
                send(status: "200 OK", body: DebugInspector.screenshotBody(query: query),
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
                    body: Data("no such route. read: /, /views, /tmux, /settings-window. write (POST + X-Attache-Inspect): /settings, /window, /select, /shot\n".utf8),
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
