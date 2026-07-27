//
//  AppSettings.swift
//  TmuxGUI
//

import AppKit
import GhosttyTerminal
import GhosttyTheme

/// Every persisted preference in one place: its key, its default, and the
/// clamp that stops a hand-edited value putting the app somewhere it cannot
/// get back from.
///
/// There is deliberately no "preserve unknown keys" machinery. `UserDefaults`
/// stores each key separately and `set(_:forKey:)` writes exactly one of them,
/// so a key a newer build wrote is not at risk from a write here — there is no
/// whole-document rewrite for it to fall out of. Three rules replace that
/// machinery:
///
/// - never `removeObject` a key a shipped build still reads;
/// - an unrecognised value falls back to the default and the fallback is *not*
///   written back, so a downgrade does not destroy the newer choice;
/// - clamp where a value is used, never on load. A launch path that read,
///   clamped and wrote through a setter would silently replace a newer build's
///   setting with this build's idea of the legal range.
enum AppSettings {

    enum Key {
        static let fontFamily           = "TmuxGUIFontFamily"
        static let fontSize             = "TmuxGUIFontSize"
        static let appearance           = "TmuxGUIAppearance"
        static let lightTheme           = "TmuxGUILightTheme"
        static let darkTheme            = "TmuxGUIDarkTheme"
        static let scrollbackPrimeLines = "TmuxGUIScrollbackPrimeLines"
        static let sidebarWidth         = "TmuxGUISidebarWidth"
        static let closingTabKills      = "TmuxGUIClosingTabKills"
        static let paneFocusRing        = "TmuxGUIPaneFocusRing"
    }

    /// Posted after any setting changes, with `ChromeTheme.current` already
    /// rebuilt. Open surfaces re-read what they need instead of relaunching.
    static let didChange = Notification.Name("TmuxGUIAppSettingsDidChange")

    /// Which of the two theme slots is showing. `system` follows the OS.
    enum Appearance: String, CaseIterable {
        case system
        case light
        case dark

        var title: String {
            switch self {
            case .system: "Follow System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    // ─── Defaults ────────────────────────────────────────────────────────────

    /// Matches `TerminalConfiguration.default`, so a build with no stored
    /// settings renders exactly what the app rendered before settings existed.
    static let defaultFontSize: Double = 14

    /// The two halves of libghostty's `TerminalTheme.default`, by name. Same
    /// reasoning: an upgrade changes nothing until the user picks something.
    static let defaultLightThemeName = "Alabaster"
    static let defaultDarkThemeName = "Afterglow"

    static let defaultScrollbackPrimeLines = 2000
    static let defaultSidebarWidth: CGFloat = 168

    // ─── Ranges ──────────────────────────────────────────────────────────────

    /// A font size clamp is a data-safety measure here, not a cosmetic one.
    /// Cell size scales with it, `PaneGridView.gridSize` floors at one cell,
    /// and a grid of 1×1 is sent to tmux as `refresh-client -C 1x1` — which
    /// reflows every window in the session to a single column for every
    /// attached client, including whatever agent is running in those panes.
    /// The damage lands outside this app and there is no undo for it.
    static let fontSizeRange: ClosedRange<Double> = 6 ... 72

    /// Negative renders `capture-pane -S --200`, which tmux rejects once per
    /// pane; very large pulls a whole history through the control pipe the
    /// first time a pane is shown.
    static let scrollbackPrimeRange: ClosedRange<Int> = 0 ... 50000

    /// Zero collapses the session rail underneath the traffic lights, which
    /// float over it because the window has no title bar.
    static let sidebarWidthRange: ClosedRange<CGFloat> = 120 ... 400

    // ─── Accessors ───────────────────────────────────────────────────────────

    private static var store: UserDefaults { .standard }

    /// Empty means "whatever libghostty picks", which is what the app used
    /// before there was a setting.
    static var fontFamily: String {
        get {
            let raw = store.string(forKey: Key.fontFamily) ?? ""
            // The value is interpolated into a generated ghostty config file
            // as `font-family = <raw>`, one setting per line. A newline in the
            // stored string would end that line and start another directive,
            // so a name that could do it is treated as absent rather than
            // escaped — the same reasoning that has tmux addressed by id.
            guard !raw.contains(where: \.isNewline) else { return "" }
            return raw
        }
        set { store.set(newValue, forKey: Key.fontFamily) }
    }

    static var fontSize: Double {
        get {
            clamp(
                store.object(forKey: Key.fontSize) as? Double ?? defaultFontSize,
                to: fontSizeRange, fallback: defaultFontSize
            )
        }
        set { store.set(clamp(newValue, to: fontSizeRange, fallback: defaultFontSize), forKey: Key.fontSize) }
    }

    static var appearance: Appearance {
        get { store.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .system }
        set { store.set(newValue.rawValue, forKey: Key.appearance) }
    }

    static var lightThemeName: String {
        get { store.string(forKey: Key.lightTheme) ?? defaultLightThemeName }
        set { store.set(newValue, forKey: Key.lightTheme) }
    }

    static var darkThemeName: String {
        get { store.string(forKey: Key.darkTheme) ?? defaultDarkThemeName }
        set { store.set(newValue, forKey: Key.darkTheme) }
    }

    static var scrollbackPrimeLines: Int {
        get {
            clamp(
                store.object(forKey: Key.scrollbackPrimeLines) as? Int ?? defaultScrollbackPrimeLines,
                to: scrollbackPrimeRange
            )
        }
        set { store.set(clamp(newValue, to: scrollbackPrimeRange), forKey: Key.scrollbackPrimeLines) }
    }

    static var sidebarWidth: CGFloat {
        get {
            clamp(
                (store.object(forKey: Key.sidebarWidth) as? Double).map { CGFloat($0) } ?? defaultSidebarWidth,
                to: sidebarWidthRange, fallback: defaultSidebarWidth
            )
        }
        set {
            store.set(
                Double(clamp(newValue, to: sidebarWidthRange, fallback: defaultSidebarWidth)),
                forKey: Key.sidebarWidth
            )
        }
    }

    /// Whether the ✕ on a tab kills the tmux window instead of hiding it.
    ///
    /// Absent must read as `false`. Hiding is reversible; killing ends every
    /// process in the window, which routinely means an agent mid-run, and
    /// there is no undo. `object(forKey:) as? Bool` rather than
    /// `bool(forKey:)` because only the former can tell absent from false.
    static var closingTabKillsWindow: Bool {
        get { store.object(forKey: Key.closingTabKills) as? Bool ?? false }
        set { store.set(newValue, forKey: Key.closingTabKills) }
    }

    /// Whether the split window marks its active pane with an outline.
    ///
    /// Absent reads as `true`: with a split, keystrokes go to one pane and
    /// nothing else on screen says which. Off is for people who find any mark
    /// around the pane they are reading a distraction and would rather find
    /// the cursor — nothing is drawn at all, not a fainter version.
    /// `object(forKey:) as? Bool` rather than `bool(forKey:)`, because only the
    /// former can tell an absent key from a stored `false`.
    static var showsPaneFocusRing: Bool {
        get { store.object(forKey: Key.paneFocusRing) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.paneFocusRing) }
    }

    // ─── Derived values ──────────────────────────────────────────────────────

    /// The font overrides, as libghostty config keys. Applied on top of the
    /// base config the `TerminalController` was built with rather than
    /// replacing it, so the padding and keybind settings there survive.
    static func terminalConfiguration() -> TerminalConfiguration {
        TerminalConfiguration { builder in
            let family = fontFamily
            if !family.isEmpty { builder.withFontFamily(family) }
            builder.withFontSize(Float(fontSize))
        }
    }

    /// Both slots at once. libghostty picks between them from the surface's
    /// effective appearance, so "follow the system" needs no code here — an
    /// appearance change already reaches `TerminalController.setColorScheme`
    /// through the platform view.
    static func terminalTheme() -> TerminalTheme {
        TerminalTheme(
            light: themeDefinition(named: lightThemeName, default: defaultLightThemeName)
                .toTerminalConfiguration(),
            dark: themeDefinition(named: darkThemeName, default: defaultDarkThemeName)
                .toTerminalConfiguration()
        )
    }

    /// A stored name that no longer exists in the catalog resolves to the
    /// default without the key being rewritten, so a scheme added by a newer
    /// build survives being opened by an older one.
    static func themeDefinition(named name: String, default fallbackName: String) -> GhosttyThemeDefinition {
        GhosttyThemeCatalog.theme(named: name)
            ?? GhosttyThemeCatalog.theme(named: fallbackName)
            ?? GhosttyThemeCatalog.allThemes[0]
    }

    /// The scheme the terminal is showing right now — the one the chrome
    /// derives from.
    @MainActor
    static func effectiveThemeDefinition() -> GhosttyThemeDefinition {
        isShowingDarkAppearance
            ? themeDefinition(named: darkThemeName, default: defaultDarkThemeName)
            : themeDefinition(named: lightThemeName, default: defaultLightThemeName)
    }

    @MainActor
    static var isShowingDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // ─── Applying ────────────────────────────────────────────────────────────

    /// Pin the whole process to one appearance, or let it follow the system.
    ///
    /// Driving `NSApp.appearance` rather than tracking the override separately
    /// means the terminal surfaces need no special case: their existing
    /// `viewDidChangeEffectiveAppearance` already tells the controller which
    /// half of the theme to use, and menus and alerts stay consistent with it.
    @MainActor
    static func applyAppearanceOverride() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Rebuild the derived chrome colours and tell every open surface. Call
    /// after any write.
    @MainActor
    static func notifyChanged() {
        ChromeTheme.reload()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The same, but only when the appearance is actually an input to what is
    /// on screen.
    ///
    /// A pinned theme makes a light/dark flip select the same scheme it
    /// selected before, so every colour is unchanged — and the fan-out is not
    /// free: it walks each session's `TerminalController` and rebuilds both
    /// strips. Machinery that runs for a change it cannot possibly be affected
    /// by is where a grid bug gets to hide, so it does not run at all here.
    @MainActor
    static func notifyIfAppearanceSelectsAnotherTheme() {
        guard effectiveThemeDefinition().name != ChromeTheme.current.sourceName else { return }
        notifyChanged()
    }

    // ─── Clamping ────────────────────────────────────────────────────────────

    private static func clamp<Value: Comparable>(_ value: Value, to range: ClosedRange<Value>) -> Value {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The same for floating point, where `min`/`max` are not enough.
    ///
    /// NaN compares false against everything, so `min(max(nan, lo), hi)` is
    /// `nan` — the clamp passes it straight through and it reaches
    /// `UserDefaults`, which stores it happily, so every later launch reads it
    /// back. From there it is not a settings problem any more: `JSONEncoder`
    /// refuses non-conforming floats so the inspector stops answering, a NaN
    /// width makes `NSLayoutConstraint` raise, and a NaN that reaches the grid
    /// arithmetic traps on the conversion to `Int`.
    ///
    /// A non-finite value is not a number this app can act on, so it becomes
    /// the default — the same value an absent key gives.
    private static func clamp<Value: BinaryFloatingPoint>(
        _ value: Value,
        to range: ClosedRange<Value>,
        fallback: Value
    ) -> Value {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
