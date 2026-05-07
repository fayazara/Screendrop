//
//  SettingsGeneralPane.swift
//  OpenShot
//

import AppKit
import SwiftUI

struct GeneralSettingsPane: View {
    @AppStorage(OpenShotPreferences.exportDirectoryPathKey) private var exportDirectoryPath = ""

    var body: some View {
        SettingsPane {
            SettingsSection {
                SettingsRow("Startup:") {
                    Text("Launch at Login is managed in\nSystem Settings → General → Login Items")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineSpacing(2)
                }
            }

            SettingsSectionDivider()

            SettingsSection {
                SettingsRow("Export location:") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                            .font(.system(size: 14))

                        Text(OpenShotPreferences.exportDirectory.abbreviatedPath)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                    )
                }

                SettingsRow("") {
                    HStack(spacing: 8) {
                        Button("Choose Folder...") {
                            chooseExportDirectory()
                        }

                        Button("Use Default") {
                            exportDirectoryPath = ""
                        }
                        .disabled(exportDirectoryPath.isEmpty)
                    }
                    .controlSize(.small)
                }
            }

            SettingsSectionDivider()

            SettingsSection {
                SettingsRow("Desktop icons:") {
                    Toggle("Hide while capturing", isOn: .constant(false))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Save Location"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = OpenShotPreferences.exportDirectory

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        exportDirectoryPath = url.path
    }
}
