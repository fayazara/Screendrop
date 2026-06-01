//
//  MenuBarView.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import ScreenCaptureKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var updaterManager = UpdaterManager.shared
    @State private var recordingSources = RecordingSourceCatalog.shared
    @State private var historyStore = ScreenshotHistoryStore.shared
    
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

            Menu {
                recordingMenuContent
            } label: {
                Label("Record Screen", systemImage: "record.circle")
            }

            Divider()

            Menu {
                historyMenuContent
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
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
            await recordingSources.refresh()
            historyStore.reload()
        }
    }

    @ViewBuilder
    private var recordingMenuContent: some View {
        if recordingSources.isLoading {
            Label("Loading sources...", systemImage: "hourglass")
        }

        if let errorMessage = recordingSources.errorMessage {
            Text("Unable to load sources")
            Text(errorMessage)
        }

        Menu("Full Screen") {
            if recordingSources.displays.isEmpty {
                Text("No displays found")
            } else {
                ForEach(Array(recordingSources.displays.enumerated()), id: \.element.displayID) { index, display in
                    Button(RecordingSourceCatalog.displayTitle(display, index: index)) {
                        CaptureCoordinator.shared.recordFullscreen(display)
                    }
                }
            }
        }

        Menu("Area") {
            if recordingSources.displays.isEmpty {
                Text("No displays found")
            } else {
                ForEach(Array(recordingSources.displays.enumerated()), id: \.element.displayID) { index, display in
                    Button(RecordingSourceCatalog.displayTitle(display, index: index)) {
                        CaptureCoordinator.shared.recordArea(display)
                    }
                }
            }
        }

        Menu("Window") {
            if recordingSources.windows.isEmpty {
                Text("No app windows found")
            } else {
                ForEach(recordingSources.windows, id: \.windowID) { window in
                    Button(RecordingSourceCatalog.windowTitle(window)) {
                        CaptureCoordinator.shared.recordWindow(window)
                    }
                }
            }

            Divider()

            Button {
                Task {
                    await recordingSources.refresh()
                }
            } label: {
                Label("Refresh Windows", systemImage: "arrow.clockwise")
            }
        }

        Divider()

        Button {
            Task {
                await recordingSources.refresh()
            }
        } label: {
            Label("Refresh Sources", systemImage: "arrow.clockwise")
        }
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
            historyStore.reload()
            openSettings(tab: .history)
        } label: {
            Label("Show All History", systemImage: "rectangle.stack")
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

    private func historyMenuTitle(for item: ScreenshotHistoryItem) -> String {
        let name = item.fileName
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
}
