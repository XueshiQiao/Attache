import Cocoa
import GhosttyTerminal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaultContentSize = NSSize(width: 1280, height: 780)
    private let minimumContentSize = NSSize(width: 700, height: 380)
    private var window: NSWindow?
    private var main: MainViewController?
    private var settings: SettingsWindowController?
    private var titleTimer: Timer?
    private var status = "Starting…"
    #if DEBUG
        private var inspectorMenuItem: NSMenuItem?
    #endif

    func applicationDidFinishLaunching(_: Notification) {
        // Before anything draws: pin the process appearance if the user asked
        // for one, then derive the chrome colours from whichever half of the
        // theme that leaves showing. Both are read-only with respect to the
        // stored settings, so a launch cannot rewrite them.
        AppSettings.applyAppearanceOverride()
        ChromeTheme.reload()

        // Diagnostics is wired before the first connection exists, so the
        // first command of the first attach is already covered. The sink is
        // the one place detection meets presentation — everything else about
        // the two layers is kept apart on purpose.
        DiagnosticsCenter.shared.noticeSink = { notice in
            MainActor.assumeIsolated { NoticeCenter.shared.post(notice) }
        }
        ActivationProbe.shared.start()

        installMenu()

        guard let tmuxPath = TmuxControlClient.locateTmux() else {
            fail(
                "tmux not found",
                "Looked in /opt/homebrew/bin, /usr/local/bin, /usr/bin and the PATH of a login shell."
            )
            return
        }
        // Both answers fail the same way here: tmux that will not run and a
        // server with nothing in it leave the app with nothing to show.
        guard let names = TmuxControlClient.listSessions(tmuxPath: tmuxPath), !names.isEmpty else {
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
            // libghostty's own log, off by default because it is per-frame
            // chatty. It is the only thing that says *why* a surface did not
            // come up, and a surface that never reports its cell size leaves
            // the grid on its placeholder — which looks like a layout bug and
            // is not one.
            if ProcessInfo.processInfo.environment["TMUXGUI_GHOSTTY_LOG"] == "1" {
                TerminalDebugLog.sink = { message in TmuxLog.lifecycle("ghostty: \(message)") }
                TerminalDebugLog.enable([.lifecycle, .metrics])
            }
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
        // No visible title bar. The content runs to the top of the window: the
        // rail on the left, with the traffic lights floating over it, and panes
        // on the right all the way up. The window-tab strip used to fill that
        // band on the right; the tabs are rows in the rail now and nothing
        // replaced it, which is why `isMovableByWindowBackground` below and the
        // rail's own `mouseDownCanMoveWindow` are the only ways left to drag
        // this window by its inside.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The rule that comes with this line: a view that owns a mouse gesture
        // must override `mouseDownCanMoveWindow` to return false. AppKit asks
        // the hit view that question *before* it delivers `mouseDown`, and the
        // inherited answer is yes — so a view can implement dragging correctly,
        // show the right cursor, and never receive an event. That is what made
        // pane splitters undraggable and text unselectable until 2026-07-28;
        // both are fixed by two overrides rather than by any change here.
        window.isMovableByWindowBackground = true
        // Not opaque, so the materials inside have a desktop to sample.
        //
        // This one line is why the rail's 0.55 tint did nothing for a year:
        // `NSVisualEffectView` composites what is *behind the window*, and an
        // opaque window has nothing behind it. Measured before the change —
        // rail (43,46,56), panes (42,46,56), both fully opaque and, to the eye,
        // the same colour. The alpha was already there and had nothing to let
        // through.
        //
        // Set here rather than left to `applyWindowChrome` because a window
        // that starts opaque and is made translucent a moment later flashes.
        window.isOpaque = false
        // Has to match `PaneGridView`'s fill, alpha included. That view's
        // backing layer runs 66pt past its own bounds on macOS 26 and paints
        // the *window's* colour in the overhang; while both were the system
        // grey the mismatch was invisible, a theme exposed it, and translucency
        // exposes it twice over — two different alphas over the same desktop
        // are visible in a way two similar greys were not.
        window.backgroundColor = ChromeTheme.current.background
            .withAlphaComponent(AppSettings.windowOpacity)
        // An empty toolbar, and it is load-bearing rather than decoration.
        // `NSSplitViewItem.allowsFullHeightLayout` only lifts the sidebar into
        // the titlebar band — which is what puts the traffic lights inside the
        // rail's rounded panel instead of above it — when the window actually
        // has a toolbar. Unified style, no items: nothing is supposed to be
        // drawn in that band on the content side — panes run up into it.
        let toolbar = NSToolbar(identifier: "TmuxGUIMain")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
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
        entry(appMenu, "Settings…", ",", [.command], #selector(showSettings))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide TmuxGUI", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit TmuxGUI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        entry(editMenu, "Undo", "z", [.command], #selector(undoInPaneOrResponder))
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        entry(editMenu, "Paste", "v", [.command], #selector(pasteIntoPaneOrResponder))
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        mainMenu.addItem(makePaneMenuItem())
        mainMenu.addItem(makeWindowMenuItem())
        mainMenu.addItem(makeSessionMenuItem())

        // The throughput probe used to be a top-level menu called "Measure",
        // which said nothing about what it measured or that it runs for the
        // better part of a minute. It lives on the settings window's About
        // page now, where it can show its report without a modal.

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

    /// The pane level, which is also a pane's right-click menu.
    ///
    /// Ordered smallest to largest beside Window and Session, matching the way
    /// tmux nests them. It exists mainly so the splits have real key
    /// equivalents: a context menu's items are drawn with their shortcuts but
    /// never consulted for them, so without a menu-bar copy ⌘D would be a
    /// promise the right-click menu makes and nothing keeps.
    ///
    /// The titles name where the new pane lands, not which way the divider
    /// runs: tmux calls "beside" `-h` and iTerm calls the same arrangement
    /// "Split Vertically", so either of those words would be wrong for half
    /// the people reading it. See `SessionViewController.PaneSplit`.
    ///
    /// Kill Pane deliberately has no shortcut. ⌘W is Hide Current Window, and a
    /// neighbouring key that ends processes with no undo is the kind of
    /// adjacency that gets hit by accident.
    private func makePaneMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Pane")
        entry(menu, "Split Right", "d", [.command], #selector(splitRight))
        // Uppercase, and it has to be. AppKit matches a key equivalent against
        // the event's `charactersIgnoringModifiers`, which ignores every
        // modifier *except* shift — so ⇧⌘D arrives as "D" and an item
        // registered as "d" is never found. Measured 2026-07-29: with the
        // lowercase form, ⇧⌘D reached neither the menu nor the log while ⌘D on
        // the line above worked, so it read as the split being broken rather
        // than as the shortcut never firing.
        entry(menu, "Split Down", "D", [.command, .shift], #selector(splitDown))
        menu.addItem(.separator())
        entry(menu, "Zoom Pane", "\r", [.command], #selector(toggleZoomPane))
        menu.addItem(.separator())
        entry(menu, "Kill Pane…", "", [], #selector(killPane))
        item.submenu = menu
        return item
    }

    /// Native shortcuts for the window level, which lives in the rail.
    ///
    /// These sit alongside the user's tmux `prefix` bindings rather than
    /// replacing them: ⌘T and `prefix + c` both end up calling `new-window`,
    /// and the rail updates the same way whichever one was used.
    private func makeWindowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        entry(menu, "New Window", "t", [.command], #selector(newWindow))
        entry(menu, "Hide Current Window", "w", [.command], #selector(hideCurrentWindow))
        menu.addItem(.separator())
        entry(menu, "Next Window", "]", [.command, .shift], #selector(nextWindow))
        entry(menu, "Previous Window", "[", [.command, .shift], #selector(previousWindow))
        menu.addItem(.separator())
        // The window tmux calls 0-9, not the first through tenth row. tmux's
        // own `prefix 0-9` addresses windows the same way, and the rail draws
        // that number beside every row — so ⌘4 goes to the row marked 4
        // whatever else is in the list and whatever `base-index` is set to.
        // 0 included, because `base-index 0` sessions have a window 0 and it
        // would otherwise be the one row with no shortcut.
        for index in 0 ... 9 {
            entry(menu, "Window \(index)", "\(index)", [.command],
                  #selector(selectWindowIndex(_:)), tag: index)
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

    /// ⌘V, intercepted here and nowhere else.
    ///
    /// A pane's paste has to go through tmux — see
    /// `TmuxSessionConnection.paste(text:into:)` for why — and libghostty's
    /// `TerminalView` declares `paste(_:)` `internal`, so the subclass this app
    /// already has for exactly this kind of interception cannot override it.
    /// The menu item is the remaining place.
    ///
    /// Everything that is not a pane keeps the ordinary behaviour by being
    /// forwarded straight back down the responder chain. The rail's rename
    /// field is a real `NSTextField` and its ⌘V is a text field's paste with
    /// nothing to do with tmux; so is every field in the settings window.
    @objc private func pasteIntoPaneOrResponder(_ sender: Any?) {
        if main?.currentSession?.pasteIntoFocusedPane() == true { return }
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
    }

    /// ⌘Z, on the same terms as ⌘V.
    ///
    /// Undo in a pane belongs to the program running there — the shell's line
    /// editor, or a TUI's input box — and the only way to ask for it is the
    /// byte that program reads as undo. See
    /// `SessionViewController.sendUndoToFocusedPane` for which byte and how it
    /// was established.
    ///
    /// Everything that is not a pane gets the ordinary `undo:` down the
    /// responder chain, which is what the rail's rename field and the settings
    /// window's fields want. Before this existed ⌘Z did nothing anywhere in the
    /// app: there was no Edit-menu item for it at all.
    @objc private func undoInPaneOrResponder(_ sender: Any?) {
        if main?.currentSession?.sendUndoToFocusedPane() == true { return }
        NSApp.sendAction(Selector(("undo:")), to: nil, from: sender)
    }

    // The pane these act on is the one the keyboard is in, not the one the app
    // last drew a focus ring on — see `SessionViewController.paneWithKeyboard`.
    // Each returns false when there is no pane at all, which is what happens
    // with the settings window in front, and the shortcut then does nothing
    // rather than addressing whichever pane was last touched.
    @objc private func splitRight() {
        _ = main?.currentSession?.splitFocusedPane(.right)
    }

    @objc private func splitDown() {
        _ = main?.currentSession?.splitFocusedPane(.down)
    }

    @objc private func toggleZoomPane() {
        _ = main?.currentSession?.toggleZoomOnFocusedPane()
    }

    @objc private func killPane() {
        _ = main?.currentSession?.confirmKillFocusedPane()
    }

    @objc private func newWindow() { main?.currentSession?.newWindow() }
    @objc private func hideCurrentWindow() { main?.currentSession?.hideActiveWindow() }
    @objc private func nextWindow() { main?.currentSession?.selectAdjacentWindow(offset: 1) }
    @objc private func previousWindow() { main?.currentSession?.selectAdjacentWindow(offset: -1) }
    @objc private func selectWindowIndex(_ sender: NSMenuItem) {
        main?.currentSession?.selectWindow(atIndex: sender.tag)
    }

    @objc private func newSession() { main?.server.newSession() }
    @objc private func nextSession() { main?.selectAdjacentSession(offset: 1) }
    @objc private func previousSession() { main?.selectAdjacentSession(offset: -1) }
    @objc private func selectSessionSlot(_ sender: NSMenuItem) {
        main?.selectSession(atSlot: sender.tag - 1)
    }

    // MARK: - Settings

    @objc private func showSettings() {
        if settings == nil {
            settings = SettingsWindowController { [weak self] completion in
                guard let connection = self?.main?.currentSession?.connection else {
                    completion("No session is on screen, so there is nothing to measure.")
                    return
                }
                connection.runThroughputProbe { report in
                    // Through TmuxLog, not print: the probe runs for the better
                    // part of a minute and its result is the one number this
                    // project trusts about throughput. stdout alone loses it
                    // when the app quits; the log file keeps it.
                    TmuxLog.lifecycle(report)
                    completion(report)
                }
            }
        }
        settings?.show()
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
