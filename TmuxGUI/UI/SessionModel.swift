//
//  SessionModel.swift
//  TmuxGUI
//

import Cocoa

/// One session's state and commands, with no view of its own.
///
/// What is left of `SessionViewController` after tmux took over the drawing.
/// Every method here is either a tmux command or upkeep of the one piece of
/// state this app authors — which window ids the user has hidden from the rail.
/// The comments that survive are the ones that record something measured; each
/// says what it cost to find out.
///
/// It is not a view controller and holds no window, so anything that has to ask
/// "is the user looking at this" belongs to `EmbeddedSessionViewController`,
/// which has one. That split is what stops the app from answering ⌘V while the
/// settings window has the keyboard.
@MainActor
final class SessionModel {
    let connection: TmuxSessionConnection

    /// Windows the user hid from the rail.
    ///
    /// Hiding must never kill anything — an AI agent mid-run is the expensive
    /// case and there is no undo for it. But the rail is a mirror of tmux's
    /// window list, so "hidden" has to be remembered here or the row simply
    /// reappears on the next sync. This set is the app's one piece of state
    /// tmux cannot contradict, and the only one.
    private(set) var hiddenWindowIDs = Set<String>()

    /// A window hidden while it was the active one, until tmux reports that the
    /// selection has actually moved off it.
    ///
    /// Hiding sends tmux nothing about hiding — only a `select-window` for the
    /// row to move to. Until that comes back, tmux's idea of the active window
    /// is still the row that was just hidden, and the "tmux made it active
    /// again, so put it back" rule in `syncWithModel` reads that as tmux
    /// undoing the hide. It fired on every ⌘W: the window was hidden, restored
    /// a microsecond later, and all that survived was the selection change —
    /// which on a two-window session looks exactly like ⌘W toggling between
    /// window 1 and window 2, because that is what it was doing.
    private var hidingActiveWindow: String?

    private var syncScheduled = false

    var onWindowsChanged: (() -> Void)?
    var onStatusChange: ((String) -> Void)?

    init(connection: TmuxSessionConnection) {
        self.connection = connection
        connection.addModelObserver { [weak self] in self?.setNeedsSync() }
        connection.onStatusChange = { [weak self] status in self?.onStatusChange?(status) }
    }

    /// The pane every keyboard-driven command addresses.
    ///
    /// tmux's answer, not a ring this app keeps. The old controller could ask
    /// which of its own surfaces held the keyboard; there are no surfaces now,
    /// and tmux is the one that knows where the panes are.
    var activePaneID: String? { connection.activeWindow?.activePaneID }

    // MARK: - Windows

    /// Addressed by tmux's own `window_index`, the way `prefix 0-9` is — not by
    /// position in the rail. A hidden window is not selected: its row is not
    /// there, so its number addresses nothing, and selecting it would bring it
    /// back because `syncWithModel` restores whatever tmux makes active. Hiding
    /// is the one piece of state this app authors, and a shortcut should not
    /// undo it by arithmetic.
    func selectWindow(atIndex index: Int) {
        guard let window = connection.windows.first(where: { $0.index == index }),
              !hiddenWindowIDs.contains(window.id)
        else { return }
        connection.selectWindow(id: window.id)
    }

    func selectAdjacentWindow(offset: Int) {
        let visible = connection.windows.filter { !hiddenWindowIDs.contains($0.id) }
        guard !visible.isEmpty,
              let current = visible.firstIndex(where: { $0.id == connection.activeWindowID })
        else { return }
        let next = (current + offset + visible.count) % visible.count
        connection.selectWindow(id: visible[next].id)
    }

    func newWindow() { connection.newWindow() }

    func selectWindow(id: String) { connection.selectWindow(id: id) }

    func renameWindow(id: String, to name: String) {
        connection.renameWindow(id: id, to: name)
    }

    /// `anchor` is the window this one should land in front of, or nil for
    /// "after everything else" — which needs a different tmux command, because
    /// `move-window -b` cannot append. See `TmuxSessionConnection`.
    func moveWindow(id: String, before anchor: String?) {
        guard connection.moveWindow(id: id, before: anchor) else {
            TmuxLog.lifecycle(
                "not moving \(id) — \(connection.sessionName) has no free index above its"
                    + " windows, or has not learned its session id yet",
                session: connection.sessionName
            )
            return
        }
    }

    func hideActiveWindow() {
        guard let id = connection.activeWindowID else { return }
        hideWindow(id)
    }

    func hideWindow(_ id: String) {
        // Hiding sends nothing to tmux, so it leaves no trace there. Logged
        // anyway: "the row is gone" has two causes and only one of them lost
        // anything, and telling them apart afterwards is otherwise guesswork.
        TmuxLog.lifecycle(
            "hiding window \(id) from the rail (tmux is untouched, nothing is killed)",
            session: connection.sessionName
        )
        hiddenWindowIDs.insert(id)
        let visible = connection.windows.filter { !hiddenWindowIDs.contains($0.id) }
        if connection.activeWindowID == id, let next = visible.first {
            hidingActiveWindow = id
            connection.selectWindow(id: next.id)
        } else if visible.isEmpty {
            // Never leave the user staring at nothing with no way back.
            hiddenWindowIDs.remove(id)
        }
        syncWithModel()
    }

    func restoreHiddenWindows() {
        hiddenWindowIDs.removeAll()
        hidingActiveWindow = nil
        syncWithModel()
    }

    /// The one destructive thing the rail can do, and one of the two places in
    /// the app that end processes.
    ///
    /// The confirmation names the window and the log line names the session,
    /// and the rail outlives every session it draws — so a kill belongs to the
    /// session, not to the rail. The wording is the wording the tab strip used;
    /// nothing about the stakes changed when the tabs became rows.
    func confirmKillWindow(id: String) {
        guard let window = connection.windows.first(where: { $0.id == id }) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Kill window \(window.index):\(window.name)?"
        alert.informativeText = "Every process in the window ends, including any AI agent mid-run."
            + "\nTo just get it out of the way, use Hide From The Sidebar."
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")

        // Both outcomes are logged, and the prompt itself is logged before it
        // is shown. If work disappears, the question is whether this dialog was
        // ever put in front of a human — a GUI driven by automation can answer
        // it without one, and the log is the only place that shows the
        // difference.
        TmuxLog.destructive(
            "kill confirmation shown for \(window.id) (\(window.index):\(window.name))",
            session: connection.sessionName
        )
        guard alert.runModal() == .alertFirstButtonReturn else {
            TmuxLog.lifecycle("kill cancelled for \(window.id)", session: connection.sessionName)
            return
        }
        TmuxLog.destructive(
            "kill CONFIRMED for \(window.id) (\(window.index):\(window.name)) — every process in it ends",
            session: connection.sessionName
        )
        connection.killWindow(id: window.id)
    }

    // MARK: - Model upkeep

    /// Coalesce model changes to one rebuild per runloop turn.
    ///
    /// Attaching to a session with a dozen windows produces a burst of
    /// notifications — one per window plus a layout change each — and every one
    /// of them re-reads the window list.
    private func setNeedsSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            syncScheduled = false
            syncWithModel()
        }
    }

    /// Reconcile the hidden set with what tmux currently says, then tell the
    /// rail. This is the whole of what a session controller does now: tmux
    /// draws the panes, so there is nothing else to bring up to date.
    func syncWithModel() {
        // A window that came back on its own — tmux made it active again —
        // should not stay hidden; that would leave the GUI showing something
        // other than what tmux says is current.
        //
        // Except while this app is the one moving away from it. Hiding the
        // active window sends a `select-window` and then runs this immediately,
        // long before tmux can answer, so tmux still names the row that was just
        // hidden — which is not tmux putting it back, it is tmux not having been
        // told yet. See `hidingActiveWindow`.
        if let active = connection.activeWindowID {
            if active == hidingActiveWindow {
                // Still waiting on our own select-window.
            } else {
                hidingActiveWindow = nil
                hiddenWindowIDs.remove(active)
            }
        }
        hiddenWindowIDs.formIntersection(Set(connection.windows.map(\.id)))
        onWindowsChanged?()
    }

    // MARK: - Panes

    /// Where a split puts the new pane.
    ///
    /// Named after the result rather than after the divider, because the other
    /// two names for this are actively misleading: tmux calls "beside" `-h` and
    /// iTerm calls the very same arrangement "Split Vertically". Nothing in the
    /// UI has to know which of those is meant.
    enum PaneSplit {
        case right
        case down
    }

    func splitPane(_ paneID: String, _ direction: PaneSplit) {
        connection.splitPane(id: paneID, horizontally: direction == .right)
    }

    func toggleZoom(_ paneID: String) {
        connection.toggleZoom(paneID: paneID)
    }

    /// ⌘Z, as the byte a program in a pane understands.
    ///
    /// **Measured, because none of it was guessable.** Against Claude Code
    /// 2.1.220 in a pane, three candidates were driven in with `send-keys -H`
    /// and the input box watched:
    ///
    /// - `CSI 122;9u` — ⌘Z the way the kitty keyboard protocol encodes it, and
    ///   what a terminal that had negotiated that protocol would send. Claude
    ///   Code does not read it: the input box gained a literal **z**. Sending
    ///   this would be worse than sending nothing.
    /// - `ESC z` — nothing at all.
    /// - **`0x1f`** — the undo. It took back the stray `z`, and in the test that
    ///   matters it emptied the box after a bracketed paste of eighteen
    ///   characters.
    ///
    /// `0x1f` is Ctrl+`_`, which GNU readline binds to `undo` — so this is one
    /// byte that means undo to the shell prompt and to the TUI alike, rather
    /// than a mapping invented for one program.
    func sendUndo(to paneID: String) {
        connection.sendKeys(paneID: paneID, data: Data([0x1f]))
    }

    /// What ⌘V means for one pane, whichever way the pane was chosen.
    func pastePasteboard(into paneID: String) -> Bool {
        switch PasteContent.read(from: .general) {
        case let .text(text):
            return connection.paste(text: text, into: paneID)

        case .imageWithoutFile:
            // Ctrl-V, so the program in the pane reads the pasteboard itself —
            // see `PasteContent.imageWithoutFile`. Sent as a keystroke rather
            // than through `paste-buffer`, because it *is* a keystroke: there
            // is no text to put in a buffer. Against a shell rather than an
            // image-aware program this is `quoted-insert`, which waits for one
            // more key and inserts it literally — nothing is lost and nothing
            // runs.
            connection.sendKeys(paneID: paneID, data: Data([0x16]))
            TmuxLog.lifecycle(
                "pasteboard holds an image and no file — sent Ctrl-V to \(paneID) so the "
                    + "program can read it",
                session: connection.sessionName
            )
            return true

        case .nothing:
            return false
        }
    }

    /// Ending one pane, on the same terms as ending a window.
    ///
    /// Separate wording from hiding and a confirmation first, because there is
    /// no undo and a pane is exactly as likely to hold an agent mid-run as a
    /// window is. The extra sentence when this is the window's last pane is not
    /// decoration: tmux closes a window whose last pane is killed, so the same
    /// menu item means "close one pane" most of the time and "close the whole
    /// window" the rest of it, and the dialog is the only place that difference
    /// can be stated before it happens.
    func confirmKillPane(_ paneID: String) {
        let window = connection.activeWindow
        let isLastPane = (window?.paneIDs.count ?? 0) <= 1

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isLastPane
            ? "Kill the last pane of window \(window.map { "\($0.index):\($0.name)" } ?? "")?"
            : "Kill pane \(paneID)?"
        alert.informativeText = isLastPane
            ? "It is the only pane left, so tmux closes the window with it."
                + "\nEvery process in it ends, including any AI agent mid-run."
            : "Every process in the pane ends, including any AI agent mid-run."
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")

        // Logged before it is shown and on both outcomes, for the reason spelled
        // out at `confirmKillWindow`: if work disappears, the log is the only
        // record of whether a human was ever asked.
        TmuxLog.destructive(
            "kill confirmation shown for pane \(paneID)\(isLastPane ? " (last pane — takes the window)" : "")",
            session: connection.sessionName
        )
        guard alert.runModal() == .alertFirstButtonReturn else {
            TmuxLog.lifecycle("pane kill cancelled for \(paneID)", session: connection.sessionName)
            return
        }
        TmuxLog.destructive(
            "pane kill CONFIRMED for \(paneID) — every process in it ends",
            session: connection.sessionName
        )
        connection.killPane(id: paneID)
    }

    // MARK: - Pane context menu

    /// The right-click menu for the pane tmux says is active.
    ///
    /// Built fresh on every click rather than kept, because two of its items
    /// depend on what tmux says right now — whether the window has more than
    /// one pane, and whether one of them is zoomed.
    ///
    /// The *active* pane rather than the one under the pointer: tmux draws the
    /// panes, so nothing on this side knows where they are. `copySelection` is
    /// passed in for the same reason — the selection lives inside the libghostty
    /// surface the view half owns.
    func activePaneContextMenu(copySelection: @escaping () -> Void) -> NSMenu? {
        guard let paneID = activePaneID else { return nil }
        let menu = NSMenu()
        // Off, or AppKit decides what is enabled by asking each item's target
        // whether it responds to the selector — which every one of these does,
        // so the answer is always yes and `isEnabled` set below is overwritten
        // before the menu is drawn. Zoom on a one-pane window looked available
        // and did nothing.
        menu.autoenablesItems = false
        let window = connection.activeWindow
        let paneCount = window?.paneIDs.count ?? 1
        // The two layouts differ exactly while a pane is zoomed — the same
        // derivation `DebugInspector` uses. There is no zoom flag to read.
        let isZoomed = window.map { $0.visibleLayoutText != $0.savedLayoutText } ?? false

        menu.addItem(paneItem("Split Right", key: "d", flags: [.command]) { [weak self] in
            self?.splitPane(paneID, .right)
        })
        // Uppercase "D" for the shifted one — see the Pane menu in `AppDelegate`
        // for why. Only the drawing of it matters here, but a context menu that
        // advertises a different shortcut from the one that works is worse than
        // one that advertises none.
        menu.addItem(paneItem("Split Down", key: "D", flags: [.command, .shift]) { [weak self] in
            self?.splitPane(paneID, .down)
        })

        menu.addItem(.separator())

        let zoom = paneItem(
            isZoomed ? "Unzoom Pane" : "Zoom Pane", key: "\r", flags: [.command]
        ) { [weak self] in
            self?.toggleZoom(paneID)
        }
        // tmux ignores `-Z` on a one-pane window rather than erroring, so an
        // enabled item there would be a menu entry that does nothing.
        zoom.isEnabled = paneCount > 1
        menu.addItem(zoom)

        menu.addItem(.separator())

        // Copy is offered whether or not anything is selected: libghostty's
        // selection state is internal to that module, so this side cannot ask,
        // and the handler already answers "nothing selected" by doing nothing.
        //
        // Called through a closure rather than sent as `copy:`, which is the
        // obvious form and drew a clipboard icon beside this one item — AppKit
        // decorates the standard edit selectors — indenting Copy and Paste away
        // from every other title in the menu.
        menu.addItem(paneItem("Copy", key: "c", flags: [.command]) { copySelection() })

        menu.addItem(paneItem("Paste", key: "v", flags: [.command]) { [weak self] in
            _ = self?.pastePasteboard(into: paneID)
        })

        menu.addItem(.separator())

        // Trailing ellipsis because it asks first, and the wording says kill
        // rather than close: this is the item that ends processes.
        menu.addItem(paneItem("Kill Pane…", key: "", flags: []) { [weak self] in
            self?.confirmKillPane(paneID)
        })

        return menu
    }

    /// A menu item that runs a closure.
    ///
    /// `NSMenuItem` only takes a selector, so the closure is parked on a small
    /// owned object the item retains. The alternative — one `@objc` method per
    /// item reading the pane id back out of `representedObject` — puts the pane
    /// id through a round trip that can be nil, for a menu whose whole point is
    /// that it knows which pane it belongs to.
    ///
    /// The key equivalents are shown, not obeyed: a context menu's items are not
    /// consulted for shortcuts. The real ⌘D and ⇧⌘D live in the Pane menu in
    /// `AppDelegate`; these are here so the menu tells the user they exist.
    private func paneItem(
        _ title: String, key: String, flags: NSEvent.ModifierFlags, action: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ClosureTarget.fire), keyEquivalent: key)
        item.keyEquivalentModifierMask = flags
        let target = ClosureTarget(action)
        item.target = target
        item.representedObject = target // the item is the only owner
        return item
    }

    private final class ClosureTarget: NSObject {
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }

    #if DEBUG
        /// `/paste?run=1&session=…`, for driving ⌘V without a pointer.
        ///
        /// The route exists because synthesising ⌘V needs an Accessibility
        /// grant an agent's shell does not have. It names its session for a
        /// reason paid for on 2026-07-28: acting on "whatever is on screen" put
        /// a test paste of an image into the user's own working session,
        /// because the person at the machine switched between the select and
        /// the run.
        func debugPasteIntoActivePane() -> Bool {
            guard let paneID = activePaneID else { return false }
            return pastePasteboard(into: paneID)
        }
    #endif
}
