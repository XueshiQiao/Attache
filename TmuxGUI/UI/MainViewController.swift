//
//  MainViewController.swift
//  TmuxGUI
//

import Cocoa

/// The whole window: session rail on the left, the selected session's windows
/// and panes on the right.
///
/// The three levels the app exists to provide, top to bottom:
///
///     tmux session  →  a group heading in the left rail
///     tmux window   →  a row under that heading
///     tmux pane     →  a split in the content area
///
/// The first two used to be separate controls in separate halves of the window.
/// They are one list now, so this controller has one more job than it had: the
/// rail is a single view that outlives every session, and the window level it
/// draws belongs to whichever `SessionViewController` is on screen. Routing
/// those clicks is what `wireSidebar` does.
///
/// Session controllers are kept once created, so switching back to a session
/// shows content that stayed current while it was off screen — the connection
/// never detached.
///
/// The rail is a real `NSSplitViewItem` sidebar rather than a view placed by
/// hand. That is where the full-height look with the traffic lights over the
/// rail comes from, along with the divider, the drag to resize and the
/// thickness limits — all of which were previously either hand-drawn, hand
/// measured, or missing, and each of which is a thing to re-chase every time
/// AppKit changes.
@MainActor
final class MainViewController: NSSplitViewController {
    let server: TmuxServer

    private let sidebar = SessionSidebarView(frame: .zero)
    private let content = Content()
    private var controllers = [String: SessionViewController]()
    private var currentName: String?
    private var sidebarItem: NSSplitViewItem?
    /// The rail width this controller last placed the divider at. Not the
    /// rail's current width, which the user is free to drag.
    private var appliedSidebarWidth: CGFloat?
    private var settingsObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?

    var onStatusChange: ((String) -> Void)?

    init(server: TmuxServer) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    var currentSession: SessionViewController? {
        guard let currentName else { return nil }
        return controllers[currentName]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        installSidebar()

        // The system flipping between light and dark is the input "follow
        // system" runs on, and nothing is stored for it — so it takes the same
        // path a settings change does, but only when it actually selects a
        // different scheme. Observed on the application rather than through a
        // view subclass: `viewDidChangeEffectiveAppearance` exists only on
        // `NSView`, and the app no longer owns the view at the root of the
        // window — the split view controller does.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in AppSettings.notifyIfAppearanceSelectsAnotherTheme() }
        }

        wireSidebar()

        server.onChange = { [weak self] in self?.refreshSidebar() }
        server.start()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let controller = self else { return }
            Task { @MainActor in controller.applySettings() }
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    /// The rail's clicks, both levels of them.
    ///
    /// Session-level ones go to the server. Window-level ones go to the
    /// controller of the session the *rows* belonged to, which the rail hands
    /// over with every callback — deliberately not `currentSession`. The rail
    /// stops rebuilding while a rename field is open or a drag is in flight, so
    /// those rows can outlive a session switch: a drag blocks other clicks but
    /// not ⌃⌘2, and an open editor blocks nothing. Routing a reorder to the
    /// session that happens to be on screen when the mouse comes up would send
    /// `move-window -t <that session>:<index>` and move the window into it.
    ///
    /// **+** on a heading is the one action that is *supposed* to reach another
    /// session: making a window somewhere you are not looking and then not
    /// going there would leave no sign it happened, so it switches too.
    private func wireSidebar() {
        sidebar.onSelect = { [weak self] name in self?.show(sessionNamed: name) }
        sidebar.onNew = { [weak self] in self?.server.newSession() }
        sidebar.onRename = { [weak self] old, new in
            self?.server.connection(for: old)?.renameSession(to: new)
        }

        sidebar.onNewWindow = { [weak self] name in
            guard let self, let connection = server.connection(for: name) else { return }
            connection.newWindow()
            if currentName != name { show(sessionNamed: name) }
        }
        // Clicking a window in a session that is not the one on screen means
        // "show me that window", so it switches first. The rail can list any
        // session's windows now, which makes this reachable in a way it was not
        // when only the current session had rows.
        sidebar.onSelectWindow = { [weak self] session, id in
            guard let self else { return }
            show(sessionNamed: session)
            inSession(session) { $0.selectWindow(id: id) }
        }
        sidebar.onRenameWindow = { [weak self] session, id, name in
            self?.inSession(session) { $0.renameWindow(id: id, to: name) }
        }
        sidebar.onMoveWindow = { [weak self] from, id, to, anchor in
            guard let self else { return }
            guard from != to else {
                inSession(from) { $0.moveWindow(id: id, before: anchor) }
                return
            }
            moveWindow(id: id, from: from, to: to, before: anchor)
        }
        sidebar.onHideWindow = { [weak self] session, id in
            self?.inSession(session) { $0.hideWindow(id) }
        }
        sidebar.onKillWindow = { [weak self] session, id in
            self?.inSession(session) { $0.confirmKillWindow(id: id) }
        }
        sidebar.onRestoreHidden = { [weak self] session in
            self?.inSession(session) { $0.restoreHiddenWindows() }
        }
    }

    /// Move a window out of one session and into another.
    ///
    /// This is the one drag that is not a reorder: the window leaves its
    /// session, and two things follow from that.
    ///
    /// The command goes out on the **destination's** connection, because `-t` is
    /// session-relative and resolves through that connection's `sessionTarget`.
    /// The source connection is not involved at all — `-s @25` names the window
    /// by an id that is unique across the whole server, which is the same
    /// property that makes every other command here safe to target by id.
    ///
    /// And tmux destroys a session the moment its last window leaves, so
    /// dragging the only window out of a session deletes that session. Nothing
    /// running dies — the window and its panes arrive intact on the other side —
    /// but the session, its name and anything set on it are gone, and any other
    /// client attached to it is detached. That is not something to do silently
    /// on a drag that could have been a slip, so it asks first.
    private func moveWindow(id: String, from: String, to: String, before anchor: String?) {
        guard let source = server.connection(for: from),
              server.connection(for: to) != nil else { return }

        // tmux's window list, not the rail's rows: a session with one visible
        // window and two hidden ones survives the move, and counting rows would
        // put a warning in front of the user that is simply not true.
        let emptied = source.windows.count == 1 && source.windows.first?.id == id

        // Whether this is the window on screen, decided before anything is
        // sent. If it is, the app goes with it — see `send`.
        let following = from == currentName && id == source.activeWindowID

        // On the next turn, so the drag has finished unwinding before a modal
        // spins its own event loop inside it. The command is built from ids and
        // an index captured at drop time, so it does not matter that the rail
        // rebuilds behind the alert.
        guard !emptied else {
            DispatchQueue.main.async { [weak self] in
                guard let self, confirmMoveEmptying(session: from, into: to) else { return }
                // Re-checked after the human, not before: the sentence they
                // agreed to named this session, and `move-window -s @25` takes
                // the window from wherever it is by the time it runs. Another
                // client moving it away while the alert was open would turn a
                // confirmed "empty this session" into a move out of a session
                // nobody was asked about.
                guard let source = server.connection(for: from), source.holds(windowID: id) else {
                    TmuxLog.lifecycle(
                        "not moving \(id) — it left \(from) while the confirmation was open",
                        session: from
                    )
                    return
                }
                send(id: id, from: from, to: to, before: anchor,
                     emptying: true, following: following)
            }
            return
        }
        send(id: id, from: from, to: to, before: anchor,
             emptying: false, following: following)
    }

    /// Issue the move, and go with the window when it is the one being looked
    /// at.
    ///
    /// Following is not the app deciding to navigate: dragging the row you are
    /// reading is a request to keep reading it, and leaving the user behind in
    /// the session they just emptied — or on some other window of it — is the
    /// screen doing something they did not ask for. So the destination is told
    /// to select the window, and the app shows that session.
    ///
    /// `select-window` is deliberate here and deliberately absent everywhere
    /// else in this file. `-d` is what stops an ordinary cross-session drop
    /// from yanking the destination's current window away from whoever else is
    /// attached there; sending it back only for the followed case keeps that
    /// true for every other drop.
    private func send(
        id: String, from: String, to: String,
        before anchor: String?, emptying: Bool, following: Bool
    ) {
        guard let destination = server.connection(for: to) else { return }
        TmuxLog.lifecycle(
            "moving window \(id) from \(from) into \(to)"
                + (emptying ? " — \(from) has no other window and tmux will destroy it" : "")
                + (following ? " — it is the window on screen, so the app follows it" : ""),
            session: from
        )

        // Nothing follows a move that was never issued. A destination whose
        // connection has not yet learned its session id refuses every
        // session-relative command, and switching the app to it anyway would
        // leave the window where it was while the screen moved on — the app
        // showing something tmux was never told to do.
        guard destination.moveWindow(id: id, before: anchor) else {
            TmuxLog.lifecycle(
                "the move was not sent — \(to) has no session id yet, or no free index"
                    + " above its windows; staying put",
                session: to
            )
            return
        }

        guard following else { return }
        // Down the destination's own pipe, after its move, so tmux runs them in
        // that order. Selecting before the window has arrived would name a
        // window that is not in this session yet.
        destination.selectWindow(id: id)
        show(sessionNamed: to)
    }

    /// Asked before a move that will take a session with it. Same shape as the
    /// kill confirmation, deliberately: both are "there is no undo for this".
    private func confirmMoveEmptying(session: String, into destination: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move the last window out of \(session)?"
        alert.informativeText =
            "tmux destroys a session when its last window leaves, so \(session) will be gone —"
                + " with its name, its options, and any other terminal attached to it."
                + "\nNothing running ends: the window and its panes arrive in \(destination)."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")

        TmuxLog.destructive(
            "confirmation shown for emptying \(session) by moving its last window to \(destination)",
            session: session
        )
        guard alert.runModal() == .alertFirstButtonReturn else {
            TmuxLog.lifecycle("move cancelled — \(session) keeps its last window", session: session)
            return false
        }
        return true
    }

    /// Run a window-level action against the session it was aimed at, making
    /// that session's controller if this is the first time anything has needed
    /// one.
    ///
    /// Creating it here is not an optimisation, it is the fix for a real gap:
    /// the rail lists the windows of every session it has open, so hiding,
    /// renaming or killing a window in a session that has never been *shown* is
    /// an ordinary thing to do — and a controller is what owns the hidden set
    /// and the kill confirmation. Before this, those clicks reached a nil
    /// lookup and vanished, leaving nothing but a log line.
    ///
    /// The lookup can still miss, and that is what the log line is for now.
    /// Sessions are keyed by *name* throughout this app — `controllers`,
    /// `TmuxServer.connection(for:)` — so a session renamed by another client
    /// becomes, as far as this app is concerned, a different session, and an
    /// action aimed at the old name has nowhere to go. Keying by tmux's `$17`
    /// is the real fix and is bigger than this file.
    private func inSession(_ name: String, _ action: (SessionViewController) -> Void) {
        guard let controller = controller(forSessionNamed: name) else {
            TmuxLog.lifecycle(
                "dropping a window action aimed at \(name) — the server has no"
                    + " connection under that name, most likely renamed elsewhere",
                session: name
            )
            return
        }
        action(controller)
    }

    /// This session's controller, made on demand. One per session for the life
    /// of the session, because it holds the pane surfaces and the hidden set.
    private func controller(forSessionNamed name: String) -> SessionViewController? {
        if let existing = controllers[name] { return existing }
        guard let connection = server.connection(for: name) else { return nil }

        let controller = SessionViewController(connection: connection)
        controller.onStatusChange = { [weak self] status in self?.onStatusChange?(status) }
        // Hiding and restoring never reach tmux, so `server.onChange` — which is
        // fed by connection notifications — cannot see them. Without this the
        // row a user just hid would stay in the rail until tmux happened to say
        // something else.
        controller.onWindowsChanged = { [weak self] in self?.refreshSidebar() }
        controllers[name] = controller
        return controller
    }

    // MARK: - Chrome

    private func installSidebar() {
        // `sidebarWithViewController:`, because the inset rounded panel it
        // draws on macOS 26 is the thing that was wanted, not a defect. An
        // earlier reading of the report had this as a plain item filling the
        // column edge to edge, which removed the panel entirely — the opposite
        // of the ask. `allowsFullHeightLayout` is what puts the traffic lights
        // *inside* that panel rather than in a band above it.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: Hosting(view: sidebar))
        sidebarItem.allowsFullHeightLayout = true
        // Not collapsible. Collapsing is standard sidebar behaviour and comes
        // free, but the only ways back are a toolbar button and a View menu
        // item, and this window has neither — a user who drags the divider
        // shut would have no route to the session list at all.
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = AppSettings.sidebarWidthRange.lowerBound
        sidebarItem.maximumThickness = AppSettings.sidebarWidthRange.upperBound
        self.sidebarItem = sidebarItem
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: content))

        // No autosave name on purpose: the width is a setting, and an autosaved
        // divider position would silently outrank it after the first drag.
        appliedSidebarWidth = AppSettings.sidebarWidth
        splitView.setPosition(AppSettings.sidebarWidth, ofDividerAt: 0)
    }

    /// Wraps a view the app already builds and owns in the view controller a
    /// split view item requires.
    private final class Hosting: NSViewController {
        private let hosted: NSView

        init(view: NSView) {
            hosted = view
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not supported") }

        /// The rail is the panel's content; the panel and its material belong
        /// to the sidebar split view item. Supplying a backdrop here was an
        /// attempt to fill the column edge to edge, which is exactly what the
        /// inset panel is not supposed to do.
        override func loadView() { view = hosted }
    }

    /// The right-hand half, and the parent of whichever session is on screen.
    ///
    /// Its existence is not decoration. `NSSplitViewController` overrides
    /// `addChild` to mean "add another split view item", so parenting a session
    /// controller to the window's controller silently turns every session ever
    /// shown into another column — the first run of this had a 239pt content
    /// area and an empty 792pt one beside it. Session controllers are children
    /// of this instead, where `addChild` means what it says.
    private final class Content: NSViewController {
        override func loadView() {
            let view = NSView()
            view.wantsLayer = true
            self.view = view
        }

        func show(_ controller: NSViewController) {
            for child in children where child !== controller {
                child.view.removeFromSuperview()
                child.removeFromParent()
            }
            guard controller.parent !== self else { return }
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.topAnchor.constraint(equalTo: view.topAnchor),
                controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
    }

    // MARK: - Settings

    /// One place where a settings change fans out, so the order is fixed and
    /// visible: chrome first, then each session's own terminal controller.
    ///
    /// Session controllers are per-session by construction — each owns a
    /// `TerminalController` — so a font change has to reach every one of them,
    /// not just the session on screen. A session left out would keep the old
    /// cell size and report a grid tmux disagrees with the moment it is shown.
    private func applySettings() {
        // Logged because this is the only thing that reaches into every
        // session's terminal controller after launch, and a font change there
        // moves the cell size. If the app and tmux ever disagree on a column
        // again, the first question is how many times this ran and why.
        TmuxLog.lifecycle(
            "applying settings to \(controllers.count) session controller(s) —"
                + " theme \(ChromeTheme.current.sourceName), font"
                + " \(AppSettings.fontFamily.isEmpty ? "default" : AppSettings.fontFamily)"
                + " \(Int(AppSettings.fontSize))pt"
        )
        // Only when the *setting* moved. Comparing against the rail's current
        // width instead would undo the user's own divider drag on the next
        // theme change, which is a thing a drag-resizable sidebar must not do
        // — and dragging is one of the behaviours the split view was adopted
        // for.
        if appliedSidebarWidth != AppSettings.sidebarWidth, splitViewItems.count > 1 {
            appliedSidebarWidth = AppSettings.sidebarWidth
            splitView.setPosition(AppSettings.sidebarWidth, ofDividerAt: 0)
        }
        view.window?.backgroundColor = ChromeTheme.current.background
        sidebar.applyChromeTheme()
        for controller in controllers.values { controller.applySettings() }
    }

    // MARK: - Sessions

    private func refreshSidebar() {
        discardControllersForVanishedSessions()

        // Every session's windows, not just the one on screen: any of them can
        // be opened in the rail now. The lists are already in hand — each
        // connection stays attached whether or not its session is displayed —
        // so this costs a walk, not a round trip.
        let entries = server.sessionNames.map { name -> SessionSidebarView.Entry in
            let connection = server.connection(for: name)
            return SessionSidebarView.Entry(
                name: name,
                hasActivity: connection?.hasActivity ?? false,
                windows: connection?.windows ?? [],
                activeWindowID: connection?.activeWindowID,
                // Only a session that has been shown has a controller, and
                // therefore a hidden set. One that has not cannot have hidden
                // anything, which is what the empty default says.
                hiddenIDs: controllers[name]?.hiddenWindowIDs ?? []
            )
        }

        // Whatever the app was showing may have been renamed or killed
        // elsewhere; fall back to the first session rather than a blank pane.
        if currentName == nil || !server.sessionNames.contains(currentName!) {
            if let first = server.sessionNames.first { show(sessionNamed: first) }
        }

        sidebar.update(entries: entries, selected: currentName)
    }

    /// Give up the controller of a session the server no longer has.
    ///
    /// `TmuxServer` reconciles the *connections* against `list-sessions` and is
    /// the only thing that stops one; the controllers are this object's, and
    /// nothing was reconciling them. What a left-behind one holds is not
    /// abstract: its GPU surfaces, and its panes still registered to a router
    /// whose connection has been stopped — so it keeps memory alive for a
    /// session that can never produce another byte. And because `show` looks
    /// the controller up by *name*, a new session created with the name of an
    /// old one would have been handed the stale controller, pointing at the
    /// dead connection, for as long as the app ran.
    ///
    /// A session can vanish without this app doing anything — killed from any
    /// terminal — so this runs from `refreshSidebar`, on the same reconcile the
    /// connection set is dropped by, rather than from anything the UI does.
    private func discardControllersForVanishedSessions() {
        let live = Set(server.sessionNames)
        for (name, controller) in controllers where !live.contains(name) {
            TmuxLog.lifecycle(
                "dropping the view controller for \(name) — the session is gone from the server",
                session: name
            )
            controller.releaseSurfaces()
            controller.view.removeFromSuperview()
            if controller.parent != nil { controller.removeFromParent() }
            controllers.removeValue(forKey: name)
            // Leaves the fallback below to pick a session that still exists.
            if currentName == name { currentName = nil }
        }
    }

    func show(sessionNamed name: String) {
        guard currentName != name, let connection = server.connection(for: name),
              let controller = controller(forSessionNamed: name) else { return }

        currentName = name
        content.show(controller)

        // Draw what tmux has already said, rather than waiting to be told
        // again. A controller learns its session from notifications, and the
        // ones that describe an existing session arrived when the connection
        // attached — long before there was a controller to hear them. What has
        // been masking that is the grid report this show triggers:
        // `refresh-client -C` resizes the session's windows and a resize comes
        // back as `%layout-change`. Verified on tmux 3.6a that tmux sends that
        // notification even when the size did not change — but
        // `TmuxSessionConnection` drops one whose layout text is identical,
        // correctly, because nothing changed. So a session whose windows tmux
        // will not resize renders nothing at all and gets no second chance: a
        // window put on `window-size manual` (which `resize-window` does
        // permanently), or a `window-size smallest` session with a smaller
        // client attached somewhere else.
        //
        // After `content.show`, not inside the controller's `viewDidLoad`: the
        // sync also hands first responder to the focused pane, and at
        // `viewDidLoad` the view is not in a window yet.
        controller.syncWithModel()

        connection.announceStatus()
        refreshSidebar()
    }

    func showStatus(_ status: String, detail: String) {
        sidebar.showStatus(status, detail: detail)
    }

    /// ⌃⌘1-9 — the session-level counterpart of ⌘1-9 for windows.
    func selectSession(atSlot slot: Int) {
        guard slot >= 0, slot < server.sessionNames.count else { return }
        show(sessionNamed: server.sessionNames[slot])
    }

    func selectAdjacentSession(offset: Int) {
        let names = server.sessionNames
        guard !names.isEmpty, let current = currentName,
              let index = names.firstIndex(of: current) else { return }
        show(sessionNamed: names[(index + offset + names.count) % names.count])
    }

    /// Shut the app's tmux side down, once.
    ///
    /// Two things need releasing and they have different owners. The surfaces
    /// belong to the session controllers, which built them; the connections
    /// belong to `TmuxServer`, which created every one of them and is the only
    /// thing that stops one. Session controllers used to stop their connection
    /// as well, so every session that had ever been displayed got
    /// `detach-client` and SIGTERM twice about a millisecond apart — visible in
    /// the log as two DESTRUCTIVE lines per session. Nothing was ever observed
    /// to break, but a teardown that runs twice is a teardown whose order
    /// nobody can reason about.
    func stop() {
        for controller in controllers.values { controller.releaseSurfaces() }
        server.stop()
    }
}

#if DEBUG

    extension MainViewController {
        var debugShownSessionName: String? { currentName }

        /// Names this controller is holding a `SessionViewController` for.
        ///
        /// The one thing `debugSessionReports()` cannot show: it walks tmux's
        /// current session list, so a controller whose session is gone is
        /// absent from that report rather than flagged in it.
        var debugSessionControllerNames: [String] { controllers.keys.sorted() }

        /// A session's controller by name, on screen or not. The off-screen
        /// ones are the interesting half: a font change reaches every one of
        /// them, and their views have no window.
        func debugSessionController(named name: String) -> SessionViewController? {
            controllers[name]
        }

        /// Every session on the server, whether or not it has ever been shown.
        /// A session with no controller still has a live connection, and its
        /// window list is exactly the thing worth diffing against tmux.
        func debugSessionReports() -> [DebugInspector.SessionReport] {
            server.sessionNames.compactMap { name in
                guard let connection = server.connection(for: name) else { return nil }
                if let controller = controllers[name] {
                    return controller.debugReport(isShown: name == currentName)
                }
                return DebugInspector.SessionReport(connection: connection)
            }
        }
    }

#endif
