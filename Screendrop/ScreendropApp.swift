//
//  ScreendropApp.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import SwiftUI

@main
struct ScreendropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) var openWindow
    @AppStorage(ScreendropPreferences.showMenuBarIconKey) private var showMenuBarIcon = true

    var body: some Scene {
        let _ = configurePreviewPresentation()

        MenuBarExtra("Screendrop", image: "MenuBarIcon", isInserted: $showMenuBarIcon) {
            MenuBarView()
        }
        
        WindowGroup("Screendrop Annotate", id: "ANNOTATION_EDITOR", for: URL.self) { value in
            AnnotationEditorWindow(url: value)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 760)

        WindowGroup("Screendrop Video Editor", id: "VIDEO_EDITOR", for: URL.self) { value in
            VideoEditorWindow(url: value)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1280, height: 800)
    }

    @MainActor
    private func configurePreviewPresentation() {
        PreviewPanelPresenter.shared.onAnnotate = { [openWindow] url in
            openWindow(id: "ANNOTATION_EDITOR", value: url)
        }
        PreviewPanelPresenter.shared.onEditVideo = { [openWindow] url in
            openWindow(id: "VIDEO_EDITOR", value: url)
        }

        CaptureCoordinator.shared.onShowPreview = { [openWindow] url, displayID in
            // Set the editor openers first so auto-annotate can fire during add.
            PreviewPanelPresenter.shared.onAnnotate = { url in
                openWindow(id: "ANNOTATION_EDITOR", value: url)
            }
            PreviewPanelPresenter.shared.onEditVideo = { url in
                openWindow(id: "VIDEO_EDITOR", value: url)
            }

            let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url)
            ScreenshotPreviewStack.shared.add(url: historyURL)

            if AfterCaptureActions.isEnabled(.showOverlay, for: .screenshot) {
                PreviewPanelPresenter.shared.show(displayID: displayID)
            }
        }

        ScreenRecordingManager.shared.onFinishRecording = { url, displayID in
            Task { @MainActor in
                let historyURL = await ScreenshotHistoryStore.shared.importVideo(from: url)
                ScreenshotPreviewStack.shared.addVideo(url: historyURL)
                if AfterCaptureActions.isEnabled(.showOverlay, for: .recording) {
                    PreviewPanelPresenter.shared.show(displayID: displayID)
                }
            }
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updaterManager = UpdaterManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        HotkeyManager.shared.registerHotkeys()
        updaterManager.start()
    }

    /// When the menu bar icon is hidden, reopening Screendrop (e.g. from
    /// Spotlight or Finder) is the only way back in, so surface Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !ScreendropPreferences.showMenuBarIcon {
            SettingsWindowController.show(tab: .general)
        }
        return true
    }
}
