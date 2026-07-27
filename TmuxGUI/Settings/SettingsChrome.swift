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

/// The whole settings window, in SwiftUI, the way AnyDrag next door does it.
///
/// This was briefly rebuilt on an `NSSplitViewController` to chase the sidebar
/// look, and that was the wrong turn: `NavigationSplitView` with the sidebar
/// list style is what produces the standard appearance — a grey that reaches
/// the window's corner with the traffic lights inside it, and a selection drawn
/// as an inset rounded pill rather than a full-width bar. Rebuilding it in
/// AppKit got the grey right and the selection wrong.
///
/// The piece that was missing is the toolbar. With `toolbarStyle = .unified`
/// and no toolbar items at all, the band is reserved and nothing fills it, and
/// the sidebar starts below it. AnyDrag has a sidebar-toggle button there; so
/// does this now, and it earns its place — the split view can collapse and
/// there would otherwise be no way back.
struct SettingsRootView: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        NavigationSplitView {
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
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 206, max: 240)
            .safeAreaInset(edge: .top, spacing: 0) { brand }
        } detail: {
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
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        NSApp.keyWindow?.firstResponder?.tryToPerform(
                            #selector(NSSplitViewController.toggleSidebar(_:)), with: nil
                        )
                    } label: {
                        Image(systemName: "sidebar.leading")
                    }
                    .help("Show or hide the sidebar")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
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
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
