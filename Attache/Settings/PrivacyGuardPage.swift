//
//  PrivacyGuardPage.swift
//  Attache
//

import AppKit
import Combine
import SwiftUI

/// The privacy guard, one host at a time: whether each agent there is
/// protected, the rules, what was masked, what was let through, a place to
/// try the rules, and the vault.
///
/// Everything shown is read from attache-cli on that host and every change
/// goes back to it (`HostGuard`); the page keeps no state of the guard's own
/// beyond which host and which tab are up. A real value appears only where
/// the owner pressed Show, through `guard reveal`, and only on this screen.
struct PrivacyGuardPage: View {
    @EnvironmentObject var store: SettingsStore
    @State private var hostID: String?

    var body: some View {
        let hosts = store.guardHosts()
        let selected = hosts.first { $0.id == hostID } ?? hosts.first
        Group {
            if let host = selected {
                PrivacyGuardHostView(model: store.hostGuard(for: host), hosts: hosts, hostID: Binding(
                    get: { host.id }, set: { hostID = $0 }
                ))
                .id(host.id)
            } else {
                Text("No host is connected yet.").foregroundStyle(.secondary)
            }
        }
    }
}

private enum GuardTab: String, CaseIterable, Identifiable {
    case rules = "Rules", activity = "Activity", notMasked = "Not Masked", tryIt = "Try It", vault = "Vault"
    var id: String { rawValue }
}

private struct PrivacyGuardHostView: View {
    @ObservedObject var model: HostGuard
    let hosts: [HostContext]
    @Binding var hostID: String
    @State private var tab = GuardTab.rules
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            header
            agentsSection
            Section {
                Picker("", selection: $tab) {
                    ForEach(GuardTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            switch tab {
            case .rules: GuardRulesTab(model: model).disabled(!model.loaded)
            case .activity: GuardActivityTab(model: model)
            case .notMasked: GuardNotMaskedTab(model: model)
            case .tryIt: GuardTryTab(model: model)
            case .vault: GuardVaultTab(model: model)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshAll() }
        .onReceive(tick) { _ in
            if tab == .activity || tab == .notMasked { model.refreshEvents() }
            model.refreshStatus()
        }
        .onChange(of: model.rules) { _, _ in model.rulesChanged() }
    }

    private var header: some View {
        Section {
            HStack(spacing: 12) {
                featureLabel(
                    "eye.slash.fill", .cyan, "Privacy Guard",
                    "Keeps IP addresses, email addresses, keys and the words you choose out of every agent's "
                        + "conversation on this host. The model sees a placeholder such as ⟦ip:7f3a9c⟧; the real "
                        + "value is put back only when a command runs or a file is written."
                )
                Spacer(minLength: 8)
                Picker("Host", selection: $hostID) {
                    ForEach(hosts, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
            }
            HStack {
                stateBadge
                Spacer()
                Menu("Pause") {
                    Button("For 10 minutes") { model.pause(minutes: 10) }
                    Button("For 30 minutes") { model.pause(minutes: 30) }
                    Button("For 2 hours") { model.pause(minutes: 120) }
                    if model.pausedUntil != nil {
                        Divider()
                        Button("Resume now") { model.pause(minutes: 0) }
                    }
                }
                .fixedSize()
                Button {
                    model.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Read everything again from the host")
            }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }
        }
    }

    @ViewBuilder private var stateBadge: some View {
        if let until = model.pausedUntil {
            Label("Paused until \(until.formatted(date: .omitted, time: .shortened)): nothing is masked",
                  systemImage: "pause.circle.fill").foregroundStyle(.orange)
        } else if model.active == false {
            Label("Off: nothing is masked on this host", systemImage: "circle.slash").foregroundStyle(.red)
        } else if model.active == true {
            Label("On", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
        } else {
            Label("Reading…", systemImage: "hourglass").foregroundStyle(.secondary)
        }
    }

    private var agentsSection: some View {
        Section("Agents on this host") {
            if model.agents.isEmpty {
                Text("Reading…").foregroundStyle(.secondary)
            }
            ForEach(model.agents) { agent in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(agent)).foregroundStyle(colour(agent)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.title + (agent.how.map { " · \($0)" } ?? ""))
                        Text(agent.present || agent.installed ? agent.note : "not found on this host")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let message = model.agentMessage[agent.id] {
                            Text(message).font(.caption)
                                .foregroundStyle(message.hasPrefix("Failed") ? .red : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if model.busyAgent == agent.id {
                        ProgressView().controlSize(.small)
                    } else if agent.installed {
                        if !agent.current {
                            Button("Update") { model.install(agent.id) }
                        }
                        Button("Remove") { model.install(agent.id, remove: true) }
                    } else {
                        Button("Protect") { model.install(agent.id) }
                            .disabled(!agent.present)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func icon(_ a: GuardAgentStatus) -> String {
        if !a.installed { return a.present ? "exclamationmark.triangle.fill" : "minus.circle" }
        return a.current ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill"
    }

    private func colour(_ a: GuardAgentStatus) -> Color {
        if !a.installed { return a.present ? .orange : .secondary }
        return a.current ? .green : .yellow
    }
}

// MARK: - Placeholder chip

private struct TokenChip: View {
    let token: String
    var body: some View {
        Text(token)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.cyan.opacity(0.18)))
            .textSelection(.enabled)
    }
}

/// A placeholder with its Show / Hide button and, once shown, the value.
private struct RevealableToken: View {
    @ObservedObject var model: HostGuard
    let token: String
    var body: some View {
        HStack(spacing: 6) {
            TokenChip(token: token)
            if let value = model.revealed[token] {
                Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Button("Hide") { model.hide(token) }.buttonStyle(.borderless).font(.caption)
            } else {
                Button("Show") { model.reveal([token]) }.buttonStyle(.borderless).font(.caption)
            }
        }
    }
}

// MARK: - Rules

private struct GuardRulesTab: View {
    @ObservedObject var model: HostGuard

    var body: some View {
        Section {
            Toggle("Mask private values on this host", isOn: $model.rules.enabled)
        } footer: {
            Text("Saved to \(model.rulesPath) on the host as you change it, and used by the next thing any agent stores.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Built-in detectors") {
            ForEach(GuardDetector.all) { d in
                Toggle(isOn: Binding(
                    get: { model.rules.detects(d.id) },
                    set: { model.rules.detect[d.id] = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.title)
                        Text(d.example).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        Section {
            if model.rules.words.isEmpty {
                Text("None yet. Add host names, real names, account names, a tailnet name.")
                    .foregroundStyle(.secondary).font(.callout)
            }
            ForEach($model.rules.words) { $word in
                HStack {
                    TextField("word", text: $word.text).textFieldStyle(.roundedBorder)
                    Toggle("Aa", isOn: Binding(get: { !word.ignoreCase }, set: { word.ignoreCase = !$0 }))
                        .toggleStyle(.button).help("Match case")
                    actionPicker($word.action)
                    Toggle("", isOn: $word.enabled).labelsHidden().help("On / off")
                    deleteButton { model.rules.words.removeAll { $0.id == word.id } }
                }
            }
        } header: {
            addHeader("Words") { model.rules.words.append(GuardWord()) }
        } footer: {
            Text("Matched anywhere in the text, so a host name inside a longer one is caught too.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            if model.rules.patterns.isEmpty {
                Text("None yet. A pattern is a regular expression; with a capture group only the group is masked.")
                    .foregroundStyle(.secondary).font(.callout)
            }
            ForEach(Array(model.rules.patterns.enumerated()), id: \.element.id) { index, pattern in
                let binding = $model.rules.patterns[index]
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("name", text: binding.name).textFieldStyle(.roundedBorder).frame(maxWidth: 140)
                        TextField("placeholder word", text: binding.kind).textFieldStyle(.roundedBorder).frame(maxWidth: 110)
                            .help("The word inside the placeholder: ⟦word:…⟧")
                        actionPicker(binding.action)
                        Toggle("", isOn: binding.enabled).labelsHidden()
                        deleteButton { model.rules.patterns.removeAll { $0.id == pattern.id } }
                    }
                    TextField("regular expression, e.g. ACME-(\\d{4})", text: binding.pattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    if let why = model.patternErrors[index] {
                        Text("Not used: \(why)").font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            addHeader("Patterns") { model.rules.patterns.append(GuardPattern()) }
        }
        Section {
            ForEach(model.rules.allow.indices, id: \.self) { i in
                HStack {
                    TextField("value", text: Binding(
                        get: { i < model.rules.allow.count ? model.rules.allow[i] : "" },
                        set: { if i < model.rules.allow.count { model.rules.allow[i] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    deleteButton { if i < model.rules.allow.count { model.rules.allow.remove(at: i) } }
                }
            }
        } header: {
            addHeader("Never mask") { model.rules.allow.append("") }
        } footer: {
            Text("Exact values, compared without regard to case: a public resolver, a git host's SSH user.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func actionPicker(_ action: Binding<GuardAction>) -> some View {
        Picker("", selection: action) {
            ForEach(GuardAction.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: 200)
    }

    private func deleteButton(_ remove: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Remove")
    }

    private func addHeader(_ title: String, _ add: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: add) { Label("Add", systemImage: "plus") }.buttonStyle(.borderless)
        }
    }
}

// MARK: - Activity

private struct GuardActivityTab: View {
    @ObservedObject var model: HostGuard
    @State private var agent = "all"

    var body: some View {
        let rows = model.events.filter { $0.action != "pass" && (agent == "all" || $0.agent == agent) }
        Section {
            if rows.isEmpty {
                Text("Nothing masked yet.").foregroundStyle(.secondary)
            }
            ForEach(rows.prefix(300)) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(e.date.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    Text(e.agent).font(.caption).frame(width: 46, alignment: .leading)
                    Text(e.action).font(.caption.bold()).foregroundStyle(colour(e.action)).frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        RevealableToken(model: model, token: e.token)
                        Text("\(e.rule) · \(e.site)\(e.count > 1 ? " · ×\(e.count)" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if e.action == "mask" {
                        Button("Stop masking") { model.allow(e.token) }
                            .buttonStyle(.borderless).font(.caption)
                            .help("Add this value to Never mask")
                    }
                }
            }
        } header: {
            HStack {
                Text("Masked, restored and withheld")
                Spacer()
                Picker("", selection: $agent) {
                    Text("All agents").tag("all")
                    ForEach(GuardCommands.agents, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 130)
                Button("Clear") { model.clearEvents() }.buttonStyle(.borderless)
            }
        } footer: {
            Text("Only placeholders are recorded. Show asks the host for the value and keeps it on this screen only.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func colour(_ action: String) -> Color {
        switch action {
        case "mask": .cyan
        case "restore": .green
        case "block": .red
        default: .secondary
        }
    }
}

// MARK: - Not masked

private struct GuardNotMaskedTab: View {
    @ObservedObject var model: HostGuard

    var body: some View {
        var seen: [String: (GuardEvent, Int)] = [:]
        for e in model.events where e.action == "pass" {
            let total = (seen[e.token]?.1 ?? 0) + e.count
            seen[e.token] = (seen[e.token]?.0 ?? e, total)
        }
        let rows = seen.values.sorted { $0.0.date > $1.0.date }
        return Section {
            if rows.isEmpty {
                Text("Nothing was let through.").foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.0.token) { e, total in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        RevealableToken(model: model, token: e.token)
                        Text("\(e.kind) · \(why(e)) · seen \(total)× · last \(e.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Mask from now on") { model.maskFromNow(e.token) }.buttonStyle(.borderless).font(.caption)
                }
            }
        } header: {
            Text("Found, and let through")
        } footer: {
            Text("Values a detector found that the rules let pass: on Never mask, or their detector is off. "
                + "This is where a gap in the rules shows up.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func why(_ e: GuardEvent) -> String {
        if GuardDetector.all.contains(where: { $0.id == e.rule }), !model.rules.detects(e.rule) {
            return "its detector is off"
        }
        return "on Never mask"
    }
}

// MARK: - Try it

private struct GuardTryTab: View {
    @ObservedObject var model: HostGuard
    @State private var text = "ssh admin@example.com via 203.0.113.7, then ping fd7a:115c:a1e0::1\nkey sk-ant-api03-EXAMPLEexampleEXAMPLEexample"
    @State private var result: GuardTestResult?
    @State private var tested = ""

    var body: some View {
        Section {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90)
            HStack {
                Button("Check") { run() }
                Text("Uses the rules as they are on this page, saved or not. Nothing is recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Paste text to see what the rules do to it")
        }
        if let result, tested == text {
            Section("What would be masked") {
                Text(highlighted(result)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                ForEach(Array(result.hits.enumerated()), id: \.offset) { _, h in
                    HStack {
                        Text(snippet(h)).font(.system(.callout, design: .monospaced))
                        Spacer()
                        Text("\(h.verdict) · \(h.rule)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(result.errors, id: \.self) { Text("Pattern not used: \($0)").font(.caption).foregroundStyle(.red) }
            }
            Section(result.blocked ? "What the agent would get (withheld: a block rule matched)" : "What the agent would get") {
                Text(result.masked).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

    private func run() {
        let input = text
        model.test(input) { r in
            result = r
            tested = input
        }
    }

    private func range(_ h: GuardTestHit) -> Range<String.Index>? {
        let u = tested.utf8
        guard h.start >= 0, h.end <= u.count, h.start < h.end,
              let a = u.index(u.startIndex, offsetBy: h.start, limitedBy: u.endIndex),
              let b = u.index(u.startIndex, offsetBy: h.end, limitedBy: u.endIndex) else { return nil }
        return a..<b
    }

    private func snippet(_ h: GuardTestHit) -> String {
        range(h).map { String(tested[$0]) } ?? "?"
    }

    private func highlighted(_ r: GuardTestResult) -> AttributedString {
        var out = AttributedString(tested)
        for h in r.hits {
            guard let sr = range(h),
                  let lower = AttributedString.Index(sr.lowerBound, within: out),
                  let upper = AttributedString.Index(sr.upperBound, within: out) else { continue }
            switch h.verdict {
            case "pass":
                out[lower..<upper].strikethroughStyle = .single
                out[lower..<upper].foregroundColor = .secondary
            case "block":
                out[lower..<upper].backgroundColor = .red.opacity(0.3)
            default:
                out[lower..<upper].backgroundColor = .cyan.opacity(0.3)
            }
        }
        return out
    }
}

// MARK: - Vault

private struct GuardVaultTab: View {
    @ObservedObject var model: HostGuard
    @State private var confirmForget = false

    var body: some View {
        Section {
            if model.vault.isEmpty {
                Text("Empty.").foregroundStyle(.secondary)
            }
            ForEach(model.vault.prefix(500)) { e in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        RevealableToken(model: model, token: e.token)
                        Text("\(e.rule) · \(e.masked ? (e.restore ? "masked, restored in commands" : "masked, never restored") : "let through") · first \(e.first.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget") { model.forget([e.token]) }.buttonStyle(.borderless).font(.caption)
                }
            }
        } header: {
            HStack {
                Text("Placeholders and their values (\(model.vault.count))")
                Spacer()
                Button("Forget All…", role: .destructive) { confirmForget = true }.buttonStyle(.borderless)
            }
        } footer: {
            Text("Kept on the host only, in a file only your account can read. A forgotten placeholder can no "
                + "longer be put back: a command an agent writes with it will get the placeholder itself.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Forget every placeholder on this host?", isPresented: $confirmForget) {
            Button("Forget All", role: .destructive) { model.forgetAll() }
        } message: {
            Text("Conversations that already hold placeholders will no longer be able to use them in commands.")
        }
    }
}
