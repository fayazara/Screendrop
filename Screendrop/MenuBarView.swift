//
//  MenuBarView.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var updaterManager = UpdaterManager.shared
    @State private var historyStore = ScreenshotHistoryStore.shared
    @State private var projectStore = RecordingProjectStore.shared

    var body: some View {
        Group {
            Button {
                CaptureCoordinator.shared.captureFullscreen()
            } label: {
                Label("Capture Fullscreen", systemImage: "macwindow")
            }
            
            Button {
                CaptureCoordinator.shared.captureWindow()
            } label: {
                Label("Capture Window", systemImage: "macwindow.on.rectangle")
            }
            
            Button {
                CaptureCoordinator.shared.captureArea()
            } label: {
                Label("Capture Area", systemImage: "rectangle.dashed")
            }

            Button {
                CaptureCoordinator.shared.captureText()
            } label: {
                Label("Capture Text", systemImage: "text.viewfinder")
            }

            Button {
                RecordingPickerPresenter.shared.show()
            } label: {
                Label("Record Screen", systemImage: "record.circle")
            }

            Divider()

            Button {
                CaptureLibraryModel.shared.show()
            } label: {
                Label("Open Library", systemImage: "square.grid.2x2")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Menu {
                projectsMenuContent
            } label: {
                Label("Recordings", systemImage: "film.stack")
            }

            Menu {
                historyMenuContent
            } label: {
                Label("Recent Captures", systemImage: "clock.arrow.circlepath")
            }

            Button {
                openScreenshotsFolder()
            } label: {
                Label("Open Screenshots Folder", systemImage: "folder")
            }
            
            Button {
                openSettings(tab: .general)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])

            Button {
                updaterManager.checkForUpdates()
            } label: {
                Label("Check for Updates...", systemImage: "arrow.down.circle")
            }
            .disabled(!updaterManager.canCheckForUpdates)
            
            Divider()
            
            Button("Quit Screendrop") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            historyStore.reload()
            projectStore.reload()
        }
    }

    /// Reopening a recording is the common case after the first edit, so the
    /// recents land here rather than behind Settings.
    @ViewBuilder
    private var projectsMenuContent: some View {
        if projectStore.projects.isEmpty {
            Text("No recordings")
        } else {
            ForEach(projectStore.recentProjects) { project in
                Button(projectMenuTitle(for: project)) {
                    RecordingProjectOpener.shared.open(project.session)
                }
            }

            Divider()
        }

        Button {
            CaptureLibraryModel.shared.show(filter: .recordings)
        } label: {
            Label("Show All Recordings…", systemImage: "square.grid.2x2")
        }
    }

    private func projectMenuTitle(for project: RecordingProjectSummary) -> String {
        let name = truncatedMenuTitle(project.displayName)
        return project.hasUnsavedDraft ? "\(name) - Unsaved" : name
    }

    @ViewBuilder
    private var historyMenuContent: some View {
        if historyStore.recentItems.isEmpty {
            Text("No captures")
        } else {
            ForEach(historyStore.recentItems) { item in
                Button(historyMenuTitle(for: item)) {
                    showHistoryPreview(item)
                }
            }

            Divider()
        }

        Button {
            CaptureLibraryModel.shared.show(filter: .all)
        } label: {
            Label("Show All Captures…", systemImage: "rectangle.stack")
        }
    }

    private func showHistoryPreview(_ item: ScreenshotHistoryItem) {
        if item.isVideo {
            ScreenshotPreviewStack.shared.previewExistingVideo(url: item.url)
        } else {
            ScreenshotPreviewStack.shared.previewExistingImage(url: item.url)
        }
        PreviewPanelPresenter.shared.show(displayID: ActiveDisplayResolver.activeDisplayID(preferPointer: false))
    }

    private func openSettings(tab: SettingsTab) {
        SettingsWindowController.show(tab: tab)
    }

    private func openScreenshotsFolder() {
        let directory = ScreendropPreferences.exportDirectory

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            showOpenScreenshotsFolderError(directory: directory, errorDescription: error.localizedDescription)
            return
        }

        if !NSWorkspace.shared.open(directory) {
            showOpenScreenshotsFolderError(directory: directory, errorDescription: nil)
        }
    }

    private func showOpenScreenshotsFolderError(directory: URL, errorDescription: String?) {
        let alert = NSAlert()
        alert.messageText = "Could not open screenshots folder."
        alert.informativeText = errorDescription ?? directory.path
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func historyMenuTitle(for item: ScreenshotHistoryItem) -> String {
        let name = item.displayName ?? item.fileName
        let limit = 30

        guard name.count > limit else {
            return name
        }

        let url = URL(fileURLWithPath: name)
        let pathExtension = url.pathExtension
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let baseName = url.deletingPathExtension().lastPathComponent
        let allowedBaseLength = max(8, limit - suffix.count - 3)

        return "\(baseName.prefix(allowedBaseLength))...\(suffix)"
    }

    /// Menus get unusably wide with full session names, which carry a
    /// timestamp and a uniquing suffix.
    private func truncatedMenuTitle(_ name: String) -> String {
        let limit = 34
        guard name.count > limit else { return name }
        return "\(name.prefix(limit - 1))…"
    }
}
