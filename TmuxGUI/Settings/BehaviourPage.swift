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
            // First on the page on purpose. It is the only setting here that
            // can end a process, and it used to sit below two steppers and a
            // three-line footer — far enough down that the owner of the app
            // asked twice for a setting that was already there.
            Section {
                Picker(selection: Binding(
                    get: { store.closingTabKillsWindow },
                    set: { store.setClosingTabKillsWindow($0) }
                )) {
                    // The menu items' own wording, verbatim. A picker that
                    // paraphrases what it selects makes the user match two
                    // different sentences to the same thing, and these two
                    // are exactly long enough to be truncated if anything is
                    // appended — measured in the window at its default size.
                    Text("Hide From The Sidebar").tag(false)
                    Text("Kill This tmux Window…").tag(true)
                } label: {
                    iconLabel(
                        "contextualmenu.and.cursorarrow",
                        store.closingTabKillsWindow ? .red : .gray,
                        "First item on a window's menu"
                    )
                }

                if store.closingTabKillsWindow {
                    Label(
                        "Killing ends every process in the window, including an agent mid-run, "
                            + "and there is no undo. It still asks first.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Windows")
            } footer: {
                // What this setting used to be: what the ✕ on a window tab did.
                // There are no tabs and no ✕ — the windows are rows in the rail
                // — so it moved to the only close gesture left rather than being
                // retired. It cannot take a capability away: both items are in
                // the menu whichever way it is set, so all it decides is which
                // one the pointer lands on first.
                Text(
                    "Both actions are always in the menu; this only decides which one comes "
                        + "first. Hiding removes the row from the sidebar and sends tmux nothing "
                        + "at all — the window is still there in `tmux attach`, and the "
                        + "\"N hidden\" row under the session brings it back."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(isOn: Binding(
                    get: { store.copyOnSelect },
                    set: { store.setCopyOnSelect($0) }
                )) {
                    iconLabel(
                        "text.cursor",
                        store.copyOnSelect ? .blue : .gray,
                        "Copy on select"
                    )
                }
            } header: {
                Text("Selection")
            } footer: {
                // Off is macOS; on is what iTerm2 and most Linux terminals do.
                // Said plainly because the cost only shows up later: a
                // selection made while reading has already replaced whatever
                // was on the clipboard.
                Text(
                    "Off, selected text goes to the clipboard only when you press ⌘C. On, it "
                        + "goes there the moment you release the mouse — which also means any "
                        + "selection you make while reading replaces what you last copied."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

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

        }
        .formStyle(.grouped)
        .navigationTitle("Behaviour")
    }
}
