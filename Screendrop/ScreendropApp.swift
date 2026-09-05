//
//  ScreendropApp.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import Carbon

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

        Window("Screendrop Library", id: "CAPTURE_LIBRARY") {
            CaptureLibraryView()
        }
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Show Library") { CaptureLibraryModel.shared.show() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindowController.show(tab: .general) }
                    .keyboardShortcut(",", modifiers: .command)
            }
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
        CaptureLibraryModel.shared.installOpener { [openWindow] in
            openWindow(id: "CAPTURE_LIBRARY")
        }
        PreviewPanelPresenter.shared.onAnnotate = { [openWindow] url in
            openWindow(id: "ANNOTATION_EDITOR", value: url)
        }
        PreviewPanelPresenter.shared.onEditVideo = { [openWindow] url in
            openWindow(
                id: "VIDEO_EDITOR",
                value: ScreenshotHistoryStore.shared.editorURL(for: url)
            )
        }
        // The menu bar extra has no scene of its own, so it reaches Studio
        // through this opener.
        RecordingProjectOpener.shared.openHandler = { [openWindow] directoryURL in
            openWindow(id: "VIDEO_EDITOR", value: directoryURL)
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

        appDelegate.onOpenFiles = { [openWindow] urls in
            for url in urls where UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url)
                openWindow(id: "ANNOTATION_EDITOR", value: historyURL)
            }
        }

        ScreenRecordingManager.shared.onFinishRecording = { session, displayID in
            Task { @MainActor in
                // A recording session is already an editable project: the
                // screen, camera, audio, and event tracks do not need to be
                // flattened before Studio can open them. Rendering here made
                // Stop behave like Export and blocked short recordings behind
                // a full-resolution transcode.
                let historyURL = await ScreenshotHistoryStore.shared.importRecordingSession(session)
                RecordingProjectStore.shared.reload()
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
    private var openedFilesAtLaunch = false

    /// Files handed to us via Finder's "Open With" (or `open -a Screendrop`)
    /// before `onOpenFiles` is wired up, e.g. a cold launch where SwiftUI's
    /// scene body - and therefore the `openWindow` closure - hasn't run yet.
    private var pendingOpenURLs: [URL] = []
    var onOpenFiles: (([URL]) -> Void)? {
        didSet {
            guard let onOpenFiles, !pendingOpenURLs.isEmpty else { return }
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            onOpenFiles(urls)
        }
    }

    /// The notification delegate has to be in place *before* launch
    /// finishes, or the system handles clicks on export notifications
    /// itself - activating the app and never calling us back to reveal the
    /// file. `applicationDidFinishLaunching` is already too late.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = RecordingExportNotificationDelegate.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        HotkeyManager.shared.registerHotkeys()
        updaterManager.start()
        RecordingRecoveryCoordinator.recoverInterruptedRecordings()
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchReason = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        let launchedInBackground = launchReason == keyAELaunchedAsLogInItem
            || launchReason == keyAELaunchedAsServiceItem
        // Let Finder's open-file event reach its editor without also opening a
        // Library. Login/service launches keep the existing quiet menu-bar mode.
        DispatchQueue.main.async { [weak self] in
            guard let self, !launchedInBackground, !self.openedFilesAtLaunch else { return }
            CaptureLibraryModel.shared.show()
        }
    }

    /// Finder "Open With" / `open -a Screendrop file.png` entry point.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedFilesAtLaunch = true
        guard let onOpenFiles else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        onOpenFiles(urls)
    }

    /// Finder, Spotlight and the Dock all reopen the same Library window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        CaptureLibraryModel.shared.show()
        return false
    }

    /// Guard against silently losing captures. Screenshots that were never
    /// saved to disk (Auto Save off and not manually saved) only live in the
    /// temporary directory, so quitting - including a Sparkle update relaunch,
    /// which terminates the app - discards them. Warn before that happens.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Studio's autosave is debounced. Flushing here means quitting never
        // costs the last edit - the project reopens on its draft.
        StudioProjectRegistry.shared.flushDrafts()
        let unsavedProjectCount = StudioProjectRegistry.shared.unsavedProjectCount
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
        var informativeText = """
        These captures haven't been saved to your Mac and will be lost if you quit. \
        Turn on Auto Save in Settings to keep every capture automatically.
        """
        if unsavedProjectCount > 0 {
            // Unlike captures, these are safe - say so, so the warning above
            // doesn't read as covering them too.
            informativeText += """
            \n\n\(unsavedProjectCount) recording project\(unsavedProjectCount == 1 ? " has" : "s have") \
            unsaved edits. Those are kept and restored the next time you open them.
            """
        }
        alert.informativeText = informativeText

        // Cancel is the default (and leftmost-safe) action so an accidental
        // Return never discards work.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")

        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
