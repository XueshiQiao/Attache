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

    // Nothing here copies a selection. Copy-on-select is libghostty's, through
    // the `copy-on-select` key in the terminal configuration — see
    // `AppSettings.terminalConfiguration`. A copy made here as well is what made
    // the setting do the opposite of what it said. The mouse overrides below
    // rewrite modifiers and hand the event straight on; none of them acts on a
    // selection.

    // MARK: - Links under the pointer

    /// The gesture that makes a path or URL under the pointer clickable, or nil
    /// when the feature is off. Set by whoever reads the settings; the view
    /// deliberately does not, the same arrangement `onDropText` uses.
    ///
    /// Why the event is rewritten at all is on `TerminalLinkGesture`.
    var linkGesture: (() -> TerminalLinkGesture?)?

    /// Where the last press carrying the configured gesture landed, in this
    /// view's coordinates, and nil for a press that did not carry it.
    ///
    /// Two jobs, and the second one is a guard. libghostty's open-URL callback
    /// carries the matched string and nothing else — no pane, no point — so a
    /// *relative* match like `src/main.swift` has no directory to resolve
    /// against without this. And nil is what tells the controller to ignore an
    /// open it never asked for: ⇧⌘ reaches Ghostty's own link handling
    /// whatever this app does, so with the feature switched off — or with a
    /// different gesture configured — a ⇧⌘-click would still open things
    /// unless the acting end checks that the press was one of ours.
    private(set) var lastLinkPress: NSPoint?

    /// Only a real move is rewritten here, and the type check is the whole
    /// point of the guard.
    ///
    /// libghostty's own `mouseDragged` ends by calling `mouseMoved(with:)` —
    /// a virtual call, so it lands in this override carrying a
    /// `.leftMouseDragged` event. Without the check, a plain drag that the
    /// press did *not* rewrite would start being rewritten the moment the user
    /// pressed the modifier mid-drag, which is exactly the split sequence
    /// `pressWasRewritten` exists to prevent: tmux would have the press and the
    /// release while libghostty quietly kept the motion in between.
    override func mouseMoved(with event: NSEvent) {
        guard event.type == .mouseMoved else {
            super.mouseMoved(with: event)
            return
        }
        super.mouseMoved(with: linkMouseEvent(from: event) ?? event)
    }

    /// Whether the press that is currently down was rewritten.
    ///
    /// A press, the drags that follow it and its release are one gesture and
    /// have to arrive at one consumer. libghostty decides *per event* whether
    /// ⇧ takes that event away from the program in the terminal, so rewriting
    /// only the press splits the sequence in two: the press is handled locally
    /// while an unrewritten drag is still eligible to be reported onward, and
    /// the program is then sent motion with no button-press under it.
    ///
    /// That mouse input reaches tmux at all is measured rather than assumed —
    /// clicking a window's name in tmux's own status line switches windows in
    /// this app, 2026-07-31. The note in CLAUDE.md saying no mouse button
    /// reaches a pane was true of the pane renderer and is not true now.
    private var pressWasRewritten = false

    override func mouseDown(with event: NSEvent) {
        let translated = linkMouseEvent(from: event)
        pressWasRewritten = translated != nil
        lastLinkPress = translated == nil ? nil : convert(event.locationInWindow, from: nil)
        super.mouseDown(with: translated ?? event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: pressWasRewritten ? forcedLinkEvent(from: event) : event)
    }

    override func mouseUp(with event: NSEvent) {
        let continuing = pressWasRewritten
        pressWasRewritten = false
        super.mouseUp(with: continuing ? forcedLinkEvent(from: event) : event)
    }

    // There is deliberately no `flagsChanged` override, and getting here took
    // two wrong turns worth recording.
    //
    // Rewriting the modifier event was the first. The synthesised event keeps
    // the physical key's `keyCode` while carrying different flags, and
    // libghostty reads press-versus-release off whether that key is in the
    // flags — so a press can arrive as the release of a key that is still
    // held, and a program using a keyboard protocol that reports modifiers is
    // told about an event that never happened.
    //
    // Synthesising a *mouse move* on a modifier change was the second, and it
    // is no better: libghostty passes a move to its cursor-position API, which
    // is the same path that reports the pointer to the program. Pressing ⌘
    // while a mouse-reporting program sits under the pointer would send it
    // motion the user never made — the same class of defect as the 705
    // unrequested mouse reports recorded in CLAUDE.md, and there is no filter
    // left in the way, because `TerminalReply` lost its call sites when the
    // pane renderer was deleted.
    //
    // So neither exists, and the cost is one honest limitation: holding the
    // modifier without moving the pointer does not light up the link under it
    // until the pointer moves a pixel.

    private func linkModifiers(for event: NSEvent) -> NSEvent.ModifierFlags? {
        // `mouseMoved` is the hottest path in the app — it fires for every
        // pixel of pointer travel across a pane — and a bare move carries no
        // modifier at all. Testing the flags first means the ordinary case
        // costs one mask-and-compare and never reaches the settings store,
        // which is two dictionary lookups and a string-to-enum away.
        guard !event.modifierFlags.intersection(TerminalLinkGesture.considered).isEmpty,
              let gesture = linkGesture?()
        else { return nil }
        return gesture.ghosttyFlags(for: event.modifierFlags)
    }

    private func linkMouseEvent(from event: NSEvent) -> NSEvent? {
        guard let flags = linkModifiers(for: event) else { return nil }
        return mouseEvent(from: event, flags: flags)
    }

    /// Carry on a rewritten sequence whatever is being held *now*: the modifier
    /// can be let go mid-drag, and the release still has to reach the consumer
    /// its press went to.
    private func forcedLinkEvent(from event: NSEvent) -> NSEvent {
        mouseEvent(from: event, flags: TerminalLinkGesture.ghosttyEquivalent) ?? event
    }

    private func mouseEvent(from event: NSEvent, flags: NSEvent.ModifierFlags) -> NSEvent? {
        // `clickCount` raises on an event that has none — a bare move is not a
        // click — so it is read only for the types that carry one.
        let clicks: Int
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            clicks = event.clickCount
        default:
            clicks = 0
        }
        return NSEvent.mouseEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: flags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: clicks,
            pressure: event.pressure
        )
    }


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
    /// **That was true and is not any more.** Measured 2026-07-29 with htop in
    /// a pane and the surface's write callback logged, neither a right-click
    /// nor a left click produced a single outbound byte — but that was the pane
    /// renderer, where this app sat between the surface and tmux. On the
    /// `tmux attach` surface mouse input arrives: clicking a window's name in
    /// tmux's own status line switches windows, measured 2026-07-31. So this
    /// menu *is* taking a right-click away from the program in the pane, which
    /// is what ⌥ right-click exists to give back.
    ///
    /// ⌥ is kept for that reason rather than as a road left open, at the cost
    /// of one condition. The gesture that reaches the pane already exists and nothing
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
