//
//  BehaviourPage.swift
//  Attache
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
                    get: { store.sidebarShowsGit },
                    set: { store.setSidebarShowsGit($0) }
                )) {
                    iconLabel(
                        "arrow.triangle.branch",
                        store.sidebarShowsGit ? .orange : .gray,
                        "Second line on each window row"
                    )
                }

                Toggle(isOn: Binding(
                    get: { store.sidebarShowsAgent },
                    set: { store.setSidebarShowsAgent($0) }
                )) {
                    iconLabel(
                        "circle.fill",
                        store.sidebarShowsAgent ? .blue : .gray,
                        "Mark windows running a coding agent"
                    )
                }

                if store.sidebarShowsAgent {
                    Picker(selection: Binding(
                        get: { store.agentStateSource },
                        set: { store.setAgentStateSource($0) }
                    )) {
                        ForEach(AgentStateSource.allCases, id: \.self) { source in
                            Text(source.title).tag(source)
                        }
                    } label: {
                        iconLabel(
                            "antenna.radiowaves.left.and.right",
                            .blue,
                            "Where the agent's state comes from"
                        )
                    }

                    Label(
                        store.agentStateSource == .hook
                            ? "Exact, and the state is stored in tmux so any terminal attached to "
                                + "the same session sees it. Needs the hook below."
                            : "Needs nothing installed, and works the moment an agent appears. "
                                + "It reads the pane and infers, so it is guessing from a user "
                                + "interface its author is free to change — and it only knows "
                                + "Claude Code's. A pane it has no rules for is marked as an "
                                + "agent and nothing more.",
                        systemImage: store.agentStateSource == .hook ? "checkmark.seal" : "eye"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: Binding(
                        get: { store.sidebarShowsAgentText },
                        set: { store.setSidebarShowsAgentText($0) }
                    )) {
                        iconLabel(
                            "textformat",
                            store.sidebarShowsAgentText ? .blue : .gray,
                            "Spell the agent's state out beside the dot"
                        )
                    }

                    Toggle(isOn: Binding(
                        get: { store.sidebarShowsAgentStats },
                        set: { store.setSidebarShowsAgentStats($0) }
                    )) {
                        iconLabel(
                            "gauge.with.needle",
                            store.sidebarShowsAgentStats ? .blue : .gray,
                            "Model, context and cost on the row"
                        )
                    }

                    Toggle(isOn: Binding(
                        get: { store.sidebarShowsUsage },
                        set: { store.setSidebarShowsUsage($0) }
                    )) {
                        iconLabel(
                            "chart.bar.horizontal.page",
                            store.sidebarShowsUsage ? .blue : .gray,
                            "5-hour and weekly limits at the foot of the rail"
                        )
                    }

                    if store.sidebarShowsAgentStats || store.sidebarShowsUsage {
                        Label(
                            store.statusLineInstalled
                                ? "Both read the status line wrapper below."
                                : "Both need the status line wrapper below — without it there is "
                                    + "nothing to draw, and rows stay the height they are now.",
                            systemImage: store.statusLineInstalled ? "checkmark.seal" : "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: Binding(
                    get: { store.gitAutoFetch },
                    set: { store.setGitAutoFetch($0) }
                )) {
                    iconLabel(
                        "arrow.down.circle",
                        store.gitAutoFetch ? .blue : .gray,
                        "Fetch in the background so ↓ is real"
                    )
                }

                if store.gitAutoFetch {
                    Stepper(
                        value: Binding(
                            get: { store.gitAutoFetchMinutes },
                            set: { store.setGitAutoFetchMinutes($0) }
                        ),
                        in: AppSettings.gitAutoFetchMinutesRange
                    ) {
                        Text("Every \(store.gitAutoFetchMinutes) minute\(store.gitAutoFetchMinutes == 1 ? "" : "s")")
                    }

                    Label(
                        "This opens a network connection to every remote of every repository the "
                            + "sidebar is showing. It never prompts for credentials — a repository "
                            + "that needs them is skipped instead.",
                        systemImage: "network"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Sidebar status")
            } footer: {
                // The honest version of the `↓` column, written down where the
                // decision is made rather than only in a tooltip.
                Text(
                    "The second line shows the branch and what has changed in it. Turning it off "
                        + "puts the rows back to a single line, which fits about half again as "
                        + "many windows on screen.\n\n"
                        + "Git can only compare against the last `git fetch`, so without "
                        + "background fetching a repository can be behind its remote and the "
                        + "sidebar has no way to know. With it off, the row's tooltip says how "
                        + "long ago the last fetch was rather than showing a ↓0 that would read "
                        + "as \"nothing to pull\"."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                // Deliberately not a toggle. A switch reads as a preference,
                // and this writes a file belonging to another program that
                // several other tools have written into — the button says what
                // it does and shows the change first.
                HStack {
                    iconLabel(
                        store.agentHookInstalled ? "checkmark.seal.fill" : "seal",
                        store.agentHookInstalled ? .green : .gray,
                        store.agentHookInstalled
                            ? "Claude Code reports its state"
                            : "Claude Code is detected, but not what it is doing"
                    )
                    Spacer()
                    if store.agentHookNeedsUpdate {
                        Button("Update…") { store.installAgentHook() }
                            .disabled(store.agentHookBusy)
                        Button("Remove") { store.uninstallAgentHook() }
                            .disabled(store.agentHookBusy)
                    } else if store.agentHookInstalled {
                        Button("Remove") { store.uninstallAgentHook() }
                            .disabled(store.agentHookBusy)
                    } else {
                        Button("Install…") { store.installAgentHook() }
                            .disabled(store.agentHookBusy)
                    }
                }

                if !store.agentHookInstalled || store.agentHookNeedsUpdate,
                   !store.agentHookPlan.isEmpty
                {
                    DisclosureGroup("Show exactly what will be added") {
                        Text(store.agentHookPlan)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                }

                if let message = store.agentHookMessage {
                    Label(
                        message,
                        systemImage: store.agentHookFailed
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(store.agentHookFailed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Agent status")
            } footer: {
                Text(
                    "Without this, the sidebar can tell that Claude Code is running in a window "
                        + "but not whether it is working, waiting for you, or finished.\n\n"
                        + "Installing adds one line per event to ~/.claude/settings.json and writes "
                        + "a short readable script to ~/.claude/hooks/. Your existing hooks are kept "
                        + "— nothing is replaced, only appended — and the file is copied to a "
                        + "timestamped backup first. The state is stored in tmux itself, so "
                        + "`tmux attach` from any terminal sees the same thing.\n\n"
                        + "One thing it cannot preserve: the file comes back sorted and "
                        + "re-indented, because there is no way to keep the original key order. "
                        + "Nothing is lost, and the backup has the original."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    featureLabel(
                        store.statusLineInstalled ? "checkmark.circle.fill" : "gauge.with.needle",
                        store.statusLineInstalled ? .green : .orange,
                        store.statusLineInstalled
                            ? "Claude Code reports its model, context and cost"
                            : "Claude Code's model, context and cost are not reported",
                        store.statusLineInstalled
                            ? (store.statusLineWrapped.map { "Wrapping: \($0)" }
                                ?? "You had no status line, so a minimal one is drawn.")
                            : (store.statusLineWrapped.map {
                                "Your status line will keep drawing exactly as it does now: \($0)"
                            } ?? "You have no status line, so a minimal one will be drawn.")
                    )
                    Spacer()
                    if store.statusLineInstalled {
                        Button("Remove") { store.uninstallStatusLine() }
                            .disabled(store.statusLineBusy)
                    } else {
                        Button("Install…") { store.installStatusLine() }
                            .disabled(store.statusLineBusy)
                    }
                }

                if let message = store.statusLineMessage {
                    Label(
                        message,
                        systemImage: store.statusLineFailed
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(store.statusLineFailed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Session details")
            } footer: {
                Text(
                    "How full an agent's context is, which model it is on, what the session has "
                        + "cost, and how much of your 5-hour and weekly limits is left — Claude "
                        + "Code publishes all of that in exactly one place, the JSON it hands to "
                        + "your status line. Hooks never see it.\n\n"
                        + "So this points statusLine.command at a small script that runs your own "
                        + "status line with the same input and prints its output unchanged. The "
                        + "line in your terminal does not change, whichever status line you use. "
                        + "If you have none, it draws a minimal one, because a status line that "
                        + "prints nothing still costs a row.\n\n"
                        + "The script needs nothing installed — no jq, no Python. It writes the "
                        + "numbers into tmux, where the sidebar already reads everything else. "
                        + "Your settings file is copied to a timestamped backup first, and the "
                        + "command being wrapped is kept in ~/.claude/hooks/"
                        + "tmuxgui-statusline.conf where you can read or change it."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { store.hidesConversationWithoutAgent },
                    set: { store.setHidesConversationWithoutAgent($0) }
                )) {
                    iconLabel(
                        "sidebar.trailing",
                        store.hidesConversationWithoutAgent ? .blue : .gray,
                        "Hide the rail when no agent is running"
                    )
                }
            } header: {
                Text("Conversation")
            } footer: {
                Text(
                    "The rail on the right shows the conversation of the window on screen, so "
                        + "it follows that window: switch to one with no agent and the rail "
                        + "slides away, switch back and it returns. Each transition changes the "
                        + "terminal's width once. The toggle in the window's top-right corner "
                        + "(or ⌘\\) always wins for the window you are on — it can summon the "
                        + "rail with no agent there, and hide it with one. Off, the rail stays "
                        + "up everywhere — a window with no agent just says so."
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
