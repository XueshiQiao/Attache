//
//  AppSettings.swift
//  Attache
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

    /// The name each setting has in `~/.config/tmux-gui.toml`.
    ///
    /// Written for a person to read, because the file is one a person edits.
    /// The plist names these replaced are in `plistKeys` below, which exists
    /// only so the one-time migration can find them.
    enum Key {
        static let fontFamily             = "font_family"
        static let fontSize               = "font_size"
        static let appearance             = "appearance"
        static let lightTheme             = "light_theme"
        static let darkTheme              = "dark_theme"
        static let scrollbackPrimeLines   = "scrollback_prime_lines"
        static let sidebarWidth           = "sidebar_width"
        static let closingTabKills        = "closing_tab_kills_window"
        static let paneFocusRing          = "pane_focus_ring"
        static let copyOnSelect           = "copy_on_select"
        static let quickActions           = "quick_actions"
        static let windowOpacity          = "window_opacity"
        static let backgroundBlur         = "background_blur"
        static let chromeMaterial         = "chrome_material"
        static let frostiness             = "frostiness"
        static let blurRadius             = "blur_radius"
        static let railExtraTint          = "rail_extra_tint"
        static let glassStyle             = "glass_style"
        static let sidebarShowsGit        = "sidebar_shows_git"
        static let sidebarShowsAgent      = "sidebar_shows_agent"
        static let sidebarShowsAgentText  = "sidebar_shows_agent_text"
        static let sidebarShowsAgentStats = "sidebar_shows_agent_stats"
        static let sidebarShowsUsage      = "sidebar_shows_usage"
        static let agentStateSource       = "agent_state_source"
        static let logsAgentTransitions   = "logs_agent_transitions"
        static let gitAutoFetch           = "git_auto_fetch"
        static let gitAutoFetchMinutes    = "git_auto_fetch_minutes"
        static let liquidGlassClear       = "liquid_glass_clear"
        static let linkClick              = "link_click"
        static let linkModifier           = "link_modifier"
    }

    /// The old `UserDefaults` name for each key, for the migration and nothing
    /// else. Deleting an entry here does not remove a setting — it strands
    /// whatever the user had stored under it, so entries stay until the
    /// migration itself is retired.
    ///
    /// These names are **not** renamed with the app. They name keys inside
    /// `~/Library/Preferences/dev.xueshi.TmuxGUI.plist`, a file that already
    /// exists on disk and that this code can only ever read; rewriting them to
    /// say Attaché would point the migration at keys nobody has ever written.
    ///
    /// The rename did make this unreachable, though, and it is worth saying so
    /// rather than leaving the next reader to work it out: `UserDefaults
    /// .standard` resolves against the bundle identifier, which is now
    /// `me.xueshi.attache`, so it opens a different plist and finds none of
    /// these. Nothing is lost by that — a machine that had settings here
    /// migrated them into the TOML file under the old name already, and
    /// `SettingsFile.adoptLegacyFileIfNeeded` carries *that* file forward.
    static let plistKeys: [String: String] = [
        "TmuxGUIFontFamily": "font_family",
        "TmuxGUIFontSize": "font_size",
        "TmuxGUIAppearance": "appearance",
        "TmuxGUILightTheme": "light_theme",
        "TmuxGUIDarkTheme": "dark_theme",
        "TmuxGUIScrollbackPrimeLines": "scrollback_prime_lines",
        "TmuxGUISidebarWidth": "sidebar_width",
        "TmuxGUIClosingTabKills": "closing_tab_kills_window",
        "TmuxGUIPaneFocusRing": "pane_focus_ring",
        "TmuxGUICopyOnSelect": "copy_on_select",
        "TmuxGUIQuickActions": "quick_actions",
        "TmuxGUIWindowOpacity": "window_opacity",
        "TmuxGUIBackgroundBlur": "background_blur",
        "TmuxGUIChromeMaterial": "chrome_material",
        "TmuxGUIFrostiness": "frostiness",
        "TmuxGUIBlurRadius": "blur_radius",
        "TmuxGUIRailExtraTint": "rail_extra_tint",
        "TmuxGUIGlassStyle": "glass_style",
        "TmuxGUISidebarShowsGit": "sidebar_shows_git",
        "TmuxGUISidebarShowsAgent": "sidebar_shows_agent",
        "TmuxGUISidebarShowsAgentText": "sidebar_shows_agent_text",
        "TmuxGUISidebarShowsAgentStats": "sidebar_shows_agent_stats",
        "TmuxGUISidebarShowsUsage": "sidebar_shows_usage",
        "TmuxGUIAgentStateSource": "agent_state_source",
        "TmuxGUILogsAgentTransitions": "logs_agent_transitions",
        "TmuxGUIGitAutoFetch": "git_auto_fetch",
        "TmuxGUIGitAutoFetchMinutes": "git_auto_fetch_minutes",
        "TmuxGUILiquidGlassClear": "liquid_glass_clear",
    ]

    /// Posted after any setting changes, with `ChromeTheme.current` already
    /// rebuilt. Open surfaces re-read what they need instead of relaunching.
    static let didChange = Notification.Name("AttacheAppSettingsDidChange")

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

    /// How much of what is behind the window shows through it.
    ///
    /// 1.0 is the app as it was before any of this existed, and it has to stay
    /// reachable: a terminal that cannot be made solid is unusable over a busy
    /// desktop, and this is a preference, not a look the app imposes.
    ///
    /// The floor is 0 now, and it took a wrong turn to get there. It was 0.3,
    /// on the reasoning that a fully transparent window is text on a wallpaper.
    /// That was only true while this was the *only* control: the material
    /// underneath has an opacity of its own, and it turned out to be nearly all
    /// of the opacity — dialled to 0.15, the window still barely showed the
    /// desktop. With `frostiness` separated out, a tint of 0 over a frosted
    /// sheet is a perfectly readable window, so the floor has nothing left to
    /// protect.
    static let windowOpacityRange: ClosedRange<CGFloat> = 0 ... 1.0
    static let defaultWindowOpacity: CGFloat = 0.35

    /// How much less of the desktop the rail lets through than the panes do.
    ///
    /// Added to the tint's alpha rather than applied as a darker colour, and
    /// the difference is visible: over a material, more alpha reads as *deeper
    /// glass* — darker and a little less frosted — where a darker colour at the
    /// same alpha reads as a different paint on the same glass. The first is
    /// what the mockup this was dialled in on does, and it is the one that was
    /// picked.
    ///
    /// Small on purpose: it is now the *only* thing separating the two halves,
    /// since the line between them is gone, but a rail that reads as a
    /// different window rather than a deeper part of this one is worse than no
    /// distinction at all.
    static let railExtraTintRange: ClosedRange<CGFloat> = 0 ... 0.5
    static let defaultRailExtraTint: CGFloat = 0.10

    static var railExtraTint: CGFloat {
        get {
            clamp(
                (store.object(forKey: Key.railExtraTint) as? Double).map { CGFloat($0) }
                    ?? defaultRailExtraTint,
                to: railExtraTintRange, fallback: defaultRailExtraTint
            )
        }
        set {
            store.set(
                Double(clamp(newValue, to: railExtraTintRange, fallback: defaultRailExtraTint)),
                forKey: Key.railExtraTint
            )
        }
    }



    // ─── Accessors ───────────────────────────────────────────────────────────

    private static var store: SettingsFile { .shared }

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

    /// How opaque the window is, 0.3 to 1.0. See `windowOpacityRange`.
    static var windowOpacity: CGFloat {
        get {
            clamp(
                (store.object(forKey: Key.windowOpacity) as? Double).map { CGFloat($0) }
                    ?? defaultWindowOpacity,
                to: windowOpacityRange, fallback: defaultWindowOpacity
            )
        }
        set {
            store.set(
                Double(clamp(newValue, to: windowOpacityRange, fallback: defaultWindowOpacity)),
                forKey: Key.windowOpacity
            )
        }
    }

    /// Which of the three ways of showing the desktop the window uses.
    ///
    /// Three, and they are kept side by side on purpose: they are not settings
    /// of one mechanism but three different mechanisms, and which one looks
    /// right is not a question anyone can answer by reading. See `WindowGlass`
    /// for what each does and which knobs belong to it.
    enum GlassStyle: String, CaseIterable {
        /// This app's own: a gaussian blur at any radius, plus a tint.
        case blur
        /// macOS 26's `NSGlassEffectView` — what Ghostty calls
        /// `macos-glass-regular` and `macos-glass-clear`.
        case liquidGlass
        /// The classic `NSVisualEffectView` materials.
        case material

        var title: String {
            switch self {
            case .blur: "Blur"
            case .liquidGlass: "Liquid Glass"
            case .material: "System material"
            }
        }

        /// Liquid Glass needs macOS 26. Offering it where it cannot be built
        /// would be a picker entry that silently does nothing.
        var isAvailable: Bool {
            guard case .liquidGlass = self else { return true }
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }

    static let defaultGlassStyle: GlassStyle = .blur

    static var glassStyle: GlassStyle {
        get {
            let stored = store.string(forKey: Key.glassStyle).flatMap(GlassStyle.init(rawValue:))
            // A style stored by a newer OS and read back on an older one falls
            // back rather than rendering nothing.
            return (stored?.isAvailable == true ? stored : nil) ?? defaultGlassStyle
        }
        set { store.set(newValue.rawValue, forKey: Key.glassStyle) }
    }

    /// Which of `NSGlassEffectView`'s two styles. Clear is the more transparent
    /// of the two; regular carries more of its own material.
    static var liquidGlassIsClear: Bool {
        get { store.object(forKey: Key.liquidGlassClear) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.liquidGlassClear) }
    }

    /// The system material the whole window is drawn over, or none at all.
    ///
    /// Exists because a macOS "material" is not a pane of glass. It is a mostly
    /// opaque frosted sheet with a colour of its own, and which one is chosen
    /// decides how much of the desktop survives it — far more than the tint
    /// painted on top does. The first build of this had `.underWindowBackground`
    /// on the content half and AppKit's `.sidebar` on the rail, and the result
    /// was a window whose opacity slider visibly did almost nothing.
    ///
    /// `none` is the Ghostty answer: no material, so the fill is the only thing
    /// between the text and the desktop. Sharpest, and the only one where the
    /// opacity setting means exactly what it says.
    enum ChromeMaterial: String, CaseIterable {
        case none
        case underWindowBackground
        case windowBackground
        case sidebar
        case menu
        case popover
        case hudWindow
        case fullScreenUI

        var title: String {
            switch self {
            case .none: "No material — clearest"
            case .underWindowBackground: "Under window"
            case .windowBackground: "Window"
            case .sidebar: "Sidebar"
            case .menu: "Menu"
            case .popover: "Popover"
            case .hudWindow: "HUD"
            case .fullScreenUI: "Full screen"
            }
        }
    }

    /// `.sidebar`, and not for its looks.
    ///
    /// While the rail is a real `NSSplitViewItem` sidebar, AppKit paints the
    /// column it lives in — the inset margin around the panel — with this
    /// material, and there is no supported way to ask it not to. Anything else
    /// on the content half is therefore a *second* kind of frost next to the
    /// first, which is exactly the "three sheets of glass" this setting exists
    /// to end. Matching it is the only way both halves can look like one
    /// window while that panel is there.
    /// None, now that the blur is this app's own.
    ///
    /// A material was the only way to get any blur at all while the rail was a
    /// system sidebar, and it brought its own opacity with it — most of the
    /// window's, as it turned out. With `blurRadius` doing the blurring there
    /// is nothing left for a material to contribute except that opacity, so the
    /// default is to have none and let the two settings mean what they say.
    /// The others stay reachable for anyone who wants the system's look.
    static let defaultChromeMaterial: ChromeMaterial = .none

    static var chromeMaterial: ChromeMaterial {
        get {
            (store.string(forKey: Key.chromeMaterial)).flatMap(ChromeMaterial.init(rawValue:))
                ?? defaultChromeMaterial
        }
        set { store.set(newValue.rawValue, forKey: Key.chromeMaterial) }
    }

    /// The alpha the rail's tint goes on at. See `railExtraTint`.
    static var railOpacity: CGFloat {
        min(1.0, windowOpacity + railExtraTint)
    }

    /// How much of the frosted sheet is there at all, 0 to 1.
    ///
    /// The second of the two dimensions, and the one that was missing. A macOS
    /// material is a thick sheet of frost with an opacity of its own that no
    /// tint painted on top can reduce — so with only the tint to turn, the
    /// window had a floor it could not go below, and that floor was most of the
    /// way to opaque. This is the sheet's own alpha.
    ///
    /// The two together are what every other terminal calls "opacity" and
    /// "blur", and they are genuinely independent: `frostiness` decides how
    /// much the desktop is *blurred and lightened*, `windowOpacity` decides how
    /// much of the terminal's own colour is laid over the result. Frost 0 is
    /// clear glass — sharp desktop, no blur.
    static let frostinessRange: ClosedRange<CGFloat> = 0 ... 1.0
    static let defaultFrostiness: CGFloat = 0.7

    static var frostiness: CGFloat {
        get {
            clamp(
                (store.object(forKey: Key.frostiness) as? Double).map { CGFloat($0) }
                    ?? defaultFrostiness,
                to: frostinessRange, fallback: defaultFrostiness
            )
        }
        set {
            store.set(
                Double(clamp(newValue, to: frostinessRange, fallback: defaultFrostiness)),
                forKey: Key.frostiness
            )
        }
    }

    /// How far the desktop behind the window is blurred, in points.
    ///
    /// The dimension `NSVisualEffectView` does not have. A material's blur is
    /// whatever Apple chose for that material and there is no way to ask for
    /// more or less of it — which is why turning the other two knobs never
    /// produced the frosted-but-see-through look this was after.
    ///
    /// Done by asking the window server for it — see `WindowServerBlur`, which
    /// also records why the obvious public route, a `CALayer.backgroundFilters`
    /// gaussian, blurs this window's edges and not its middle: every pane is a
    /// Metal layer composited above the layer the filter hangs on, so the
    /// desktop seen through a pane never passes through it.
    ///
    /// 0 is clear glass — the desktop shows through sharp. It is a real
    /// setting and not a disabled state. What a radius costs has not been
    /// measured here, and the work is the window server's rather than this
    /// process's — which is a reason to measure it somewhere other than this
    /// app's frame time, not a reason to assume it is free.
    static let blurRadiusRange: ClosedRange<CGFloat> = 0 ... 80
    static let defaultBlurRadius: CGFloat = 30

    static var blurRadius: CGFloat {
        get {
            clamp(
                (store.object(forKey: Key.blurRadius) as? Double).map { CGFloat($0) }
                    ?? defaultBlurRadius,
                to: blurRadiusRange, fallback: defaultBlurRadius
            )
        }
        set {
            store.set(
                Double(clamp(newValue, to: blurRadiusRange, fallback: defaultBlurRadius)),
                forKey: Key.blurRadius
            )
        }
    }

    /// Whether the material behind the window blurs the desktop.
    ///
    /// Absent reads as `true`: translucency without blur is a window you can
    /// read the desktop's text through, which is the effect nobody wants. Off
    /// still leaves the window translucent — it is the difference between
    /// frosted and plain glass — and it is the setting to reach for if the blur
    /// ever costs measurable frames.
    static var backgroundBlur: Bool {
        get { store.object(forKey: Key.backgroundBlur) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.backgroundBlur) }
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

    /// Whether a modifier turns a path or URL under the pointer into a link.
    ///
    /// On by default: the matching and the underline are libghostty's own and
    /// cost nothing to leave on, and with this off the gesture is simply an
    /// ordinary click.
    static var linkClickEnabled: Bool {
        get { store.object(forKey: Key.linkClick) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.linkClick) }
    }

    /// Which modifier that is.
    ///
    /// A stored value that is not a gesture resolves to the default without
    /// the key being rewritten, the same way a missing theme name does, so a
    /// gesture added by a newer build survives being opened by an older one.
    static var linkModifier: TerminalLinkGesture {
        get {
            (store.object(forKey: Key.linkModifier) as? String)
                .flatMap(TerminalLinkGesture.init(rawValue:)) ?? .command
        }
        set { store.set(newValue.rawValue, forKey: Key.linkModifier) }
    }

    /// Whether a window row carries a second line with its repository's state.
    ///
    /// On by default, and the one setting here that changes the *shape* of the
    /// rail: the row goes from 27pt to 40pt, so a list of twenty windows needs
    /// half again the height. That is a trade only the person looking at their
    /// own twenty windows can make, which is why it is a switch and not a
    /// constant. Off restores the rail exactly as it was.
    static var sidebarShowsGit: Bool {
        get { store.object(forKey: Key.sidebarShowsGit) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.sidebarShowsGit) }
    }

    /// Whether a window running a coding agent is marked.
    ///
    /// Independent of the Git line, because they answer different questions and
    /// the dot costs no height at all.
    static var sidebarShowsAgent: Bool {
        get { store.object(forKey: Key.sidebarShowsAgent) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.sidebarShowsAgent) }
    }

    /// Whether the agent's state is spelled out in words beside its dot.
    ///
    /// On by default. A colour has to be learned before it means anything, and
    /// there is no legend on screen to learn it from — the first question asked
    /// about the dots was what the colours meant. The word costs width, which
    /// is why it can be turned off once it has been learned.
    static var sidebarShowsAgentText: Bool {
        get { store.object(forKey: Key.sidebarShowsAgentText) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.sidebarShowsAgentText) }
    }

    /// Whether a window running an agent gets a third line with the model it
    /// is on, how full its context is, and what the session has cost.
    ///
    /// On by default, and it costs height only on rows that have an agent —
    /// see `SidebarWindowRow.height`. Needs the status line wrapper installed;
    /// without it there is simply nothing to draw and the row stays two lines,
    /// which is why this is not gated on the installer.
    static var sidebarShowsAgentStats: Bool {
        get { store.object(forKey: Key.sidebarShowsAgentStats) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.sidebarShowsAgentStats) }
    }

    /// Whether the account's rate-limit windows are drawn at the foot of the
    /// rail. Account-wide rather than per window, which is why it is not part
    /// of the row settings above.
    static var sidebarShowsUsage: Bool {
        get { store.object(forKey: Key.sidebarShowsUsage) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.sidebarShowsUsage) }
    }

    /// Where an agent's state is read from. See `AgentStateStrategy`.
    ///
    /// Hooks are the default: exact, and the state lands in tmux where any
    /// client can see it. Reading the pane needs nothing installed but infers
    /// from a user interface its author is free to change.
    static var agentStateSource: AgentStateSource {
        get {
            store.string(forKey: Key.agentStateSource)
                .flatMap(AgentStateSource.init(rawValue:)) ?? .hook
        }
        set { store.set(newValue.rawValue, forKey: Key.agentStateSource) }
    }

    /// Whether to write a state-transition log per tmux window.
    ///
    /// On by default, because the thing it is for is checking that the state
    /// machine the app implements is the one that was designed — and a log that
    /// has to be switched on before the interesting transition happens is a log
    /// that is always switched on afterwards.
    static var logsAgentTransitions: Bool {
        get { store.object(forKey: Key.logsAgentTransitions) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.logsAgentTransitions) }
    }

    /// Whether to run `git fetch` in the background so `↓` means something.
    ///
    /// **Off by default and it should stay that way.** `# branch.ab` is
    /// measured against the last fetch, so without one the app cannot know what
    /// the remote has — and the honest answer to that is a tooltip saying so,
    /// not a network connection nobody asked for. Turning this on means a
    /// sidebar that talks to every remote of every repository it is drawing:
    /// private repositories, credentials, a laptop on a phone tether.
    static var gitAutoFetch: Bool {
        get { store.object(forKey: Key.gitAutoFetch) as? Bool ?? false }
        set { store.set(newValue, forKey: Key.gitAutoFetch) }
    }

    static let gitAutoFetchMinutesRange: ClosedRange<Int> = 1 ... 240
    static let defaultGitAutoFetchMinutes = 10

    static var gitAutoFetchMinutes: Int {
        get {
            let stored = store.object(forKey: Key.gitAutoFetchMinutes) as? Int
            guard let stored else { return defaultGitAutoFetchMinutes }
            return min(max(stored, gitAutoFetchMinutesRange.lowerBound), gitAutoFetchMinutesRange.upperBound)
        }
        set { store.set(newValue, forKey: Key.gitAutoFetchMinutes) }
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

    /// Whether releasing the mouse after selecting text puts it on the
    /// clipboard.
    ///
    /// Absent reads as `false`, which is ⌘C and the macOS convention. On is the
    /// habit people bring from iTerm2 and from Linux terminals. Neither is
    /// obviously right — the cost of on is that the clipboard is overwritten by
    /// a selection made while reading — so this is a setting rather than a
    /// decision. `object(forKey:) as? Bool` rather than `bool(forKey:)`,
    /// because only the former can tell an absent key from a stored `false`.
    static var copyOnSelect: Bool {
        get { store.object(forKey: Key.copyOnSelect) as? Bool ?? false }
        set { store.set(newValue, forKey: Key.copyOnSelect) }
    }

    /// The user's Quick Actions menu.
    ///
    /// An absent key means "never edited" and yields the installed list; an
    /// empty *array* is a list the user emptied on purpose and stays empty. The
    /// two have to be told apart or clearing the table would put the default
    /// entry straight back, which reads as the app refusing to be edited.
    ///
    /// Unreadable stored data falls back to the installed list rather than
    /// throwing the menu away, because the alternative is a menu that silently
    /// empties itself after an upgrade.
    /// The user's Quick Actions menu.
    ///
    /// `nil` from the store means "never edited" and yields the installed list;
    /// an empty *array* is a list the user emptied on purpose and stays empty.
    /// The two have to be told apart or clearing the table would put the
    /// default entry straight back, which reads as the app refusing to be
    /// edited.
    static var quickActions: [QuickAction] {
        get { store.storedQuickActions ?? QuickAction.installed }
        set { store.setQuickActions(newValue) }
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
            // Stated in both positions, and that is the point: libghostty's own
            // default is `true`, so this app copied every selection to the
            // clipboard for as long as it has existed, with nothing anywhere
            // saying so. The first version of the setting added a second copy
            // in `mouseUp` on top of that one — two mechanisms for one
            // behaviour, which is how "off" ended up copying and "on" ended up
            // not. There is one mechanism now and it is libghostty's.
            builder.withCustom("copy-on-select", copyOnSelect ? "true" : "false")
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
