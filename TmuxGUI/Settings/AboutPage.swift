//
//  AboutPage.swift
//  TmuxGUI
//

import AppKit
import SwiftUI

// The app hero, and the home of the control-mode throughput probe — which used
// to live in a top-level menu called "Measure" that gave no hint of what it
// measured or that it takes the better part of a minute.

struct AboutPage: View {
    @EnvironmentObject var store: SettingsStore

    private var versionString: String {
        let bundle = Bundle.main
        let short = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                    Text("TmuxGUI").font(.title2).fontWeight(.bold)
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

            Section {
                HStack {
                    featureLabel(
                        "speedometer", .green,
                        "Throughput probe",
                        "Floods a scratch pane for about 18 seconds and reports what actually arrived."
                    )
                    Spacer(minLength: 8)
                    Button(store.isProbing ? "Running…" : "Run") { store.runThroughputProbe() }
                        .disabled(store.isProbing)
                }

                if let report = store.probeReport {
                    // In the page rather than an alert: the old report was a
                    // modal, and main-queue work — including the surfaces
                    // rendering the panes being measured — queues up behind a
                    // modal run loop for as long as it is open.
                    Text(report)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Runs against the session currently on screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}
