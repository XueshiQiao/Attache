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
    ///
    /// **How much darker is a perceptual step, not a fraction, and that was
    /// worth a rewrite.** This used to be `blend(background, toward: .black,
    /// by: 0.22)` — every channel multiplied by 0.78 — which makes the size of
    /// the step proportional to how bright the background already is. On Ayu
    /// that removed 5 of 255 levels and read as intended; on Ayu Light it
    /// removed 53 and the rail became a slab of mid grey with everything on it
    /// washed out. Measured 2026-08-25 against a screenshot: the rail sampled
    /// (186,187,188), the window name 3.3:1 on it, the branch line 2.1:1 and
    /// the row number 1.5:1 — against 9.9 / 6.8 / 4.6 for the same three roles
    /// on the dark scheme. One rule, an order of magnitude apart.
    ///
    /// `deepened(_:by:)` moves a fixed distance in CIE L* instead, so "a step
    /// deeper" means the same amount of *seen* darkening on either. Across the
    /// 485-scheme catalog the step is now L* 5.5 everywhere it fits, against
    /// 2.6 on the median dark scheme and 18.8 on the median light one before.
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

    /// How much deeper than the panes the rail is painted, in CIE L*.
    ///
    /// A perceptual distance rather than a fraction — see `railBackground` for
    /// what a fraction did. 5.5 is the size of the step the dark schemes were
    /// *supposed* to be getting: it leaves a boundary that is plainly there
    /// without the rail reading as a separate window, and it is small enough
    /// that all but the near-black schemes have room for it.
    ///
    /// This is a rendering calibration in the same sense as
    /// `AppSettings.railCoatFullDepthExtra`: changing it changes what every
    /// existing install looks like at a setting nobody touched.
    private static let railStep: CGFloat = 5.5

    /// Contrast floors for the two quiet text roles. 4.5:1 is the WCAG floor
    /// for body text and 3:1 for large text; these sit around and below them,
    /// because these roles are *meant* to recede and a floor that forced them
    /// to the body-text ratio would flatten the hierarchy into three copies of
    /// the same tone. They are a floor on "still legible", not a target.
    ///
    /// **They moved with the ceiling.** 4.0 and 3.0 were picked when the name
    /// above them was itself only 4.73:1 on a light scheme — there was no room
    /// for anything higher. `systemInk(on:drawnOn:)` put the name at 12.0:1,
    /// and leaving the floors where they were would have spent none of that:
    /// measured 2026-08-25, the quiet tones would have landed at 4.00 and 3.00
    /// on Ayu Light — better than the 2.14 and 1.52 that started this — but
    /// 6.24 and **3.00** on Ayu dark, against 7.18 and 4.88 before. That is a
    /// fix for the light scheme paid for by making the dark one fainter, which
    /// is not a trade anyone asked for. At 5.0 and 3.6 the light scheme gets
    /// 12.02 / 5.00 / 3.60 and the dark one 14.06 / 6.24 / 3.60, so both ends
    /// come out at least as legible as they went in.
    ///
    /// **Measured against `railBackground`, which is the colour the rail is
    /// painted in and not the colour it ends up.** The rail is translucent, so
    /// what these tones land on is that paint over a blurred desktop, and
    /// neither the wallpaper nor either opacity slider is visible from in here
    /// — the same limitation the comment in `init` records, and one these
    /// floors narrow rather than remove. Measured 2026-08-25 on Ayu at the
    /// shipped 55% / 10%: the rail composites to (14,15,19) over a black
    /// desktop, where the tertiary tone is 4.7:1, and to (103,105,108) over a
    /// white one, where the same two colours are 1.4:1. A factor of three,
    /// decided by the wallpaper.
    ///
    /// So this is a floor on the derivation, not a promise about a pixel, and
    /// `ChromeThemeCheck` asserts exactly that and no more. Raised by an
    /// independent review, which read the first version of this comment as
    /// claiming the stronger thing. Doing better needs the composite, which
    /// means the floors would have to move with the opacity sliders and be
    /// solved against a worst-case backdrop — a change to when the theme is
    /// rebuilt, not to the arithmetic here.
    private static let mutedFloor: CGFloat = 5.0
    private static let faintFloor: CGFloat = 3.6

    /// The accent luminance at which the selected row's label flips from white
    /// to black.
    ///
    /// This was 0.45 and it was too high, in a way that only shows up on
    /// schemes nobody here runs. WCAG contrast is not symmetric about the
    /// middle of the range: black and white are equally readable at a
    /// luminance of about 0.179, not 0.5, so every accent between 0.179 and
    /// the threshold gets white text when black would have been better — and
    /// just under 0.45 is where that is worst. Measured across the catalog by
    /// running this file: at 0.45 the label is under 3:1 on **61 of 485**
    /// schemes, worst 2.10:1 (Wilmersdorf, hazyland, GitHub Dark High
    /// Contrast, Citruszest, One Half Dark). At 0.30 it is under 3:1 on
    /// **none**, worst 3.04:1, and those 61 land near 9.9:1. No scheme is made
    /// worse.
    ///
    /// 0.30 rather than the ratio-optimal 0.179 on purpose. The arithmetic
    /// prefers black on every mid-blue accent, which is correct and looks
    /// wrong — a selected row in a Mac sidebar has white text on blue, and
    /// 0.30 keeps that while still clearing the floor everywhere. Found by an
    /// independent review; the counts here are this file's own, not that
    /// review's re-implementation.
    private static let onAccentSplit: CGFloat = 0.30

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
        railBackground = Self.deepened(background, by: Self.railStep)
        // The three text roles are the system's, not the scheme's, and which
        // half of the system's they are is decided by the terminal background
        // rather than by the appearance setting — see `systemInk(on:)`.
        let ink = Self.systemInk(on: background, drawnOn: railBackground)
        text = ink.label
        // **These used to be blends of the scheme's own foreground, and that
        // is what made a light scheme unreadable.** A blend of a weak pair is
        // weaker still: Ayu Light's foreground is `#5c6166`, only 5.5:1
        // against its own background, so 62% of the way there was 2.6:1 before
        // the rail was even accounted for, and on screen it measured 1.5:1.
        // The scheme was not an outlier either — it ranks 80th of the 87 light
        // schemes in the catalog by how legible its own foreground is.
        //
        // Ghostty solves this by not having the problem: its chrome text is
        // `NSColor.labelColor` and friends, and the theme decides only which
        // *appearance* those resolve against — `NSAppearance(ghosttyConfig:)`
        // reads the background's luminance and flips the whole window to aqua
        // or darkAqua. Theme colours go into fills (titlebar, glass tint,
        // split divider) and never into text. Read at Ghostty 557de7c9,
        // 2026-08-25. This is that, and `systemInk(on:drawnOn:)` is where it
        // happens.
        //
        // The floors stay on top of it, and measuring says they have to. The
        // system's own tones are calibrated for an opaque system background,
        // not for a translucent rail over a wallpaper: measured 2026-08-25 on
        // the rail colour, `labelColor` lands at 12.0:1 on Ayu Light where the
        // old derivation gave 4.7 — the whole complaint, gone — but
        // `tertiaryLabelColor` lands at 1.8:1 where the old one gave 3.0, and
        // 2.1:1 on Ayu dark where it gave 4.9. Taking the system's three tones
        // unmodified would have fixed the loud text by making the quiet text
        // worse than it started.
        //
        // So the floors are applied to the system's tones instead of to the
        // scheme's, which in this idiom just means using more of the ink: each
        // tone is black or white at some alpha over the rail, and `raised`
        // walks further along that same ray until it clears. Capped in order,
        // so no tone can out-contrast the one above it.
        let nameContrast = Self.contrastRatio(ink.label, railBackground)
        mutedText = Self.raised(
            ink.secondary,
            from: railBackground, toward: ink.pure,
            on: railBackground, to: min(Self.mutedFloor, nameContrast)
        )
        faintText = Self.raised(
            ink.tertiary,
            from: railBackground, toward: ink.pure,
            on: railBackground, to: min(Self.faintFloor, Self.contrastRatio(mutedText, railBackground))
        )
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
        // the moment the accent is a light colour. Which way to jump is
        // `onAccentSplit`.
        onAccent = Self.relativeLuminance(accent) > Self.onAccentSplit ? .black : .white
    }

    private init(
        background: NSColor, text: NSColor, mutedText: NSColor, faintText: NSColor,
        separator: NSColor, hover: NSColor, accent: NSColor, onAccent: NSColor,
        sourceName: String
    ) {
        self.background = background
        railBackground = Self.deepened(background, by: Self.railStep)
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

    /// The system's three label tones, resolved against the appearance the
    /// *terminal background* implies and flattened onto the surface they will
    /// be drawn on.
    ///
    /// Two decisions, and both are Ghostty's.
    ///
    /// **The appearance comes from the background, not from the setting.** The
    /// app's own appearance preference already picks which of the two schemes
    /// is showing, so the two normally agree — but nothing stops someone
    /// naming a dark scheme in `light_theme`, and then a system label resolved
    /// against the *app's* appearance would be dark ink on a dark rail. Asking
    /// the colour that is actually about to be behind the text removes that
    /// case rather than documenting it. Ghostty does the same thing in
    /// `NSAppearance(ghosttyConfig:)`, from the same input.
    ///
    /// **Flattened rather than left with their alpha**, because every other
    /// colour on this type is opaque and a dozen call sites say
    /// `theme.faintText.withAlphaComponent(0.8)`. That call *replaces* an
    /// alpha, so handing back `tertiaryLabelColor`'s own 0.26 would turn a
    /// deliberate fade into a threefold darkening at each of those sites, with
    /// nothing to see in the diff. Flattening keeps the invariant the rest of
    /// this file already relies on.
    ///
    /// `pure` is the ink itself — black or white — which is the far end of the
    /// ray all three tones sit on, and therefore what a floor walks toward.
    nonisolated private static func systemInk(
        on background: NSColor, drawnOn surface: NSColor
    ) -> (label: NSColor, secondary: NSColor, tertiary: NSColor, pure: NSColor) {
        let isLight = lightness(of: background) >= 50
        let pure: NSColor = isLight ? .black : .white
        // 50 is the L* midpoint rather than Ghostty's `luminance > 0.5`, which
        // is a Rec.601 luma on gamma-encoded components — cheaper, and it puts
        // the boundary somewhere no scheme in this catalog actually disagrees
        // about. Using the same lightness the rail's own step is measured in
        // keeps one definition of "light" in the file instead of two.
        guard let appearance = NSAppearance(named: isLight ? .aqua : .darkAqua) else {
            // No appearance to resolve against is not a reason to draw nothing
            // legible: fall back to the ink at the alphas macOS itself uses.
            return (
                flattened(pure.withAlphaComponent(0.85), on: surface),
                flattened(pure.withAlphaComponent(0.50), on: surface),
                flattened(pure.withAlphaComponent(0.26), on: surface),
                pure
            )
        }
        var label = NSColor.labelColor
        var secondary = NSColor.secondaryLabelColor
        var tertiary = NSColor.tertiaryLabelColor
        appearance.performAsCurrentDrawingAppearance {
            label = NSColor.labelColor.usingColorSpace(.sRGB) ?? label
            secondary = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? secondary
            tertiary = NSColor.tertiaryLabelColor.usingColorSpace(.sRGB) ?? tertiary
        }
        return (
            flattened(label, on: surface),
            flattened(secondary, on: surface),
            flattened(tertiary, on: surface),
            pure
        )
    }

    /// What a colour with alpha becomes once it is drawn on `surface`.
    nonisolated private static func flattened(_ colour: NSColor, on surface: NSColor) -> NSColor {
        guard let ink = colour.usingColorSpace(.sRGB),
              let ground = surface.usingColorSpace(.sRGB)
        else { return colour }
        let a = ink.alphaComponent
        return NSColor(
            srgbRed: ground.redComponent * (1 - a) + ink.redComponent * a,
            green: ground.greenComponent * (1 - a) + ink.greenComponent * a,
            blue: ground.blueComponent * (1 - a) + ink.blueComponent * a,
            alpha: 1
        )
    }

    /// The colour with this one's hue, `amount` lower in CIE L* — or as far
    /// down as there is room, when the background is already nearly black.
    ///
    /// Clamping rather than flipping to *lighter*, and that is the whole
    /// difference between this and the obvious alternative. 56 of the catalog's
    /// 398 dark schemes have a background below L* 5.5; letting those turn the
    /// rail lighter than the panes would reverse what the boundary means on a
    /// sixth of them, on no signal the user can see. Clamped, they get the step
    /// they have room for — which for a scheme that dark is invisible either
    /// way, and was invisible under the old rule too.
    nonisolated private static func deepened(_ color: NSColor, by amount: CGFloat) -> NSColor {
        scaled(color, toLightness: max(0, lightness(of: color) - amount))
    }

    /// CIE L*, from the same relative luminance the contrast ratio is built on.
    nonisolated static func lightness(of color: NSColor) -> CGFloat {
        let y = relativeLuminance(color)
        return y > 0.008856 ? 116 * pow(y, 1.0 / 3.0) - 16 : 903.3 * y
    }

    /// `color` scaled until it lands on `target` L*.
    ///
    /// Scaling the *encoded* components rather than interpolating toward black
    /// keeps every result on the ray from black through `color`, so the hue and
    /// the ratio between channels survive — a rail derived from a blue-black
    /// scheme stays blue-black. Bisected because L* is not invertible through
    /// the sRGB transfer function in closed form, and 40 halvings of a range
    /// that starts at 4 is far below a quantisation step.
    nonisolated private static func scaled(_ color: NSColor, toLightness target: CGFloat) -> NSColor {
        guard let srgb = color.usingColorSpace(.sRGB) else { return color }
        var low: CGFloat = 0
        var high: CGFloat = 4
        var result = srgb
        for _ in 0 ..< 40 {
            let factor = (low + high) / 2
            result = NSColor(
                srgbRed: min(1, srgb.redComponent * factor),
                green: min(1, srgb.greenComponent * factor),
                blue: min(1, srgb.blueComponent * factor),
                alpha: 1
            )
            if lightness(of: result) < target { low = factor } else { high = factor }
        }
        return result
    }

    /// `tone` pushed further along the ray it was already on until it clears
    /// `floor` against the surface it will be drawn on.
    ///
    /// The rest of the way to `foreground` first; and past it, toward whichever
    /// end of the range the surface is *not* at, for the schemes whose own
    /// foreground does not clear the floor either — Ayu Light's is 5.5:1
    /// against its own background, so 62% of it was never going to be legible
    /// on a rail.
    ///
    /// Bisection is safe on a ratio that is not monotonic along this ray. It
    /// dips to 1:1 where the ray crosses the surface's own luminance and rises
    /// on both sides, so there are two crossings for a floor below
    /// `contrastRatio(background, surface)` and exactly one above it. That
    /// quantity is the rail's own step — at most about 1.1:1 — and both floors
    /// are far above it.
    nonisolated private static func raised(
        _ tone: NSColor, from background: NSColor, toward foreground: NSColor,
        on surface: NSColor, to floor: CGFloat
    ) -> NSColor {
        guard contrastRatio(tone, surface) < floor else { return tone }
        let foregroundReaches = contrastRatio(foreground, surface) >= floor
        let start = foregroundReaches ? background : foreground
        let end: NSColor = foregroundReaches
            ? foreground
            : (lightness(of: surface) < 50 ? .white : .black)
        var low: CGFloat = 0
        var high: CGFloat = 1
        for _ in 0 ..< 30 {
            let mid = (low + high) / 2
            if contrastRatio(blend(start, toward: end, by: mid), surface) < floor {
                low = mid
            } else {
                high = mid
            }
        }
        return blend(start, toward: end, by: high)
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
