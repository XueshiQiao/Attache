//
//  SettingsWindowController.swift
//  TmuxGUI
//

import Cocoa
import Combine
import GhosttyTheme
import SwiftUI

// MARK: - SettingsStore
//
// The single source of truth the settings UI binds to. It mirrors `AppSettings`
// into `@Published` properties so SwiftUI has something to observe, and every
// change goes back out through exactly one path per setting:
//
//   1. `AppSettings` (the UserDefaults write, so it survives relaunch),
//   2. the published mirror (so the control it came from settles),
//   3. `AppSettings.notifyChanged()` (so open surfaces react without a relaunch).
//
// The views stay dumb: they read these properties and call the `set*` methods.
// The store owns the rules — clamping, and pinning the process appearance when
// the user overrides it.

@MainActor
final class SettingsStore: ObservableObject {

    /// Which sidebar page is showing. Kept here rather than in `@State` so it
    /// survives the window being closed and reopened.
    @Published var page: SettingsPage = .terminal

    // ─── Mirrors of AppSettings ──────────────────────────────────────────────
    @Published private(set) var fontFamily: String
    @Published private(set) var fontSize: Double
    @Published private(set) var appearance: AppSettings.Appearance
    @Published private(set) var lightThemeName: String
    @Published private(set) var darkThemeName: String
    @Published private(set) var scrollbackPrimeLines: Int
    @Published private(set) var sidebarWidth: CGFloat
    @Published private(set) var closingTabKillsWindow: Bool

    // ─── Throughput probe (About page) ───────────────────────────────────────
    @Published private(set) var isProbing = false
    @Published private(set) var probeReport: String?

    /// Runs the control-mode probe against whichever session is on screen.
    /// Injected so the settings layer never reaches into the tmux layer.
    private let probe: (@escaping (String) -> Void) -> Void

    init(probe: @escaping (@escaping (String) -> Void) -> Void) {
        self.probe = probe
        fontFamily = AppSettings.fontFamily
        fontSize = AppSettings.fontSize
        appearance = AppSettings.appearance
        lightThemeName = AppSettings.lightThemeName
        darkThemeName = AppSettings.darkThemeName
        scrollbackPrimeLines = AppSettings.scrollbackPrimeLines
        sidebarWidth = AppSettings.sidebarWidth
        closingTabKillsWindow = AppSettings.closingTabKillsWindow
    }

    // MARK: Font

    func setFontFamily(_ family: String) {
        AppSettings.fontFamily = family
        fontFamily = AppSettings.fontFamily
        AppSettings.notifyChanged()
    }

    func setFontSize(_ size: Double) {
        AppSettings.fontSize = size.rounded()
        fontSize = AppSettings.fontSize
        AppSettings.notifyChanged()
    }

    func resetFontSize() { setFontSize(AppSettings.defaultFontSize) }

    /// Monospaced families only. A proportional font in a terminal makes every
    /// column measurement meaningless, and the grid this app places panes on
    /// is counted in cells.
    static let monospacedFontFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    // MARK: Appearance and theme

    func setAppearance(_ value: AppSettings.Appearance) {
        AppSettings.appearance = value
        appearance = value
        // Pin the process first: the chrome derives from whichever half of the
        // theme is showing, and that is read back off the effective appearance.
        AppSettings.applyAppearanceOverride()
        AppSettings.notifyChanged()
    }

    func setLightThemeName(_ name: String) {
        AppSettings.lightThemeName = name
        lightThemeName = name
        AppSettings.notifyChanged()
    }

    func setDarkThemeName(_ name: String) {
        AppSettings.darkThemeName = name
        darkThemeName = name
        AppSettings.notifyChanged()
    }

    /// Every scheme in the catalog, in one alphabetical list the picker walks.
    /// Adding a scheme upstream adds a row here and touches nothing else.
    static let allThemes: [GhosttyThemeDefinition] = GhosttyThemeCatalog.allThemes
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    static func themes(matching query: String) -> [GhosttyThemeDefinition] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return allThemes }
        return allThemes.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    // MARK: Behaviour

    func setScrollbackPrimeLines(_ lines: Int) {
        AppSettings.scrollbackPrimeLines = lines
        scrollbackPrimeLines = AppSettings.scrollbackPrimeLines
        AppSettings.notifyChanged()
    }

    func resetScrollbackPrimeLines() { setScrollbackPrimeLines(AppSettings.defaultScrollbackPrimeLines) }

    func setSidebarWidth(_ width: CGFloat) {
        AppSettings.sidebarWidth = width.rounded()
        sidebarWidth = AppSettings.sidebarWidth
        AppSettings.notifyChanged()
    }

    func resetSidebarWidth() { setSidebarWidth(AppSettings.defaultSidebarWidth) }

    func setClosingTabKillsWindow(_ kills: Bool) {
        TmuxLog.destructive(
            kills
                ? "closing a tab will now KILL its tmux window — every process in it, no undo"
                : "closing a tab hides it again; tmux is left alone"
        )
        AppSettings.closingTabKillsWindow = kills
        closingTabKillsWindow = kills
        AppSettings.notifyChanged()
    }

    // MARK: Throughput probe

    func runThroughputProbe() {
        guard !isProbing else { return }
        isProbing = true
        probeReport = nil
        // The probe's own completion is not guaranteed to land on the main
        // thread — the control client delivers replies on its reader queue and
        // only the success path detours through a main-queue timer — so the
        // hop is made here rather than assumed anywhere upstream.
        probe { [weak self] report in
            Task { @MainActor in
                guard let self else { return }
                self.isProbing = false
                self.probeReport = report
            }
        }
    }
}

// MARK: - SettingsWindowController
//
// Hosts `SettingsRootView` in a plain window. Closing hides rather than
// terminates: the app's real window is somewhere behind this one and quitting
// because settings were dismissed would detach every tmux session.

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let store: SettingsStore

    init(probe: @escaping (@escaping (String) -> Void) -> Void) {
        store = SettingsStore(probe: probe)

        // An AppKit split view controller rather than SwiftUI's
        // `NavigationSplitView`. On macOS 26 the SwiftUI one draws the sidebar
        // as an inset rounded panel and leaves the traffic lights in a band
        // above it; the standard sidebar runs the full height of the window
        // with the lights inside it. `NSSplitViewItem(sidebarWithViewController:)`
        // is what produces that, and it also brings the sidebar material the
        // panel version does not have. The pages stay SwiftUI — only who owns
        // the split changed.
        let split = NSSplitViewController()
        // Plain item plus our own material, not `sidebarWithViewController:`.
        // The sidebar behaviour draws an inset rounded panel on macOS 26, which
        // is what left the traffic lights in a band above the grey instead of
        // inside it — the same thing the main window's rail was reported for.
        let sidebarHost = NSHostingController(
            rootView: SettingsSidebarView().environmentObject(store)
        )
        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        sidebarHost.view.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(sidebarHost.view)
        NSLayoutConstraint.activate([
            sidebarHost.view.topAnchor.constraint(equalTo: backdrop.topAnchor),
            sidebarHost.view.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            sidebarHost.view.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            sidebarHost.view.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        let sidebarShell = NSViewController()
        sidebarShell.view = backdrop
        sidebarShell.addChild(sidebarHost)
        let sidebarItem = NSSplitViewItem(viewController: sidebarShell)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 240
        // Full-height layout is the part that puts the traffic lights over the
        // sidebar instead of above it.
        sidebarItem.titlebarSeparatorStyle = .none
        split.addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(
            viewController: NSHostingController(
                rootView: SettingsDetailView().environmentObject(store)
            )
        )
        detailItem.titlebarSeparatorStyle = .none
        split.addSplitViewItem(detailItem)

        window = NSWindow(contentViewController: split)
        window.title = "TmuxGUI Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        // No `toolbarStyle`. This window has no toolbar, and asking for the
        // unified style without one reserves the title-bar band anyway — which
        // is what pushed the sidebar down and left the traffic lights sitting
        // above the grey instead of inside it. The main window never set it and
        // never had the problem.
        window.setContentSize(NSSize(width: 820, height: 620))
        window.setFrameAutosaveName("TmuxGUISettings")
        window.center()
        super.init()
        window.delegate = self
    }

    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }

    #if DEBUG
        /// Force the SwiftUI tree to be built and hand back its root view,
        /// without the window ever being ordered in. See
        /// `DebugInspector.settingsWindowBody`.
        func debugBuildOffScreen(page: SettingsPage) -> NSView {
            store.page = page
            return window.contentViewController!.view
        }
    #endif
}
