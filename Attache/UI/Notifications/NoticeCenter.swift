//
//  NoticeCenter.swift
//  Attache
//

import Cocoa

/// Puts notices on screen: top-right of the main window, sliding in, stacking
/// downward, dismissing themselves.
///
/// One consistent surface for every producer — see `AppNotice`. Presentation
/// choices live here and nowhere else, so the next producer gets the same
/// pixels by construction.
///
/// The toasts live in a borderless child window rather than in the main
/// window's view tree, for two reasons that are both scars: the content view
/// is an `NSSplitView` whose subview list `NSSplitViewController` owns (a
/// stray sibling there has undefined layout), and on macOS 26 a drawing
/// sibling's backing layer overdraws 66 pt past itself with last-added
/// winning — a hierarchy this app already lost a day to. A child window is
/// above all of it by construction, moves with its parent for free, and its
/// transparent regions pass clicks through to the window below, so the panes
/// stay clickable right up to a toast's actual edge.
@MainActor
final class NoticeCenter {
    static let shared = NoticeCenter()

    private struct Shown {
        let view: ToastView
        let dismissTimer: Timer
    }

    private var shown = [Shown]()
    private var overlay: NSWindow?
    private weak var parent: NSWindow?

    /// Enough to read, few enough to not wallpaper the panes. Oldest goes
    /// first when a fifth arrives.
    private let stackCap = 4

    private let topOffset: CGFloat = 40 // below the 28 pt title band, plus air
    private let trailingMargin: CGFloat = 12
    private let gap: CGFloat = 8

    /// Notices that arrived before there was a window to put them over.
    ///
    /// **Dropping these was a real defect and exactly the kind this whole
    /// feature exists to remove.** `TmuxChildRegistry.sweep()` runs at launch,
    /// deliberately before the first connection and therefore before the window
    /// exists, and its "cleaned up after a previous run" notice went straight
    /// into the `guard` below and vanished — found 2026-07-30 by provoking a
    /// reclaim and watching for a toast that never came. A producer must not
    /// have to know how early it is; anything that arrives before there is
    /// somewhere to draw waits here and goes up when there is.
    ///
    /// Capped, and the newest win. A launch that somehow produced hundreds of
    /// notices should not open with a wall of them, and the last few are the
    /// ones still worth reading.
    private var pending = [AppNotice]()
    private let pendingCap = 4

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(parentChanged(_:)),
            name: NSWindow.didResizeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(parentClosing(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
        // A window appearing is what makes a held notice showable. `didBecomeKey`
        // rather than `didBecomeMain`: a window that is ordered front on launch
        // gets both, and this one also fires when the app is brought back from
        // another application, which is a second chance to flush.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowAppeared(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
    }

    /// Put up anything that was waiting for a window. Safe to call whenever;
    /// with an empty queue it does nothing.
    @objc private func windowAppeared(_: Notification) {
        guard !pending.isEmpty, targetWindow() != nil else { return }
        let held = pending
        pending.removeAll()
        for notice in held { post(notice) }
    }

    func post(_ notice: AppNotice) {
        guard let window = targetWindow() else {
            pending.append(notice)
            if pending.count > pendingCap { pending.removeFirst(pending.count - pendingCap) }
            return
        }
        ensureOverlay(over: window)

        let toast = ToastView(notice: notice)
        toast.onDismiss = { [weak self, weak toast] in
            guard let self, let toast else { return }
            self.dismiss(toast)
        }

        while shown.count >= stackCap {
            dismiss(shown[0].view, animated: false)
        }

        // An error is the app saying a connection is unusable; it stays a
        // little longer because the person it is for has, by definition, just
        // had their attention somewhere else.
        let duration: TimeInterval = notice.severity == .error ? 8 : 6
        let timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) {
            [weak self, weak toast] _ in
            MainActor.assumeIsolated {
                guard let self, let toast else { return }
                self.dismiss(toast)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shown.append(Shown(view: toast, dismissTimer: timer))

        overlay?.contentView?.addSubview(toast)
        layout(animated: true, arriving: toast)
    }

    // MARK: - Dismissal

    private func dismiss(_ toast: ToastView, animated: Bool = true) {
        guard let index = shown.firstIndex(where: { $0.view === toast }) else { return }
        shown[index].dismissTimer.invalidate()
        shown.remove(at: index)

        guard animated else {
            toast.removeFromSuperview()
            layout(animated: false, arriving: nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            toast.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                toast.removeFromSuperview()
                self.layout(animated: true, arriving: nil)
            }
        }
    }

    // MARK: - Placement

    /// The window notices belong over: the main window when there is one, and
    /// otherwise the largest visible ordinary window — which is the main
    /// window again in the one real case (`mainWindow` is nil whenever the
    /// app is not active, and an inactive app is exactly when the deaf-channel
    /// toast fires).
    private func targetWindow() -> NSWindow? {
        if let main = NSApp.mainWindow, !(main is NSPanel) { return main }
        return NSApp.windows
            .filter { $0.isVisible && !($0 is NSPanel) && $0 !== overlay }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func ensureOverlay(over window: NSWindow) {
        if overlay != nil, parent === window { return }
        teardownOverlay()

        let child = NSWindow(
            contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false
        )
        child.isOpaque = false
        child.backgroundColor = .clear
        child.hasShadow = false // each toast casts its own
        child.isReleasedWhenClosed = false
        child.ignoresMouseEvents = false
        child.contentView = FlippedContainer()
        window.addChildWindow(child, ordered: .above)
        overlay = child
        parent = window
    }

    private func teardownOverlay() {
        for entry in shown { entry.dismissTimer.invalidate() }
        shown.removeAll()
        if let overlay {
            parent?.removeChildWindow(overlay)
            overlay.orderOut(nil)
        }
        overlay = nil
        parent = nil
    }

    /// Frame the overlay to wrap the stack exactly and place each toast.
    ///
    /// The overlay is sized to the toasts and nothing more, because its
    /// transparent area still belongs to a window: keeping it minimal keeps
    /// the pass-through question confined to the 8 pt gaps instead of a whole
    /// quadrant of the panes.
    private func layout(animated: Bool, arriving: ToastView?) {
        guard let overlay, let parent else { return }
        guard !shown.isEmpty else {
            overlay.setFrame(.zero, display: false)
            return
        }

        let stackHeight = shown.reduce(0) { $0 + $1.view.frame.height }
            + gap * CGFloat(shown.count - 1)
        let width = ToastView.width
        let origin = NSPoint(
            x: parent.frame.maxX - width - trailingMargin,
            y: parent.frame.maxY - topOffset - stackHeight
        )
        overlay.setFrame(
            NSRect(origin: origin, size: NSSize(width: width, height: stackHeight)),
            display: true
        )

        // Container is flipped: y runs downward, newest toast lowest.
        var y: CGFloat = 0
        for entry in shown {
            let target = NSRect(
                x: 0, y: y, width: width, height: entry.view.frame.height
            )
            if entry.view === arriving {
                // Slide in from the right edge, fading up.
                entry.view.frame = target.offsetBy(dx: 24, dy: 0)
                entry.view.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    entry.view.animator().frame = target
                    entry.view.animator().alphaValue = 1
                }
            } else if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    entry.view.animator().frame = target
                }
            } else {
                entry.view.frame = target
            }
            y += entry.view.frame.height + gap
        }
    }

    @objc private func parentChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === parent else { return }
        layout(animated: false, arriving: nil)
    }

    @objc private func parentClosing(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === parent else { return }
        teardownOverlay()
    }

    private final class FlippedContainer: NSView {
        override var isFlipped: Bool { true }
    }
}
