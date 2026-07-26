import Cocoa
import GhosttyTerminal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaultContentSize = NSSize(width: 1100, height: 720)
    private let minimumContentSize = NSSize(width: 520, height: 340)
    private var window: NSWindow?
    private var sessionController: SessionViewController?
    private var titleTimer: Timer?
    private var status = "启动中…"

    func applicationDidFinishLaunching(_: Notification) {
        installMenu()

        guard let tmuxPath = TmuxControlClient.locateTmux() else {
            fail("找不到 tmux", "在 /opt/homebrew/bin、/usr/local/bin、/usr/bin 和登录 shell 的 PATH 里都没找到 tmux。")
            return
        }

        let sessions = TmuxControlClient.listSessions(tmuxPath: tmuxPath)
        guard let sessionName = chooseSession(from: sessions) else {
            fail("没有可用的 tmux session", "tmux 服务器没在跑，或者一个 session 都没有。先在终端里建一个再启动本 app。")
            return
        }

        let connection = TmuxSessionConnection(tmuxPath: tmuxPath, sessionName: sessionName)
        let controller = SessionViewController(connection: connection)
        controller.onStatusChange = { [weak self] status in
            self?.status = status
            self?.refreshTitle()
        }
        sessionController = controller

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TmuxGUI"
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
        titleTimer?.invalidate()
        // Detach cleanly. The panes keep running — that is the whole point.
        sessionController?.stop()
    }

    private func refreshTitle() {
        window?.title = status
        guard let metrics = sessionController?.connection.metrics.snapshot() else { return }
        window?.subtitle = metrics.titleSummary
    }

    // MARK: - Session choice

    /// Which session to attach to: `TMUX_GUI_SESSION` wins, so a measurement
    /// run can target a throwaway session without touching the real ones;
    /// otherwise the first session tmux reports.
    private func chooseSession(from sessions: [String]) -> String? {
        if let requested = ProcessInfo.processInfo.environment["TMUX_GUI_SESSION"],
           !requested.isEmpty
        {
            guard sessions.contains(requested) else {
                fail(
                    "找不到 session「\(requested)」",
                    "TMUX_GUI_SESSION 指定了它，但服务器上只有：\(sessions.joined(separator: ", "))"
                )
                return nil
            }
            return requested
        }
        return sessions.first
    }

    // MARK: - Menu

    /// `main.swift` runs `NSApplication` directly with no nib, so there is no
    /// menu bar unless one is built by hand — and without it ⌘Q does nothing.
    private func installMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隐藏 TmuxGUI", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 TmuxGUI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let probeItem = NSMenuItem()
        let probeMenu = NSMenu(title: "测量")
        let run = NSMenuItem(
            title: "跑一轮吞吐压测（约 18 秒）",
            action: #selector(runThroughputProbe),
            keyEquivalent: "r"
        )
        run.target = self
        probeMenu.addItem(run)
        probeItem.submenu = probeMenu
        mainMenu.addItem(probeItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func runThroughputProbe() {
        sessionController?.connection.runThroughputProbe { [weak self] report in
            print(report)
            self?.showReport(report)
        }
    }

    private func showReport(_ report: String) {
        let alert = NSAlert()
        alert.messageText = "控制模式吞吐压测"
        alert.informativeText = report
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - Errors

    private func fail(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
