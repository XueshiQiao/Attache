//
//  TmuxPaneSurface.swift
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

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecameFirstResponder?() }
        return accepted
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// One tmux pane, rendered by one libghostty surface.
///
/// The surface never learns it is talking to tmux. It asks for bytes through
/// the `.inMemory` backend and hands keystrokes back; where those come from
/// and go to is entirely this class's business.
@MainActor
final class TmuxPaneSurface {
    let paneID: String
    let view: TmuxTerminalView
    let terminalSession: InMemoryTerminalSession

    /// Whether this surface has been seeded with tmux's scrollback. Done
    /// once per pane: replaying history again on every resize would stack
    /// duplicate copies of it into the buffer.
    var hasPrimedHistory = false

    /// Cell geometry from the last resize. The pane grid needs it to place
    /// views on the same character grid tmux is laying panes out on.
    private(set) var gridMetrics: TerminalGridMetrics?

    /// Fires on every resize, not just the first. The grid uses it both to
    /// learn the cell size and to keep checking that the surface really ends
    /// up with the column count it was placed for.
    var onGridMetrics: ((TerminalGridMetrics) -> Void)?
    /// This pane took the keyboard, so tmux should be told to make it the
    /// active one. Carries the pane id because the view does not know it.
    var onFocusRequested: ((String) -> Void)?

    private let sendKeys: (String, Data) -> Void
    private var delegateBox: DelegateBox?

    init(
        paneID: String,
        controller: TerminalController,
        sendKeys: @escaping (String, Data) -> Void
    ) {
        self.paneID = paneID
        self.sendKeys = sendKeys

        view = TmuxTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        // The surface's own resize callback is deliberately NOT wired to
        // `refresh-client`: a pane's size is decided by tmux's layout, not by
        // how big this particular view happens to be. Only the whole grid
        // reports its size to tmux, in TmuxSessionConnection.
        //
        // This channel is the pane's keyboard, so only what the user typed is
        // allowed down it. libghostty also answers on it as a terminal in its
        // own right — device attributes, cursor position, and a pointer report
        // on every refresh once a program turns on mouse tracking — and tmux,
        // which really is the pane's terminal, has already answered. See
        // `TerminalReply`.
        terminalSession = InMemoryTerminalSession(
            write: { data in
                guard !TerminalReply.isEntirelyReplies(data) else {
                    #if DEBUG
                        // An explicit caller: `#function` would resolve to the
                        // initializer this closure was built in, and a log
                        // whose purpose is "who sent it" must not name the
                        // wrong place.
                        TmuxLog.lifecycle(
                            "withheld \(paneID) — \(OutboundShape.describe(data))",
                            caller: "TmuxPaneSurface.terminalWrite"
                        )
                    #endif
                    return
                }
                #if DEBUG
                    TmuxLog.lifecycle(
                        "outbound \(paneID) — \(OutboundShape.describe(data))",
                        caller: "TmuxPaneSurface.terminalWrite"
                    )
                #endif
                Task { @MainActor in sendKeys(paneID, data) }
            },
            resize: { _ in }
        )

        let box = DelegateBox(owner: self)
        delegateBox = box
        view.delegate = box
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("tmux pane \(paneID)")
        // After every stored property is set, because the closure captures
        // `self`. The id is captured too rather than read back, so the closure
        // needs nothing from a surface that may already be going away.
        let id = paneID
        view.onBecameFirstResponder = { [weak self] in self?.onFocusRequested?(id) }
    }

    /// Hidden panes stay attached to tmux and keep receiving output, so
    /// switching back to a window shows current content with no reload. Only
    /// the GPU-side surface is released.
    func setVisible(_ visible: Bool) {
        view.setSurfaceVisible(visible)
    }

    fileprivate func gridDidResize(_ metrics: TerminalGridMetrics) {
        gridMetrics = metrics
        onGridMetrics?(metrics)
    }

    /// AppKit delegates are unowned-unsafe in libghostty's view, and a
    /// `TerminalView` outlives individual callbacks, so the conformance lives
    /// on a separate object the surface owns rather than on the surface
    /// itself. That keeps the retain graph one-directional.
    private final class DelegateBox: NSObject, TerminalSurfaceGridResizeDelegate {
        weak var owner: TmuxPaneSurface?
        init(owner: TmuxPaneSurface) { self.owner = owner }

        func terminalDidResize(_ size: TerminalGridMetrics) {
            owner?.gridDidResize(size)
        }
    }
}
