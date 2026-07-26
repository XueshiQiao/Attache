import Cocoa
import GhosttyTerminal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaultContentSize = NSSize(width: 900, height: 600)
    private let minimumContentSize = NSSize(width: 480, height: 320)
    private var window: NSWindow?
    private var viewController: ViewController?

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

        let controller = ViewController(tmuxPath: tmuxPath, sessionName: sessionName)
        viewController = controller

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
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    func applicationWillTerminate(_: Notification) {
        // Detach cleanly so tmux does not keep a dead control client around.
        viewController?.paneSession.stop()
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
        appMenu.addItem(
            withTitle: "隐藏 TmuxGUI",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 TmuxGUI",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
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
        guard let session = viewController?.paneSession else { return }
        session.runThroughputProbe { [weak self] report in
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
