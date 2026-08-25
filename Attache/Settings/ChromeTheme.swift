//
//  ChromeTheme.swift
//  Attache
//

import Cocoa
import GhosttyTheme

/// The colours the app's own chrome draws with, derived from the terminal
/// scheme that is currently showing.
///
/// Only two colours in a scheme are *guaranteed* to be legible together: the
/// `foreground`/`background` pair, because that is the pair the user reads
/// terminal output in. Everything here except the accent is a blend of those
/// two, which is why chrome built this way can never be less readable than the
/// terminal the user chose — a 485-scheme catalog has plenty of entries whose
/// ANSI colours are nearly invisible against their own background.
///
/// These colours come from hex, so unlike a system semantic colour they do not
/// change meaning with the appearance and a `cgColor` taken from one does not
/// go stale. The set is rebuilt outright when the theme or the appearance
/// changes; nothing re-resolves in place.
struct ChromeTheme {
    /// Window and chrome fill. Nudged off the terminal background so the tab
    /// strip and rail separate from pane content instead of merging with it.
    let background: NSColor
    /// The rail's tint. The same colour as `background`, a step deeper.
    ///
    /// A *colour* difference and deliberately not an alpha difference. Making
    /// the rail more opaque was the first attempt and it reads as "deeper" only
    /// because it stops being glass: measured, at 85% window opacity plus a
    /// 12% extra tint the rail came out at 97% and no longer sampled the
    /// desktop at all — moving the window changed every pixel of the content
    /// half and not one of the rail's. Both halves carry the same alpha now, so
    /// both show the same amount of what is behind the window, and the rail is
    /// simply painted in a darker colour.
    let railBackground: NSColor
    /// Primary label colour — the scheme's own foreground.
    let text: NSColor
    /// Replaces `secondaryLabelColor`.
    let mutedText: NSColor
    /// Replaces `tertiaryLabelColor`.
    let faintText: NSColor
    let separator: NSColor
    /// Hover wash for rows and tabs.
    let hover: NSColor
    /// Selection fill. The one colour not derived from the foreground pair,
    /// so it is the one with a contrast floor.
    let accent: NSColor
    /// Black or white, whichever is readable on `accent`.
    let onAccent: NSColor
    /// The scheme these colours were derived from. Kept so an appearance
    /// change can be tested for whether it selects a different scheme at all
    /// before anything is rebuilt.
    let sourceName: String

    // MARK: - Current

    /// What the chrome is drawing with right now. Read at draw time rather
    /// than captured, so a view that redraws picks up a change for free.
    @MainActor private(set) static var current: ChromeTheme = .system

    @MainActor
    static func reload() {
        current = ChromeTheme(definition: AppSettings.effectiveThemeDefinition())
    }

    // MARK: - Derivation

    init(definition: GhosttyThemeDefinition) {
        guard let terminalBackground = Self.color(hex: definition.background),
              let foreground = Self.color(hex: definition.foreground)
        else {
            // A scheme whose own two mandatory colours will not parse is not
            // one to guess at. Fall back to the system chrome the app used
            // before it had themes.
            self = .system
            return
        }
        sourceName = definition.name

        let background = Self.blend(terminalBackground, toward: foreground, by: 0.06)
        self.background = background
        // Toward black rather than away from the foreground: "deeper" has to
        // mean the same thing on a light scheme as on a dark one, and blending
        // away from the foreground would lighten the rail on a light scheme —
        // the opposite of what the divider is there to say.
        railBackground = Self.blend(background, toward: .black, by: 0.22)
        text = foreground
        // 0.80 and 0.62, not the 0.60/0.40 these started at, and the reason is
        // that the surface underneath is not the colour they are derived from.
        // These blends assume the text lands on `background`. It lands on the
        // rail, and the rail is translucent — what it composites to is pulled
        // toward whatever is behind the window, while the text is drawn opaque
        // and is not pulled anywhere. Neither the wallpaper nor the opacity
        // setting is visible from in here.
        //
        // Measured 2026-08-24 on the Ayu scheme at 54.5% window opacity over a
        // mid-grey desktop: the rail composited to (62,63,67) where the
        // derivation assumed (17,19,23) — nearly four times the luminance —
        // and the two roles came out at 2.48:1 and 1.53:1 against it. Both are
        // under the 3:1 floor for even large text. At these fractions the same
        // measurement gives 3.8:1 and 2.7:1, and the three steps stay far
        // enough apart to still read as a hierarchy.
        //
        // A floor, not a solution: no fixed fraction can be right for every
        // wallpaper. These are chosen to fail toward "brighter than strictly
        // needed" on a dark backdrop rather than toward unreadable on a light
        // one.
        mutedText = Self.blend(background, toward: foreground, by: 0.80)
        faintText = Self.blend(background, toward: foreground, by: 0.62)
        separator = Self.blend(background, toward: foreground, by: 0.18)
        hover = Self.blend(background, toward: foreground, by: 0.09)

        // Candidates in the order they read as "this scheme's highlight".
        // Several schemes set an ANSI blue barely distinguishable from their
        // own background, so each candidate has to clear a contrast floor
        // before it is allowed to be the colour a selected row is filled with
        // — otherwise the selection becomes invisible on exactly those
        // schemes. 3:1 is the WCAG floor for a non-text element.
        let candidates = [
            definition.cursorColor,
            definition.palette[4],
            definition.palette[12],
            definition.selectionBackground,
        ]
        let accent = candidates
            .compactMap { $0.flatMap(Self.color(hex:)) }
            .first { Self.contrastRatio($0, background) >= 3 }
            ?? foreground
        self.accent = accent
        // `SessionRowView` used to hardcode white here, which is unreadable
        // the moment the accent is a light colour.
        onAccent = Self.relativeLuminance(accent) > 0.45 ? .black : .white
    }

    private init(
        background: NSColor, text: NSColor, mutedText: NSColor, faintText: NSColor,
        separator: NSColor, hover: NSColor, accent: NSColor, onAccent: NSColor,
        sourceName: String
    ) {
        self.background = background
        railBackground = Self.blend(background, toward: .black, by: 0.22)
        self.text = text
        self.mutedText = mutedText
        self.faintText = faintText
        self.separator = separator
        self.hover = hover
        self.accent = accent
        self.onAccent = onAccent
        self.sourceName = sourceName
    }

    /// The pre-theme look, in system semantic colours. Only reached when a
    /// scheme fails to parse, which the shipped catalog never does.
    static let system = ChromeTheme(
        background: .windowBackgroundColor,
        text: .labelColor,
        mutedText: .secondaryLabelColor,
        faintText: .tertiaryLabelColor,
        separator: NSColor.separatorColor.withAlphaComponent(0.5),
        hover: NSColor.separatorColor.withAlphaComponent(0.35),
        accent: .controlAccentColor,
        onAccent: .white,
        // Empty rather than a scheme name, so the appearance gate always treats
        // the fallback as "not what the settings currently select" and rebuilds.
        sourceName: ""
    )

    /// The colour the rail's own coat is painted in, `depth` of the way from
    /// the panes' colour to the rail's.
    ///
    /// A ramp rather than the fixed `railBackground`, and the reason is the one
    /// corner where a fixed colour cannot be made continuous. The coat's
    /// *alpha* has to be `extra/(1-windowOpacity)` for the pair of coats to
    /// land on the right opacity — see `AppSettings.railFillAlpha` — and at a
    /// fully opaque window that expression saturates for every positive extra,
    /// so a fixed colour turns a percentage slider into an on/off switch: the
    /// whole rail flips to `railBackground` the moment the slider leaves zero.
    ///
    /// Ramping the colour by the extra's own fraction of its range fixes it
    /// from every direction. Zero still paints the panes' colour, a small extra
    /// is a small step, and pushing the *window* opacity to 1 at a fixed extra
    /// changes nothing — this depth does not depend on it. Raised by an
    /// independent review, which also showed why the obvious alternative
    /// (scaling the alpha by the extra's range only at opacity 1) merely moves
    /// the jump onto the window-opacity slider.
    nonisolated func railCoat(depth: CGFloat) -> NSColor {
        Self.blend(background, toward: railBackground, by: max(0, min(1, depth)))
    }

    // MARK: - Colour arithmetic

    /// Themes store `rrggbb`, occasionally with a leading `#`.
    nonisolated static func color(hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    nonisolated private static func blend(_ base: NSColor, toward other: NSColor, by fraction: CGFloat) -> NSColor {
        guard let from = base.usingColorSpace(.sRGB), let to = other.usingColorSpace(.sRGB) else {
            return base
        }
        return NSColor(
            srgbRed: from.redComponent + (to.redComponent - from.redComponent) * fraction,
            green: from.greenComponent + (to.greenComponent - from.greenComponent) * fraction,
            blue: from.blueComponent + (to.blueComponent - from.blueComponent) * fraction,
            alpha: 1
        )
    }

    /// WCAG relative luminance.
    nonisolated static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    nonisolated static func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
