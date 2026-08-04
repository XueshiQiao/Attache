//
//  EmbeddedSessionViewController.swift
//  Attache
//

import Cocoa
import GhosttyTerminal

/// One session's content half, drawn by tmux instead of by this app.
///
/// The alternative to `SessionViewController`, and the whole difference is who
/// paints: that one parses `%output` and places a surface per pane; this one
/// runs a plain `tmux attach` on a pty ghostty owns and gives tmux a single
/// surface to draw the entire picture into — splitters, every pane, the cursor.
/// Route B of `docs/embed-tmux-evaluation.html`, chosen because two things the
/// owner asked for (copy mode and `display-popup`) were measured to put nothing
/// at all on the control-mode stream, so route A cannot render them at any
/// price.
///
/// Everything outside this view is unchanged: the rail still lists sessions and
/// windows from the control-mode connection, a row click is still a tmux
/// command, and the title band above still says which window is active. That is
/// the point — the app is meant to look identical and differ only in its
/// middle.
@MainActor
final class EmbeddedSessionViewController: NSViewController {
    let model: SessionModel
    var connection: TmuxSessionConnection { model.connection }

    private let titleBand = TitleBandView(frame: .zero)
    /// `TmuxTerminalView`, not a second class of its own.
    ///
    /// It was one at first, carrying copies of the two AppKit overrides the
    /// pane surfaces had already paid for — and the copy silently lacked the
    /// third thing that view does: the right-click handling. Reported as "the
    /// pane menu is gone". Two views that must behave identically are one view.
    private let terminalView: TmuxTerminalView

    private let terminalController: TerminalController
    private var delegateBox: DelegateBox?

    /// Whether the status row is pushed out of sight.
    ///
    /// Off, by the owner's decision, and the reason is that hiding it hid more
    /// than a duplicate rail. tmux's status line is also where tmux *talks*:
    /// `rename-window` draws its input there, `kill-window` asks its `y/n`
    /// there, and every tmux message and the copy-mode indicator land there
    /// too. With the row off screen those prompts were invisible, so the key
    /// bindings that raise them looked dead — you pressed the binding, nothing
    /// appeared, and the keystrokes went into a prompt you could not see.
    ///
    /// The hiding machinery below is kept rather than deleted: the duplication
    /// it was solving is real, and the plan is to answer it by reworking this
    /// app's own tab bar. When that lands, flipping this back is one line.
    private static let hidesStatusRow = false

    /// The band's height, and the reason it exists at all: without it the
    /// window's rounded top corners would clip terminal text, and there would
    /// be nothing on this side of the window to drag it by.
    static let titleBandHeight: CGFloat = 28

    /// How many rows tmux's status line occupies for this session.
    ///
    /// There is no per-client way to turn it off — `status` is a *session*
    /// option, so switching it off here would also strip it from the user's own
    /// `tmux attach` in a terminal (checked, man tmux 3.6a). That is why the
    /// row was never suppressed, only placed outside the clip: the terminal
    /// view is this many cells taller than the container it sits in, and the
    /// window's backing store masks the overhang.
    ///
    /// Read from tmux rather than assumed to be 1, because `status` can be
    /// `off`, `on`, or a count up to 5.
    private let statusRows: Int

    /// Whether those rows sit above the window instead of below it, which
    /// shifts every pane down the screen by that many rows. Only `cell(at:)`
    /// cares.
    private let statusAtTop: Bool

    /// The machine this session lives on: its transport built the attach
    /// command above, and its helper is what a ⌘-click's existence checks go
    /// through — the local disk must be unreachable for a remote pane's
    /// paths, because a path that exists on both machines is the wrong file
    /// with the right name.
    private let host: HostContext

    /// Set from the surface's own resize callback, which is the only place a
    /// cell height can be had — it is font-derived, so it does not move unless
    /// the font does, and the overhang constraint below can safely depend on
    /// it.
    private var cellHeight: CGFloat = 0

    /// The other half of the same measurement, kept only so a click's position
    /// can be turned into the pane it landed in — see `paneID(at:)`.
    private var cellWidth: CGFloat = 0
    private var overhang: NSLayoutConstraint?


    init(model: SessionModel, host: HostContext) {
        self.model = model
        self.host = host
        let transport = host.transport
        let connection = model.connection
        statusRows = TmuxStatusOption.lines(
            transport: transport, sessionID: connection.sessionID
        )
        statusAtTop = TmuxStatusOption.isAtTop(
            transport: transport, sessionID: connection.sessionID
        )

        let base = TerminalConfiguration(startingFrom: .default) { builder in
            builder.withBackgroundOpacity(0)
            builder.withCustom("window-padding-x", "0")
            builder.withCustom("window-padding-y", "0")
            builder.withCustom("window-padding-balance", "false")
            // The transport renders this line, and the quoting in it is not
            // decoration: ghostty hands the value to `/bin/sh -c`, a remote
            // attach adds ssh's own join-and-reparse on top, and a session id
            // *is* `$N` — each unquoted layer is a shell that expands it to
            // nothing, so the attach silently targets whatever is current.
            // `TransportCheck` executes this rendering through both shells
            // and compares the argv that comes out the far end.
            builder.withCustom(
                "command",
                transport.attachShellCommand(sessionID: connection.sessionID)
            )
            // An attach that fails prints one line and exits; without this the
            // surface tears down before anyone can read it.
            builder.withCustom("wait-after-command", "true")
        }
        terminalController = TerminalController(
            configSource: .generated(base.rendered),
            theme: AppSettings.terminalTheme(),
            terminalConfiguration: AppSettings.terminalConfiguration()
        )
        terminalView = TmuxTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func loadView() {
        // `ContentHalfView` rather than a plain `NSView`: it is the view that
        // answers `mouseDownCanMoveWindow` for this half, and the answer being
        // unwritten is what made every splitter in this app undraggable for a
        // while — the fixed defect recorded in TODO.md, section 0.1.
        let root = ContentHalfView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        root.wantsLayer = true

        for subview in [terminalView, titleBand] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        // The title band goes in last of the two siblings that draw, because on
        // macOS 26 a drawing view gets a backing layer 66pt taller than itself
        // and whichever sibling was added last wins the overlap. See CLAUDE.md.
        root.addSubview(terminalView)
        root.addSubview(titleBand)

        // When the status row IS hidden (see `hidesStatusRow`, currently off) it
        // is pushed past the **bottom of the window**, and that choice was
        // measured rather than picked.
        //
        // The obvious construction is an intermediate view with
        // `masksToBounds`, with the terminal hanging out of it. Built that way
        // first, and tmux's status line stayed on screen: a layer mask does not
        // contain what libghostty draws, which is of a piece with the overhang
        // trap in CLAUDE.md — a view in this app can and does paint outside its
        // superview. The window's backing store is the one boundary nothing gets
        // past, so the overhang goes there.
        //
        // Zero to start with: `cellHeight` is only knowable from the surface's
        // first resize, and a guess here would be one frame with a stripe of
        // tmux status line in it. Positive lowers the bottom edge — verified
        // against the inspector's frames after a negative constant moved it the
        // other way and shortened the view instead.
        let overhang = terminalView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        self.overhang = overhang

        NSLayoutConstraint.activate([
            titleBand.topAnchor.constraint(equalTo: root.topAnchor),
            titleBand.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBand.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBand.heightAnchor.constraint(
                equalToConstant: Self.titleBandHeight
            ),

            terminalView.topAnchor.constraint(equalTo: titleBand.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overhang,
        ])

        let box = DelegateBox(owner: self)
        delegateBox = box
        terminalView.delegate = box
        terminalView.controller = terminalController
        terminalView.configuration = TerminalSurfaceOptions(backend: .exec)
        terminalView.setAccessibilityElement(true)
        terminalView.setAccessibilityLabel("tmux session \(connection.sessionID), drawn by tmux")
        terminalView.onContextMenu = { [weak self] in
            guard let self else { return nil }
            return model.activePaneContextMenu { [weak self] in self?.copySelection() }
        }
        // Dropping a file was refused outright until this was wired: the view
        // registers for the drag types and then asks its owner what to do with
        // what it caught, and this half was not answering. Reported as
        // "dragging an image in still does not work" — ⌘V of the same image
        // worked, because that has libghostty's own paste to fall through to
        // and a drop has nothing at all.
        terminalView.onDropText = { [weak self] text in
            guard let self, let paneID = model.activePaneID else { return false }
            return connection.paste(text: text, into: paneID)
        }
        // Read on every event rather than captured, so changing the gesture in
        // the settings file takes effect without rebuilding the surface.
        terminalView.linkGesture = {
            AppSettings.linkClickEnabled ? AppSettings.linkModifier : nil
        }

        view = root
        // The same channel the pane controller uses. tmux still announces
        // structural changes on the control-mode connection whether or not this
        // app is the one painting, and the title band is this app's own — so a
        // window switched from another terminal has to reach it here.
        connection.addModelObserver { [weak self] in self?.syncWithModel() }
    }

    /// Give up the surface and let the `tmux attach` child exit.
    ///
    /// Not optional politeness: an attached client keeps a claim on the
    /// session's size, so an embedded client left running after the user
    /// switches back to route A would go on arguing with the pane grid over how
    /// many columns the session has — the fight documented at
    /// `reclaimWindowSizeIfTaken`, with nothing on screen to explain it.
    func detach() {
        terminalView.setSurfaceVisible(false)
        terminalView.removeFromSuperview()
        if parent != nil { removeFromParent() }
    }

    /// The rail and the title band are this app's; the picture is tmux's. So
    /// the only thing to sync here is the band — everything the old controller
    /// did with layouts, pane sets and snapshots is tmux's business now.
    func syncWithModel() {
        titleBand.show(name: connection.windows.first { $0.isActive }?.name)
    }

    /// Hand the keyboard to the terminal. **Only from `show`.**
    ///
    /// This used to be the last line of `syncWithModel`, which runs on every
    /// tmux notification — so anything that had the keyboard lost it the moment
    /// tmux said anything at all. Reported as "renaming a window ends by
    /// itself": double-clicking a row opens a field editor, the click's own
    /// `select-window` comes back as a notification a few milliseconds later,
    /// and the field editor was taken away mid-word. Nothing about a
    /// notification is a reason to move the keyboard; being shown is.
    func takeKeyboard() {
        guard let window = view.window else { return }
        // Never out of a text field, and this is the second half of the same
        // defect. Moving the call out of `syncWithModel` was not enough:
        // double-clicking a row belonging to another session *both* starts the
        // rename and switches session, and the switch calls this — so the field
        // editor opened and was taken away in the same gesture. The rail's
        // editor is a field editor, which is an `NSText`; nothing this app does
        // should ever pull the keyboard out of one.
        guard !(window.firstResponder is NSText) else { return }
        window.makeFirstResponder(terminalView)
    }

    /// The pane commands the menu bar drives, which have no pointer to take a
    /// pane from and use the one tmux says is active.
    ///
    /// They live here rather than on `SessionModel` for one reason: each has to
    /// answer "is the user actually looking at this" first. A window keeps
    /// naming a first responder while some other window has the keyboard, so
    /// without the `isKeyWindow` test, editing a text field in the settings
    /// window and pressing ⌘V would put the clipboard into a terminal pane.
    ///
    /// Each answers whether it found a pane, so `AppDelegate` can tell "there
    /// was nothing to do" from "done" and fall through to the responder chain.
    private var addressablePane: String? {
        guard view.window?.isKeyWindow == true else { return nil }
        return model.activePaneID
    }

    func pasteIntoFocusedPane() -> Bool {
        guard let paneID = addressablePane else { return false }
        return model.pastePasteboard(into: paneID)
    }

    /// ⌘Z. Reported not working after tmux took over the drawing, and ⌘V
    /// reported working — which is the whole diagnosis in one pair. Both ask
    /// which pane has the keyboard; paste then falls through the responder
    /// chain to libghostty's own, which writes to the pty, so it survived.
    /// Undo has no such fallback, because a terminal has no undo of its own.
    /// See `SessionModel.sendUndo` for the byte and how it was measured.
    func sendUndo() -> Bool {
        guard let paneID = addressablePane else { return false }
        model.sendUndo(to: paneID)
        return true
    }

    func splitFocusedPane(_ direction: SessionModel.PaneSplit) -> Bool {
        guard let paneID = addressablePane else { return false }
        model.splitPane(paneID, direction)
        return true
    }

    func toggleZoomOnFocusedPane() -> Bool {
        guard let paneID = addressablePane else { return false }
        model.toggleZoom(paneID)
        return true
    }

    func confirmKillFocusedPane() -> Bool {
        guard let paneID = addressablePane else { return false }
        model.confirmKillPane(paneID)
        return true
    }

    /// Copy whatever is selected in the embedded terminal.
    ///
    /// libghostty's selection is internal to the surface, so this is the only
    /// side that can ask for it — which is why the pane menu takes it as a
    /// closure rather than reaching for a surface this half does not have.
    func copySelection() {
        terminalView.copySelectedTextToPasteboard()
    }

    /// A settings change that can move a glyph or a colour.
    ///
    /// One terminal controller per session, so every session has to be told —
    /// not just the one on screen. The font half matters more here than it did
    /// under the pane grid: ghostty sizes the pty from its own grid, so a font
    /// change is what tells tmux the session got wider.
    func applySettings() {
        _ = terminalController.setTheme(AppSettings.terminalTheme())
        _ = terminalController.setTerminalConfiguration(AppSettings.terminalConfiguration())
        titleBand.applyChromeTheme()
    }

    func applyChromeTheme() {
        titleBand.applyChromeTheme()
    }

    private func gridDidResize(_ metrics: TerminalGridMetrics) {
        // Device pixels on the way in — the same unit `PaneGridView` counts in,
        // and the same conversion back to points.
        let scale = max(view.window?.backingScaleFactor ?? 1, 1)
        // Assigned before the early return below, which only guards the
        // overhang constraint: the width has its own reader and a resize that
        // changes the width without changing the height would otherwise leave
        // it stale.
        cellWidth = CGFloat(metrics.cellWidthPixels) / scale
        let height = CGFloat(metrics.cellHeightPixels) / scale
        guard height > 0, height != cellHeight else { return }
        cellHeight = height
        let hidden = Self.hidesStatusRow ? statusRows : 0
        overhang?.constant = height * CGFloat(hidden)
        // Deliberately not `onStatusChange`: that channel writes the window
        // title and the rail's footer, and this app's title says which window
        // is active. A grid size parked there permanently would be this
        // controller redecorating chrome that is supposed to look identical
        // under both halves.
        TmuxLog.lifecycle(
            "tmux draws \(connection.sessionID) — \(metrics.columns)x\(metrics.rows),"
                + " \(statusRows) status row(s), \(hidden) clipped at \(height)pt"
        )
    }

    // MARK: - Opening a link

    /// Act on a link libghostty matched and the user clicked.
    ///
    /// The matching, the underline and the pointing-hand cursor are all
    /// libghostty's; this is the other end of it, and until it existed the
    /// gesture highlighted a path and then did nothing at all.
    ///
    /// Off the main thread because deciding what the string *is* means asking
    /// the file system, and a path on a network volume that has gone away
    /// blocks for as long as the mount takes to give up.
    private func openLink(_ raw: String) {
        // `lastLinkPress` being nil means the click was not the gesture this app
        // offers — ⇧⌘ reaches libghostty's own link handling whatever the
        // settings say, so without this `link_click = false` would not actually
        // switch anything off.
        guard AppSettings.linkClickEnabled, let press = terminalView.lastLinkPress else { return }
        // The *cell* is what gets carried, not a pane id. Which pane covers a
        // cell is tmux's to answer and it is asked below, because this side's
        // window list lags the screen by a notification and a round trip.
        let cell = cell(at: press)

        guard host.transport.pathsAreLocal else {
            openRemoteLink(raw, cell: cell)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let direct = TerminalLinkTarget.resolve(raw, cwd: nil, existence: Self.existence)
            // A URL or an absolute path is already answerable, so it opens
            // without a round trip to tmux. Only a relative match has to ask
            // which directory it belongs to.
            guard direct == .unsupported else {
                DispatchQueue.main.async { self?.perform(direct, raw: raw) }
                return
            }
            guard let cell else {
                DispatchQueue.main.async { self?.perform(.unsupported, raw: raw) }
                return
            }
            DispatchQueue.main.async {
                // A cell no pane covers — a divider, or a window that changed
                // shape in between — answers nil and the click is dropped,
                // which is the right end for it.
                self?.connection.workingDirectory(atColumn: cell.column, row: cell.row) { cwd in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let target = TerminalLinkTarget.resolve(
                            raw, cwd: cwd, existence: Self.existence
                        )
                        DispatchQueue.main.async { self?.perform(target, raw: raw) }
                    }
                }
            }
        }
    }

    /// The remote shape of the same two-step: URLs and absolute paths first,
    /// a tmux ask only for a relative match — but every existence answer
    /// comes from the pane's machine, in one classification round trip.
    private func openRemoteLink(_ raw: String, cell: (column: Int, row: Int)?) {
        guard let helper = host.helper else {
            connection.showStatusMessage("Attaché: can't reach \(host.displayName) right now")
            return
        }
        RemoteLinkResolver.resolve(raw: raw, cwd: nil, helper: helper) { [weak self] first in
            guard let self else { return }
            guard let first else {
                self.connection.showStatusMessage(
                    "Attaché: can't reach \(self.host.displayName) right now"
                )
                return
            }
            guard first == .unsupported, let cell else {
                self.performRemote(first, raw: raw)
                return
            }
            self.connection.workingDirectory(atColumn: cell.column, row: cell.row) { cwd in
                RemoteLinkResolver.resolve(raw: raw, cwd: cwd, helper: helper) { [weak self] target in
                    guard let self else { return }
                    guard let target else {
                        self.connection.showStatusMessage(
                            "Attaché: can't reach \(self.host.displayName) right now"
                        )
                        return
                    }
                    self.performRemote(target, raw: raw)
                }
            }
        }
    }

    private func performRemote(_ target: TerminalLinkTarget, raw: String) {
        switch target {
        case let .url(url):
            // A URL is machine-independent; the person's browser is here.
            NSWorkspace.shared.open(url)
        case let .directory(path), let .file(path):
            RemoteOpener.open(
                path: path,
                host: host.displayName,
                destination: host.transport.ssh?.destination ?? host.displayName,
                template: host.config?.remoteOpenCommand,
                status: { [weak self] message in self?.connection.showStatusMessage(message) }
            )
        case let .missing(path):
            connection.showStatusMessage("Attaché: no such path on \(host.displayName) — \(path)")
        case .unsupported:
            connection.showStatusMessage("Attaché: not a path this app can open — \(raw)")
        }
    }

    private static func existence(_ path: String) -> TerminalLinkTarget.Existence {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .absent
        }
        return isDirectory.boolValue ? .directory : .file
    }

    /// A file reveals rather than opens: what a click means is "show me this",
    /// and opening by extension would start an installer for a `.pkg` and a
    /// disk image for a `.dmg` on a gesture the user meant as navigation.
    private func perform(_ target: TerminalLinkTarget, raw: String) {
        switch target {
        case let .url(url):
            NSWorkspace.shared.open(url)
        case let .directory(path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case let .file(path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case let .missing(path):
            // Said out loud on purpose. libghostty matches on shape and never
            // asks the disk, so it underlines paths that are not there — and a
            // click that silently does nothing reads as the app being broken.
            connection.showStatusMessage("Attaché: no such path — \(path)")
        case .unsupported:
            connection.showStatusMessage("Attaché: not a path this app can open — \(raw)")
        }
    }

    /// Which cell of tmux's grid a remembered click landed on.
    ///
    /// libghostty's open-URL callback carries the matched string and no
    /// position at all, so the press has to be remembered by the view and read
    /// back here. Answering in cells rather than in panes is deliberate: the
    /// pane covering a cell is a question only tmux can answer without going
    /// stale, and `TmuxSessionConnection.workingDirectory(atColumn:row:)` asks
    /// it at the moment it matters.
    private func cell(at point: NSPoint) -> (column: Int, row: Int)? {
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        // The view's origin is bottom-left and tmux counts rows from the top.
        let screenRow = Int((terminalView.bounds.height - point.y) / cellHeight)
        // A status line above the window is not part of the window, so it has
        // to come off before the row means anything to `pane_top`. Without
        // this, `status-position top` with two rows reads a click two rows
        // lower than it was — past a horizontal divider and into the pane
        // below, which then answers with its own directory and opens the wrong
        // file rather than nothing at all.
        let row = screenRow - (statusAtTop ? statusRows : 0)
        // Negative means the click was on the status line itself.
        guard row >= 0 else { return nil }
        return (column: Int(point.x / cellWidth), row: row)
    }

    /// libghostty holds its delegate unowned-unsafe, so the conformance lives
    /// on an object this controller owns rather than on the controller itself —
    /// the same arrangement `TmuxPaneSurface` uses and for the same reason.
    private final class DelegateBox: NSObject, TerminalSurfaceGridResizeDelegate,
        TerminalSurfaceOpenURLDelegate
    {
        weak var owner: EmbeddedSessionViewController?
        init(owner: EmbeddedSessionViewController) { self.owner = owner }

        func terminalDidResize(_ size: TerminalGridMetrics) {
            owner?.gridDidResize(size)
        }

        func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
            owner?.openLink(url)
        }
    }
}

// The surface class this file used to declare is gone: `TmuxTerminalView` is
// the one view both content halves use. See the comment on `terminalView`.
