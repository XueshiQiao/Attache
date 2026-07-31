//
//  EmbeddedSessionViewController.swift
//  TmuxGUI
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
    let connection: TmuxSessionConnection

    private let titleBand = TitleBandView(frame: .zero)
    /// `TmuxTerminalView`, not a second class of its own.
    ///
    /// It was one at first, carrying copies of the two AppKit overrides the
    /// pane surfaces had already paid for — and the copy silently lacked the
    /// third thing that view does: the right-click handling. Reported as "the
    /// pane menu is gone". Two views that must behave identically are one view.
    private let terminalView: TmuxTerminalView

    /// Builds the pane menu for a right-click. Set by whoever knows which
    /// controller holds the model; this half deliberately does not.
    var contextMenu: (() -> NSMenu?)?
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

    /// Set from the surface's own resize callback, which is the only place a
    /// cell height can be had — it is font-derived, so it does not move unless
    /// the font does, and the overhang constraint below can safely depend on
    /// it.
    private var cellHeight: CGFloat = 0
    private var overhang: NSLayoutConstraint?


    init(connection: TmuxSessionConnection, tmuxPath: String) {
        self.connection = connection
        statusRows = Self.statusLines(tmuxPath: tmuxPath, sessionID: connection.sessionID)

        let base = TerminalConfiguration(startingFrom: .default) { builder in
            builder.withBackgroundOpacity(0)
            builder.withCustom("window-padding-x", "0")
            builder.withCustom("window-padding-y", "0")
            builder.withCustom("window-padding-balance", "false")
            // Single-quoted, and that is not decoration: ghostty hands this
            // value to `/bin/sh -c`, and a session id *is* `$N` — unquoted,
            // the shell expands `$34` to nothing and the attach silently
            // targets whatever is current. A tmux id matches `[$@%]\d+` and so
            // cannot carry a quote of its own, which is what makes quoting it
            // safe rather than merely hopeful — the same reason this project
            // targets tmux by id everywhere.
            builder.withCustom("command", "\(tmuxPath) attach -t '\(connection.sessionID)'")
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
                equalToConstant: SessionViewController.titleBandHeight
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
        terminalView.onContextMenu = { [weak self] in self?.contextMenu?() }

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

    /// Copy whatever is selected in the embedded terminal.
    ///
    /// libghostty's selection is internal to the surface, so this is the only
    /// side that can ask for it — which is why the pane menu takes it as a
    /// closure rather than reaching for a surface this half does not have.
    func copySelection() {
        terminalView.copySelectedTextToPasteboard()
    }

    func applyChromeTheme() {
        titleBand.applyChromeTheme()
    }

    /// Asks tmux how many rows its status line occupies for this session.
    ///
    /// Synchronous and one-shot, on purpose: it runs once per session
    /// controller, and the answer has to be in hand before the first frame or
    /// the status line shows through. `#{status_lines}` would be the obvious
    /// format and does not exist on 3.6a — measured, it expands to nothing —
    /// so the option itself is read. It answers `off`, `on`, or a count.
    private static func statusLines(tmuxPath: String, sessionID: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["show-options", "-v", "-t", sessionID, "status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return 1
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "off": return 0
        case "on", "": return 1
        default: return Int(value) ?? 1
        }
    }

    private func gridDidResize(_ metrics: TerminalGridMetrics) {
        // Device pixels on the way in — the same unit `PaneGridView` counts in,
        // and the same conversion back to points.
        let scale = max(view.window?.backingScaleFactor ?? 1, 1)
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

    /// libghostty holds its delegate unowned-unsafe, so the conformance lives
    /// on an object this controller owns rather than on the controller itself —
    /// the same arrangement `TmuxPaneSurface` uses and for the same reason.
    private final class DelegateBox: NSObject, TerminalSurfaceGridResizeDelegate {
        weak var owner: EmbeddedSessionViewController?
        init(owner: EmbeddedSessionViewController) { self.owner = owner }

        func terminalDidResize(_ size: TerminalGridMetrics) {
            owner?.gridDidResize(size)
        }
    }
}

// The surface class this file used to declare is gone: `TmuxTerminalView` is
// the one view both content halves use. See the comment on `terminalView`.
