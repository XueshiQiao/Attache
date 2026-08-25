//
//  HostsPage.swift
//  Attache
//

import Combine
import SwiftUI

/// The editor over the `[[host]]` blocks: a master list of remote machines
/// with live connection dots, and the selected one's fields beside it.
///
/// Everything here edits a *draft*; nothing reaches the file or a connection
/// until Apply, and Apply on a connected host asks first — the save is also
/// the reconnect, and a reconnect mid-thought should be a choice, not a side
/// effect of tabbing out of a field. The file stays the single source of
/// truth: saving writes the block and posts the settings change, and the main
/// window reconciles its connections from that, exactly as if the block had
/// been edited by hand and the app relaunched — minus the relaunch.
struct HostsPage: View {
    @EnvironmentObject var store: SettingsStore

    /// What the list can point at: a saved block, or the one being created.
    private enum Selection: Hashable {
        case host(String)
        case new
    }

    @State private var hosts: [HostDraft] = []
    @State private var selection: Selection?
    @State private var draft = HostDraft()
    @State private var original = HostDraft()
    @State private var problem: String?
    @State private var probing = false
    @State private var probeMessage: String?
    @State private var probeFailed = false
    @State private var confirmingApply = false
    @State private var confirmingRemove = false
    @State private var confirmingDiscard = false
    @State private var pendingSelection: Selection??
    /// Which probe the result labels belong to. A completion carrying an
    /// older generation is dropped: without this, testing host A, switching
    /// to host B and testing again let A's slow answer land on B's form as
    /// a success B never earned (Codex review). Bumped by every selection
    /// change, every edit, and every new probe.
    @State private var probeGeneration = 0
    /// True while the probe itself writes the tmux path it discovered into
    /// the draft, so the edit-invalidation in `onChange` can tell the
    /// probe's own answer from the person typing over it.
    @State private var fillingFromProbe = false
    /// Bumped by the shared timer so the status dots follow the live
    /// contexts — connection state is not a published property anywhere,
    /// and polling once a second in an open settings window is cheaper than
    /// plumbing a callback through three layers for a coloured dot.
    @State private var tick = 0

    private static let statusTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            hostList
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .onAppear {
            refresh()
            store.refreshRemoteSetups()
            consumeHandOff(store.hostsPageSelection)
        }
        .onReceive(store.$hostsPageSelection) { consumeHandOff($0) }
        .onReceive(Self.statusTimer) { _ in
            tick &+= 1
            let current = AppSettings.hostDrafts
            if current != hosts { refresh() }
        }
        .onChange(of: draft) { _ in
            // The result on screen describes the draft it was run against;
            // an edit makes it about a draft that no longer exists. The one
            // exception is the probe filling in the path it just found —
            // that edit is the result.
            if fillingFromProbe {
                fillingFromProbe = false
                return
            }
            guard probing || probeMessage != nil else { return }
            probeGeneration &+= 1
            probing = false
            probeMessage = nil
        }
        .navigationTitle("Hosts")
    }

    // ─── Master list ─────────────────────────────────────────────────────────

    private var hostList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selection }, set: { requestSelect($0) })) {
                ForEach(hosts, id: \.name) { host in
                    HStack(spacing: 8) {
                        statusDot(for: host.name)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(host.name)
                            Text(host.ssh)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(Selection.host(host.name))
                }
                if selection == .new {
                    Label("New host", systemImage: "plus.circle.dotted")
                        .foregroundStyle(.secondary)
                        .tag(Selection.new)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 2) {
                Button { requestSelect(.new) } label: {
                    Image(systemName: "plus").frame(width: 22, height: 20)
                }
                Button { confirmingRemove = true } label: {
                    Image(systemName: "minus").frame(width: 22, height: 20)
                }
                .disabled(selectedName == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
        )
        .frame(width: 212)
    }

    // ─── Detail ──────────────────────────────────────────────────────────────

    @ViewBuilder
    private var detail: some View {
        if selection == nil {
            placeholder
        } else {
            editor
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(hosts.isEmpty ? "No remote hosts yet" : "Select a host")
                .font(.headline)
            Text(
                hosts.isEmpty
                    ? "A host is another machine whose tmux this app attaches to over ssh. "
                        + "Its sessions get their own block in the sidebar, beside this Mac's."
                    : "Pick a machine on the left, or add another."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
            if hosts.isEmpty {
                Button("Add Host…") { requestSelect(.new) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("mini"))
                VStack(alignment: .leading, spacing: 3) {
                    TextField(
                        "SSH destination", text: $draft.ssh,
                        prompt: Text("user@host, or an ~/.ssh/config alias")
                    )
                    .font(.system(.body, design: .monospaced))
                    Text("Key-based login must already work — there is nowhere to type a password.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    TextField(
                        "tmux path", text: $draft.tmuxPath,
                        prompt: Text("found automatically")
                    )
                    .font(.system(.body, design: .monospaced))
                    Text(
                        "Left empty, Attaché finds tmux on that machine when you test or "
                            + "apply — command -v first, then the usual install places — and "
                            + "fills this in."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(selection == .new ? "New host" : "Host")
            }

            Section {
                TextField("tmux socket", text: $draft.tmuxSocket, prompt: Text("default"))
                    .font(.system(.body, design: .monospaced))
                TextField("Git tool", text: $draft.gitToolCommand, prompt: Text("lazygit"))
                    .font(.system(.body, design: .monospaced))
                VStack(alignment: .leading, spacing: 3) {
                    TextField(
                        "Open files with", text: $draft.remoteOpenCommand,
                        prompt: Text("code --remote ssh-remote+%h %p")
                    )
                    .font(.system(.body, design: .monospaced))
                    Text("What ⌘-clicking a remote path runs here: %h is the ssh destination, %p the path.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Advanced")
            }

            statusSection
            agentSetupSection

            Section {
                HStack {
                    if selectedName != nil {
                        Button("Remove Host…", role: .destructive) { confirmingRemove = true }
                    }
                    Spacer()
                    if isDirty {
                        Button("Revert") { revert() }
                    }
                    Button("Apply") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isDirty)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text(
                    "Changes are written to ~/.config/attache.toml and applied without a "
                        + "relaunch. Applying to a connected host reconnects it; tmux there "
                        + "keeps running throughout."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .confirmationDialog(
            "Reconnect \(selectedName ?? "") to apply?",
            isPresented: $confirmingApply, titleVisibility: .visible
        ) {
            Button("Apply & Reconnect") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The change takes effect by disconnecting and reconnecting this host. "
                    + "tmux there keeps running; its sessions return as the connection does."
            )
        }
        .confirmationDialog(
            "Remove \(selectedName ?? "") from Attaché?",
            isPresented: $confirmingRemove, titleVisibility: .visible
        ) {
            Button("Remove Host", role: .destructive) { removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This disconnects Attaché and deletes the [[host]] block from "
                    + "~/.config/attache.toml. tmux on that machine keeps running — every "
                    + "session, window and agent there is untouched, and adding the host "
                    + "back shows them again."
            )
        }
        .confirmationDialog(
            "Discard the unsaved changes?",
            isPresented: $confirmingDiscard, titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                if let pending = pendingSelection { activate(pending) }
                pendingSelection = nil
            }
            Button("Keep Editing", role: .cancel) { pendingSelection = nil }
        } message: {
            Text("The edits in this form have not been applied.")
        }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 8) {
                if let name = selectedName, let live = store.liveHost(named: name) {
                    statusDot(for: name)
                    Text(statusText(for: live))
                        .lineLimit(2)
                    Spacer()
                    Button("Reconnect") { live.reconnect() }
                } else {
                    Text(selection == .new ? "Not connected yet — apply to connect." : "Not connected.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Button("Test Connection") { testConnection() }
                    .disabled(probing)
            }
            if probing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Trying \(draft.ssh)…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let probeMessage {
                Label(
                    probeMessage,
                    systemImage: probeFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(probeFailed ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Test runs the draft as it stands — nothing is saved by testing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The per-host agent hooks, moved here from the Behaviour page: they
    /// are installed *on that machine*, so they belong beside its other
    /// settings rather than in a general list two pages away.
    @ViewBuilder
    private var agentSetupSection: some View {
        if let name = selectedName,
           let row = store.remoteSetups.first(where: { $0.id == name })
        {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        featureLabel(
                            Self.remoteSetupSymbol(row),
                            Self.remoteSetupColor(row),
                            "Agent status on \(row.name)",
                            Self.remoteSetupText(row)
                        )
                        Spacer()
                        remoteSetupButtons(row)
                    }
                    if let wrapped = row.wrapped, !wrapped.isEmpty {
                        Text("Would wrap: " + wrapped)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = row.message {
                        Label(
                            message,
                            systemImage: row.failed
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(row.failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Agent status")
            } footer: {
                Text(
                    "\(row.name) has its own ~/.claude/settings.json, and agents there "
                        + "report state and transcripts only once it carries the same "
                        + "entries as this Mac's. Install writes the hooks, the status "
                        + "line wrapper and a timestamped backup on that machine, over ssh."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ─── State transitions ───────────────────────────────────────────────────

    private var selectedName: String? {
        if case .host(let name) = selection { return name }
        return nil
    }

    private var isDirty: Bool {
        selection == .new ? draft != HostDraft() : draft != original
    }

    private func refresh() {
        hosts = AppSettings.hostDrafts
        // The selected block can vanish under the editor — removed from the
        // rail, or by hand. Fall back to the placeholder rather than a form
        // over a host that is not there; unsaved edits are the discard
        // dialog's job, and an *external* removal already took the data.
        if let name = selectedName, !hosts.contains(where: { $0.name == name }) {
            selection = nil
            draft = HostDraft()
            original = HostDraft()
        }
    }

    private func consumeHandOff(_ name: String?) {
        guard let name else { return }
        refresh()
        if hosts.contains(where: { $0.name == name }) { requestSelect(.host(name)) }
        store.hostsPageSelection = nil
    }

    private func requestSelect(_ next: Selection?) {
        guard next != selection else { return }
        if isDirty {
            pendingSelection = next
            confirmingDiscard = true
            return
        }
        activate(next)
    }

    private func activate(_ next: Selection?) {
        selection = next
        problem = nil
        probeGeneration &+= 1
        probeMessage = nil
        probing = false
        switch next {
        case .host(let name):
            let found = hosts.first { $0.name == name } ?? HostDraft()
            draft = found
            original = found
        case .new:
            draft = HostDraft()
            original = HostDraft()
        case nil:
            draft = HostDraft()
            original = HostDraft()
        }
    }

    private func revert() {
        draft = selection == .new ? HostDraft() : original
        problem = nil
    }

    // ─── Actions ─────────────────────────────────────────────────────────────

    private func validate() -> Bool {
        let others = hosts.map(\.name).filter { $0 != selectedName }
        if let found = draft.problem(otherNames: others) {
            problem = found
            return false
        }
        problem = nil
        return true
    }

    private func apply() {
        guard validate() else { return }
        // An empty tmux path is a question the machine can answer for
        // itself. Best effort on purpose: a host that is offline right now
        // still deserves to be saveable, so any discovery failure falls
        // through to the plain save and the connection error says the rest.
        if draft.tmuxPath.trimmingCharacters(in: .whitespaces).isEmpty, let config = draft.config {
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
                continueApply()
            }
            return
        }
        continueApply()
    }

    private func continueApply() {
        // A connected (or connecting) host gets the reconnect warning; a new
        // host, or one that is already down, has nothing to interrupt.
        if let name = selectedName, let live = store.liveHost(named: name) {
            if case .down = live.state {
                save()
            } else {
                confirmingApply = true
            }
            return
        }
        save()
    }

    private func save() {
        let replacing = selectedName
        if let refused = AppSettings.saveHost(draft, replacingName: replacing) {
            problem = refused
            return
        }
        let savedName = draft.config?.name ?? draft.name
        refresh()
        selection = .host(savedName)
        let found = hosts.first { $0.name == savedName } ?? draft
        draft = found
        original = found
        problem = nil
        // The provider's list changes on the next runloop turn, once the
        // main window has reconciled; the setup rows follow it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            store.refreshRemoteSetups()
        }
    }

    private func removeSelected() {
        guard let name = selectedName else { return }
        if let refused = AppSettings.removeHost(named: name) {
            problem = refused
            return
        }
        selection = nil
        draft = HostDraft()
        original = HostDraft()
        problem = nil
        refresh()
    }

    private func testConnection() {
        let others = hosts.map(\.name).filter { $0 != selectedName }
        if let found = draft.problem(otherNames: others) {
            problem = found
            return
        }
        problem = nil
        guard let config = draft.config else { return }
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

    // ─── Status rendering ────────────────────────────────────────────────────

    private func statusDot(for name: String) -> some View {
        let color: Color
        switch store.liveHost(named: name)?.state {
        case .ready: color = .green
        case .connecting: color = .yellow
        case .down: color = .red
        case nil: color = .gray
        }
        return Circle().fill(color).frame(width: 7, height: 7)
    }

    private func statusText(for live: HostContext) -> String {
        switch live.state {
        case .ready:
            if let version = live.tmuxVersion { return "Connected — tmux \(version.text)" }
            return "Connected"
        case .connecting:
            return "Connecting…"
        case .down(let reason):
            return reason
        }
    }

    // ─── Agent setup rendering (moved from BehaviourPage) ────────────────────

    static func remoteSetupSymbol(_ row: SettingsStore.RemoteSetupRow) -> String {
        switch (row.hookState, row.statusLineState) {
        case (.installed, .installed): "checkmark.seal.fill"
        case (.unreachable, _): "bolt.horizontal.circle"
        case (.refused, _), (_, .refused): "exclamationmark.triangle.fill"
        case (.unknown, .unknown): "circle.dotted"
        default: "seal"
        }
    }

    static func remoteSetupColor(_ row: SettingsStore.RemoteSetupRow) -> Color {
        switch (row.hookState, row.statusLineState) {
        case (.installed, .installed): .green
        case (.unreachable, _): .orange
        case (.refused, _), (_, .refused): .red
        default: .gray
        }
    }

    static func remoteSetupText(_ row: SettingsStore.RemoteSetupRow) -> String {
        switch (row.hookState, row.statusLineState) {
        case (.unknown, .unknown): "checking…"
        case (.unreachable(let reason), _): reason
        case (.refused(let reason), _), (_, .refused(let reason)): reason
        case (.installed, .installed): "agents there report state and transcripts"
        case (.notInstalled, _): "not installed there"
        default: "installed by an older version — update to refresh"
        }
    }

    @ViewBuilder
    private func remoteSetupButtons(_ row: SettingsStore.RemoteSetupRow) -> some View {
        switch (row.hookState, row.statusLineState) {
        case (.unreachable, _), (.unknown, .unknown), (.refused, _), (_, .refused):
            EmptyView()
        case (.installed, .installed):
            Button("Remove") { store.uninstallRemoteSetup(hostID: row.id) }
                .disabled(row.busy)
        case (.notInstalled, _):
            Button("Install…") { store.installRemoteSetup(hostID: row.id) }
                .disabled(row.busy)
        default:
            Button("Update…") { store.installRemoteSetup(hostID: row.id) }
                .disabled(row.busy)
            Button("Remove") { store.uninstallRemoteSetup(hostID: row.id) }
                .disabled(row.busy)
        }
    }
}
