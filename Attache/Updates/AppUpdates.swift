//
//  AppUpdates.swift
//  Attache
//

import Combine
import Sparkle

// The app's one Sparkle updater, wrapped so the SwiftUI About page and the App
// menu can drive it without either one owning Sparkle.
//
// Sparkle keeps its own state — whether automatic checks are on, when it last
// looked — in UserDefaults, under its own keys. That is deliberately *not*
// routed through `SettingsFile`/attache.toml. It is the framework's private
// bookkeeping, the same kind of thing as the window frames AppKit writes into
// the plist: not one of the app's own preferences, and nothing the person edits
// their config to change. Do not "fix" it into SettingsFile.

@MainActor
final class AppUpdates: ObservableObject {
    static let shared = AppUpdates()

    private let controller: SPUStandardUpdaterController

    /// False while a check is already running, so the button can disable itself
    /// rather than stack checks. Sparkle is the only thing that knows, so this
    /// tracks its `canCheckForUpdates` by KVO.
    @Published private(set) var canCheck: Bool

    /// Mirror of Sparkle's automatic-check preference, for the About toggle.
    @Published private(set) var automaticallyChecks: Bool

    private var canCheckObserver: NSKeyValueObservation?

    private init() {
        // startingUpdater: true — the updater starts its scheduled-check timer
        // (which does nothing until automatic checks are on) and becomes able to
        // answer a manual check. No delegates: the default user driver puts up
        // Sparkle's own standard update windows.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        canCheck = controller.updater.canCheckForUpdates
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates

        // `canCheckForUpdates` is documented as bind-ready and flips to false for
        // the duration of a check. The observation hops to the main actor before
        // touching a published property.
        canCheckObserver = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    /// Constructing `AppUpdates.shared` is what starts the updater; this is just
    /// an explicit, readable call site for `applicationDidFinishLaunching`.
    func start() {}

    /// A user-initiated check, from the App menu or the About page.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Turn Sparkle's background checking on or off. The write goes to Sparkle,
    /// which persists it; the mirror is updated so the toggle settles.
    func setAutomaticallyChecks(_ on: Bool) {
        controller.updater.automaticallyChecksForUpdates = on
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    }
}
