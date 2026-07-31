//
//  EmbeddedTmuxPrototype.swift
//  TmuxGUI
//

#if DEBUG

    import Cocoa
    import GhosttyTerminal

    /// Route B of docs/embed-tmux-evaluation.html, built to be judged rather
    /// than shipped: a plain `tmux attach` on a ghostty-owned pty, tmux drawing
    /// everything itself into one surface, while route A keeps running
    /// untouched in the main window.
    ///
    /// Debug-only on purpose. The evaluation's verdict was "prototype first,
    /// and make it daily-usable before deciding" — a Debug menu window is
    /// exactly that much and no more. If route B wins, this file is the seed of
    /// a real implementation and the dual rendering path goes away; if it
    /// loses, deleting this file removes the whole experiment. It must not
    /// grow features while the decision is open.
    @MainActor
    final class EmbeddedTmuxWindowController: NSWindowController, NSWindowDelegate {
        /// Open prototype windows, kept alive here because nothing else owns
        /// them. `isReleasedWhenClosed` is off and the delegate removes the
        /// entry, so a closed window and its child process go away together.
        private static var openControllers = [EmbeddedTmuxWindowController]()

        /// One controller per window rather than the session controllers'
        /// shared pattern: the command to run travels in the ghostty
        /// *configuration* (the `command` key), and two windows attached to
        /// different targets must not fight over one config.
        private let terminalController: TerminalController
        private let terminalView: TmuxTerminalView
        let command: String

        /// Refuses rather than opens when the command cannot survive the trip
        /// into a ghostty config line. Every caller funnels through here.
        @discardableResult
        static func open(command: String) -> Bool {
            guard isRenderableCommand(command) else { return false }
            let controller = EmbeddedTmuxWindowController(command: command)
            openControllers.append(controller)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            // The surface only learns it has the keyboard from a become/resign
            // pair — the same lesson TmuxTerminalView documents.
            controller.window?.makeFirstResponder(controller.terminalView)
            return true
        }

        /// The command travels as one `command = <value>` line in a rendered
        /// ghostty config, so a control character in it is not an odd command —
        /// it is a way to write *other config lines*, and an invalid line makes
        /// the controller fall back to its default configuration: a plain
        /// shell opens while everything reports success. Found in review;
        /// refused here so both callers get the same answer.
        static func isRenderableCommand(_ command: String) -> Bool {
            !command.isEmpty
                && !command.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        }

        private init(command: String) {
            self.command = command
            let base = TerminalConfiguration(startingFrom: .default) { builder in
                // Zero padding to match route A's picture density. Unlike route
                // A this is cosmetic: the child reads its size from the pty,
                // which ghostty sets from its own grid, so the two cannot
                // disagree about columns no matter what the padding is.
                builder.withCustom("window-padding-x", "0")
                builder.withCustom("window-padding-y", "0")
                builder.withCustom("window-padding-balance", "false")
                // The prototype's whole point: a real command on a real pty.
                builder.withCustom("command", command)
                // An attach that fails (bad target, missing terminfo on a
                // machine without Ghostty) prints one line and exits; without
                // this the surface would close before that line can be read and
                // the failure would be invisible.
                builder.withCustom("wait-after-command", "true")
            }
            terminalController = TerminalController(
                configSource: .generated(base.rendered),
                theme: AppSettings.terminalTheme(),
                terminalConfiguration: AppSettings.terminalConfiguration()
            )

            terminalView = TmuxTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
            terminalView.controller = terminalController
            terminalView.configuration = TerminalSurfaceOptions(backend: .exec)
            terminalView.setAccessibilityElement(true)
            terminalView.setAccessibilityLabel("embedded tmux prototype")

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Embedded tmux — \(command)"
            window.contentView = terminalView
            window.isReleasedWhenClosed = false
            window.center()
            super.init(window: window)
            window.delegate = self
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not built from a nib") }

        func windowWillClose(_: Notification) {
            Self.openControllers.removeAll { $0 === self }
        }
    }

    // The surface is `TmuxTerminalView`, the same one the panes use. A class
    // of its own lived here briefly and its copy of those AppKit overrides was
    // missing the right-click handling, which presented as the pane menu
    // disappearing in the embedded half.

    extension DebugInspector {
        /// `/embed?run=1[&socket=<name>][&target=<session>]` opens a route B
        /// prototype window. It exists because the menu entry is a modal
        /// prompt, and driving a modal needs the Accessibility grant an
        /// agent's shell does not have — the same reason `/paste` exists.
        ///
        /// It deliberately does NOT take a command string. The inspector's
        /// POST-plus-header gate stops a *browser*; it authenticates no local
        /// process, and this app is explicitly unsandboxed — a route that ran
        /// caller-supplied text would let any sandboxed same-user process with
        /// loopback access execute outside its sandbox through us. Found in
        /// review. The command is built here, from the tmux this app already
        /// located, and both parameters are held to characters that can
        /// neither quote, escape, nor write a config line. Free-form commands
        /// stay in the Debug menu prompt, where the typist is the person at
        /// the machine.
        static func embedBody(query: String) -> Data {
            struct Report: Encodable {
                let opened: Bool
                let command: String?
                let refusal: String?
            }
            func refuse(_ why: String) -> Data {
                encode(Report(opened: false, command: nil, refusal: why))
            }
            var parameters = [String: String]()
            for pair in query.split(separator: "&") {
                let halves = pair.split(separator: "=", maxSplits: 1)
                guard let key = halves.first.map(String.init) else { continue }
                let raw = halves.count > 1 ? String(halves[1]) : ""
                parameters[key] = raw.removingPercentEncoding ?? raw
            }
            guard parameters["run"] == "1" else {
                return refuse("add run=1 to open a window")
            }
            if parameters["cmd"] != nil {
                return refuse("cmd is gone — this route builds the command itself; use socket= and target=")
            }
            // Letters, digits, and the punctuation tmux targets actually use.
            // No space, no quote, no backslash — and nothing that could reach
            // the config renderer as a control character.
            //
            // `$` is deliberately absent even though a session id is `$N`, and
            // that costs this route the ability to name one. ghostty runs the
            // command through `/bin/sh -c`, so `$` is not a character in a
            // target — it is shell expansion: `work$IFS-d` passes any
            // character-set check and arrives at tmux as `-t work -d`, which
            // detaches somebody else's client. Found by review after the first
            // fix; the whitelist that closed arbitrary execution had opened
            // this. Nothing else left in here is special to sh. Name sessions
            // by name (`=name` works) until this route stops going through a
            // shell.
            func safe(_ value: String, allowing extras: String) -> Bool {
                !value.isEmpty && value.allSatisfy {
                    $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-"
                        || extras.contains($0)
                }
            }
            guard let tmuxPath = TmuxControlClient.locateTmux() else {
                return refuse("no tmux on this machine")
            }
            var command = tmuxPath
            if let socket = parameters["socket"] {
                guard safe(socket, allowing: "") else {
                    return refuse("socket: letters, digits, . _ - only")
                }
                command += " -L \(socket)"
            }
            command += " attach"
            if let target = parameters["target"] {
                guard safe(target, allowing: "@%=:") else {
                    return refuse("target: letters, digits, . _ - @ % = : only (no $: ghostty runs this through sh)")
                }
                command += " -t \(target)"
            }
            guard EmbeddedTmuxWindowController.open(command: command) else {
                return refuse("command failed the config-line check")
            }
            return encode(Report(opened: true, command: command, refusal: nil))
        }
    }

#endif
