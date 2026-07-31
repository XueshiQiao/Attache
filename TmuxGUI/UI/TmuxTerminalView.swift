//
//  TmuxTerminalView.swift
//  TmuxGUI
//

import Cocoa
import GhosttyTerminal

/// A terminal surface that lets the app's menu claim ⌘ combinations first.
///
/// libghostty's view treats ⌘ keys as candidates for its own keybinds and
/// consumes them before the main menu is consulted, which silently kills ⌘T,
/// ⌘W and ⌘0-9. Those are the native half of the promise that a tmux `prefix`
/// binding and a Mac shortcut both work, so the menu gets first refusal and
/// the terminal only sees what the menu declines. ⌘C and ⌘V still reach the
/// terminal because the Edit menu routes them back down the responder chain.
final class TmuxTerminalView: TerminalView {
    /// This surface has taken the keyboard.
    ///
    /// The only reliable place to learn that a pane was clicked. The pane grid
    /// hands every point that is not on a splitter to the surface underneath,
    /// so a click inside a pane never reaches the grid's own `mouseDown` — its
    /// `onPaneClicked` fires for gaps and nothing else. Meanwhile the surface
    /// quietly becomes first responder and the keystrokes start going there.
    /// That divergence is what left the focus ring on the pane the app had
    /// guessed while the typing went somewhere else.
    var onBecameFirstResponder: (() -> Void)?

    /// Text a drop wants put into this pane, answering whether the pane took
    /// it. Set by whoever knows the pane id; the view deliberately does not.
    var onDropText: ((String) -> Bool)?

    /// The menu a right-click in this pane should open, or nil to leave the
    /// event to libghostty. Set by whoever knows the pane id; the view
    /// deliberately does not, the same arrangement `onDropText` uses.
    var onContextMenu: (() -> NSMenu?)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecameFirstResponder?() }
        return accepted
    }

    // MARK: - Dropping a file onto a pane

    /// Accept files and text, which is what a terminal can do something with.
    ///
    /// Nothing in this project registered for any dragged type before
    /// 2026-07-28, so dragging an image out of Finder was refused by the window
    /// outright — the cursor showed the no-drop sign and there was nothing to
    /// debug, because no code ran. Registered on the pane rather than on the
    /// grid so the drop knows which pane it landed in.
    ///
    /// `viewDidMoveToWindow` rather than an initialiser: `TerminalView`'s own
    /// init chain is the library's, and registering is idempotent.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL, .string])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedText(from: sender) == nil ? [] : .copy
    }

    /// Answers with what actually happened. Returning `true` for a drop nobody
    /// took — the callback gone in a teardown, the temporary file refused —
    /// tells AppKit the drop landed and shows the user the accepting animation
    /// over a pane that received nothing.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = droppedText(from: sender) else { return false }
        return onDropText?(text) ?? false
    }

    /// A drag carries its own pasteboard, so it asks the same question ⌘V does
    /// and gets the same answer — except for an image with no file behind it,
    /// which for a paste means "send Ctrl-V and let the program read the system
    /// pasteboard". A dragged image is not *on* the system pasteboard, so that
    /// answer is wrong here and the drop is refused instead.
    private func droppedText(from sender: NSDraggingInfo) -> String? {
        if case let .text(text) = PasteContent.read(from: sender.draggingPasteboard) {
            return text
        }
        return nil
    }

    /// Tell the surface it does not have the keyboard.
    ///
    /// libghostty learns "not focused" from exactly one place —
    /// `resignFirstResponder` — which by definition cannot fire for a surface
    /// that was never focused in the first place. `ghostty_surface_set_focus`
    /// is therefore never called for it and the terminal core keeps its own
    /// default, which is focused: a second pane appearing in a window drew a
    /// solid blinking cursor next to the one that really had the keyboard.
    /// The window is already key by then, so no `windowDidBecomeKey` arrives
    /// to correct it either — which is why clicking any pane fixed it, that
    /// being the first thing to produce a become/resign pair.
    ///
    /// Calling the responder callback by hand is the only channel the library
    /// offers for this. Guarded so it can never contradict AppKit: a view that
    /// really is the first responder keeps its focus, because taking it away
    /// would leave keystrokes arriving at a surface that believes it is not
    /// being typed into.
    func relinquishFocusIfNotFirstResponder() {
        guard window?.firstResponder !== self else { return }
        _ = resignFirstResponder()
    }

    /// A press in a pane belongs to the pane.
    ///
    /// Without this the window is dragged instead, and libghostty's selection
    /// never sees a single event: `AppDelegate` sets
    /// `isMovableByWindowBackground`, and AppKit asks the hit view this
    /// question *before* delivering `mouseDown`. The default is inherited and
    /// it is yes, so a view that implements dragging perfectly still gets
    /// nothing — measured on both panes of a split window before this line
    /// existed, while AppKit's own `NSSplitDividerView` in the same window
    /// reported false.
    ///
    /// The rule this is an instance of is at `isMovableByWindowBackground` in
    /// `AppDelegate`: anything that owns a gesture has to say so here.
    override var mouseDownCanMoveWindow: Bool { false }

    // There is deliberately no `mouseUp` here. Copy-on-select is libghostty's,
    // through the `copy-on-select` key in the terminal configuration — see
    // `AppSettings.terminalConfiguration`. A copy made here as well is what made
    // the setting do the opposite of what it said.

    // MARK: - Right-click

    /// Whether the matching `rightMouseUp` belongs to a menu this view opened.
    ///
    /// Set on the way down and cleared at the start of the *next* press rather
    /// than only on the way up, because `popUpContextMenu` runs its own event
    /// loop and swallows the release — so the up half often never arrives and a
    /// flag cleared only there would stay set and eat a later ⌥ right-click's
    /// release instead.
    private var openedOwnMenu = false

    /// Right-click opens the app's menu; ⌥ right-click goes to libghostty.
    ///
    /// The ⌥ half is a road left open rather than one in use. libghostty's
    /// `rightMouseDown` asks its surface to report a right-button press, and
    /// `TerminalReply` would forward one — only bare pointer motion is withheld,
    /// button presses are deliberate acts. Reading that, it looks as though a
    /// program with mouse tracking on receives right-clicks today.
    ///
    /// **It does not.** Measured 2026-07-29 with htop running in a pane and the
    /// surface's write callback logged: neither a right-click nor a plain left
    /// click produced a single outbound byte. Nothing about mouse buttons
    /// reaches a pane in this app at present, so the menu is not taking a
    /// working mechanism away from anyone.
    ///
    /// ⌥ is kept anyway, at the cost of one condition. If pane mouse input is
    /// ever wired up, the gesture that reaches it already exists and nothing
    /// here has to be renegotiated; and a right-click a user wants delivered
    /// rather than answered has somewhere to go.
    ///
    /// Focus is taken exactly as libghostty's own handler took it, so a
    /// right-click moves the active pane the same way it did before this
    /// existed. The menu itself does not need it — every item names its pane by
    /// id — but changing what a right-click does to focus was not the ask.
    override func rightMouseDown(with event: NSEvent) {
        openedOwnMenu = false
        guard !event.modifierFlags.contains(.option), let menu = onContextMenu?() else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        openedOwnMenu = true
        // `popUp(positioning:at:in:)` rather than `NSMenu.popUpContextMenu`,
        // which is the obvious call and the wrong one here: it is the API that
        // enriches a context menu with the system's own items, and this view
        // conforms to `NSTextInputClient` for input-method support — so AppKit
        // appended an **AutoFill** submenu to the pane menu, offering to type a
        // saved password into a terminal. Observed, not guessed at.
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    /// Swallow the release that belongs to a menu this view opened.
    ///
    /// libghostty's `rightMouseUp` sends a mouse *release* report unconditionally.
    /// Letting it run after a press this view kept would hand the program in the
    /// pane a release with no matching press — which for a TUI tracking drags is
    /// a button it thinks is still down being let go at a coordinate nothing
    /// happened at.
    override func rightMouseUp(with event: NSEvent) {
        guard !openedOwnMenu else {
            openedOwnMenu = false
            return
        }
        super.rightMouseUp(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
