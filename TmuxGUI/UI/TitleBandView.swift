//
//  TitleBandView.swift
//  TmuxGUI
//

import Cocoa

/// The window's title bar, restored — and drawn by nobody.
///
/// See `SessionViewController.titleBandHeight` for why the band exists and why
/// it is 28pt. What lives here is the one rule that makes it invisible: this
/// view has no `draw(_:)`. `window.backgroundColor` is already
/// `ChromeTheme.background` and `PaneGridView` fills the same colour, so a view
/// that paints nothing sits over that stack pixel-identical to one painting the
/// theme background — under every scheme the app derives, with no second copy
/// of the colour to keep in step, and with no stake in the macOS 26 overdraw
/// fight between drawing siblings.
///
/// The only thing in it is the active window's name, at the quietest weight the
/// chrome has. A louder title would be the third permanent copy of a string the
/// rail already shows twice, in the heading and in the selected row.
@MainActor
final class TitleBandView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 12pt medium rather than 11pt regular. Recessive is the point of this
        // band, but the first pass took it far enough that the name read as a
        // watermark — quiet has to stay legible at a glance from the far side
        // of a 5K display.
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        label.refusesFirstResponder = true
        addSubview(label)
        applyChromeTheme()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    /// The whole band drags the window. That is what it is for — with the tab
    /// strip gone this is the only thing in the content half that does, and the
    /// window has no system title bar to grab.
    override var mouseDownCanMoveWindow: Bool { true }

    /// Nothing here handles a click, so nothing here can swallow the drag. The
    /// label opts out too; a text field that takes hit tests would leave a dead
    /// strip in the middle of the band where the window stops moving.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    func applyChromeTheme() {
        // `mutedText`, not `faintText`: the faint role is for a count or a
        // hint you read only when you go looking, and this is the one label
        // that says which window the panes belong to.
        label.textColor = ChromeTheme.current.mutedText
    }

    /// The window's name, and only the name.
    ///
    /// No index. The rail already numbers every row, and that number is what
    /// ⌘0-9 addresses — repeating it over the panes made the band read as a
    /// second, competing index rather than as a title.
    ///
    /// `nil` clears it: a session with no active window has nothing to name.
    func show(name: String?) {
        label.stringValue = name ?? ""
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Centred over the panes, the way a title bar centres a title — not
        // over the whole window, because this view spans only the content half
        // and the rail is its own column.
        label.alignment = .center
        label.frame = CGRect(
            x: 12, y: (bounds.height - 16) / 2,
            width: max(0, bounds.width - 24), height: 16
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyChromeTheme() }
    }
}
