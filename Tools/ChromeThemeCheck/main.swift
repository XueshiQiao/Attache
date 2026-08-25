//
//  main.swift
//  ChromeThemeCheck
//
//  Cross-check for `ChromeTheme`'s derivation, run against the whole shipped
//  scheme catalog rather than against fixtures.
//
//      xcodebuild … build            # once, so the package products exist
//      swiftc -O -o /tmp/chromethemecheck \
//          -I /tmp/dd/Build/Products/Debug \
//          -Xcc -I -Xcc /tmp/dd/Build/Products/Debug/include \
//          Attache/Settings/ChromeTheme.swift Tools/ChromeThemeCheck/main.swift \
//          /tmp/dd/Build/Products/Debug/{GhosttyTheme,GhosttyTerminal,GhosttyKit,MSDisplayLink}.o \
//          /tmp/dd/Build/Products/Debug/libghostty.a
//      /tmp/chromethemecheck
//
//  Unlike the other checks here this one cannot be built from source files
//  alone: the catalog lives in the `GhosttyTheme` module, and reading the real
//  485 schemes rather than a copy of them is the entire point. So it links the
//  package products a normal `xcodebuild` has already produced. `GhosttyTheme`
//  drags in three more objects for symbols it references but this check never
//  calls, and `libghostty.a` closes those out.
//
//  What this protects is not visible by looking at the app, and that is the
//  point of it. The chrome's colours are derived from whichever of 485 schemes
//  the user picked, so a rule that is right on the two schemes an agent happens
//  to have open can be wrong on a hundred others, in a direction nobody will
//  report — text that is merely hard to read does not look like a bug, it looks
//  like a theme.
//
//  That is exactly how the defect this file was written for survived. The rail
//  was "a step deeper" by `blend(background, toward: .black, by: 0.22)`, which
//  scales the step by how bright the background already is: 5 levels of 255 on
//  a dark scheme, 53 on a light one. Measured on a screenshot 2026-08-25, the
//  light rail sampled (186,187,188) with the row numbers at 1.5:1 on it, while
//  the same three text roles on the dark scheme were at 9.9 / 6.8 / 4.6. Nobody
//  running the dark scheme could have seen it.
//
//  The four properties below are the ones a fixture cannot check, because each
//  is a statement about the *whole* catalog.
//

import AppKit
import GhosttyTheme

// `ChromeTheme.reload()` is the one member that reaches outside this file.
// Stubbed rather than linked, because the derivation is what is under test and
// pulling in `AppSettings` would pull in the app.
enum AppSettings {
    @MainActor static func effectiveThemeDefinition() -> GhosttyThemeDefinition {
        GhosttyThemeCatalog.allThemes[0]
    }
    // Only `reload()` reads these, and this tool never calls it — every case
    // below constructs a theme with an explicit `Glass` instead, which is the
    // point: the settings are an input to the derivation now, so they have to
    // be driven rather than read.
    static let windowOpacity: CGFloat = 1
    static let railCoatDepth: CGFloat = 1
    static let railFillAlpha: CGFloat = 1
}

// MARK: - Reading the result

/// Everything a case wants to know about one derived scheme.
struct Derived {
    let name: String
    let isDark: Bool
    let background: NSColor
    let rail: NSColor
    let text: NSColor
    let muted: NSColor
    let faint: NSColor
    let accent: NSColor
    let onAccent: NSColor

    /// The surface the three text roles were solved against — the rail as it
    /// composites at this glass setting over the worst backdrop for its ink.
    /// Every contrast below is measured here rather than on `rail`, because
    /// that is the thing a person looks at.
    let surface: NSColor
    /// Black or white — the most any tone here could possibly manage.
    let ink: NSColor

    init(_ definition: GhosttyThemeDefinition, glass: ChromeTheme.Glass) {
        let theme = ChromeTheme(definition: definition, glass: glass)
        name = definition.name
        background = theme.background
        rail = theme.railBackground
        text = theme.text
        muted = theme.mutedText
        faint = theme.faintText
        accent = theme.accent
        onAccent = theme.onAccent
        isDark = ChromeTheme.lightness(of: theme.background) < 50
        surface = theme.textSurface
        ink = theme.textInk
    }

    var step: CGFloat {
        ChromeTheme.lightness(of: background) - ChromeTheme.lightness(of: rail)
    }
    var textContrast: CGFloat { ChromeTheme.contrastRatio(text, surface) }
    var mutedContrast: CGFloat { ChromeTheme.contrastRatio(muted, surface) }
    var faintContrast: CGFloat { ChromeTheme.contrastRatio(faint, surface) }
    /// The ceiling: what pure ink would get on this surface. A tone below its
    /// target is only a failure when this says the target was reachable.
    var reachable: CGFloat { ChromeTheme.contrastRatio(ink, surface) }
}

func glass(_ opacity: CGFloat, _ extra: CGFloat) -> ChromeTheme.Glass {
    // The same two expressions `AppSettings` uses, restated so this tool needs
    // no settings file. `railCoatFullDepthExtra` is 0.5.
    ChromeTheme.Glass(
        windowOpacity: opacity,
        coatDepth: min(1, extra / 0.5),
        coatAlpha: opacity >= 1 ? (extra > 0 ? 1 : 0) : min(1, extra / (1 - opacity))
    )
}

/// The slider positions every case below is run at.
///
/// One setting is not a test of this file any more: the text is solved against
/// what the two coats compose to, so a rule that holds at one opacity can fail
/// at another — and the failure that prompted this ran at the *shipped
/// defaults*, not at some extreme. Opaque is the baseline every constant in
/// `ChromeTheme` was originally written against; 55%/10% is what ships; the
/// last two are the ends of what the sliders can reach.
let settings: [(String, ChromeTheme.Glass)] = [
    ("opaque", .opaque),
    ("55% + 10% (shipped)", glass(0.55, 0.10)),
    ("20% + 10%", glass(0.20, 0.10)),
    ("99% + 50%", glass(0.99, 0.50)),
]


func rgb(_ color: NSColor) -> String {
    guard let srgb = color.usingColorSpace(.sRGB) else { return "?" }
    return String(
        format: "(%3.0f,%3.0f,%3.0f)",
        srgb.redComponent * 255, srgb.greenComponent * 255, srgb.blueComponent * 255
    )
}

let catalog = GhosttyThemeCatalog.allThemes
/// The shipped defaults, which the structural cases and the pins both read.
let derived = catalog.map { Derived($0, glass: settings[1].1) }
var failures: [String] = []

// MARK: - 1. The rail is never lighter than the panes

// The obvious way to write a fixed perceptual step is "go 5.5 L* down, and if
// there is no room go 5.5 L* up instead". 56 of the catalog's dark schemes have
// a background below L* 5.5, so that version reverses what the boundary means
// on a sixth of them — and reverses it silently, on schemes whose owner has no
// reason to connect it to a rail setting. `deepened(_:by:)` clamps instead.
for scheme in derived where ChromeTheme.lightness(of: scheme.rail)
    > ChromeTheme.lightness(of: scheme.background) + 0.001
{
    failures.append(
        "rail lighter than panes on \(scheme.name): "
            + "\(rgb(scheme.background)) -> \(rgb(scheme.rail))"
    )
}

// MARK: - 2. The step is the same size everywhere it fits

// The whole reason the derivation moved to L*: "one step deeper" has to be one
// step on every scheme. A fraction is not — that is the defect. Anything short
// of the full step is only allowed when the scheme ran out of room, which means
// the rail is against the floor.
let expectedStep: CGFloat = 5.5
for scheme in derived {
    let short = expectedStep - scheme.step
    guard short > 0.05 else {
        if scheme.step > expectedStep + 0.05 {
            failures.append(
                "step overshoots on \(scheme.name): L* \(String(format: "%.2f", scheme.step))"
            )
        }
        continue
    }
    if ChromeTheme.lightness(of: scheme.rail) > 0.05 {
        failures.append(
            "step short on \(scheme.name) with room to spare: "
                + "L* \(String(format: "%.2f", scheme.step)), rail at L* "
                + String(format: "%.2f", ChromeTheme.lightness(of: scheme.rail))
        )
    }
}

// MARK: - 4. The selected row's own label is legible on it

// The accent has a 3:1 floor against the chrome background, so the selected
// row is always visible. That says nothing about the *label* on it, which is
// black or white by `onAccentSplit` — and WCAG contrast is not symmetric about
// the middle of the range, so a threshold picked to look like a midpoint puts
// white text on accents where black was the readable choice. At the 0.45 this
// started with, 61 of 485 schemes ended under 3:1, worst 2.10:1.
for scheme in derived {
    let label = ChromeTheme.contrastRatio(scheme.onAccent, scheme.accent)
    if label < 3 {
        failures.append(
            "selected-row label under 3:1 on \(scheme.name): "
                + String(format: "%.2f", label) + ":1 — "
                + "\(rgb(scheme.onAccent)) on \(rgb(scheme.accent))"
        )
    }
}

// MARK: - 3. The text, across the whole of both sliders

// One glass setting is not a test of this any more. The text is solved against
// what the two coats compose to, so a rule that holds at one opacity can fail
// at another — and the failure that prompted the composite ran at the *shipped
// defaults*, not at an extreme: over a bright desktop the rail arrives at
// (103,105,108), and a tertiary tone solved against the *paint* colour landed
// on (104,105,107). 1.01:1. Drawn in the colour of the thing it was drawn on,
// and the row numbers were simply not there.
//
// The ordering assertion below looks redundant beside the floors and is the
// opposite: each floor is capped by the role above it, so a broken primary
// drags its own cap down and the floors pass on text nobody can read. Found by
// mutation — flipping the appearance in `systemInk(on:drawnOn:)` reported six
// failures across 485 schemes before there was a case for the primary role.
for (label, glassSetting) in settings {
    for scheme in catalog.map({ Derived($0, glass: glassSetting) }) {
        // Absolute numbers are the wrong assertion out here. At 20% opacity
        // over a white desktop a dark scheme's rail composites to a light
        // grey, and pure white on it manages 1.9:1 — there is no colour that
        // does better, so demanding one would be demanding the impossible.
        // What must hold is that the derivation spent everything it had.
        //
        // Only the primary role gets an absolute expectation here. The quiet
        // two are deliberately allowed to fall with the ceiling — that is what
        // `floorTaper` is for — so pinning them to 5.0 and 3.6 out here would
        // either contradict the implementation or restate it. Their exact
        // numbers are guarded for the two shipped schemes further down; what
        // is guarded for all 485 is that they stay ordered and stay visible.
        let ceiling = scheme.reachable
        for (role, got, want) in [
            ("primary", scheme.textContrast, min(4.5, ceiling)),
        ] where got < want - 0.02 && got < ceiling - 0.02 {
            failures.append(
                "at \(label): \(role) tone below what the ink allows on \(scheme.name) — "
                    + String(format: "%.2f", got) + ":1 with "
                    + String(format: "%.2f", ceiling) + ":1 available"
            )
        }
        // The thing that actually happened, stated directly: a tone must never
        // be the colour of the surface it is drawn on. 1.01:1 is what the
        // tertiary role measured at the shipped defaults before the composite
        // was part of the derivation.
        for (role, value) in [
            ("primary", scheme.textContrast),
            ("secondary", scheme.mutedContrast),
            ("tertiary", scheme.faintContrast),
        ] where value < min(1.6, ceiling - 0.02) {
            failures.append(
                "at \(label): \(role) tone is indistinguishable from the rail on "
                    + "\(scheme.name) — " + String(format: "%.2f", value) + ":1"
            )
        }
        if scheme.mutedContrast > scheme.textContrast + 0.02
            || scheme.faintContrast > scheme.mutedContrast + 0.02
        {
            failures.append("at \(label): text roles out of order on \(scheme.name)")
        }
    }
}

// MARK: - 5. The two schemes the fix was measured on

// Regression guards with the numbers written down, so a later change to the
// step or the floors has to move these on purpose. Both are the shipped
// defaults in `AppSettings`.
struct Pin {
    let scheme: String
    let rail: String
    let text: CGFloat
    let muted: CGFloat
    let faint: CGFloat
}

let pins = [
    // The dark default. These are measured on the *composited* rail at the
    // shipped 55% / 10% over the worst backdrop for its ink — a white desktop
    // — which is the number a person can actually be shown, and far below the
    // 14.06 / 6.24 / 3.60 the same scheme gets on the paint colour. The old
    // derivation put the tertiary tone at 1.01:1 here.
    Pin(scheme: "Ayu", rail: "( 10, 11, 13)", text: 4.52, muted: 3.34, faint: 2.62),
    // The light default, and the scheme the complaint started on. Its rail
    // composites over a black desktop instead, and it started at 3.26 / 2.14 /
    // 1.52 measured on the paint alone.
    Pin(scheme: "Ayu Light", rail: "(223,224,225)", text: 6.41, muted: 4.42, faint: 3.29),
]

for pin in pins {
    guard let definition = GhosttyThemeCatalog.theme(named: pin.scheme) else {
        failures.append("scheme missing from the catalog: \(pin.scheme)")
        continue
    }
    let scheme = Derived(definition, glass: settings[1].1)
    if rgb(scheme.rail) != pin.rail {
        failures.append("\(pin.scheme) rail is \(rgb(scheme.rail)), expected \(pin.rail)")
    }
    for (role, got, want) in [
        ("name", scheme.textContrast, pin.text),
        ("secondary", scheme.mutedContrast, pin.muted),
        ("tertiary", scheme.faintContrast, pin.faint),
    ] where abs(got - want) > 0.01 {
        failures.append(
            "\(pin.scheme) \(role) is " + String(format: "%.2f", got)
                + ":1, expected " + String(format: "%.2f", want) + ":1"
        )
    }
}

// MARK: - Report

let darkCount = derived.filter(\.isDark).count
if failures.isEmpty {
    print(
        "ChromeThemeCheck: \(derived.count) schemes "
            + "(\(darkCount) dark, \(derived.count - darkCount) light), all pass"
    )
    // The distribution is not a pass condition — it is what makes a regression
    // legible when one of the cases above starts failing.
    print(
        "  primary text: worst "
            + String(format: "%.2f", derived.map(\.textContrast).min() ?? 0) + ":1"
    )
    let labels = derived.map { ChromeTheme.contrastRatio($0.onAccent, $0.accent) }
    print(
        "  selected-row label: worst "
            + String(format: "%.2f", labels.min() ?? 0) + ":1, under 4.5:1 on "
            + "\(labels.filter { $0 < 4.5 }.count) scheme(s)"
    )
    // Reported rather than asserted. Under the composite these are ordinary
    // numbers, not anomalies: at the shipped opacity over the worst desktop a
    // dark scheme's rail is a mid grey and 3:1 is simply not on offer. What
    // would be an anomaly is a tone that cannot be told from the rail at all,
    // which is the counter worth watching.
    let quiet = derived.map(\.faintContrast)
    print(
        "  tertiary tone: worst " + String(format: "%.2f", quiet.min() ?? 0)
            + ":1, indistinguishable (under 1.6:1) on "
            + "\(quiet.filter { $0 < 1.6 }.count) scheme(s)"
    )
    let clamped = derived.filter { $0.step < expectedStep - 0.05 }
    print("  rail step clamped by a near-black background on \(clamped.count) scheme(s)")
} else {
    for failure in failures.prefix(40) { print("FAIL  \(failure)") }
    if failures.count > 40 { print("… and \(failures.count - 40) more") }
    print("ChromeThemeCheck: \(failures.count) failure(s) across \(derived.count) schemes")
    exit(1)
}
