//
//  QuickActionsPage.swift
//  TmuxGUI
//

import SwiftUI

/// The editor behind the Quick Actions menu.
///
/// A plain editable list rather than a table with a live preview: a row is two
/// text fields, and what it does is visible in the menu itself the moment the
/// field loses focus.
struct QuickActionsPage: View {
    @EnvironmentObject var store: SettingsStore
    @State private var selection: QuickAction.ID?

    var body: some View {
        Form {
            Section {
                if store.quickActions.isEmpty {
                    // An emptied list is a choice, so it gets a sentence rather
                    // than a silently blank box — and a way back that does not
                    // require remembering what the default was.
                    HStack {
                        Text("No actions. The menu is hidden while this list is empty.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore Default") { store.setQuickActions(QuickAction.installed) }
                    }
                    .font(.callout)
                }
                ForEach(store.quickActions) { action in
                    row(for: action)
                }
                .onDelete { offsets in
                    var actions = store.quickActions
                    actions.remove(atOffsets: offsets)
                    store.setQuickActions(actions)
                }
                .onMove { source, destination in
                    var actions = store.quickActions
                    actions.move(fromOffsets: source, toOffset: destination)
                    store.setQuickActions(actions)
                }
            } header: {
                HStack {
                    Text("Actions")
                    Spacer()
                    Button {
                        store.setQuickActions(
                            store.quickActions + [QuickAction(title: "", command: "")]
                        )
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            } footer: {
                Text(
                    "Each action is one tmux command, sent to the session you are looking at — "
                        + "the same thing you would write after `bind` in ~/.tmux.conf. A relative "
                        + "target works the way it does there: `set status` toggles the status "
                        + "line of the current session, `next-window` moves within it.\n\n"
                        + "Rows with an empty name or command are skipped. Drag to reorder; "
                        + "swipe or press Delete to remove one."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func row(for action: QuickAction) -> some View {
        // Bound through the store rather than to a local copy: the menu is
        // rebuilt from the stored list, so an edit that lived only in this view
        // would show a menu item whose name and command disagreed with the
        // table that produced it.
        let binding = Binding(
            get: { store.quickActions.first { $0.id == action.id } ?? action },
            set: { edited in
                var actions = store.quickActions
                guard let index = actions.firstIndex(where: { $0.id == action.id }) else { return }
                actions[index] = edited
                store.setQuickActions(actions)
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Name in the menu", text: binding.title)
                .textFieldStyle(.roundedBorder)
            TextField("tmux command, e.g. set status", text: binding.command)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
        .padding(.vertical, 4)
    }
}
