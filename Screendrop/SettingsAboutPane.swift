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
        SettingsPage {
            Section {
                VStack(spacing: Space.l) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

                    VStack(spacing: Space.s) {
                        Text("Screendrop")
                            .font(.dsDisplay)
                        Tag(text: versionText)
                    }

                    Text("Screenshots and screen recordings, made beautiful in a click.")
                        .font(.dsCallout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
                        HStack(spacing: GlassMetrics.gap) {
                            SettingsButton("Check for Updates", systemImage: "arrow.down.circle", isProminent: true) {
                                updaterManager.checkForUpdates()
                            }
                            .disabled(!updaterManager.canCheckForUpdates)

                            SettingsButton("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") {
                                open("https://github.com/fayazara/screendrop")
                            }

                            SettingsButton("@fayazara", systemImage: "at") {
                                open("https://x.com/fayazara")
                            }
                        }
                    }
                    .padding(.top, Space.xs)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.xxl)
            }

            Section("Updates") {
                Toggle(isOn: Binding(
                    get: { updaterManager.automaticallyChecksForUpdates },
                    set: { updaterManager.automaticallyChecksForUpdates = $0 }
                )) {
                    SettingsControlLabel(
                        "Check for updates automatically",
                        detail: "Screendrop looks for a new version in the background and asks before installing it."
                    )
                }
            }

            Section {
                Text("Screendrop is open source and built by Fayaz Ahmed. Issues, ideas and pull requests are welcome on GitHub.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
