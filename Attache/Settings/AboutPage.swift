//
//  AboutPage.swift
//  Attache
//

import AppKit
import SwiftUI

// The app hero, plus the update controls and the links back to the source.

struct AboutPage: View {
    @EnvironmentObject var store: SettingsStore
    @ObservedObject private var updates = AppUpdates.shared

    private var versionString: String {
        let bundle = Bundle.main
        let short = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        return "Version \(short) (\(build))"
    }

    private static let repoURL = URL(string: "https://github.com/XueshiQiao/Attache")!
    private static let releasesURL = URL(string: "https://github.com/XueshiQiao/Attache/releases")!

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                    Text("Attaché").font(.title2).fontWeight(.bold)
                    Text(versionString).font(.callout).foregroundStyle(.secondary)
                    Text("A native window onto tmux. tmux owns the sessions, windows and panes; this app renders them and translates clicks back into tmux commands.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section("Updates") {
                HStack(spacing: 12) {
                    featureLabel(
                        "arrow.down.circle.fill", .blue, "Check for Updates",
                        "Look for a newer version right now."
                    )
                    Spacer(minLength: 8)
                    // Disabled while a check is already running — `canCheck`
                    // mirrors Sparkle's own `canCheckForUpdates`.
                    Button("Check Now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheck)
                }
                .padding(.vertical, 2)

                optionRow(
                    symbol: "arrow.triangle.2.circlepath", color: .green,
                    title: "Automatic Updates",
                    subtitle: "Check in the background and offer new versions as they ship."
                ) {
                    Toggle("", isOn: Binding(
                        get: { updates.automaticallyChecks },
                        set: { updates.setAutomaticallyChecks($0) }
                    ))
                    .labelsHidden()
                }
            }

            Section("Source") {
                Link(destination: Self.repoURL) {
                    iconLabel("chevron.left.forwardslash.chevron.right", .gray, "GitHub Repository")
                }
                Link(destination: Self.releasesURL) {
                    iconLabel("shippingbox.fill", .brown, "All Releases")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}
