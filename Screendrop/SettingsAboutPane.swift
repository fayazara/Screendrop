//
//  SettingsAboutPane.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct SettingsAboutPane: View {
    @ObservedObject private var updaterManager = UpdaterManager.shared

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

        switch (version, build) {
        case let (version?, build?):
            return "Version \(version) (\(build))"
        case let (version?, nil):
            return "Version \(version)"
        default:
            return "Version 1.0"
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Screendrop")
                            .font(.largeTitle.bold())

                        Text(versionText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("A native screenshot and recording tool for macOS.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Updates") {
                Toggle(isOn: Binding(
                    get: { updaterManager.automaticallyChecksForUpdates },
                    set: { updaterManager.automaticallyChecksForUpdates = $0 }
                )) {
                    Text("Automatically check for updates")
                }

                Button("Check for Updates...") {
                    updaterManager.checkForUpdates()
                }
                .disabled(!updaterManager.canCheckForUpdates)
            }

            Section("Project") {
                Text("Screendrop is a lightweight opensource app for capturing screenshots and screen recordings on macOS.")
                    .foregroundStyle(.secondary)

                Link("GitHub", destination: URL(string: "https://github.com/fayazara/screendrop")!)
            }

            Section("Credits") {
                Text("Built by Fayaz Ahmed")
                    .foregroundStyle(.secondary)

                Link("GitHub", destination: URL(string: "https://github.com/fayazara")!)

                Link("Follow on Twitter", destination: URL(string: "https://x.com/fayazara")!)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
