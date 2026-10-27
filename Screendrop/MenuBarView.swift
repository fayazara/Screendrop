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
    @State private var hotkeys = HotkeyManager.shared
    @State private var shortcutTick = 0

    var body: some View {
        menu
            .onReceive(NotificationCenter.default.publisher(for: HotkeyManager.didChangeNotification)) { _ in
                shortcutTick &+= 1
            }
    }

    private var menu: some View {
        Group {
            Button {
                CaptureCoordinator.shared.captureFullscreen()
            } label: {
                Label(captureTitle("Capture Fullscreen", .fullscreen), systemImage: "macwindow")
            }
            
            Button {
                CaptureCoordinator.shared.captureWindow()
            } label: {
                Label(captureTitle("Capture Window", .window), systemImage: "macwindow.on.rectangle")
            }
            
            Button {
                CaptureCoordinator.shared.captureArea()
            } label: {
                Label(captureTitle("Capture Area", .area), systemImage: "rectangle.dashed")
            }

            Button {
                CaptureCoordinator.shared.captureText()
            } label: {
                Label(captureTitle("Capture Text", .textCapture), systemImage: "text.viewfinder")
            }

            Button {
                ScrollingCaptureController.shared.start()
            } label: {
                Label(
                    captureTitle("Scrolling Capture…", .scrollingCapture),
                    systemImage: "arrow.up.and.down.text.horizontal"
                )
            }

            Button {
                RecordingPickerPresenter.shared.show()
            } label: {
                Label(captureTitle("Record Screen", .screenRecording), systemImage: "record.circle")
            }

            Button {
                ScrollingCapturePermission.request()
            } label: {
                Label(
                    ScrollingCapturePermission.isTrusted
                        ? "Automatic Scrolling Enabled"
                        : "Enable Automatic Scrolling…",
                    systemImage: "accessibility"
                )
            }

            Divider()

            Button {
                RecentCapturesStripPresenter.shared.show()
            } label: {
                Label(
                    "Recent Captures  \(RecentCapturesStripPresenter.shared.shortcutHint)",
                    systemImage: "rectangle.stack"
                )
            }

            Button {
                CaptureLibraryModel.shared.show()
            } label: {
                Label("Open Library", systemImage: "square.grid.2x2")
            }

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
                Label("Check for Updates…", systemImage: "arrow.down.circle")
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

    /// The global shortcut the app has registered, shown beside the menu item
    /// so it can be discovered without opening Settings.
    private func captureTitle(_ title: String, _ action: CaptureHotkeyAction) -> String {
        // Reading the revision registers an Observation dependency so the
        // menu is rebuilt when a shortcut changes in Settings, instead of
        // keeping the label it was first built with.
        _ = hotkeys.shortcutRevision
        _ = shortcutTick
        return "\(title)  \(CaptureHotkeyPreferences.shortcut(for: action).displayString)"
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
            CaptureShelf.shared.show(existing: item.url, kind: .video)
            CaptureShelfPresenter.shared.show(displayID: ActiveDisplayResolver.activeDisplayID(preferPointer: false))
        } else {
            // A recent screenshot opens as a pin: movable and resizable,
            // rather than a fixed thumbnail that has to be pinned again.
            PinnedScreenshotPresenter.shared.pin(url: item.url)
        }
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

        return "\(baseName.prefix(allowedBaseLength))…\(suffix)"
    }

    /// Menus get unusably wide with full session names, which carry a
    /// timestamp and a uniquing suffix.
    private func truncatedMenuTitle(_ name: String) -> String {
        let limit = 34
        guard name.count > limit else { return name }
        return "\(name.prefix(limit - 1))…"
    }
}
