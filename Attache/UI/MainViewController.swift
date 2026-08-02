//
//  MainViewController.swift
//  Attache
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
    private lazy var content = Content(backdrop: contentBackdrop)
    /// Keyed by tmux's `$N`, like `TmuxServer.connections`. Keyed by name, a
    /// rename read as "that session is gone" and threw the controller away —
    /// GPU surfaces, primed scrollback and the hidden-window set with it.
    private var models = [String: SessionModel]()
    /// The route B content halves, one per session, made only while
    /// `tmuxDrawsItself` is on. Keyed the same way and for the same reason.
    ///
    /// Both maps can hold an entry for one session, and that is the design: the
    /// `SessionViewController` keeps the model the rail reads and draws nothing
    /// (`stopRendering`), while this one is what the user looks at. Splitting it
    /// that way is what lets every rail action, every shortcut and the hidden
    /// set behave identically under both — they are tmux commands, and tmux does
    /// not know which of the two is painting.
    private var embedded = [String: EmbeddedSessionViewController]()
    private var currentSessionID: String?
    private var sidebarItem: NSSplitViewItem?

    /// The right-hand rail and the thing that feeds it. Both exist whether or
    /// not the setting is on — the split item is added once and collapsed,
    /// because adding and removing a split view item at runtime re-runs the
    /// whole divider layout and loses the width the person dragged to.
    private let conversation = ConversationSidebarView(frame: .zero)
    private let conversations = ConversationController()
    private var conversationItem: NSSplitViewItem?
    private var appliedConversationWidth: CGFloat?
    private var hasPlacedConversation = false

    /// The repositories behind the rail's rows.
    ///
    /// Owned here rather than by a session controller because it is keyed by
    /// repository, not by session: four windows across three sessions in one
    /// checkout are one repository and must be one `git status`. Its work list
    /// is set from `refreshSidebar`, which is the only place that knows what is
    /// actually on screen.
    private let gitStatus = GitStatusService()
    /// The rail width this controller last placed the divider at. Not the
    /// rail's current width, which the user is free to drag.
    private var appliedSidebarWidth: CGFloat?
    private var settingsObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?

    var onStatusChange: ((String) -> Void)?

    init(server: TmuxServer) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// The session on screen, as state and commands rather than as a view.
    var currentSession: SessionModel? {
        guard let currentSessionID else { return nil }
        return models[currentSessionID]
    }

    /// The content half the user is actually looking at, for the shortcuts that
    /// address "the pane with the keyboard". `currentSession` answers with the
    /// half that holds the model, which under `tmuxDrawsItself` is not the one
    /// on screen — the difference is why ⌘Z stopped working after the switch.
    var currentEmbedded: EmbeddedSessionViewController? {
        guard let currentSessionID else { return nil }
        return embedded[currentSessionID]
    }

    /// Run a Quick Action against the session on screen.
    ///
    /// The connection rather than `currentSession`: that one is a *view*
    /// controller, and with `tmuxDrawsItself` on it is not the half being
    /// looked at. What a session-level command addresses is the session.
    func run(quickAction: QuickAction) {
        guard let currentSessionID, let connection = server.connection(id: currentSessionID) else {
            showStatus("No session", detail: "Quick Actions need a session on screen")
            return
        }
        connection.runUserCommand(quickAction.command)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        removeDividerLine()
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

        observeReturningToTheApp()
        observeWindowVisibility()
        gitStatus.applySettings()
    }

    /// Stop reading repositories while nobody can see the answer.
    ///
    /// A `git status` is 82ms of process spawn and the rail refreshes on a
    /// timer; behind another window, or on another Space, that is a laptop
    /// running `git` all day to draw something nobody is looking at. Occlusion
    /// rather than key window: the app losing focus while its window is still
    /// visible beside a browser is exactly when a row's Git state is worth
    /// keeping current.
    private func observeWindowVisibility() {
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                guard let self, window === self.view.window else { return }
                let hidden = !window.occlusionState.contains(.visible)
                self.gitStatus.setPaused(hidden)
                // The pane capture the screen strategy runs is the same kind of
                // work for the same nobody.
                for id in self.server.sessionIDs {
                    self.server.connection(id: id)?.setPaused(hidden)
                }
            }
        }
    }

    /// The window's blur has to wait for the window.
    ///
    /// `applyBackdropSettings` runs from `viewDidLoad`, where `view.window` is
    /// still nil — the blur is set on a window by number, so at that point
    /// there is nothing to set it on. Every later route (a settings change, a
    /// style switch) has a window by definition; this is the first paint.
    override func viewDidAppear() {
        super.viewDidAppear()
        applyBackdropBlur(radius: WindowGlass.resolved().blurRadius)
        TmuxLog.lifecycle(
            "window-server blur \(WindowServerBlur.isAvailable ? "available" : "UNAVAILABLE")"
                + ", radius \(Int(WindowGlass.resolved().blurRadius))"
        )
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        for observer in returnObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private var returnObservers = [NSObjectProtocol]()

    /// Take the window size back whenever the user comes back to this app.
    ///
    /// This is the one thing tmux cannot tell the app, and the reason the size
    /// mechanism was ineffective in the case it was written for. tmux's default
    /// `window-size latest` sizes a session's windows to whichever client had
    /// the most recent activity, so attaching an ordinary terminal to the same
    /// session and typing in it hands that terminal the size — and the app then
    /// draws tmux's smaller layout inside its own larger window, leaving the
    /// dead space below and to the right of the panes that this presents as.
    ///
    /// A real terminal recovers from that by *being* used: keystrokes from an
    /// attached client are activity, so switching to it makes it the latest and
    /// tmux reflows. This app never gets there. Its keystrokes go out as
    /// `send-keys` commands rather than as client input, and — the part that
    /// made the existing fix inert — `reclaimWindowSizeIfTaken` was reachable
    /// only from `syncWithModel`, which runs on tmux's structural
    /// notifications. Coming back to a window produces none: measured, the app
    /// regaining focus generates nothing at all on the control stream. So the
    /// only moment at which the app could act was a moment it was never told
    /// about.
    ///
    /// Both notifications, because they answer different questions and either
    /// one alone leaves a real gap. `didBecomeActive` fires when the app is
    /// brought forward from another application — the case in the report — but
    /// not when the user moves between two windows of this app. `didBecomeKey`
    /// fires for that, and also when the app is activated by clicking its
    /// window. Asking twice costs nothing: the size is compared against tmux's
    /// before anything is sent, so a redundant call returns without a command.
    private func observeReturningToTheApp() {
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            returnObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.setNeedsWindowSizeReclaim()
            })
        }
    }

    private var reclaimScheduled = false

    /// Coalesce to one reclaim per return, and decide from the state that has
    /// settled rather than from the notification.
    ///
    /// One click on the app's icon delivers *both* notifications, and acting on
    /// each sent two `switch-client` + `refresh-client` pairs for a single
    /// user action — observed in the log, two attempts 13ms apart. Neither
    /// notification is the wrong one to listen to, so the fix is to treat both
    /// as the same request rather than to drop one.
    ///
    /// Deferring also fixes what filtering on the notification could not.
    /// `didBecomeActive` carries no window, so a settings window in front would
    /// still have asked for a reclaim of a terminal window the user never
    /// returned to — resizing a session shared with another terminal for
    /// nobody's benefit. And filtering `didBecomeKey` on the window identity is
    /// unreliable at the moment it arrives, because key status is still moving.
    /// By the next turn it has stopped, so `isKeyWindow` can simply be asked.
    private func setNeedsWindowSizeReclaim() {
        guard !reclaimScheduled else { return }
        reclaimScheduled = true
        Task { @MainActor [weak self] in
            self?.reclaimScheduled = false
            self?.reclaimWindowSizeForShownSession()
        }
    }

    /// Only the session on screen, only once it really has a window, and only
    /// when that window is the one the user is looking at.
    ///
    /// A session the user is not looking at has no business arguing about a size
    /// that describes a window showing something else — the same reason
    /// `syncWithModel` guards its own call this way. The key-window test is the
    /// stronger version of that for this trigger: the terminal window being
    /// *attached* is not the same as it being the window that just came forward.
    private func reclaimWindowSizeForShownSession() {
        guard let controller = currentSession, view.window?.isKeyWindow == true else { return }
        controller.connection.reclaimWindowSizeIfTaken(isUserReturning: true)
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
        // A repository changed under a row. Goes through the same rebuild every
        // tmux notification uses rather than reaching into a row, so the rail
        // has exactly one way to be redrawn — and so the rebuild's own guards
        // still hold: it refuses while a rename field is open or a drag is in
        // flight, and a `git status` finishing must not be the one thing that
        // pulls a row out from under the pointer.
        gitStatus.onChange = { [weak self] in self?.refreshSidebar() }

        sidebar.onSelect = { [weak self] id in self?.show(sessionID: id) }
        sidebar.onNew = { [weak self] in self?.server.newSession() }
        sidebar.onRename = { [weak self] id, new in
            self?.server.connection(id: id)?.renameSession(to: new)
        }

        sidebar.onNewWindow = { [weak self] id in
            guard let self, let connection = server.connection(id: id) else { return }
            cancelStartupTargeting()   // creating a window is a choice too, and
            // it does not necessarily change session
            connection.newWindow()
            if currentSessionID != id { show(sessionID: id) }
        }
        // Clicking a window in a session that is not the one on screen means
        // "show me that window", so it switches first. The rail can list any
        // session's windows now, which makes this reachable in a way it was not
        // when only the current session had rows.
        sidebar.onSelectWindow = { [weak self] session, id in
            guard let self else { return }
            show(sessionID: session)
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
            // Same reason as ⌘W: hiding a row can move the selection, and it
            // is a deliberate act either way.
            self?.userIsChoosingWindow()
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
        guard let source = server.connection(id: from),
              server.connection(id: to) != nil else { return }

        // tmux's window list, not the rail's rows: a session with one visible
        // window and two hidden ones survives the move, and counting rows would
        // put a warning in front of the user that is simply not true.
        let emptied = source.windows.count == 1 && source.windows.first?.id == id

        // Whether this is the window on screen, decided before anything is
        // sent. If it is, the app goes with it — see `send`.
        let following = from == currentSessionID && id == source.activeWindowID

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
                guard let source = server.connection(id: from), source.holds(windowID: id) else {
                    TmuxLog.lifecycle(
                        "not moving \(id) — it left \(describe(from)) while the confirmation"
                            + " was open",
                        session: describe(from)
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
        guard let destination = server.connection(id: to) else { return }
        TmuxLog.lifecycle(
            "moving window \(id) from \(describe(from)) into \(describe(to))"
                + (emptying ? " — \(describe(from)) has no other window and tmux will destroy it" : "")
                + (following ? " — it is the window on screen, so the app follows it" : ""),
            session: describe(from)
        )

        // Nothing follows a move that was never issued. A destination whose
        // connection has not yet learned its session id refuses every
        // session-relative command, and switching the app to it anyway would
        // leave the window where it was while the screen moved on — the app
        // showing something tmux was never told to do.
        guard destination.moveWindow(id: id, before: anchor) else {
            TmuxLog.lifecycle(
                "the move was not sent — \(describe(to)) has no free index above its"
                    + " windows; staying put",
                session: describe(to)
            )
            return
        }

        guard following else { return }
        // Down the destination's own pipe, after its move, so tmux runs them in
        // that order. Selecting before the window has arrived would name a
        // window that is not in this session yet.
        destination.selectWindow(id: id)
        show(sessionID: to)
    }

    /// Asked before a move that will take a session with it. Same shape as the
    /// kill confirmation, deliberately: both are "there is no undo for this".
    private func confirmMoveEmptying(session: String, into destination: String) -> Bool {
        // Names, because this is the one place a session is described to a
        // human. Everything around it is ids.
        let session = describe(session)
        let destination = describe(destination)
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
    /// The lookup can still miss, and that is what the log line is for: a
    /// session killed from another terminal between the rail drawing its rows
    /// and the user clicking one. It can no longer miss because of a *rename* —
    /// `$17` is what everything here is keyed by, and tmux never reuses one.
    private func inSession(_ id: String, _ action: (SessionModel) -> Void) {
        guard let controller = model(forSessionID: id) else {
            TmuxLog.lifecycle(
                "dropping a window action aimed at \(id) — the server has no connection"
                    + " for it, so the session is gone",
                session: id
            )
            return
        }
        action(controller)
    }

    /// This session's controller, made on demand. One per session for the life
    /// of the session, because it holds the pane surfaces and the hidden set.
    private func model(forSessionID id: String) -> SessionModel? {
        if let existing = models[id] { return existing }
        guard let connection = server.connection(id: id) else { return nil }

        let controller = SessionModel(connection: connection)
        controller.onStatusChange = { [weak self] status in self?.onStatusChange?(status) }
        // Hiding and restoring never reach tmux, so `server.onChange` — which is
        // fed by connection notifications — cannot see them. Without this the
        // row a user just hid would stay in the rail until tmux happened to say
        // something else.
        controller.onWindowsChanged = { [weak self] in self?.refreshSidebar() }
        models[id] = controller
        return controller
    }

    /// This session's route B content half, made on demand.
    ///
    /// One `tmux attach` child process per session, kept for the life of the
    /// session so switching back is instant — tmux holds the screen, so there
    /// is nothing to replay.
    private func embeddedController(forSessionID id: String) -> EmbeddedSessionViewController? {
        if let existing = embedded[id] { return existing }
        guard let connection = server.connection(id: id) else { return nil }
        guard let model = model(forSessionID: id) else { return nil }
        let controller = EmbeddedSessionViewController(model: model, tmuxPath: server.tmuxPath)
        embedded[id] = controller
        return controller
    }

    /// A session id rendered for a human — `$3 (agents)`. Used in log lines and
    /// confirmation text, and nowhere that decides anything.
    private func describe(_ id: String) -> String {
        guard let name = server.name(ofSession: id) else { return id }
        return "\(id) (\(name))"
    }

    // MARK: - Chrome

    private func installSidebar() {
        // A plain item, and the reasoning has *changed* — this is not the
        // mistake CLAUDE.md records, it is the fix for what that mistake had
        // been standing in front of.
        //
        // `sidebarWithViewController:` draws the rail as an inset rounded panel,
        // and that panel was correctly the design: the traffic lights belong
        // inside it, and deleting it twice to get them there was the error. But
        // on macOS 26 the panel arrives with the system's Liquid Glass
        // treatment — a bright refractive rim around the inset margin — and that
        // rim is a *third* kind of glass beside the rail's tint and the panes'.
        // It cannot be tinted, covered or switched off, because the margin it
        // lives in belongs to AppKit and to no view this app owns. Confirmed by
        // eye against a photo wallpaper: panes frosted, panel frosted and
        // deeper, and the ring around the panel something else entirely.
        //
        // Edge to edge, the rail is a view this app draws, both halves carry the
        // same material, and the whole difference between them is one tint. The
        // window already has `.fullSizeContentView`, so the content still runs
        // to the top of the window and the traffic lights float over the rail —
        // which is where the panel used to put them, and where the terminal this
        // was dialled in against puts them too.
        applyBackdropSettings()

        let sidebarItem = NSSplitViewItem(
            viewController: Hosting(view: sidebar, backdrop: railBackdrop)
        )
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

        // The conversation rail. Same material as the session rail — the whole
        // window is one sheet of glass and a third treatment on the right would
        // read as a separate window pasted on.
        let conversationItem = NSSplitViewItem(
            viewController: Hosting(view: conversation, backdrop: railBackdrop)
        )
        conversationItem.minimumThickness = AppSettings.conversationWidthRange.lowerBound
        conversationItem.maximumThickness = AppSettings.conversationWidthRange.upperBound
        // **Above the content half's 250, and this is what makes the width
        // stick.** Holding priority decides who absorbs a window resize, and
        // with all three items at the default the split view gave every new
        // point to the terminal *and* squeezed this rail down to its minimum on
        // the way. Measured: placed correctly at 400pt while the window was
        // still 700pt wide, then 280pt — the minimum — the moment the window
        // reached 1920. The terminal is the half that should grow with the
        // window; a reading column has a width that is right and stays there.
        conversationItem.holdingPriority = NSLayoutConstraint.Priority(260)
        // Collapsible, unlike the session rail, and the difference is that this
        // one has a way back: a menu item and a preference, neither of which
        // the session list has.
        conversationItem.canCollapse = true
        conversationItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings
        self.conversationItem = conversationItem
        addSplitViewItem(conversationItem)

        conversations.onChange = { [weak self] in self?.refreshConversation() }

        // No autosave name on purpose: the width is a setting, and an autosaved
        // divider position would silently outrank it after the first drag.
        appliedSidebarWidth = AppSettings.sidebarWidth
        splitView.setPosition(AppSettings.sidebarWidth, ofDividerAt: 0)
        applyConversationVisibility()
    }

    /// Show or hide the conversation rail, and put it back at the width the
    /// setting names.
    ///
    /// **The width has to be applied against a laid-out window, and that is not
    /// a detail.** Divider 1 takes a position measured from the window's left
    /// edge, so it is `width(window) - width(rail)` — and at `installSidebar`
    /// time the window has not been sized yet, so that subtraction runs against
    /// a placeholder and lands the divider somewhere arbitrary. The first
    /// build did exactly that and shipped a 400pt setting as a ~280pt rail.
    /// `viewDidLayout` re-runs it once the width is real.
    private func applyConversationVisibility() {
        guard let conversationItem else { return }
        let wanted = AppSettings.showsConversation
        conversationItem.isCollapsed = !wanted
        guard wanted, view.bounds.width > 200 else { return }

        let width = AppSettings.conversationWidth
        appliedConversationWidth = width
        splitView.setPosition(view.bounds.width - width, ofDividerAt: 1)

        // **Believe the result, not the request.** `setPosition` is a request
        // the split view is free to clamp — against the other items' minimum
        // thicknesses, and against a window that has not reached its final
        // size. Marking the placement done regardless is what shipped a 400pt
        // setting as a 281pt rail: 281 is this item's own minimum, so the
        // request had been clamped and nothing noticed. Left unset, the next
        // layout tries again.
        hasPlacedConversation = abs(conversation.bounds.width - width) < 2
        // Logged because the answer disagreed with the request twice, for two
        // different reasons, and neither showed up anywhere else. If the rail
        // is ever the wrong width again, this line says whether the request was
        // clamped or honoured and how wide the window was at the time.
        TmuxLog.lifecycle(
            "conversation rail: asked for \(Int(width))pt in a"
                + " \(Int(view.bounds.width))pt split view, got"
                + " \(Int(conversation.bounds.width))pt"
                + " — \(hasPlacedConversation ? "placed" : "will retry")"
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Until it lands, then never again — re-running it on every layout
        // would undo the person's own divider drag on each window resize, the
        // mistake `appliedSidebarWidth` exists to avoid on the other side.
        guard !hasPlacedConversation, AppSettings.showsConversation else { return }
        applyConversationVisibility()
    }

    /// Put both halves on the same material, or on none.
    ///
    /// Both, always, and that is the point: two halves on two different system
    /// materials cannot be made to agree by tinting them, because each material
    /// decides for itself how much of the desktop it lets past.
    /// Take the line out from between the two halves.
    ///
    /// By re-classing the split view `NSSplitViewController` already built,
    /// not by supplying one — see `SeamlessSplitView` for why that second route
    /// leaves the window blank. Guarded on the class actually being a plain
    /// `NSSplitView`: if a future AppKit hands over a private subclass,
    /// re-classing would throw that subclass's behaviour away, and a visible
    /// divider is a far better outcome than a broken one.
    private func removeDividerLine() {
        guard type(of: splitView) == NSSplitView.self else {
            TmuxLog.lifecycle(
                "leaving the split view divider alone — it is a"
                    + " \(type(of: splitView)), not a plain NSSplitView"
            )
            return
        }
        object_setClass(splitView, SeamlessSplitView.self)
        // Thin rather than the pane-splitter default. `SeamlessSplitView`
        // overrides the thickness to zero regardless, so this no longer decides
        // the width of anything; it is kept because the style is also what
        // AppKit consults for the divider's other drawing, and asking for the
        // heavy pane-splitter look while claiming zero width is a contradiction
        // to leave lying around.
        splitView.dividerStyle = .thin
    }

    /// Give the zero-width divider a drag target.
    ///
    /// The strip is gone — that is what removes the two-pixel line between the
    /// halves — and a divider with no width has no place to grab. This is the
    /// documented way out: the rect AppKit *draws* stays empty while the rect it
    /// *hit-tests and sets the resize cursor over* is widened around it.
    ///
    /// 6pt straddling the boundary, not more: the panes begin immediately to
    /// the right of it, and every point claimed here is a point where a click
    /// meant for the first column of a terminal starts a resize instead.
    /// `super` is called on every path, and that is the point of the shape.
    ///
    /// `NSSplitViewController` marks this `NS_REQUIRES_SUPER`, and Swift checks
    /// only that the body *mentions* `super` somewhere — so a call reachable
    /// only from an orientation branch satisfies the compiler while never once
    /// running. This split view is vertical (measured: that is
    /// `NSSplitViewController`'s default and nothing here ever sets it), so
    /// that branch would have been dead code guarding a contract it never
    /// honoured. Found by review, not by running it.
    ///
    /// Measured 2026-07-28: `super` is a pass-through today — it returns the
    /// proposed rect untouched, and `additionalEffectiveRectOfDividerAt` is
    /// zero because this window's toolbar carries no items. Which is exactly
    /// why calling it costs nothing now, and why not calling it would stay
    /// invisible right up until a toolbar item or a tracking separator makes
    /// AppKit want a say.
    override func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        let base = super.splitView(
            splitView, effectiveRect: proposedEffectiveRect,
            forDrawnRect: drawnRect, ofDividerAt: dividerIndex
        )
        guard splitView.isVertical else { return base }
        // Union rather than replace, so whatever `super` starts contributing
        // later is added to the grab area instead of being quietly dropped.
        return base.union(drawnRect.insetBy(dx: -3, dy: 0))
    }

    private func applyBackdropSettings() {
        let glass = WindowGlass.resolved()
        applyBackdropBlur(radius: glass.blurRadius)
        railBackdrop.apply(glass.railEffect)
        contentBackdrop.apply(glass.paneEffect)
    }

    /// Blur the desktop behind the whole window, at a radius this app chooses.
    ///
    /// Through the window server rather than through a layer filter — see
    /// `WindowServerBlur` for why a `CALayer.backgroundFilters` blur cannot do
    /// this at all once the panes are Metal.
    ///
    /// Sent even when the radius is 0, because the radius lives on the window
    /// in the window server: a style switched away from would otherwise keep
    /// blurring for the rest of the session.
    private func applyBackdropBlur(radius: CGFloat) {
        guard let window = view.window else { return }
        WindowServerBlur.apply(radius: radius, to: window)
    }

    /// Wraps a view the app already builds and owns in the view controller a
    /// split view item requires.
    private final class Hosting: NSViewController {
        private let hosted: NSView
        private let backdrop: GlassBackdropView

        init(view: NSView, backdrop: GlassBackdropView) {
            hosted = view
            self.backdrop = backdrop
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not supported") }

        /// The rail is the panel's content; the panel and its material belong
        /// to the sidebar split view item. Supplying a backdrop here was an
        /// attempt to fill the column edge to edge, which is exactly what the
        /// inset panel is not supposed to do.
        override func loadView() {
            let container = NSView()
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            hosted.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(backdrop)
            container.addSubview(hosted)
            for child in [backdrop, hosted] {
                NSLayoutConstraint.activate([
                    child.topAnchor.constraint(equalTo: container.topAnchor),
                    child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
            }
            view = container
        }
    }

    /// The material the panes are drawn over.
    ///
    /// The sidebar half gets one of these free — `NSSplitViewItem`'s sidebar
    /// behaviour supplies it, and that is where the rail's translucency has
    /// always come from. The content half gets nothing, so it had to be added,
    /// and adding it is most of what makes the window read as one sheet of
    /// glass rather than as a frosted rail glued to a solid terminal.
    ///
    /// `.underWindowBackground` rather than `.sidebar`: the two are different
    /// materials, and using the sidebar's on both halves makes the divider
    /// disappear entirely. The rail is supposed to read a little deeper — see
    /// `AppSettings.railExtraTint` — and starting from the same material is
    /// what leaves that difference to the tint rather than to two system
    /// materials that shift independently across appearances.
    private let contentBackdrop = GlassBackdropView()
    /// The rail's own material, over AppKit's.
    ///
    /// `NSSplitViewItem`'s sidebar behaviour installs an `NSVisualEffectView`
    /// with the `.sidebar` material and there is no supported way to ask it not
    /// to. So this one goes *inside* the rail, on top of it. That works because
    /// `.behindWindow` blending samples what is behind the **window**, not what
    /// is behind the view — so this one reaches the desktop directly and the
    /// system's sheet underneath contributes nothing.
    ///
    /// Without it the two halves cannot match: the rail was stuck on
    /// AppKit's material while the panes were on whatever this app chose, and
    /// the visible result was a nearly opaque sidebar panel beside a nearly
    /// opaque terminal, with only the inset margin between them — the window's
    /// own background — actually letting anything through.
    private let railBackdrop = GlassBackdropView()

    /// The right-hand half, and the parent of whichever session is on screen.
    ///
    /// Its existence is not decoration. `NSSplitViewController` overrides
    /// `addChild` to mean "add another split view item", so parenting a session
    /// controller to the window's controller silently turns every session ever
    /// shown into another column — the first run of this had a 239pt content
    /// area and an empty 792pt one beside it. Session controllers are children
    /// of this instead, where `addChild` means what it says.
    private final class Content: NSViewController {
        /// Installed by `MainViewController`, behind every session's view.
        let backdrop: GlassBackdropView

        init(backdrop: GlassBackdropView) {
            self.backdrop = backdrop
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not supported") }

        override func loadView() {
            let view = NSView()
            view.wantsLayer = true
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(backdrop)
            NSLayoutConstraint.activate([
                backdrop.topAnchor.constraint(equalTo: view.topAnchor),
                backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
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
            "applying settings to \(embedded.count) session controller(s) —"
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
        view.window?.backgroundColor = WindowGlass.resolved().paneFill
        applyBackdropSettings()
        // Before the rail is rebuilt, so a fetch that was just switched off
        // does not get one more turn on the way past.
        gitStatus.applySettings()
        // Each connection decides for itself whether to start capturing panes.
        for id in server.sessionIDs { server.connection(id: id)?.applyAgentStateSource() }
        sidebar.applyChromeTheme()
        conversation.applyChromeTheme()
        // Both the switch and the width, and the width only when the *setting*
        // moved — same rule as the session rail, so a theme change does not
        // undo a divider the person dragged.
        if conversationItem?.isCollapsed == AppSettings.showsConversation
            || (AppSettings.showsConversation && appliedConversationWidth != AppSettings.conversationWidth)
        {
            hasPlacedConversation = false
            applyConversationVisibility()
        }
        for controller in embedded.values { controller.applySettings() }
        for controller in embedded.values { controller.applyChromeTheme() }
        // The row height itself is a setting now, so a change to it is a
        // relayout and not only a repaint.
        refreshSidebar()
    }

    // MARK: - Sessions

    private func refreshSidebar() {
        discardControllersForVanishedSessions()

        // Every session's windows, not just the one on screen: any of them can
        // be opened in the rail now. The lists are already in hand — each
        // connection stays attached whether or not its session is displayed —
        // so this costs a walk, not a round trip.
        // Collected while the entries are built and handed over in one call, so
        // the service's work list is exactly what the rail is drawing — a
        // session whose list is collapsed costs nothing, and a `git status` is
        // 82ms of process spawn that nobody would see the result of.
        var visiblePaths = Set<String>()

        let entries = server.sessionIDs.compactMap { id -> SessionSidebarView.Entry? in
            guard let connection = server.connection(id: id) else { return nil }
            let hidden = models[id]?.hiddenWindowIDs ?? []
            var decorations = [String: WindowDecoration]()
            for window in connection.windows where !hidden.contains(window.id) {
                var decoration = WindowDecoration()
                decoration.path = connection.pathByWindow[window.id]
                if AppSettings.sidebarShowsAgent {
                    decoration.agent = connection.agentBadge(forWindow: window.id)
                    // Gated on the badge as well as on its own setting: the
                    // numbers belong to the agent the dot is about, so a rail
                    // with the agent column switched off has no place to put
                    // them either.
                    if AppSettings.sidebarShowsAgentStats {
                        decoration.stats = connection.agentStats(forWindow: window.id)
                    }
                }
                if AppSettings.sidebarShowsGit, let path = decoration.path {
                    visiblePaths.insert(path)
                    decoration.git = gitStatus.summary(forPath: path)
                    decoration.isNotARepository = gitStatus.isKnownNotARepository(path: path)
                    decoration.fetchIsLive = gitStatus.fetchIsLive(forPath: path)
                }
                if !decoration.isEmpty || decoration.path != nil {
                    decorations[window.id] = decoration
                }
            }
            return SessionSidebarView.Entry(
                id: id,
                // Read from the connection, which is the only thing that holds
                // a session's current name: `%session-renamed` reaches it
                // directly, so the rail follows a rename without a relist.
                name: connection.sessionName,
                hasActivity: connection.hasActivity,
                windows: connection.windows,
                activeWindowID: connection.activeWindowID,
                // Only a session that has been shown has a controller, and
                // therefore a hidden set. One that has not cannot have hidden
                // anything, which is what the empty default says.
                hiddenIDs: hidden,
                decorations: decorations
            )
        }
        gitStatus.setVisiblePaths(visiblePaths)

        // Whatever the app was showing may have been killed elsewhere; fall
        // back to the first session rather than a blank pane. A rename no
        // longer reaches here at all — the id is unchanged, so nothing about
        // the session the app is showing has moved.
        if currentSessionID == nil || !server.sessionIDs.contains(currentSessionID!) {
            if let first = server.sessionIDs.first { showWithoutCancelling(sessionID: first) }
        }
        applyStartupTargetIfNeeded()

        sidebar.update(entries: entries, selected: currentSessionID)

        // Across every session, not the one on screen. Rate limits belong to
        // the account, so the answer must not change when the rail is pointed
        // at a different session — and the session being looked at is often
        // the one with no agent in it.
        sidebar.showUsage(
            server.sessionIDs
                .compactMap { server.connection(id: $0)?.accountUsage }
                .reduce(nil) { AccountUsage.fresher($0, $1) }
        )

        refreshConversation()
    }

    /// Point the conversation rail at the window on screen.
    ///
    /// Runs on the same reconcile as the session rail, which is what makes the
    /// two agree: they read the same connection, the same active window and —
    /// through `conversationEvidence(forWindow:)` — the same pane. It is called
    /// on every tmux notification, so the no-change path has to be cheap, and
    /// it is: `ConversationController.follow` compares two locators.
    /// Open on the session — and optionally the window — the person named in
    /// their settings.
    ///
    /// **The session and the window settle separately, and that is the whole
    /// shape of this.** They become knowable at different times: the session
    /// list arrives first, and a connection's *window* list is a later
    /// notification on the same control-mode stream. Treating both as one step
    /// meant that finding the session immediately concluded the window was
    /// absent — `connection.windows` is still empty at that moment — so a
    /// configured window was permanently ignored even when it existed. Found
    /// by review 2026-08-02.
    ///
    /// Both stages retry across refreshes and both give up after
    /// `startupAttemptLimit`, so a name matching nothing does not keep
    /// searching for the life of the app.
    private func applyStartupTargetIfNeeded() {
        guard !hasSettledStartupSession || !hasSettledStartupWindow else { return }
        guard !server.sessionIDs.isEmpty else { return }
        // **A counter each, because the phases run one after the other.** A
        // single shared count let the session phase spend the whole budget:
        // resolve on attempt 19 and the window phase is already out of
        // patience on its first look, so the window list arriving one refresh
        // later is ignored — the exact failure the two-phase split was meant to
        // remove. Found by review 2026-08-02.
        if !hasSettledStartupSession { startupSessionAttempts += 1 }
        else { startupWindowAttempts += 1 }
        let outOfPatience = (hasSettledStartupSession ? startupWindowAttempts : startupSessionAttempts)
            >= Self.startupAttemptLimit

        if !hasSettledStartupSession {
            let wanted = AppSettings.startupSession
            guard !wanted.isEmpty else {
                hasSettledStartupSession = true
                hasSettledStartupWindow = true
                return
            }
            let sessions = server.sessionIDs.compactMap { id -> (id: String, name: String)? in
                guard let connection = server.connection(id: id) else { return nil }
                return (id, connection.sessionName)
            }
            if let sessionID = StartupTarget.id(matching: wanted, in: sessions) {
                showWithoutCancelling(sessionID: sessionID)
                // **Settle on the result, not on having asked.** `show` returns
                // early — silently — when the session's controllers do not
                // exist yet, and on the first refresh after launch they
                // routinely do not. Marking this done before checking meant one
                // failed attempt disabled the preference for the whole session,
                // and the app sat on whatever session happened to be first
                // while the log said it had matched. Same shape as the window
                // stage below: asking is not the same as arriving.
                guard currentSessionID == sessionID else {
                    if outOfPatience {
                        hasSettledStartupSession = true
                        hasSettledStartupWindow = true
                        TmuxLog.lifecycle("startup session: found it, but it never became showable")
                    }
                    return
                }
                hasSettledStartupSession = true
                startupSessionID = sessionID
            } else if outOfPatience {
                hasSettledStartupSession = true
                hasSettledStartupWindow = true
                logStartupMiss("session", StartupTarget.miss(matching: wanted, in: sessions))
            }
            return
        }

        guard !hasSettledStartupWindow else { return }
        let wanted = AppSettings.startupWindow
        guard !wanted.isEmpty,
              let sessionID = startupSessionID,
              let connection = server.connection(id: sessionID)
        else {
            hasSettledStartupWindow = true
            return
        }
        // **An empty window list means "not yet", not "no such window".** This
        // is the distinction the first version collapsed.
        guard !connection.windows.isEmpty else {
            if outOfPatience {
                hasSettledStartupWindow = true
                TmuxLog.lifecycle("startup window: that session never reported any windows")
            }
            return
        }

        hasSettledStartupWindow = true
        let windows = connection.windows.map { (id: $0.id, name: $0.name) }
        if let windowID = StartupTarget.id(matching: wanted, in: windows) {
            // The one part of this that changes tmux rather than only the app.
            inSession(sessionID) { $0.selectWindow(id: windowID) }
        } else {
            logStartupMiss("window", StartupTarget.miss(matching: wanted, in: windows))
        }
    }

    /// Say *why* it missed. A typo and a name shared by four windows need
    /// different fixes from the person, and one "not found" cannot tell them
    /// apart. The name itself is not logged — it is the person's own text.
    private func logStartupMiss(_ what: String, _ miss: StartupTarget.Miss) {
        switch miss {
        case .noMatch:
            TmuxLog.lifecycle("startup \(what): no match — staying on the default")
        case let .ambiguous(count):
            TmuxLog.lifecycle(
                "startup \(what): \(count) of them share that name, so it names none of"
                    + " them — staying on the default"
            )
        }
    }

    /// Stop trying to place the startup target.
    ///
    /// Called from every path where the person picks a session themselves. The
    /// first version documented this behaviour and did not implement it, so a
    /// session created or renamed after launch could still yank them away from
    /// the row they had just clicked. Found by review 2026-08-02.
    /// The person is choosing a window themselves.
    ///
    /// The window shortcuts reach `SessionModel` directly rather than coming
    /// through this controller, so there is no `show` for them to pass
    /// through. Without this, ⌘1-9 during the gap between the session and
    /// window phases picks a window that `startup_window` then replaces a
    /// moment later.
    ///
    /// **Hiding counts, and reasoning that it does not was wrong.** It looks
    /// like the opposite of picking a window, but `SessionModel.hideWindow`
    /// sends `select-window` for the next visible row — so hiding the active
    /// window moves the selection like any other choice, and leaving it out let
    /// a pending `startup_window` select the hidden window straight back and
    /// the following sync un-hide it. Caught by review 2026-08-02 after I had
    /// argued the other way.
    func userIsChoosingWindow() { cancelStartupTargeting() }

    private func cancelStartupTargeting() {
        hasSettledStartupSession = true
        hasSettledStartupWindow = true
    }

    private var hasSettledStartupSession = false
    private var hasSettledStartupWindow = false
    private var startupSessionID: String?
    private var startupSessionAttempts = 0
    private var startupWindowAttempts = 0
    private static let startupAttemptLimit = 20

    private func refreshConversation() {
        guard AppSettings.showsConversation else { return }

        let connection = currentSessionID.flatMap { server.connection(id: $0) }
        let windowID = connection?.activeWindowID
        let evidence = (connection != nil && windowID != nil)
            ? connection!.conversationEvidence(forWindow: windowID!)
            : nil
        conversations.follow(evidence)

        let window = windowID.flatMap { id in connection?.windows.first { $0.id == id } }
        let stats = windowID.flatMap { connection?.agentStats(forWindow: $0) }
        conversation.show(
            conversation: conversations.conversation,
            header: ConversationSidebarView.Header(
                windowName: window.map { "\($0.index): \($0.name)" },
                model: stats?.shortModel,
                cost: stats?.costText,
                contextPercent: stats?.contextPercent
            ),
            // Three different nothings, said differently, because the fix is
            // different for each: no agent at all, an agent this app cannot
            // read, or one that has not spoken yet.
            placeholder: placeholderForConversation(evidence: evidence)
        )
    }

    private func placeholderForConversation(evidence: AgentPaneEvidence?) -> String {
        guard let evidence else {
            return "No agent is running in this window."
        }
        if conversations.conversation == nil {
            let name = evidence.kind.isEmpty ? "The agent here" : evidence.kind
            return "\(name) has not published a transcript this app can read."
        }
        return "Nothing said yet."
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
    ///
    /// Keyed by id, this now fires only when a session is genuinely gone. Keyed
    /// by name it also fired on every rename, which is what turned renaming a
    /// session into a teardown of a session that was working perfectly.
    private func discardControllersForVanishedSessions() {
        let live = Set(server.sessionIDs)
        for (id, controller) in models where !live.contains(id) {
            // The name comes off the controller's own connection, not from
            // `describe`: `TmuxServer` has already dropped the connection this
            // id would be looked up through by the time this runs, so the
            // lookup would fail on every line it is wanted for.
            let name = controller.connection.sessionName
            TmuxLog.lifecycle(
                "dropping the view controller for \(id) (\(name)) — the session is gone"
                    + " from the server",
                session: name
            )
            models.removeValue(forKey: id)
            // Its `tmux attach` child goes with it. A session that is gone
            // cannot be attached to, so the client is already dying; this is
            // what stops the view and the surface outliving it.
            embedded.removeValue(forKey: id)?.detach()
            // Leaves the fallback below to pick a session that still exists.
            if currentSessionID == id { currentSessionID = nil }
        }
    }

    /// Show a session **because the person asked for it.**
    ///
    /// Every path a person can reach — the rail, ⌃⌘1-9, next/previous session,
    /// a window clicked in another session — comes through here, and all of
    /// them cancel any startup target still waiting to be placed. Routing them
    /// past this was the defect: cancellation lived in three rail callbacks, so
    /// picking a session with the keyboard left the preference armed and it
    /// could yank the person away from their own choice a moment later. Found
    /// by review 2026-08-02, twice — the second time because the first fix only
    /// covered the mouse.
    ///
    /// Automatic navigation uses `showWithoutCancelling` instead: the fallback
    /// to the first session when the current one dies is not a choice anybody
    /// made, and must not disarm a preference that has not had its chance yet.
    func show(sessionID id: String) {
        cancelStartupTargeting()
        showWithoutCancelling(sessionID: id)
    }

    private func showWithoutCancelling(sessionID id: String) {
        guard currentSessionID != id, let connection = server.connection(id: id),
              let model = model(forSessionID: id),
              let embedded = embeddedController(forSessionID: id) else { return }

        currentSessionID = id
        content.show(embedded)

        // Render what tmux has already said rather than waiting to be told
        // again. A session learns its windows from notifications, and the ones
        // describing an existing session arrived when the connection attached —
        // long before this controller was on screen to hear them.
        model.syncWithModel()
        embedded.syncWithModel()
        // Only here, and never out of a text field. See `takeKeyboard`: doing
        // this on every model change is what took the rail's rename field away
        // mid-word.
        embedded.takeKeyboard()

        connection.announceStatus()
        refreshSidebar()
    }

    func showStatus(_ status: String, detail: String) {
        sidebar.showStatus(status, detail: detail)
    }

    /// ⌃⌘1-9 — the session level's counterpart to ⌘0-9 for windows.
    ///
    /// A *position* here, unlike the window shortcuts, and deliberately: tmux
    /// gives a session an id but no index, so there is no number of its own to
    /// address one by, and the rail draws sessions in tmux's order without
    /// numbering them.
    func selectSession(atSlot slot: Int) {
        let ids = server.sessionIDs
        guard slot >= 0, slot < ids.count else { return }
        show(sessionID: ids[slot])
    }

    func selectAdjacentSession(offset: Int) {
        let ids = server.sessionIDs
        guard !ids.isEmpty, let current = currentSessionID,
              let index = ids.firstIndex(of: current) else { return }
        show(sessionID: ids[(index + offset + ids.count) % ids.count])
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
        for controller in embedded.values { controller.detach() }
        server.stop()
    }
}

#if DEBUG

    extension MainViewController {
        var debugShownSessionName: String? {
            currentSessionID.flatMap { server.name(ofSession: $0) }
        }

        /// The sessions this controller is holding a `SessionViewController`
        /// for, as `$3 (agents)`.
        ///
        /// The one thing `debugSessionReports()` cannot show: it walks tmux's
        /// current session list, so a controller whose session is gone is
        /// absent from that report rather than flagged in it. Printed with the
        /// id because that is the leak's identity — a controller left behind
        /// has no name to look up any more.
        var debugSessionControllerNames: [String] {
            models.keys.sorted().map { describe($0) }
        }

        /// A session's model by name, on screen or not.
        ///
        /// By name because the inspector's routes are typed by a person; the
        /// name is resolved to an id here and nowhere else.
        func debugSessionController(named name: String) -> SessionModel? {
            // Made on demand rather than looked up. A session that has never
            // been shown is exactly what a test wants to aim at: driving one
            // without first putting it on screen is the only way to run a
            // check that does not take over the display of whoever is at the
            // machine. Same reasoning as `inSession` — acting on a session is
            // not conditional on having looked at it.
            server.sessionID(named: name).flatMap { model(forSessionID: $0) }
        }

        /// Show a session the inspector named. Same reasoning as above.
        func debugShow(sessionNamed name: String) {
            guard let id = server.sessionID(named: name) else { return }
            show(sessionID: id)
        }

        /// Every session on the server, whether or not it has ever been shown.
        /// A session with no controller still has a live connection, and its
        /// window list is exactly the thing worth diffing against tmux.
        func debugSessionReports() -> [DebugInspector.SessionReport] {
            server.sessionIDs.compactMap { id in
                guard let connection = server.connection(id: id) else { return nil }
                return DebugInspector.SessionReport(
                    connection: connection,
                    hiddenWindowIDs: models[id]?.hiddenWindowIDs ?? [],
                    isShown: id == currentSessionID
                )
            }
        }
    }

#endif
