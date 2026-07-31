//
//  AboutPage.swift
//  Attache
//

import AppKit
import SwiftUI

// The app hero.

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

        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}
