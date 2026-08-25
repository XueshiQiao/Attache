import Cocoa
import GhosttyTerminal

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    /// A share of the screen rather than a fixed size in points.
    ///
    /// 1280×780 was dialled in on one display and is a different window on
    /// every other one — a third of a 5K panel, most of a laptop's. These
    /// fractions are of the screen's *visible* frame, so the menu bar and the
    /// Dock are already out of it and the window cannot come up underneath
    /// either.
    private static let defaultScreenFraction = (width: 0.75, height: 0.70)

    /// The fallback for a machine that reports no screen at all — headless CI,
    /// or a session with no display attached. Never used with a screen present.
    private let fallbackContentSize = NSSize(width: 1280, height: 780)
    private let minimumContentSize = NSSize(width: 700, height: 380)
    private var window: NSWindow?
    private var main: MainViewController?
    private var settings: SettingsWindowController?
    private var titleTimer: Timer?
    private var status = "Starting…"
    /// Held so `menuNeedsUpdate` can tell this menu from any other the app
    /// delegate might end up the delegate of.
    private var quickActionsMenu: NSMenu?
    #if DEBUG
        private var inspectorMenuItem: NSMenuItem?
    #endif

    /// The window's opening size, as a share of the screen it will open on.
    ///
    /// `visibleFrame` rather than `frame`: the second one includes the menu bar
    /// and the space the Dock occupies, so a fraction of it puts part of the
    /// window under both. `window.screen` is nil before the window is placed,
    /// so this falls back to the main screen — which is where `center()` puts
    /// it anyway.
    ///
    /// Clamped to the minimum, because a fraction of a very small display can
    /// be smaller than the window is allowed to be, and `setContentSize` with
    /// something below `contentMinSize` is silently ignored.
    private func defaultContentSize(for window: NSWindow) -> NSSize {
        guard let screen = window.screen ?? NSScreen.main else { return fallbackContentSize }
        let visible = screen.visibleFrame
        return NSSize(
            width: max(visible.width * Self.defaultScreenFraction.width, minimumContentSize.width),
            height: max(visible.height * Self.defaultScreenFraction.height, minimumContentSize.height)
        )
    }

    func applicationDidFinishLaunching(_: Notification) {
        // First, before anything can build a surface: take
        // `GHOSTTY_RESOURCES_DIR` away from whatever launched this app and
        // point it at the copy of the terminfo database inside this bundle.
        // Inherited, it named a directory inside *Ghostty.app* — an unrelated
        // application whose removal then left every pane blank. See
        // `GhosttyTerminfo`. The answer is kept rather than re-derived because
        // the notice below has to wait for the sink two blocks down, and this
        // has to happen before the first `TerminalController` exists.
        let terminfo = GhosttyTerminfo.adoptOwnResourcesAtLaunch()
        // Before anything draws: pin the process appearance if the user asked
        // for one, then derive the chrome colours from whichever half of the
        // theme that leaves showing. Both are read-only with respect to the
        // stored settings, so a launch cannot rewrite them.
        // Before any setting is read: move them out of the plist if this is the
        // first run of a build that keeps them in a file. See `SettingsFile`.
        SettingsFile.migrateFromUserDefaultsIfNeeded(keys: AppSettings.plistKeys)
        AppSettings.applyAppearanceOverride()
        ChromeTheme.reload()

        // Diagnostics is wired before the first connection exists, so the
        // first command of the first attach is already covered. The sink is
        // the one place detection meets presentation — everything else about
        // the two layers is kept apart on purpose.
        DiagnosticsCenter.shared.noticeSink = { notice in
            MainActor.assumeIsolated { NoticeCenter.shared.post(notice) }
        }
        // The other half of the same wiring: TmuxLog's command tap, pointed at
        // diagnostics here so `TmuxLog` itself stays compilable alone in the
        // check tools.
        TmuxLog.commandSink = { text, session in
            DiagnosticsCenter.shared.commandSent(text, session: session)
        }
        ActivationProbe.shared.start()

        // Before any connection of our own exists, so a reclaimed pid can never
        // be one this run just spawned. A previous run that died without
        // tearing down leaves its control clients attached and unread, and tmux
        // buffers for an attached client indefinitely — see
        // `TmuxChildRegistry` for what that costs and why the process tree
        // cannot be used instead.
        let reclaimed = TmuxChildRegistry.sweep()
        if reclaimed > 0 {
            // Written out both ways rather than "1 connection(s)". This notice is
            // the app admitting it left something behind, and reading like a
            // form letter while it does so is a small thing that undoes it.
            let body = reclaimed == 1
                ? "One tmux connection was left attached by a copy of this app that"
                    + " did not shut down. It has been closed."
                : "\(reclaimed) tmux connections were left attached by a copy of this"
                    + " app that did not shut down. They have been closed."
            DiagnosticsCenter.shared.notice(AppNotice(
                severity: .warning,
                title: "Cleaned up after a previous run", body: body
            ))
        }

        // Said once, at launch, rather than per surface: every pane and every
        // tool answers this question the same way, and the thing reported is
        // one fact about this build. It can only mean the app's own bundle is
        // incomplete now that the database is shipped inside it — which is
        // worth a notice rather than only a log line, because the terminal is
        // quietly less capable than it should be and nothing else on screen
        // would ever say so.
        if let unowned = terminfo.unownedVariable {
            // The environment refused the write, so it still holds whatever
            // launched this app put there — a path into another application.
            // Nothing downstream may trust it, which `termForSurface` enforces
            // by pinning a name the system database can always resolve. An
            // error rather than a warning: it is the invariant this app is
            // supposed to hold, not a degraded nicety.
            TmuxLog.destructive("could not take \(unowned) over — surfaces pinned")
            DiagnosticsCenter.shared.notice(AppNotice(
                severity: .error,
                title: "This app could not take over its own \(unowned)",
                body: "The value it was launched with is still in place, so panes and tools"
                    + " run as \(GhosttyTerminfo.fallbackTerm) rather than trust it."
            ))
        } else if terminfo.term != nil {
            let location = terminfo.missingFrom ?? "this app's bundle"
            TmuxLog.lifecycle(
                "no \(GhosttyTerminfo.ghosttyTerm) entry under \(location)"
                    + " — surfaces pinned to \(GhosttyTerminfo.fallbackTerm)"
            )
            DiagnosticsCenter.shared.notice(AppNotice(
                severity: .warning,
                title: "This app's copy of its terminal description is missing",
                body: "\(location) holds no \(GhosttyTerminfo.ghosttyTerm) entry, which means"
                    + " an incomplete build or bundle. Panes and tools run as"
                    + " \(GhosttyTerminfo.fallbackTerm) instead."
            ))
        }

        installMenu()

        guard let tmuxPath = TmuxControlClient.locateTmux() else {
            fail(
                "tmux not found",
                "Looked in /opt/homebrew/bin, /usr/local/bin, /usr/bin and the PATH"
                    + " of a login shell. Install it — `brew install tmux` — and open"
                    + " this app again."
            )
            return
        }

        let socket: TmuxSocket
        switch TmuxSocket.parse(AppSettings.tmuxSocket) {
        case .invalid(let reason):
            // Not a silent fall-through to the default server: the person
            // asked for a specific one, and connecting elsewhere invites
            // destructive actions on the wrong sessions.
            fail(
                "tmux_socket is unusable",
                "The tmux_socket value in ~/.config/attache.toml \(reason)."
                    + " Fix or remove that line, then open this app again."
            )
            return
        case .socket(let parsed):
            socket = parsed
        }

        // Three different answers, three different behaviours — these used to
        // be one dead-end alert, which for someone who had never run tmux was
        // the whole first-launch experience. tmux errors are shown in tmux's
        // own words; an empty server is an offer, not a failure.
        let transport = TmuxTransport.local(tmuxPath: tmuxPath, socket: socket)
        switch TmuxControlClient.listSessions(transport: transport) {
        case .failed(let message):
            fail("tmux is not answering", "Asked \(transport.summary) and got: \(message)")
            return
        case .noServer:
            guard offerToCreateFirstSession(transport: transport) else { return }
        case .sessions(let sessions) where sessions.isEmpty:
            guard offerToCreateFirstSession(transport: transport) else { return }
        case .sessions:
            break
        }

        // The remote hosts, validated. A broken block is a warning that names
        // itself, never a startup failure: the local server must come up
        // whether or not a machine on the other side of an ssh config does.
        let (hostConfigs, hostProblems) = AppSettings.hosts
        for reason in hostProblems {
            DiagnosticsCenter.shared.notice(AppNotice(
                severity: .warning,
                title: "A [[host]] block was skipped",
                body: "A [[host]] block in ~/.config/attache.toml \(reason)."
            ))
        }
        let sshPath = AppSettings.sshPath
        let hosts = [HostContext.local(transport: transport)]
            + hostConfigs.map { HostContext.remote(config: $0, sshPath: sshPath) }

        let controller = MainViewController(hosts: hosts)
        // The Settings window is made on demand and needs the same hosts the
        // rail shows, for the Hosts page's status and agent-setup rows. Asked
        // of the controller each time rather than captured: the list changes
        // whenever a `[[host]]` block is edited, and a captured copy would
        // hand the settings window retired contexts.
        SettingsStore.remoteHostsProvider = { [weak controller] in controller?.hosts ?? [] }
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
            // `TMUXGUI_` is the pre-rename spelling, still read because it may
            // be sitting in a shell profile that this repository cannot see.
            let environment = ProcessInfo.processInfo.environment
            if environment["ATTACHE_GHOSTTY_LOG"] == "1" || environment["TMUXGUI_GHOSTTY_LOG"] == "1" {
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
            contentRect: NSRect(origin: .zero, size: fallbackContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Attaché"
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
        let toolbar = NSToolbar(identifier: "AttacheMain")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.contentMinSize = minimumContentSize
        window.contentViewController = controller
        // Assigning a content view controller resizes the window to fit that
        // view, and an empty container has no intrinsic size — so the window
        // collapses to `contentMinSize` unless the size is restated here.
        window.setContentSize(defaultContentSize(for: window))
        // Not `center()`. AppKit's centre is deliberately *not* the middle: it
        // puts the window a third of the way down, which is the right answer
        // for a dialog and reads as "sitting high" for a window this size.
        // Measured on this machine before the change — 73pt left of centre and
        // 45pt above it.
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(
                x: visible.minX + (visible.width - frame.width) / 2,
                y: visible.minY + (visible.height - frame.height) / 2
            ))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        titleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool { true }
    /// Only once the main window exists. The create-session offer is an
    /// alert shown *before* any other window, and with an unconditional
    /// `true` here, accepting it closed the app's only window and AppKit
    /// terminated the whole app — cleanly, with the session it had just
    /// created left running and not one line of log saying why. Observed
    /// 2026-08-04 on the first real use of that dialog.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        main != nil
    }

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
        // The detail line used to carry a byte rate for the pane on screen and
        // for the session. It is gone because its input is: the connection now
        // attaches with `refresh-client -f no-output`, so tmux sends no pane
        // bytes down it. Under that flag a healthy connection is legitimately
        // near-silent, so the meter would read the same for a live idle
        // connection and a dead one — an indicator that cannot tell those apart
        // is an anti-signal. Liveness here is event-shaped instead: the client's
        // `onExit` reaches `scheduleSessionRefresh` and the rail reconciles.
        main?.showStatus(status, detail: "")
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
        appMenu.addItem(withTitle: "Hide Attaché", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Attaché", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        // The only way in and the only way out. The rail's split item is
        // collapsible, so a person who drags it shut needs a route back, and
        // this is it — the same reason the session rail is *not* collapsible,
        // arrived at from the other side.
        entry(
            viewMenu, "Show Conversation", "\\", [.command],
            #selector(toggleConversationSidebar)
        )
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        mainMenu.addItem(makePaneMenuItem())
        mainMenu.addItem(makeWindowMenuItem())
        mainMenu.addItem(makeSessionMenuItem())
        mainMenu.addItem(makeQuickActionsMenuItem())

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
        if main?.currentEmbedded?.pasteIntoFocusedPane() == true { return }
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
        if main?.currentEmbedded?.sendUndo() == true { return }
        NSApp.sendAction(Selector(("undo:")), to: nil, from: sender)
    }

    // The pane these act on is the one the keyboard is in, not the one the app
    // last drew a focus ring on — see `SessionViewController.paneWithKeyboard`.
    // Each returns false when there is no pane at all, which is what happens
    // with the settings window in front, and the shortcut then does nothing
    // rather than addressing whichever pane was last touched.
    @objc private func splitRight() {
        _ = main?.currentEmbedded?.splitFocusedPane(.right)
    }

    @objc private func splitDown() {
        _ = main?.currentEmbedded?.splitFocusedPane(.down)
    }

    @objc private func toggleZoomPane() {
        _ = main?.currentEmbedded?.toggleZoomOnFocusedPane()
    }

    @objc private func killPane() {
        _ = main?.currentEmbedded?.confirmKillFocusedPane()
    }

    /// Flip the conversation rail — `MainViewController` owns the rule,
    /// because "visible" is a fact about the window (which window is on
    /// screen, whether it has an agent), not about the setting alone.
    @objc private func toggleConversationSidebar(_ sender: NSMenuItem) {
        main?.toggleConversationRail()
    }

    /// The checkmark on "Show Conversation" reads the rail's actual state each
    /// time the menu opens. Setting it inside the action was wrong twice over:
    /// the item started unchecked no matter what the TOML said, and went stale
    /// whenever anything else moved the rail. The `NSMenuItemValidation`
    /// conformance on the class is load-bearing — without it Swift never
    /// exposes this method to Objective-C, AppKit never calls it, and the
    /// whole thing reads as wired while doing nothing. Everything else stays
    /// enabled unconditionally, which is exactly what AppKit did for these
    /// items before this method existed.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleConversationSidebar) {
            menuItem.state =
                (main?.isConversationRailVisible ?? AppSettings.showsConversation) ? .on : .off
        }
        return true
    }

    // Each of these picks a window, and picking one is a choice — so each
    // tells the controller to stop trying to place `startup_window`. They
    // address `SessionModel` directly and so never pass through
    // `show(sessionID:)`, which is where every *session* choice is caught.
    @objc private func newWindow() {
        main?.userIsChoosingWindow()
        main?.currentSession?.newWindow()
    }
    @objc private func hideCurrentWindow() {
        // **Hiding the active window selects another one**, which is easy to
        // miss: `SessionModel.hideWindow` sends `select-window` for the next
        // visible row so that the session is not left pointing at a row the
        // rail no longer draws. Leaving this uncancelled let a pending
        // `startup_window` select the just-hidden window straight back, and the
        // sync that follows un-hides it — the row reappears by itself.
        main?.userIsChoosingWindow()
        main?.currentSession?.hideActiveWindow()
    }
    @objc private func nextWindow() {
        main?.userIsChoosingWindow()
        main?.currentSession?.selectAdjacentWindow(offset: 1)
    }
    @objc private func previousWindow() {
        main?.userIsChoosingWindow()
        main?.currentSession?.selectAdjacentWindow(offset: -1)
    }
    @objc private func selectWindowIndex(_ sender: NSMenuItem) {
        main?.userIsChoosingWindow()
        main?.currentSession?.selectWindow(atIndex: sender.tag)
    }

    // MARK: - Quick Actions

    /// The user's own tmux commands, in the menu bar.
    ///
    /// Rebuilt from the stored list every time the menu is about to open rather
    /// than once at launch, because the settings page edits that list while
    /// this menu exists. `NSMenuDelegate` is what makes that free: no
    /// observation, no cache, and no way for the menu to disagree with the
    /// table that produced it.
    private func makeQuickActionsMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Quick Actions")
        menu.delegate = self
        item.submenu = menu
        quickActionsMenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === quickActionsMenu else { return }
        menu.removeAllItems()
        let actions = AppSettings.quickActions.filter(\.isRunnable)
        for (index, action) in actions.enumerated() {
            let item = NSMenuItem(
                title: action.title, action: #selector(runQuickAction(_:)), keyEquivalent: ""
            )
            item.target = self
            // The tag indexes the same filtered list this rebuild produced, so
            // it cannot address a row that was edited away between the menu
            // opening and the click.
            item.tag = index
            item.toolTip = action.command
            menu.addItem(item)
        }
        if actions.isEmpty {
            // Not an empty menu: a menu bar item that opens onto nothing reads
            // as broken rather than as unconfigured.
            let empty = NSMenuItem(title: "No Quick Actions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        let edit = NSMenuItem(
            title: "Edit Quick Actions…", action: #selector(openQuickActionsSettings), keyEquivalent: ""
        )
        edit.target = self
        menu.addItem(edit)

        #if DEBUG
            // A section of its own, and Debug-only: editing the file by hand is
            // a thing to do while working *on* the app, and the settings window
            // is the answer for using it. It is here rather than in the Debug
            // menu because this is where a person is already standing when they
            // wonder where these actions are stored.
            menu.addItem(.separator())
            let open = NSMenuItem(
                title: "Open \(SettingsFile.url.lastPathComponent)",
                action: #selector(openSettingsFile), keyEquivalent: ""
            )
            open.target = self
            open.toolTip = SettingsFile.url.path
            menu.addItem(open)
        #endif
    }

    #if DEBUG
        /// Open the settings file in whatever the user edits `.toml` with.
        ///
        /// A file that does not exist yet is not an error and must not look
        /// like one: nothing is written until a setting changes, so a fresh
        /// install has no file and opening it would fail for a reason that has
        /// nothing wrong with it. Say which case it is instead.
        @objc private func openSettingsFile() {
            let url = SettingsFile.url
            guard FileManager.default.fileExists(atPath: url.path) else {
                report("No settings file yet at \(url.path) — change any setting and it appears")
                return
            }
            if !NSWorkspace.shared.open(url) {
                // An unopenable file is worth saying out loud: the usual cause
                // is nothing being registered for `.toml`, and the path is what
                // the person needs in order to open it themselves.
                report("Nothing on this machine opens \(url.path)")
            }
        }
    #endif

    @objc private func runQuickAction(_ sender: NSMenuItem) {
        let actions = AppSettings.quickActions.filter(\.isRunnable)
        guard actions.indices.contains(sender.tag) else { return }
        main?.run(quickAction: actions[sender.tag])
    }

    /// Opens the settings window on the page that edits this menu.
    ///
    /// Through `showSettings` rather than a second construction site, so the
    /// window is built exactly once however it is reached.
    @objc private func openQuickActionsSettings() {
        showSettings()
        settings?.select(page: .quickActions)
    }

    @objc private func newSession() { main?.server.newSession() }
    @objc private func nextSession() { main?.selectAdjacentSession(offset: 1) }
    @objc private func previousSession() { main?.selectAdjacentSession(offset: -1) }
    @objc private func selectSessionSlot(_ sender: NSMenuItem) {
        main?.selectSession(atSlot: sender.tag - 1)
    }

    // MARK: - Settings

    @objc private func showSettings() {
        if settings == nil { settings = SettingsWindowController() }
        settings?.show()
    }

    /// The rail's "Edit Host…" lands here: the Hosts page, with that host
    /// already selected. Through `showSettings` for the same reason the
    /// quick-actions door is — one construction site.
    func showHostsSettings(selecting hostName: String?) {
        showSettings()
        settings?.select(page: .hosts)
        if let hostName { settings?.selectHost(named: hostName) }
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

    /// The server has nothing to show — not running, or running empty. For
    /// someone who has never used tmux this is the first thing the app ever
    /// says to them, so it is an offer with a way forward, not a dead end.
    /// `new-session -d` also *starts* the server when there is none, loading
    /// the user's own configuration exactly as a terminal launch would — and
    /// if that configuration is broken, the `%config-error` the first attach
    /// carries is surfaced as a notice by `TmuxSessionConnection`.
    ///
    /// True means a session now exists and startup should continue. False
    /// means startup is over — the user chose to quit, or the create failed
    /// and `fail` has already put tmux's own words on screen.
    private func offerToCreateFirstSession(transport: TmuxTransport) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "No tmux sessions"
        alert.informativeText =
            "There is no server, or no sessions, on \(transport.summary)."
                + " Create a session here, or quit and create one in a terminal."
        alert.addButton(withTitle: "Create Session")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else {
            TmuxLog.lifecycle("create-session offer declined — quitting")
            NSApp.terminate(nil)
            return false
        }
        TmuxLog.lifecycle("create-session offer accepted — creating on \(transport.summary)")
        if let problem = TmuxControlClient.createDetachedSession(transport: transport) {
            fail("tmux could not create a session", problem)
            return false
        }
        // A clean exit is not proof the session still exists. The create is
        // what *started* the server, which loaded the user's configuration —
        // and `exit-unattached` or `destroy-unattached` in it can take the
        // detached session down again before the app attaches. Ask again
        // rather than open a window with nothing behind it.
        if case .sessions(let sessions) = TmuxControlClient.listSessions(
            transport: transport
        ), !sessions.isEmpty {
            return true
        }
        fail(
            "tmux did not keep the new session",
            "A session was created and was already gone when this app looked"
                + " again — usually exit-unattached or destroy-unattached in the"
                + " tmux configuration. Change that, then open this app again."
        )
        return false
    }

    private func fail(_ title: String, _ detail: String) {
        // The one line that says which exit this was. Its absence is why the
        // first silent-termination diagnosis had to be done from tmux's side.
        TmuxLog.lifecycle("fatal startup failure: \(title) — \(detail)")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
