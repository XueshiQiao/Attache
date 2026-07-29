//
//  ActivationProbe.swift
//  TmuxGUI
//

import AppKit

/// Records whether this app is the one the user's keyboard reaches.
///
/// Exists because of 2026-07-29: the app looked completely frozen — no
/// typing, no clicks — while rendering happily, main thread idle, every
/// subsystem healthy. It had merely stopped being the active application
/// (an external tool pulled activation away on every `select-pane` hook),
/// and nothing in the app had ever recorded that it was active in the first
/// place, so the one-line answer took an hour to find.
///
/// Self-subscribing: nothing in the app calls this beyond `start()`. It
/// observes and reports into `DiagnosticsCenter`'s activation ring, where
/// every snapshot picks it up — it never raises a toast itself, because
/// losing activation is exactly the moment a toast in this app cannot be
/// seen.
final class ActivationProbe {
    static let shared = ActivationProbe()

    private var started = false

    /// KVO on the key window's first responder. Re-established each time key
    /// changes, released when it resigns; `NSWindow.firstResponder` is
    /// KVO-observable and the observation is dropped with the token.
    private var responderObservation: NSKeyValueObservation?

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(appActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(appInactive),
            name: NSApplication.didResignActiveNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(windowKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(windowResignedKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil
        )
        // The workspace one is what names the thief. When activation is being
        // pulled away, the transitions of *this* app say only "lost it again";
        // which application took it is the whole diagnosis.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        DiagnosticsCenter.shared.recordActivation("probe started")
    }

    @objc private func appActive() {
        DiagnosticsCenter.shared.recordActivation("app became active")
    }

    @objc private func appInactive() {
        DiagnosticsCenter.shared.recordActivation("app resigned active")
    }

    @objc private func windowKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DiagnosticsCenter.shared.recordActivation("window became key: \(window.title)")
        observeFirstResponder(of: window)
    }

    @objc private func windowResignedKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DiagnosticsCenter.shared.recordActivation("window resigned key: \(window.title)")
        responderObservation = nil
    }

    @objc private func frontAppChanged(_ notification: Notification) {
        let name = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication)?.localizedName ?? "unknown"
        DiagnosticsCenter.shared.recordActivation("front application → \(name)")
    }

    private func observeFirstResponder(of window: NSWindow) {
        responderObservation = window.observe(\.firstResponder) { _, _ in
            // Class name only. The responder is often a terminal view, and the
            // view deliberately does not know its pane id — see
            // `TmuxTerminalView` — so there is nothing more specific to say.
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            DispatchQueue.main.async {
                DiagnosticsCenter.shared.recordActivation("first responder → \(responder)")
            }
        }
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        DiagnosticsCenter.shared.recordActivation("first responder → \(responder)")
    }
}
