//
//  PermissionsPage.swift
//  Attache
//

import AppKit
import SwiftUI

// Folder access the system makes the person grant, one row per folder.

struct PermissionsPage: View {
    /// Absent until the person has pressed Check for that folder. Nothing here
    /// probes on its own: probing an undecided folder puts a system prompt on
    /// screen, and that should only happen when the person asked for it.
    @State private var results: [ProtectedFolder: FolderAccess] = [:]
    @State private var checking: Set<ProtectedFolder> = []

    var body: some View {
        Form {
            Section {
                ForEach(ProtectedFolder.allCases) { folder in
                    HStack(spacing: 12) {
                        featureLabel(folder.symbol, color(for: folder), folder.title, status(of: folder))
                        Spacer(minLength: 8)
                        if checking.contains(folder) {
                            ProgressView().controlSize(.small)
                        } else {
                            if results[folder] == .denied {
                                Button("Open Settings") { NSWorkspace.shared.open(ProtectedFolder.settingsURL) }
                            }
                            // Always offered, even after "Allowed": a switch turned
                            // off in System Settings is only noticed by asking again.
                            if results[folder] != .missing {
                                Button(results[folder] == nil ? "Check" : "Check Again") { check(folder) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("folderAccess.\(folder.title)")
                }
            } header: {
                Text("Folder Access")
            } footer: {
                Text(
                    "Dragging a file out of one of these folders pastes its path into the pane, "
                        + "and the program in the pane then opens that path. That program can read "
                        + "the folder only if macOS has allowed the app that started its tmux server. "
                        + "\"Check\" lists the folder, which is what makes macOS ask the first time. "
                        + "A folder you refused is never asked about again; turn Attaché on for it in "
                        + "System Settings (it takes effect at once) and press Check Again to refresh this page."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button("Check All") { checkAll() }
                    .disabled(!checking.isEmpty)
            } footer: {
                Text(
                    "A tmux server that was already running before this app started belongs to "
                        + "whichever app started it, so a folder allowed here can still be refused "
                        + "to programs inside it. Those panes need the permission granted to that app."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
        // The person usually flips the switch in System Settings and comes back,
        // so re-ask the folders already known to be refused. A refused folder
        // answers at once without a prompt, so this cannot surprise anyone.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            for folder in ProtectedFolder.allCases where results[folder] == .denied { check(folder) }
        }
    }

    private func check(_ folder: ProtectedFolder) {
        guard !checking.contains(folder) else { return }
        checking.insert(folder)
        DispatchQueue.global(qos: .userInitiated).async {
            let answer = folder.probe()
            DispatchQueue.main.async {
                results[folder] = answer
                checking.remove(folder)
            }
        }
    }

    /// One folder at a time, so the system shows one prompt at a time and each
    /// answer is on screen before the next question.
    private func checkAll() {
        let folders = ProtectedFolder.allCases
        checking.formUnion(folders)
        DispatchQueue.global(qos: .userInitiated).async {
            for folder in folders {
                let answer = folder.probe()
                DispatchQueue.main.async {
                    results[folder] = answer
                    checking.remove(folder)
                }
            }
        }
    }

    private func color(for folder: ProtectedFolder) -> Color {
        switch results[folder] {
        case .granted: .green
        case .denied: .red
        case .missing, .failed, nil: .gray
        }
    }

    private func status(of folder: ProtectedFolder) -> String {
        switch results[folder] {
        case .granted: "Allowed"
        case .denied: "Not allowed — turn Attaché on for this folder in System Settings"
        case .missing: "This folder does not exist"
        case .failed(let code): "Could not be checked (error \(code)) — try again"
        case nil: "Not checked yet"
        }
    }
}
