//
//  SettingsGeneralPane.swift
//  Screendrop
//

import AppKit
import ServiceManagement
import SwiftUI

struct GeneralSettingsPane: View {
    @AppStorage(ScreendropPreferences.exportDirectoryPathKey) private var exportDirectoryPath = ""
    @AppStorage(ScreendropPreferences.saveButtonUsesFolderKey) private var saveButtonUsesFolder = false
    @AppStorage(ScreendropPreferences.playSoundsKey) private var playSounds = true
    @AppStorage(ScreendropPreferences.showMenuBarIconKey) private var showMenuBarIcon = true
    @State private var launchAtLoginStatus = LaunchAtLoginController.status
    @State private var launchAtLoginError: String?

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginStatus.isEnabled },
            set: updateLaunchAtLogin
        )
    }

    private var saveButtonUsesFolderBinding: Binding<Bool> {
        Binding(
            get: { _ = saveButtonUsesFolder; return ScreendropPreferences.saveButtonUsesConfiguredFolder },
            set: { saveButtonUsesFolder = $0 }
        )
    }

    var body: some View {
        Form {
            Section("Save Location") {
                LabeledContent("Export folder") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                            .font(.system(size: 14))

                        Text(ScreendropPreferences.exportDirectory.abbreviatedPath)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                    }
                }

                HStack(spacing: 8) {
                    Button("Choose Folder...") {
                        chooseExportDirectory()
                    }
                    .controlSize(.small)

                    Button("Use Default") {
                        exportDirectoryPath = ""
                    }
                    .controlSize(.small)
                    .disabled(exportDirectoryPath.isEmpty)
                }

                Toggle(isOn: saveButtonUsesFolderBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save without choosing a location")
                        Text("When you click Save, write straight to the export folder instead of asking where to put it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section("System") {
                Toggle(isOn: launchAtLoginBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                        Text("Start Screendrop automatically when you sign in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if launchAtLoginStatus.requiresApproval {
                    Text("Approve Screendrop in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $playSounds) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Play sounds")
                        Text("Play the camera shutter sound when a screenshot is taken.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $showMenuBarIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show menu bar icon")
                        Text("When hidden, reopen Screendrop to get back to Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            refreshLaunchAtLoginStatus()
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
        panel.directoryURL = ScreendropPreferences.exportDirectory

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        exportDirectoryPath = url.path
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = LaunchAtLoginController.status
    }

    private func updateLaunchAtLogin(_ isEnabled: Bool) {
        do {
            launchAtLoginError = nil
            try LaunchAtLoginController.setEnabled(isEnabled)
        } catch {
            launchAtLoginError = "Could not update Launch at Login: \(error.localizedDescription)"
        }

        refreshLaunchAtLoginStatus()
    }
}

private enum LaunchAtLoginStatus {
    case disabled
    case enabled
    case requiresApproval

    var isEnabled: Bool {
        self == .enabled
    }

    var requiresApproval: Bool {
        self == .requiresApproval
    }
}

@MainActor
private enum LaunchAtLoginController {
    static var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notRegistered, .notFound:
            .disabled
        @unknown default:
            .disabled
        }
    }

    static func setEnabled(_ isEnabled: Bool) throws {
        let service = SMAppService.mainApp

        if isEnabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}
