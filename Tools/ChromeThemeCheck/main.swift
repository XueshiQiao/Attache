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

    init(_ definition: GhosttyThemeDefinition) {
        let theme = ChromeTheme(definition: definition)
        name = definition.name
        background = theme.background
        rail = theme.railBackground
        text = theme.text
        muted = theme.mutedText
        faint = theme.faintText
        accent = theme.accent
        onAccent = theme.onAccent
        isDark = ChromeTheme.lightness(of: theme.background) < 50
    }

    var step: CGFloat {
        ChromeTheme.lightness(of: background) - ChromeTheme.lightness(of: rail)
    }
    var textContrast: CGFloat { ChromeTheme.contrastRatio(text, rail) }
    var mutedContrast: CGFloat { ChromeTheme.contrastRatio(muted, rail) }
    var faintContrast: CGFloat { ChromeTheme.contrastRatio(faint, rail) }
}

func rgb(_ color: NSColor) -> String {
    guard let srgb = color.usingColorSpace(.sRGB) else { return "?" }
    return String(
        format: "(%3.0f,%3.0f,%3.0f)",
        srgb.redComponent * 255, srgb.greenComponent * 255, srgb.blueComponent * 255
    )
}

let catalog = GhosttyThemeCatalog.allThemes
let derived = catalog.map(Derived.init)
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

// MARK: - 3. The loud text role is legible at all

// This looks redundant next to the floors below and is the opposite: without
// it they are *vacuous*. Each floor is capped by the role above it so a weak
// scheme flattens rather than inverts, which means a broken primary drags its
// own cap down with it — `min(mutedFloor, nameContrast)` with a nameContrast
// of 1.24 asks the secondary tone for 1.24:1, and it obliges. Every other case
// here then passes on text nobody can read.
//
// Found by mutation, not by reading: flipping the appearance in
// `systemInk(on:drawnOn:)` — white ink on a light rail, the exact thing that
// helper exists to prevent — produced six failures across 485 schemes before
// this case existed, and the floors quietly repaired most of the damage into
// something that merely looked wrong.
//
// 3.5 rather than WCAG's 4.5 for body text because one shipped scheme is
// genuinely below it: Hot Dog Stand, whose own background is fluorescent red,
// lands at 3.95. The next worst is 4.96 and the median is 12.11, so this is a
// tripwire for "the ink went the wrong way", not a design target.
for scheme in derived where scheme.textContrast < 3.5 {
    failures.append(
        "primary text under 3.5:1 on \(scheme.name): "
            + String(format: "%.2f", scheme.textContrast) + ":1 — "
            + "\(rgb(scheme.text)) on \(rgb(scheme.rail))"
    )
}

// MARK: - 4. The three text roles stay in order

// The floors are what stop a weak scheme's secondary text from being illegible,
// and an uncapped floor is how they would break the thing they protect: a
// scheme whose own foreground is 3.5:1 on the rail would get a *secondary* tone
// pushed to 4:1, so the quiet role would read as the loud one. Each floor is
// capped by the role above it, and this is that cap.
for scheme in derived {
    if scheme.mutedContrast > scheme.textContrast + 0.02 {
        failures.append(
            "secondary out-contrasts the name on \(scheme.name): "
                + String(format: "%.2f", scheme.mutedContrast) + " > "
                + String(format: "%.2f", scheme.textContrast)
        )
    }
    if scheme.faintContrast > scheme.mutedContrast + 0.02 {
        failures.append(
            "tertiary out-contrasts the secondary on \(scheme.name): "
                + String(format: "%.2f", scheme.faintContrast) + " > "
                + String(format: "%.2f", scheme.mutedContrast)
        )
    }
}

// MARK: - 5. The floors are actually reached wherever they can be

// A floor that silently gives up is worse than no floor, because the number in
// the source then describes something that never happens. Where the scheme has
// the headroom — its own foreground clears the floor — the tone must land on
// it, not near it.
for scheme in derived {
    let mutedTarget = min(4.0, scheme.textContrast)
    if scheme.mutedContrast < mutedTarget - 0.02 {
        failures.append(
            "secondary under its floor on \(scheme.name): "
                + String(format: "%.2f", scheme.mutedContrast) + " < "
                + String(format: "%.2f", mutedTarget)
        )
    }
    let faintTarget = min(3.0, scheme.mutedContrast)
    if scheme.faintContrast < faintTarget - 0.02 {
        failures.append(
            "tertiary under its floor on \(scheme.name): "
                + String(format: "%.2f", scheme.faintContrast) + " < "
                + String(format: "%.2f", faintTarget)
        )
    }
}

// MARK: - 6. The selected row's own label is legible on it

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

// MARK: - 7. The two schemes the fix was measured on

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
    // The dark default. The rail moved by at most 10 of 255; the text now
    // comes from the system rather than the scheme, which lifts the name and
    // costs the quiet tones a little — 7.18 / 4.88 before.
    Pin(scheme: "Ayu", rail: "( 10, 11, 13)", text: 14.06, muted: 6.24, faint: 3.60),
    // The light default, and the scheme the complaint came from. Started at
    // rail (186,187,188) with 3.26 / 2.14 / 1.52, and was 4.74 / 4.00 / 3.00
    // with the rail fixed but the text still derived from the scheme.
    Pin(scheme: "Ayu Light", rail: "(223,224,225)", text: 12.02, muted: 5.00, faint: 3.60),
]

for pin in pins {
    guard let definition = GhosttyThemeCatalog.theme(named: pin.scheme) else {
        failures.append("scheme missing from the catalog: \(pin.scheme)")
        continue
    }
    let scheme = Derived(definition)
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
    let unreadable = derived.filter { $0.faintContrast < 3 }
    print(
        "  tertiary tone under 3:1 on \(unreadable.count) scheme(s)"
            + (unreadable.isEmpty ? "" : ": " + unreadable.map(\.name).joined(separator: ", "))
    )
    let clamped = derived.filter { $0.step < expectedStep - 0.05 }
    print("  rail step clamped by a near-black background on \(clamped.count) scheme(s)")
} else {
    for failure in failures.prefix(40) { print("FAIL  \(failure)") }
    if failures.count > 40 { print("… and \(failures.count - 40) more") }
    print("ChromeThemeCheck: \(failures.count) failure(s) across \(derived.count) schemes")
    exit(1)
}
