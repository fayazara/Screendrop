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
    @AppStorage(ScreendropPreferences.hideDockIconKey) private var hideDockIcon = false
    @AppStorage(ScreendropPreferences.includeAppWindowsInCapturesKey)
    private var includeAppWindowsInCaptures = false
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

    @Environment(SettingsPermissions.self) private var permissions

    var body: some View {
        SettingsPage {
            Section("Permissions") {
                ForEach(SettingsPermissions.Kind.allCases) { kind in
                    SettingsPermissionRow(kind: kind, permissions: permissions)
                }
            }

            Section("App") {
                Toggle(isOn: launchAtLoginBinding) {
                    Text("Launch at login")
                }
                .toggleStyle(.ink)

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(Palette.record)
                } else if launchAtLoginStatus.requiresApproval {
                    Text("Approve Screendrop in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $showMenuBarIcon) {
                    SettingsControlLabel(
                        "Show menu bar icon",
                        detail: "When hidden, reopen Screendrop to get back to Settings."
                    )
                }
                .toggleStyle(.ink)

                Toggle(isOn: $hideDockIcon) {
                    SettingsControlLabel(
                        "Hide Dock icon",
                        detail: "Keep Screendrop out of the Dock and Cmd-Tab, even while its windows are open. The menu bar won't show Screendrop's menus."
                    )
                }
                .toggleStyle(.ink)
            }

            Section("Capture") {
                Toggle(isOn: $includeAppWindowsInCaptures) {
                    SettingsControlLabel(
                        "Include Screendrop windows in captures",
                        detail: "Show capture cards, recording controls, Settings, and other Screendrop windows in screenshots and screen recordings."
                    )
                }
                .toggleStyle(.ink)
            }

            Section("Sounds") {
                Toggle(isOn: $playSounds) {
                    SettingsControlLabel(
                        "Play sounds",
                        detail: "Play the camera shutter sound when a screenshot is taken."
                    )
                }
                .toggleStyle(.ink)
            }

            Section("Export") {
                HStack(spacing: Space.l) {
                    Text("Export location")

                    Spacer(minLength: Space.m)

                    Label {
                        Text(ScreendropPreferences.exportDirectory.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: ScreendropPreferences.exportDirectory.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    .foregroundStyle(.secondary)
                    .help(ScreendropPreferences.exportDirectory.abbreviatedPath)

                    if !exportDirectoryPath.isEmpty {
                        InspectorResetButton(help: "Use the default folder") {
                            exportDirectoryPath = ""
                        }
                        .transition(.blurPop)
                    }

                    SettingsButton("Choose…") {
                        chooseExportDirectory()
                    }
                }
                .motion(value: exportDirectoryPath.isEmpty)

                Toggle(isOn: saveButtonUsesFolderBinding) {
                    SettingsControlLabel(
                        "Save without choosing a location",
                        detail: "When you click Save, write straight to the export folder instead of asking where to put it."
                    )
                }
                .toggleStyle(.ink)
            }
        }
        .onAppear {
            refreshLaunchAtLoginStatus()
        }
        .onChange(of: hideDockIcon) { _, _ in
            AppActivationPolicy.dockIconPreferenceDidChange()
        }
        .onChange(of: includeAppWindowsInCaptures) { _, _ in
            PreviewWindowCaptureExclusion.shared.refreshRegisteredWindows()
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
