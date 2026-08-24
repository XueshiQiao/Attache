//
//  AppearancePages.swift
//  Attache
//

import AppKit
import GhosttyTheme
import SwiftUI

// The two pages that change how the terminal looks: the font it is drawn in,
// and the colour scheme it and the surrounding chrome are drawn from.

// MARK: - Terminal

struct TerminalPage: View {
    @EnvironmentObject var store: SettingsStore

    private static let systemFontTag = ""

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(
                    get: { store.fontFamily },
                    set: { store.setFontFamily($0) }
                )) {
                    Text("libghostty default").tag(Self.systemFontTag)
                    Divider()
                    ForEach(SettingsStore.monospacedFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                } label: {
                    iconLabel("textformat", .blue, "Font")
                }

                HStack {
                    iconLabel("textformat.size", .indigo, "Size")
                    Spacer()
                    Text("\(Int(store.fontSize)) pt")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper(
                        value: Binding(get: { store.fontSize }, set: { store.setFontSize($0) }),
                        in: AppSettings.fontSizeRange, step: 1
                    ) { EmptyView() }
                        .labelsHidden()
                    Button("Reset") { store.resetFontSize() }
                        .controlSize(.small)
                        .disabled(store.fontSize == AppSettings.defaultFontSize)
                }
            } header: {
                Text("Font")
            } footer: {
                Text(
                    "Only monospaced families are listed. Changing either value changes the "
                        + "size of a character cell, so the app re-measures the grid and tells "
                        + "tmux the new column and row count."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                TerminalSamplePreview(definition: previewDefinition, fontFamily: store.fontFamily, fontSize: store.fontSize)
            } header: {
                Text("Preview")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Terminal")
    }

    /// What the panes are showing right now, so the sample matches them.
    private var previewDefinition: GhosttyThemeDefinition {
        let isDark = switch store.appearance {
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        case .light: false
        case .dark: true
        }
        return AppSettings.themeDefinition(
            named: isDark ? store.darkThemeName : store.lightThemeName,
            default: isDark ? AppSettings.defaultDarkThemeName : AppSettings.defaultLightThemeName
        )
    }
}

// MARK: - Appearance

/// What the two sliders above actually control. The window's translucency is
/// this app's own — a window-server blur at a radius the user picks, with a
/// tint over it — and saying so is the only way "tint" and "blur radius" read
/// as two knobs rather than one.
private let glassFooter =
    "The tint is how much of the terminal's own colour is laid over what shows "
        + "through. 100% is a solid window and costs nothing to draw. The desktop "
        + "behind the window is blurred at whatever radius you ask for, which is the "
        + "one thing macOS's own materials will not let anyone change."

/// One labelled slider with a live readout/// One labelled slider with a live readout and nothing else. Five of these in
/// a row is the whole glass section, and writing them out longhand made the
/// difference between them impossible to see.
@MainActor
private func glassSlider(
    _ symbol: String, _ colour: Color, _ title: String,
    value: CGFloat, in range: ClosedRange<CGFloat>,
    format: @escaping (CGFloat) -> String,
    set: @escaping (CGFloat) -> Void
) -> some View {
    LabeledContent {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { value }, set: set), in: range)
            Text(format(value))
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    } label: {
        iconLabel(symbol, colour, title)
    }
}

struct AppearancePage: View {
    @EnvironmentObject var store: SettingsStore
    @State private var editingDarkSlot: Bool?
    @State private var query = ""

    /// Which of the two theme slots the list is editing. Defaults to whichever
    /// one is on screen, so the list opens on the scheme the user is looking at.
    private var isEditingDarkSlot: Bool {
        editingDarkSlot ?? {
            switch store.appearance {
            case .system: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            case .light: false
            case .dark: true
            }
        }()
    }

    private var selectedName: String {
        isEditingDarkSlot ? store.darkThemeName : store.lightThemeName
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(
                    get: { store.appearance },
                    set: { store.setAppearance($0) }
                )) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                } label: {
                    iconLabel("circle.lefthalf.filled", .purple, "Appearance")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(
                    "Following the system picks between the two schemes below. An override "
                        + "pins the whole app — menus and dialogs included — to one of them."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                glassSlider(
                    "circle.lefthalf.striped.horizontal", .teal, "Window opacity",
                    value: store.windowOpacity, in: AppSettings.windowOpacityRange,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                ) { store.setWindowOpacity($0) }

                glassSlider(
                    "sidebar.left", .indigo, "Extra sidebar opacity",
                    value: store.railExtraOpacity, in: AppSettings.railExtraOpacityRange,
                    format: { $0 <= 0 ? "same" : "+\(Int(($0 * 100).rounded()))%" }
                ) { store.setRailExtraOpacity($0) }

                glassSlider(
                    "drop.fill", .cyan, "Blur radius",
                    value: store.blurRadius, in: AppSettings.blurRadiusRange,
                    format: { "\(Int($0.rounded()))pt" }
                ) { store.setBlurRadius($0) }

                HStack {
                    Spacer()
                    Button("Reset to defaults") { store.resetGlass() }
                }
            } footer: {
                Text(glassFooter)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker(selection: Binding(
                    get: { isEditingDarkSlot },
                    set: { editingDarkSlot = $0; query = "" }
                )) {
                    Text("Light scheme").tag(false)
                    Text("Dark scheme").tag(true)
                } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(SettingsStore.allThemes.count) schemes", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // A plain scrolling stack rather than a nested `List`: a List
                // inside the split view's detail column loses its own layout
                // and spills its rows into the title bar.
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(SettingsStore.themes(matching: query)) { definition in
                            ThemeRow(definition: definition, isSelected: definition.name == selectedName) {
                                if isEditingDarkSlot {
                                    store.setDarkThemeName(definition.name)
                                } else {
                                    store.setLightThemeName(definition.name)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 260)
            } header: {
                Text(isEditingDarkSlot ? "Dark scheme — \(store.darkThemeName)" : "Light scheme — \(store.lightThemeName)")
            } footer: {
                Text(
                    "The tab strip, session rail and splitters follow the terminal scheme too. "
                        + "Their colours are blended from the scheme's own text and background "
                        + "pair, which is the only pair a scheme guarantees is readable together."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }
}

// MARK: - Rows

private struct ThemeRow: View {
    let definition: GhosttyThemeDefinition
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                ThemeSwatch(definition: definition)
                Text(definition.name).lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

/// A scheme's background, its text colour, and four of its ANSI colours — the
/// smallest sample that tells two schemes apart at list speed.
private struct ThemeSwatch: View {
    let definition: GhosttyThemeDefinition

    var body: some View {
        HStack(spacing: 3) {
            Text("Aa")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color(definition.foreground) ?? .primary)
            ForEach([1, 2, 4, 5], id: \.self) { index in
                Circle()
                    .fill(definition.palette[index].flatMap(color) ?? .clear)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 5)
        .frame(width: 62, height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(color(definition.background) ?? Color(nsColor: .textBackgroundColor))
        )
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)))
    }

    private func color(_ hex: String) -> Color? {
        ChromeTheme.color(hex: hex).map(Color.init(nsColor:))
    }
}

/// A few lines of terminal-looking text in the scheme and font the panes use,
/// so a font pick can be judged without switching windows.
private struct TerminalSamplePreview: View {
    let definition: GhosttyThemeDefinition
    let fontFamily: String
    let fontSize: Double

    private static let lines: [(Int, String)] = [
        (2, "$ tmux list-panes -F '#{pane_id} #{pane_width}x#{pane_height}'"),
        (7, "%0 120x33"),
        (7, "%1 119x33"),
        (4, "$ ▏"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, line in
                Text(line.1)
                    .font(font)
                    .foregroundStyle(paletteColor(line.0) ?? foreground)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
    }

    private var font: Font {
        // `.custom` falls back to the system font when the family is missing,
        // which is the same thing libghostty does, so the sample cannot claim
        // a font the terminal will not actually use.
        fontFamily.isEmpty
            ? .system(size: fontSize, design: .monospaced)
            : .custom(fontFamily, fixedSize: fontSize)
    }

    private var background: Color {
        ChromeTheme.color(hex: definition.background).map(Color.init(nsColor:))
            ?? Color(nsColor: .textBackgroundColor)
    }

    private var foreground: Color {
        ChromeTheme.color(hex: definition.foreground).map(Color.init(nsColor:)) ?? .primary
    }

    private func paletteColor(_ index: Int) -> Color? {
        definition.palette[index].flatMap(ChromeTheme.color(hex:)).map(Color.init(nsColor:))
    }
}
