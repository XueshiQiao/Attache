import Cocoa
import GhosttyTerminal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaultContentSize = NSSize(width: 1280, height: 780)
    private let minimumContentSize = NSSize(width: 700, height: 380)
    private var window: NSWindow?
    private var main: MainViewController?
    private var titleTimer: Timer?
    private var status = "Starting…"
    #if DEBUG
        private var inspectorMenuItem: NSMenuItem?
    #endif

    func applicationDidFinishLaunching(_: Notification) {
        installMenu()

        guard let tmuxPath = TmuxControlClient.locateTmux() else {
            fail(
                "tmux not found",
                "Looked in /opt/homebrew/bin, /usr/local/bin, /usr/bin and the PATH of a login shell."
            )
            return
        }
        guard !TmuxControlClient.listSessions(tmuxPath: tmuxPath).isEmpty else {
            fail(
                "No tmux sessions",
                "The tmux server is not running, or it has no sessions. Create one in a terminal first."
            )
            return
        }

        let controller = MainViewController(server: TmuxServer(tmuxPath: tmuxPath))
        controller.onStatusChange = { [weak self] status in
            self?.status = status
            self?.refreshTitle()
        }
        main = controller

        #if DEBUG
            DebugInspector.main = controller
            if DebugInspectorServer.isEnabledByDefault {
                TmuxLog.lifecycle(DebugInspectorServer.shared.start())
                syncInspectorMenuItem()
            }
        #endif

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "TmuxGUI"
        // No visible title bar. The content runs to the top of the window and
        // the window-tab strip occupies that band instead; the traffic lights
        // float over the session rail, which leaves room for them.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.contentMinSize = minimumContentSize
        window.contentViewController = controller
        // Assigning a content view controller resizes the window to fit that
        // view, and an empty container has no intrinsic size — so the window
        // collapses to `contentMinSize` unless the size is restated here.
        window.setContentSize(defaultContentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        titleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool { true }
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    func applicationWillTerminate(_: Notification) {
        TmuxLog.lifecycle("applicationWillTerminate — detaching every connection")
        titleTimer?.invalidate()
        // Detach cleanly. The panes keep running — that is the whole point.
        main?.stop()
        TmuxLog.lifecycle("teardown complete")
    }

    /// The title bar is hidden, so status goes to the sidebar footer instead.
    /// `window.title` is still set — Mission Control and the Window menu read
    /// it even when it is not drawn.
    private func refreshTitle() {
        window?.title = status
        let throughput = main?.currentSession?.connection.metrics.snapshot().titleSummary
        main?.showStatus(status, detail: throughput ?? "")
    }

    // MARK: - Menu

    /// `main.swift` runs `NSApplication` directly with no nib, so there is no
    /// menu bar unless one is built by hand — and without it ⌘Q does nothing.
    private func installMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide TmuxGUI", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit TmuxGUI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        mainMenu.addItem(makeWindowMenuItem())
        mainMenu.addItem(makeSessionMenuItem())

        let probeItem = NSMenuItem()
        let probeMenu = NSMenu(title: "Measure")
        let run = NSMenuItem(title: "Run Throughput Probe (~18s)", action: #selector(runThroughputProbe), keyEquivalent: "r")
        run.target = self
        probeMenu.addItem(run)
        probeItem.submenu = probeMenu
        mainMenu.addItem(probeItem)

        #if DEBUG
            mainMenu.addItem(makeDebugMenuItem())
        #endif

        NSApp.mainMenu = mainMenu
    }

    private func entry(
        _ menu: NSMenu, _ title: String, _ key: String,
        _ mask: NSEvent.ModifierFlags, _ action: Selector, tag: Int = 0
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        item.target = self
        item.tag = tag
        menu.addItem(item)
    }

    /// Native shortcuts for the things a tab strip should do.
    ///
    /// These sit alongside the user's tmux `prefix` bindings rather than
    /// replacing them: ⌘T and `prefix + c` both end up calling `new-window`,
    /// and the strip updates the same way whichever one was used.
    private func makeWindowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        entry(menu, "New Window", "t", [.command], #selector(newWindow))
        entry(menu, "Hide Current Tab", "w", [.command], #selector(hideCurrentWindow))
        menu.addItem(.separator())
        entry(menu, "Next Window", "]", [.command, .shift], #selector(nextWindow))
        entry(menu, "Previous Window", "[", [.command, .shift], #selector(previousWindow))
        menu.addItem(.separator())
        for slot in 1 ... 9 {
            entry(menu, "Window \(slot)", "\(slot)", [.command], #selector(selectWindowSlot(_:)), tag: slot)
        }
        item.submenu = menu
        return item
    }

    private func makeSessionMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Session")
        entry(menu, "New Session", "n", [.command, .shift], #selector(newSession))
        menu.addItem(.separator())
        entry(menu, "Next Session", "]", [.command, .control], #selector(nextSession))
        entry(menu, "Previous Session", "[", [.command, .control], #selector(previousSession))
        menu.addItem(.separator())
        for slot in 1 ... 9 {
            entry(menu, "Session \(slot)", "\(slot)", [.command, .control], #selector(selectSessionSlot(_:)), tag: slot)
        }
        item.submenu = menu
        return item
    }

    @objc private func newWindow() { main?.currentSession?.newWindow() }
    @objc private func hideCurrentWindow() { main?.currentSession?.hideActiveWindow() }
    @objc private func nextWindow() { main?.currentSession?.selectAdjacentWindow(offset: 1) }
    @objc private func previousWindow() { main?.currentSession?.selectAdjacentWindow(offset: -1) }
    @objc private func selectWindowSlot(_ sender: NSMenuItem) {
        main?.currentSession?.selectWindow(atVisibleSlot: sender.tag - 1)
    }

    @objc private func newSession() { main?.server.newSession() }
    @objc private func nextSession() { main?.selectAdjacentSession(offset: 1) }
    @objc private func previousSession() { main?.selectAdjacentSession(offset: -1) }
    @objc private func selectSessionSlot(_ sender: NSMenuItem) {
        main?.selectSession(atSlot: sender.tag - 1)
    }

    @objc private func runThroughputProbe() {
        main?.currentSession?.connection.runThroughputProbe { [weak self] report in
            print(report)
            self?.showReport(report)
        }
    }

    private func showReport(_ report: String) {
        let alert = NSAlert()
        alert.messageText = "Control Mode Throughput Probe"
        alert.informativeText = report
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Debug inspection

    #if DEBUG

        /// The view hierarchy and the app's tmux state, dumped somewhere an
        /// agent can read without a companion GUI. See `DebugInspector`.
        private func makeDebugMenuItem() -> NSMenuItem {
            let item = NSMenuItem()
            let menu = NSMenu(title: "Debug")
            entry(menu, "Write Inspector Snapshot", "i", [.command, .option], #selector(writeInspectorSnapshot))

            let toggle = NSMenuItem(
                title: "Inspector Server",
                action: #selector(toggleInspectorServer),
                keyEquivalent: "i"
            )
            toggle.keyEquivalentModifierMask = [.command, .option, .shift]
            toggle.target = self
            menu.addItem(toggle)
            inspectorMenuItem = toggle

            item.submenu = menu
            return item
        }

        @objc private func writeInspectorSnapshot() {
            switch DebugInspector.writeSnapshot() {
            case .success(let url):
                report("Inspector snapshot → \(url.path)")
            case .failure(let error):
                report("Inspector snapshot failed: \(error)")
            }
        }

        @objc private func toggleInspectorServer() {
            let server = DebugInspectorServer.shared
            if server.isRunning {
                server.stop()
                DebugInspectorServer.isRememberedOn = false
                report("Inspector off")
            } else {
                DebugInspectorServer.isRememberedOn = true
                report(server.start())
            }
            syncInspectorMenuItem()
        }

        private func syncInspectorMenuItem() {
            inspectorMenuItem?.state = DebugInspectorServer.shared.isRunning ? .on : .off
        }

        /// Two audiences. `TmuxLog` covers the machine one: it writes to stdout,
        /// where an agent running the binary directly is already looking, and
        /// to a file that outlives the process. The sidebar footer is for the
        /// human, and holds until tmux next has something to say.
        private func report(_ message: String) {
            TmuxLog.lifecycle(message)
            status = message
            refreshTitle()
        }

    #endif

    // MARK: - Errors

    private func fail(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
