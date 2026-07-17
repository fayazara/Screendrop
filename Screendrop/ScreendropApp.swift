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

        WindowGroup("Screendrop Recording Editor", id: "VIDEO_EDITOR", for: URL.self) { value in
            RecordingStudioWindow(url: value)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1360, height: 860)
    }

    @MainActor
    private func configurePreviewPresentation() {
        PreviewPanelPresenter.shared.onAnnotate = { [openWindow] url in
            openWindow(id: "ANNOTATION_EDITOR", value: url)
        }
        PreviewPanelPresenter.shared.onEditVideo = { [openWindow] url in
            openWindow(
                id: "VIDEO_EDITOR",
                value: ScreenshotHistoryStore.shared.editorURL(for: url)
            )
        }

        CaptureCoordinator.shared.onShowPreview = { [openWindow] url, displayID in
            // Set the editor openers first so auto-annotate can fire during add.
            PreviewPanelPresenter.shared.onAnnotate = { url in
                openWindow(id: "ANNOTATION_EDITOR", value: url)
            }
            PreviewPanelPresenter.shared.onEditVideo = { url in
                openWindow(
                    id: "VIDEO_EDITOR",
                    value: ScreenshotHistoryStore.shared.editorURL(for: url)
                )
            }

            let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url)
            ScreenshotPreviewStack.shared.add(url: historyURL)

            if AfterCaptureActions.isEnabled(.showOverlay, for: .screenshot) {
                PreviewPanelPresenter.shared.show(displayID: displayID)
            }

            return historyURL
        }

        ScreenRecordingManager.shared.onFinishRecording = { session, displayID in
            Task { @MainActor in
                // A recording session is already an editable project: the
                // screen, camera, audio, and event tracks do not need to be
                // flattened before Studio can open them. Rendering here made
                // Stop behave like Export and blocked short recordings behind
                // a full-resolution transcode.
                let historyURL = await ScreenshotHistoryStore.shared.importRecordingSession(session)
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
        RecordingRecoveryCoordinator.recoverInterruptedRecordings()
    }

    /// When the menu bar icon is hidden, reopening Screendrop (e.g. from
    /// Spotlight or Finder) is the only way back in, so surface Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !ScreendropPreferences.showMenuBarIcon {
            SettingsWindowController.show(tab: .general)
        }
        return true
    }

    /// Guard against silently losing captures. Screenshots that were never
    /// saved to disk (Auto Save off and not manually saved) only live in the
    /// temporary directory, so quitting — including a Sparkle update relaunch,
    /// which terminates the app — discards them. Warn before that happens.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsavedCount = ScreenshotPreviewStack.shared.unsavedItems.count
        if ScreenRecordingManager.shared.isActive {
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "A screen recording is still in progress"
            alert.informativeText = unsavedCount > 0
                ? "Screendrop will finish and save the recording before quitting. You also have \(unsavedCount) unsaved capture\(unsavedCount == 1 ? "" : "s") that will be discarded."
                : "Screendrop will finish and save the recording before quitting. This can take a moment for a long recording."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Finish Recording and Quit")

            guard alert.runModal() == .alertSecondButtonReturn else {
                return .terminateCancel
            }

            ScreenRecordingManager.shared.finishForTermination { session in
                Task { @MainActor in
                    if let session {
                        _ = await ScreenshotHistoryStore.shared.importRecordingSession(session)
                    }
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }

        guard unsavedCount > 0 else { return .terminateNow }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = unsavedCount == 1
            ? "You have 1 unsaved capture"
            : "You have \(unsavedCount) unsaved captures"
        alert.informativeText = """
        These captures haven't been saved to your Mac and will be lost if you quit. \
        Turn on Auto Save in Settings to keep every capture automatically.
        """

        // Cancel is the default (and leftmost-safe) action so an accidental
        // Return never discards work.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")

        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
