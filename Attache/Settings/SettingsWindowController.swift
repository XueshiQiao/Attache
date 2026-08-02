//
//  SettingsWindowController.swift
//  Attache
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
    @Published private(set) var showsPaneFocusRing: Bool
    @Published private(set) var copyOnSelect: Bool
    @Published private(set) var quickActions: [QuickAction]
    @Published private(set) var sidebarShowsGit: Bool
    @Published private(set) var sidebarShowsAgent: Bool
    @Published private(set) var sidebarShowsAgentText: Bool
    @Published private(set) var sidebarShowsAgentStats: Bool
    @Published private(set) var sidebarShowsUsage: Bool
    @Published private(set) var agentStateSource: AgentStateSource
    @Published private(set) var gitAutoFetch: Bool
    @Published private(set) var gitAutoFetchMinutes: Int
    @Published private(set) var hidesConversationWithoutAgent: Bool

    // ─── Agent hook (Behaviour page) ─────────────────────────────────────────
    @Published private(set) var agentHookInstalled = AgentHookInstaller.isInstalled()
    /// Installed, but not what this version installs. See `isUpToDate`.
    @Published private(set) var agentHookNeedsUpdate =
        AgentHookInstaller.isInstalled() && !AgentHookInstaller.isUpToDate()
    /// The exact JSON an install would add, shown before anything is written.
    @Published private(set) var agentHookPlan = (try? AgentHookInstaller.plannedAdditions()) ?? ""
    /// What happened last, including where the backup went. Kept on screen
    /// rather than flashed: the backup path is the thing someone will want an
    /// hour later, and a toast would have taken it away.
    @Published private(set) var agentHookMessage: String?
    @Published private(set) var agentHookFailed = false
    /// True while an install or uninstall is running, so the button can be
    /// disabled. A SwiftUI button fires once per completed click, so a fast
    /// double-click delivers two synchronous runs back to back — which is the
    /// realistic way two backups land in the same wall-clock second.
    @Published private(set) var agentHookBusy = false

    func refreshAgentHookState() {
        agentHookInstalled = AgentHookInstaller.isInstalled()
        agentHookNeedsUpdate = agentHookInstalled && !AgentHookInstaller.isUpToDate()
        agentHookPlan = (try? AgentHookInstaller.plannedAdditions()) ?? ""
    }

    func installAgentHook() {
        guard !agentHookBusy else { return }
        agentHookBusy = true
        defer { agentHookBusy = false }
        do {
            let backup = try AgentHookInstaller.install()
            agentHookFailed = false
            agentHookMessage = "Installed. Your previous settings were copied to "
                + backup.lastPathComponent
                + ". Claude Code picks the hook up on its next session — restart any agent "
                + "that is already running to see its state."
        } catch {
            agentHookFailed = true
            agentHookMessage = error.localizedDescription
        }
        refreshAgentHookState()
    }

    func uninstallAgentHook() {
        guard !agentHookBusy else { return }
        agentHookBusy = true
        defer { agentHookBusy = false }
        do {
            let backup = try AgentHookInstaller.uninstall()
            agentHookFailed = false
            agentHookMessage = "Removed. Your previous settings were copied to "
                + backup.lastPathComponent
                + ". The script is left in ~/.claude/hooks/ and does nothing on its own."
        } catch {
            agentHookFailed = true
            agentHookMessage = error.localizedDescription
        }
        refreshAgentHookState()
    }

    // ─── Status line wrapper (Behaviour page) ────────────────────────────────
    @Published private(set) var statusLineInstalled = AgentStatusLineInstaller.isInstalled()
    /// The command that will be wrapped, shown before anything is written. Nil
    /// means there is no status line — the case that gets a minimal one.
    @Published private(set) var statusLineWrapped = AgentStatusLineInstaller.commandToWrap()
    @Published private(set) var statusLineMessage: String?
    @Published private(set) var statusLineFailed = false
    @Published private(set) var statusLineBusy = false

    func refreshStatusLineState() {
        statusLineInstalled = AgentStatusLineInstaller.isInstalled()
        statusLineWrapped = AgentStatusLineInstaller.commandToWrap()
    }

    func installStatusLine() {
        guard !statusLineBusy else { return }
        statusLineBusy = true
        defer { statusLineBusy = false }
        do {
            let hadOne = AgentStatusLineInstaller.commandToWrap() != nil
            let backup = try AgentStatusLineInstaller.install()
            statusLineFailed = false
            // Measured 2026-07-29 on Claude Code 2.1.220: a session that is
            // already open picks up a changed `statusLine.command` within
            // seconds, so there is deliberately no "restart your agents" here.
            // The hook above does need one, which is why the two messages
            // differ.
            statusLineMessage = (hadOne
                ? "Installed around your existing status line, which still draws exactly as it did. "
                : "Installed. You had no status line, so a minimal one is drawn instead of a blank row. ")
                + "Sessions already running pick it up within a few seconds. Your previous "
                + "settings were copied to " + backup.lastPathComponent + "."
        } catch {
            statusLineFailed = true
            statusLineMessage = error.localizedDescription
        }
        refreshStatusLineState()
    }

    func uninstallStatusLine() {
        guard !statusLineBusy else { return }
        statusLineBusy = true
        defer { statusLineBusy = false }
        do {
            let backup = try AgentStatusLineInstaller.uninstall()
            statusLineFailed = false
            statusLineMessage = "Removed, and your own status line put back. Your previous "
                + "settings were copied to " + backup.lastPathComponent
                + ". The scripts are left in ~/.claude/hooks/ and do nothing on their own."
        } catch {
            statusLineFailed = true
            statusLineMessage = error.localizedDescription
        }
        refreshStatusLineState()
    }

    @Published private(set) var windowOpacity: CGFloat
    @Published private(set) var backgroundBlur: Bool
    @Published private(set) var blurRadius: CGFloat
    @Published private(set) var railExtraTint: CGFloat
    @Published private(set) var frostiness: CGFloat
    @Published private(set) var chromeMaterial: AppSettings.ChromeMaterial
    @Published private(set) var glassStyle: AppSettings.GlassStyle
    @Published private(set) var liquidGlassIsClear: Bool

    init() {
        fontFamily = AppSettings.fontFamily
        fontSize = AppSettings.fontSize
        appearance = AppSettings.appearance
        lightThemeName = AppSettings.lightThemeName
        darkThemeName = AppSettings.darkThemeName
        scrollbackPrimeLines = AppSettings.scrollbackPrimeLines
        sidebarWidth = AppSettings.sidebarWidth
        closingTabKillsWindow = AppSettings.closingTabKillsWindow
        showsPaneFocusRing = AppSettings.showsPaneFocusRing
        copyOnSelect = AppSettings.copyOnSelect
        quickActions = AppSettings.quickActions
        sidebarShowsGit = AppSettings.sidebarShowsGit
        sidebarShowsAgent = AppSettings.sidebarShowsAgent
        sidebarShowsAgentText = AppSettings.sidebarShowsAgentText
        sidebarShowsAgentStats = AppSettings.sidebarShowsAgentStats
        sidebarShowsUsage = AppSettings.sidebarShowsUsage
        agentStateSource = AppSettings.agentStateSource
        gitAutoFetch = AppSettings.gitAutoFetch
        gitAutoFetchMinutes = AppSettings.gitAutoFetchMinutes
        hidesConversationWithoutAgent = AppSettings.hidesConversationWithoutAgent
        windowOpacity = AppSettings.windowOpacity
        backgroundBlur = AppSettings.backgroundBlur
        blurRadius = AppSettings.blurRadius
        railExtraTint = AppSettings.railExtraTint
        frostiness = AppSettings.frostiness
        chromeMaterial = AppSettings.chromeMaterial
        glassStyle = AppSettings.glassStyle
        liquidGlassIsClear = AppSettings.liquidGlassIsClear
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

    func setShowsPaneFocusRing(_ shows: Bool) {
        AppSettings.showsPaneFocusRing = shows
        showsPaneFocusRing = shows
        AppSettings.notifyChanged()
    }

    func setCopyOnSelect(_ copies: Bool) {
        AppSettings.copyOnSelect = copies
        copyOnSelect = copies
        AppSettings.notifyChanged()
    }

    func setQuickActions(_ actions: [QuickAction]) {
        AppSettings.quickActions = actions
        quickActions = actions
        AppSettings.notifyChanged()
    }

    func setSidebarShowsGit(_ shows: Bool) {
        AppSettings.sidebarShowsGit = shows
        sidebarShowsGit = shows
        AppSettings.notifyChanged()
    }

    func setHidesConversationWithoutAgent(_ hides: Bool) {
        AppSettings.hidesConversationWithoutAgent = hides
        hidesConversationWithoutAgent = hides
        AppSettings.notifyChanged()
    }

    func setSidebarShowsAgent(_ shows: Bool) {
        AppSettings.sidebarShowsAgent = shows
        sidebarShowsAgent = shows
        AppSettings.notifyChanged()
    }

    func setAgentStateSource(_ source: AgentStateSource) {
        AppSettings.agentStateSource = source
        agentStateSource = source
        AppSettings.notifyChanged()
    }

    func setSidebarShowsAgentText(_ shows: Bool) {
        AppSettings.sidebarShowsAgentText = shows
        sidebarShowsAgentText = shows
        AppSettings.notifyChanged()
    }

    func setSidebarShowsAgentStats(_ shows: Bool) {
        AppSettings.sidebarShowsAgentStats = shows
        sidebarShowsAgentStats = shows
        AppSettings.notifyChanged()
    }

    func setSidebarShowsUsage(_ shows: Bool) {
        AppSettings.sidebarShowsUsage = shows
        sidebarShowsUsage = shows
        AppSettings.notifyChanged()
    }

    func setGitAutoFetch(_ fetches: Bool) {
        AppSettings.gitAutoFetch = fetches
        gitAutoFetch = fetches
        AppSettings.notifyChanged()
    }

    func setGitAutoFetchMinutes(_ minutes: Int) {
        AppSettings.gitAutoFetchMinutes = minutes
        gitAutoFetchMinutes = AppSettings.gitAutoFetchMinutes
        AppSettings.notifyChanged()
    }

    func setWindowOpacity(_ opacity: CGFloat) {
        AppSettings.windowOpacity = opacity
        windowOpacity = AppSettings.windowOpacity
        AppSettings.notifyChanged()
    }

    func resetWindowOpacity() { setWindowOpacity(AppSettings.defaultWindowOpacity) }

    func setBlurRadius(_ radius: CGFloat) {
        AppSettings.blurRadius = radius
        blurRadius = AppSettings.blurRadius
        AppSettings.notifyChanged()
    }

    func setRailExtraTint(_ tint: CGFloat) {
        AppSettings.railExtraTint = tint
        railExtraTint = AppSettings.railExtraTint
        AppSettings.notifyChanged()
    }

    func setFrostiness(_ value: CGFloat) {
        AppSettings.frostiness = value
        frostiness = AppSettings.frostiness
        AppSettings.notifyChanged()
    }

    func setGlassStyle(_ style: AppSettings.GlassStyle) {
        AppSettings.glassStyle = style
        glassStyle = style
        AppSettings.notifyChanged()
    }

    func setLiquidGlassIsClear(_ clear: Bool) {
        AppSettings.liquidGlassIsClear = clear
        liquidGlassIsClear = clear
        AppSettings.notifyChanged()
    }

    func setChromeMaterial(_ material: AppSettings.ChromeMaterial) {
        AppSettings.chromeMaterial = material
        chromeMaterial = material
        AppSettings.notifyChanged()
    }

    /// Everything about the window's glass, back to how it ships.
    func resetGlass() {
        AppSettings.windowOpacity = AppSettings.defaultWindowOpacity
        AppSettings.blurRadius = AppSettings.defaultBlurRadius
        AppSettings.railExtraTint = AppSettings.defaultRailExtraTint
        AppSettings.frostiness = AppSettings.defaultFrostiness
        AppSettings.chromeMaterial = AppSettings.defaultChromeMaterial
        AppSettings.glassStyle = AppSettings.defaultGlassStyle
        AppSettings.liquidGlassIsClear = true
        windowOpacity = AppSettings.windowOpacity
        blurRadius = AppSettings.blurRadius
        railExtraTint = AppSettings.railExtraTint
        frostiness = AppSettings.frostiness
        chromeMaterial = AppSettings.chromeMaterial
        glassStyle = AppSettings.glassStyle
        liquidGlassIsClear = AppSettings.liquidGlassIsClear
        AppSettings.notifyChanged()
    }

    func setBackgroundBlur(_ blurs: Bool) {
        AppSettings.backgroundBlur = blurs
        backgroundBlur = blurs
        AppSettings.notifyChanged()
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

    override init() {
        store = SettingsStore()

        // An AppKit split view controller rather than SwiftUI's
        // `NavigationSplitView`. On macOS 26 the SwiftUI one draws the sidebar
        // as an inset rounded panel and leaves the traffic lights in a band
        // above it; the standard sidebar runs the full height of the window
        // with the lights inside it. `NSSplitViewItem(sidebarWithViewController:)`
        // is what produces that, and it also brings the sidebar material the
        // panel version does not have. The pages stay SwiftUI — only who owns
        // the split changed.
        let split = NSSplitViewController()
        let hosting = NSHostingController(rootView: SettingsRootView().environmentObject(store))
        window = NSWindow(contentViewController: hosting)
        window.title = "Attaché Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        // Unified, and the SwiftUI side supplies a toolbar item to fill it.
        // The style with an empty toolbar is what reserves the band and pushes
        // the sidebar below the traffic lights.
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 820, height: 620))
        window.setFrameAutosaveName("AttacheSettings")
        window.center()
        super.init()
        window.delegate = self
    }

    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Move to a page, for callers that opened this window to edit one thing.
    func select(page: SettingsPage) {
        store.page = page
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
