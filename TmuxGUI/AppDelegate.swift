import Cocoa
import GhosttyTerminal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaultContentSize = NSSize(width: 1280, height: 780)
    private let minimumContentSize = NSSize(width: 700, height: 380)
    private var window: NSWindow?
    private var main: MainViewController?
    private var titleTimer: Timer?
    private var status = "启动中…"

    func applicationDidFinishLaunching(_: Notification) {
        installMenu()

        guard let tmuxPath = TmuxControlClient.locateTmux() else {
            fail("找不到 tmux", "在 /opt/homebrew/bin、/usr/local/bin、/usr/bin 和登录 shell 的 PATH 里都没找到 tmux。")
            return
        }
        guard !TmuxControlClient.listSessions(tmuxPath: tmuxPath).isEmpty else {
            fail("没有可用的 tmux session", "tmux 服务器没在跑，或者一个 session 都没有。先在终端里建一个再启动本 app。")
            return
        }

        let controller = MainViewController(server: TmuxServer(tmuxPath: tmuxPath))
        controller.onStatusChange = { [weak self] status in
            self?.status = status
            self?.refreshTitle()
        }
        main = controller

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
        main?.stop()
    }

    private func refreshTitle() {
        window?.title = status
        guard let metrics = main?.currentSession?.connection.metrics.snapshot() else { return }
        window?.subtitle = metrics.titleSummary
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

        mainMenu.addItem(makeWindowMenuItem())
        mainMenu.addItem(makeSessionMenuItem())

        let probeItem = NSMenuItem()
        let probeMenu = NSMenu(title: "测量")
        let run = NSMenuItem(title: "跑一轮吞吐压测（约 18 秒）", action: #selector(runThroughputProbe), keyEquivalent: "r")
        run.target = self
        probeMenu.addItem(run)
        probeItem.submenu = probeMenu
        mainMenu.addItem(probeItem)

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
        let menu = NSMenu(title: "窗口")
        entry(menu, "新建窗口", "t", [.command], #selector(newWindow))
        entry(menu, "隐藏当前标签", "w", [.command], #selector(hideCurrentWindow))
        menu.addItem(.separator())
        entry(menu, "下一个窗口", "]", [.command, .shift], #selector(nextWindow))
        entry(menu, "上一个窗口", "[", [.command, .shift], #selector(previousWindow))
        menu.addItem(.separator())
        for slot in 1 ... 9 {
            entry(menu, "切到第 \(slot) 个", "\(slot)", [.command], #selector(selectWindowSlot(_:)), tag: slot)
        }
        item.submenu = menu
        return item
    }

    private func makeSessionMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Session")
        entry(menu, "新建 session", "n", [.command, .shift], #selector(newSession))
        menu.addItem(.separator())
        entry(menu, "下一个 session", "]", [.command, .control], #selector(nextSession))
        entry(menu, "上一个 session", "[", [.command, .control], #selector(previousSession))
        menu.addItem(.separator())
        for slot in 1 ... 9 {
            entry(menu, "切到第 \(slot) 个", "\(slot)", [.command, .control], #selector(selectSessionSlot(_:)), tag: slot)
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
