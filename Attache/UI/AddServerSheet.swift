//
//  AddServerSheet.swift
//  Attache
//

import SwiftUI

/// The rail's "+ Add server…" sheet: the three fields a working host needs,
/// the advanced ones folded away, and a Test Connection that runs the draft
/// before anything is written. Saving goes through `AppSettings.saveHost`
/// like every other path — the sheet never touches a connection; the settings
/// change is what makes `MainViewController` connect.
struct AddServerSheet: View {
    var onClose: () -> Void

    @State private var draft = HostDraft()
    @State private var problem: String?
    @State private var probing = false
    @State private var probeMessage: String?
    @State private var probeFailed = false
    /// Ties a probe's answer to the draft it ran against; an edit mid-probe
    /// bumps it and the stale answer is dropped instead of landing on a
    /// draft it never tested. Same rule as the Hosts page.
    @State private var probeGeneration = 0
    /// The probe writing its discovered tmux path into the draft, told
    /// apart from the person typing — same rule as the Hosts page.
    @State private var fillingFromProbe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Server")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    fieldLabel("Name")
                    TextField("mini", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    fieldLabel("SSH destination")
                    TextField("user@host, or an ~/.ssh/config alias", text: $draft.ssh)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("Key-based login must already work — there is nowhere to type a password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    fieldLabel("tmux path")
                    TextField("found automatically", text: $draft.tmuxPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(
                        "Left empty, Attaché finds tmux on that machine when you test or "
                            + "connect and fills this in."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            DisclosureGroup("Advanced options") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        fieldLabel("tmux socket")
                        TextField("default", text: $draft.tmuxSocket)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        fieldLabel("Git tool")
                        TextField("lazygit", text: $draft.gitToolCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        fieldLabel("Open files with")
                        TextField("code --remote ssh-remote+%h %p", text: $draft.remoteOpenCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .padding(.top, 6)
            }
            .font(.callout)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if probing || probeMessage != nil {
                HStack(spacing: 6) {
                    if probing {
                        ProgressView().controlSize(.small)
                        Text("Trying \(draft.ssh)…").font(.caption).foregroundStyle(.secondary)
                    } else if let probeMessage {
                        Label(
                            probeMessage,
                            systemImage: probeFailed
                                ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(probeFailed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Button("Test Connection") { testConnection() }
                    .disabled(probing)
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Add & Connect") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: draft) { _ in
            if fillingFromProbe {
                fillingFromProbe = false
                return
            }
            guard probing || probeMessage != nil else { return }
            probeGeneration &+= 1
            probing = false
            probeMessage = nil
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .gridColumnAlignment(.trailing)
            .foregroundStyle(.secondary)
    }

    /// The same validation a save runs, so "test" can never pass a draft
    /// that "add" would refuse.
    private func validated() -> HostConfig? {
        let others = AppSettings.hostDrafts.map(\.name)
        if let found = draft.problem(otherNames: others) {
            problem = found
            return nil
        }
        problem = nil
        return draft.config
    }

    private func testConnection() {
        guard let config = validated() else { return }
        let discover = draft.tmuxPath.trimmingCharacters(in: .whitespaces).isEmpty
        probeGeneration &+= 1
        let generation = probeGeneration
        probing = true
        probeMessage = nil
        HostProbe.run(config: config, sshPath: AppSettings.sshPath, discoverPath: discover) { outcome in
            guard generation == probeGeneration else { return }
            probing = false
            if case .connected(_, let foundAt) = outcome, let foundAt {
                fillingFromProbe = true
                draft.tmuxPath = foundAt
            }
            probeMessage = outcome.message
            if case .failed = outcome { probeFailed = true } else { probeFailed = false }
        }
    }

    private func save() {
        guard let config = validated() else { return }
        // An empty tmux path is discovered before the block is written, so
        // the saved config carries the real location. Best effort: a
        // machine that is offline still saves, with bare "tmux" and the
        // connection error to say what to do next.
        if draft.tmuxPath.trimmingCharacters(in: .whitespaces).isEmpty {
            probeGeneration &+= 1
            let generation = probeGeneration
            probing = true
            probeMessage = nil
            HostProbe.run(config: config, sshPath: AppSettings.sshPath, discoverPath: true) { outcome in
                guard generation == probeGeneration else { return }
                probing = false
                if case .connected(_, let foundAt) = outcome, let foundAt {
                    fillingFromProbe = true
                    draft.tmuxPath = foundAt
                }
                finishSave()
            }
            return
        }
        finishSave()
    }

    private func finishSave() {
        if let refused = AppSettings.saveHost(draft, replacingName: nil) {
            problem = refused
            return
        }
        onClose()
    }
}

/// The AppKit door `MainViewController.presentAsSheet` needs. The weak
/// dance exists because the view is built before `self` is: the closure
/// captures a slot the initialiser fills one line later.
@MainActor
final class AddServerSheetController: NSHostingController<AddServerSheet> {
    init() {
        weak var controller: AddServerSheetController?
        super.init(rootView: AddServerSheet(onClose: { controller?.dismiss(nil) }))
        controller = self
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder _: NSCoder) { fatalError("not supported") }
}
