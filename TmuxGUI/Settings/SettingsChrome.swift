//
//  SettingsChrome.swift
//  TmuxGUI
//

import AppKit
import SwiftUI

// The shared visual language of the settings window — the sidebar shell, the
// coloured icon tiles, and the row builders every page is assembled from — so
// that adding a page is adding a file and a sidebar entry.
//
// Deliberately system-native: this window is the one place in the app that
// does *not* follow the terminal theme. Stock controls in stock colours are
// always legible, and a settings window that restyled itself as the user
// scrolled a list of 485 schemes would be unusable exactly when it matters.

// MARK: - Sidebar pages

enum SettingsPage: Hashable, CaseIterable {
    case terminal, appearance, behaviour, about

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .appearance: "Appearance"
        case .behaviour: "Behaviour"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: "textformat"
        case .appearance: "paintpalette.fill"
        case .behaviour: "slider.horizontal.3"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .terminal: .blue
        case .appearance: .purple
        case .behaviour: .teal
        case .about: .pink
        }
    }

    /// Language-independent id stem for accessibility identifiers.
    var axID: String {
        switch self {
        case .terminal: "terminal"
        case .appearance: "appearance"
        case .behaviour: "behaviour"
        case .about: "about"
        }
    }
}

// MARK: - Background

extension View {
    /// The soft wash behind every page, composited over an OPAQUE window base.
    /// Opaque matters: paired with `.scrollContentBackground(.hidden)`, a
    /// translucent wash makes the window vibrancy re-sample the desktop on
    /// every frame of a drag.
    func settingsBackground() -> some View {
        background(
            Color(nsColor: .windowBackgroundColor)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color(.sRGB, red: 0.40, green: 0.55, blue: 1.00, opacity: 0.10),
                            Color(.sRGB, red: 1.00, green: 0.55, blue: 0.85, opacity: 0.07),
                            Color(.sRGB, red: 0.35, green: 0.85, blue: 0.70, opacity: 0.08),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()
        )
    }
}

// MARK: - Icon tiles

/// White SF Symbol on a 26pt rounded gradient tile.
struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.72)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.18)))
    }
}

/// A System-Settings-style sidebar row icon. Rasterized so the row-selection
/// vibrancy cannot tint it.
struct SidebarIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(
                    LinearGradient(
                        colors: [color.opacity(0.98), color.opacity(0.68)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            )
            .drawingGroup()
    }
}

/// Leading "icon tile + text" label, used in almost every settings row.
func iconLabel(_ symbol: String, _ color: Color, _ text: String) -> some View {
    HStack(spacing: 10) { IconTile(symbol: symbol, color: color); Text(text) }
}

/// Icon tile + title over a wrapping secondary subtitle.
func featureLabel(_ symbol: String, _ color: Color, _ title: String, _ subtitle: String) -> some View {
    HStack(spacing: 10) {
        IconTile(symbol: symbol, color: color)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A feature row: icon + title + subtitle on the left, a control on the right.
@ViewBuilder
func optionRow(
    symbol: String,
    color: Color,
    title: String,
    subtitle: String,
    @ViewBuilder control: () -> some View
) -> some View {
    HStack(spacing: 12) {
        featureLabel(symbol, color, title, subtitle)
        Spacer(minLength: 8)
        control()
    }
    .padding(.vertical, 2)
}

// MARK: - Root view

/// The sidebar half, on its own so AppKit can own the split.
///
/// It used to be SwiftUI's `NavigationSplitView`. On macOS 26 that renders the
/// sidebar as an inset rounded panel with the traffic lights sitting in the
/// band above it, which is not the standard sidebar — the grey should run to
/// the top of the window with the lights inside it. `NSSplitViewController`
/// with a sidebar item gets that for free, and the main window already proved
/// it, so the settings window uses the same shell and keeps its pages as
/// SwiftUI.
struct SettingsSidebarView: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        List(selection: $store.page) {
            ForEach(SettingsPage.allCases, id: \.self) { page in
                HStack(spacing: 9) {
                    SidebarIcon(symbol: page.symbol, color: page.color)
                    Text(page.title)
                }
                .padding(.vertical, 2)
                .tag(page)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("nav.\(page.axID)")
            }
        }
        // `.plain`, not `.sidebar`. On macOS 26 the sidebar list style draws
        // its own inset rounded panel, which is what kept the traffic lights in
        // a band above the grey instead of inside it — the split view item was
        // already full height, the list was just not filling it. Plain leaves
        // the item's own material as the background and the rows are styled
        // here instead.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { brand }
        // Fill the whole split view item, including the band the system keeps
        // clear for the traffic lights. Without this the content stops below
        // them and the grey reads as an inset panel with the lights floating
        // above it, which is the thing this window was reported for. The brand
        // block's own top padding is what keeps the lights from landing on the
        // app icon.
        .ignoresSafeArea(.all)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text("TmuxGUI").font(.system(size: 14, weight: .bold))
                Text("v\(appVersion)").font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
        }
        // Top padding clears the traffic lights, which now sit over this view
        // rather than in a band above it.
        .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

/// The page half.
struct SettingsDetailView: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Group {
            switch store.page {
            case .terminal: TerminalPage()
            case .appearance: AppearancePage()
            case .behaviour: BehaviourPage()
            case .about: AboutPage()
            }
        }
        .accessibilityIdentifier("page.\(store.page.axID)")
        .environment(\.defaultMinListRowHeight, 34)
        .scrollContentBackground(.hidden)
        .settingsBackground()
    }
}
