//
//  BehaviourPage.swift
//  TmuxGUI
//

import SwiftUI

// Settings that change what the app does rather than how it looks.

struct BehaviourPage: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                HStack {
                    featureLabel(
                        "clock.arrow.circlepath", .orange,
                        "Replay on first show",
                        "How much of a pane's history to pull in the first time it appears."
                    )
                    Spacer(minLength: 8)
                    Text(store.scrollbackPrimeLines == 0 ? "none" : "\(store.scrollbackPrimeLines)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper(
                        value: Binding(
                            get: { Double(store.scrollbackPrimeLines) },
                            set: { store.setScrollbackPrimeLines(Int($0)) }
                        ),
                        in: Double(AppSettings.scrollbackPrimeRange.lowerBound)
                            ... Double(AppSettings.scrollbackPrimeRange.upperBound),
                        step: 250
                    ) { EmptyView() }
                        .labelsHidden()
                    Button("Reset") { store.resetScrollbackPrimeLines() }
                        .controlSize(.small)
                        .disabled(store.scrollbackPrimeLines == AppSettings.defaultScrollbackPrimeLines)
                }

                HStack {
                    featureLabel(
                        "sidebar.left", .teal,
                        "Session rail width",
                        "The left-hand rail. The traffic lights float over it, so it has a floor."
                    )
                    Spacer(minLength: 8)
                    Text("\(Int(store.sidebarWidth)) pt")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper(
                        value: Binding(get: { store.sidebarWidth }, set: { store.setSidebarWidth($0) }),
                        in: AppSettings.sidebarWidthRange, step: 4
                    ) { EmptyView() }
                        .labelsHidden()
                    Button("Reset") { store.resetSidebarWidth() }
                        .controlSize(.small)
                        .disabled(store.sidebarWidth == AppSettings.defaultSidebarWidth)
                }
            } header: {
                Text("Layout")
            } footer: {
                Text(
                    "tmux clamps the replay to what a pane actually has, so the number is a "
                        + "ceiling rather than a cost — but every replayed line crosses the "
                        + "control-mode pipe, and a large value on a busy session is felt."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker(selection: Binding(
                    get: { store.closingTabKillsWindow },
                    set: { store.setClosingTabKillsWindow($0) }
                )) {
                    Text("Hide the tab — tmux keeps running").tag(false)
                    Text("Kill the tmux window").tag(true)
                } label: {
                    iconLabel("xmark.square.fill", store.closingTabKillsWindow ? .red : .gray, "Closing a tab")
                }

                if store.closingTabKillsWindow {
                    Label(
                        "Killing ends every process in the window, including an agent mid-run, "
                            + "and there is no undo. The ✕ still asks first.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Tabs")
            } footer: {
                Text(
                    "Hiding removes the tab from this app's strip and sends tmux nothing at "
                        + "all; the window is still there in `tmux attach` and the strip's "
                        + "hidden badge brings it back."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Behaviour")
    }
}
