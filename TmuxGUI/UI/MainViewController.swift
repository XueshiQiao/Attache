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
    private lazy var content = Content(backdrop: contentBackdrop)
    /// Keyed by tmux's `$N`, like `TmuxServer.connections`. Keyed by name, a
    /// rename read as "that session is gone" and threw the controller away —
    /// GPU surfaces, primed scrollback and the hidden-window set with it.
    private var controllers = [String: SessionViewController]()
    private var currentSessionID: String?
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
        guard let currentSessionID else { return nil }
        return controllers[currentSessionID]
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
        guard let controller = currentSession,
              controller.isViewLoaded,
              let window = controller.view.window,
              window.isKeyWindow
        else { return }
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
        sidebar.onSelect = { [weak self] id in self?.show(sessionID: id) }
        sidebar.onNew = { [weak self] in self?.server.newSession() }
        sidebar.onRename = { [weak self] id, new in
            self?.server.connection(id: id)?.renameSession(to: new)
        }

        sidebar.onNewWindow = { [weak self] id in
            guard let self, let connection = server.connection(id: id) else { return }
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
    private func inSession(_ id: String, _ action: (SessionViewController) -> Void) {
        guard let controller = controller(forSessionID: id) else {
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
    private func controller(forSessionID id: String) -> SessionViewController? {
        if let existing = controllers[id] { return existing }
        guard let connection = server.connection(id: id) else { return nil }

        let controller = SessionViewController(connection: connection)
        controller.onStatusChange = { [weak self] status in self?.onStatusChange?(status) }
        // Hiding and restoring never reach tmux, so `server.onChange` — which is
        // fed by connection notifications — cannot see them. Without this the
        // row a user just hid would stay in the rail until tmux happened to say
        // something else.
        controller.onWindowsChanged = { [weak self] in self?.refreshSidebar() }
        controllers[id] = controller
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

        // No autosave name on purpose: the width is a setting, and an autosaved
        // divider position would silently outrank it after the first drag.
        appliedSidebarWidth = AppSettings.sidebarWidth
        splitView.setPosition(AppSettings.sidebarWidth, ofDividerAt: 0)
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
        // Thin rather than the pane-splitter default: the colour is clear
        // either way, but a wide clear divider leaves a band of untinted window
        // between the halves, which is a third tone in a window whose whole
        // point is that it has two.
        splitView.dividerStyle = .thin
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
        view.window?.backgroundColor = WindowGlass.resolved().paneFill
        applyBackdropSettings()
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
        let entries = server.sessionIDs.compactMap { id -> SessionSidebarView.Entry? in
            guard let connection = server.connection(id: id) else { return nil }
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
                hiddenIDs: controllers[id]?.hiddenWindowIDs ?? []
            )
        }

        // Whatever the app was showing may have been killed elsewhere; fall
        // back to the first session rather than a blank pane. A rename no
        // longer reaches here at all — the id is unchanged, so nothing about
        // the session the app is showing has moved.
        if currentSessionID == nil || !server.sessionIDs.contains(currentSessionID!) {
            if let first = server.sessionIDs.first { show(sessionID: first) }
        }

        sidebar.update(entries: entries, selected: currentSessionID)
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
        for (id, controller) in controllers where !live.contains(id) {
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
            controller.releaseSurfaces()
            controller.view.removeFromSuperview()
            if controller.parent != nil { controller.removeFromParent() }
            controllers.removeValue(forKey: id)
            // Leaves the fallback below to pick a session that still exists.
            if currentSessionID == id { currentSessionID = nil }
        }
    }

    func show(sessionID id: String) {
        guard currentSessionID != id, let connection = server.connection(id: id),
              let controller = controller(forSessionID: id) else { return }

        currentSessionID = id
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
        for controller in controllers.values { controller.releaseSurfaces() }
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
            controllers.keys.sorted().map { describe($0) }
        }

        /// A session's controller by name, on screen or not. The off-screen
        /// ones are the interesting half: a font change reaches every one of
        /// them, and their views have no window.
        ///
        /// By name because the inspector's routes are typed by a person; the
        /// name is resolved to an id here and nowhere else.
        func debugSessionController(named name: String) -> SessionViewController? {
            // Made on demand rather than looked up. A session that has never
            // been shown is exactly what a test wants to aim at: driving one
            // without first putting it on screen is the only way to run a
            // check that does not take over the display of whoever is at the
            // machine. Same reasoning as `inSession` — acting on a session is
            // not conditional on having looked at it.
            server.sessionID(named: name).flatMap { controller(forSessionID: $0) }
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
                if let controller = controllers[id] {
                    return controller.debugReport(isShown: id == currentSessionID)
                }
                return DebugInspector.SessionReport(connection: connection)
            }
        }
    }

#endif
