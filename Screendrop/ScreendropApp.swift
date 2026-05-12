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
    
    var body: some Scene {
        let _ = configurePreviewPresentation()

        MenuBarExtra("Screendrop", image: "MenuBarIcon") {
            MenuBarView()
        }
        
        Window("Settings", id: "SETTINGS") {
            SettingsView()
        }
        .windowResizability(.automatic)
        .defaultSize(width: 700, height: 540)
        
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
            let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url)
            ScreenshotPreviewStack.shared.add(url: historyURL)
            PreviewPanelPresenter.shared.onAnnotate = { url in
                openWindow(id: "ANNOTATION_EDITOR", value: url)
            }
            PreviewPanelPresenter.shared.onEditVideo = { url in
                openWindow(id: "VIDEO_EDITOR", value: url)
            }
            PreviewPanelPresenter.shared.show(displayID: displayID)
        }

        ScreenRecordingManager.shared.onFinishRecording = { url, displayID in
            Task { @MainActor in
                let historyURL = await ScreenshotHistoryStore.shared.importVideo(from: url)
                ScreenshotPreviewStack.shared.addVideo(url: historyURL)
                PreviewPanelPresenter.shared.show(displayID: displayID)
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
}
