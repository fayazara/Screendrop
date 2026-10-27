//
//  SettingsAboutPane.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct SettingsAboutPane: View {
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

    /// When this copy was built. The executable's date is stamped by the
    /// install script, so it is the quickest way to tell whether the app on
    /// disk is the build the user just made.
    private var builtText: String {
        guard let url = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date
        else { return "Built unknown" }
        return "Built " + date.formatted(date: .abbreviated, time: .shortened)
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
                        Tag(text: builtText)
                    }

                    Text("Screenshots and screen recordings, with a CleanShot-style floating preview.")
                        .font(.dsCallout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
                        HStack(spacing: GlassMetrics.gap) {
                            SettingsButton("Show in Finder", systemImage: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                            }

                            SettingsButton("Upstream GitHub", systemImage: "chevron.left.forwardslash.chevron.right") {
                                open("https://github.com/fayazara/screendrop")
                            }
                        }
                    }
                    .padding(.top, Space.xs)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.xxl)
            }

            Section("Updates") {
                SettingsControlLabel(
                    "This is a local build",
                    detail: "It does not update itself through Sparkle. Run scripts/build-and-install.sh in the fork to install a newer build; the Built date above changes every time. Screen Recording permission survives those builds because the app keeps the same Apple Development signature."
                )
            }

            Section {
                Text("Built from the open-source Screendrop project by Fayaz Ahmed. The floating preview, area selection and pinned windows in this copy are customised.")
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
