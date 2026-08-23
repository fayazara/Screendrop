//
//  CaptureCoordinator.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit
import ScreenCaptureKit
import SwiftUI

/// Single long-lived coordinator that manages the capture → preview flow.
@Observable
final class CaptureCoordinator {
    
    static let shared = CaptureCoordinator()
    
    /// Set by the App to open the preview window. Returns the URL the
    /// capture was imported to in history, so awaitable capture callers
    /// (App Intents) can hand the finished file to their result.
    var onShowPreview: ((URL, CGDirectDisplayID?) -> URL)?
    
    private init() {}
    
    // MARK: - Capture Actions

    func captureFullscreen() {
        Task { await performCaptureFullscreen() }
    }

    func captureWindow() {
        Task { await performCaptureWindow() }
    }

    func captureArea() {
        Task { await performCaptureArea() }
    }

    func captureText() {
        Task { await performCaptureText() }
    }

    // MARK: - Awaitable Capture Actions

    /// Awaitable variants for callers (App Intents / Shortcuts) that need the
    /// resulting file back to hand off to a following action. Both routes
    /// funnel through the same finish-capture path as the hotkey/menu bar
    /// triggers, so history import, sound, and preview behavior stay
    /// identical either way.
    @discardableResult
    func captureFullscreenAwaiting() async -> URL? {
        await performCaptureFullscreen()
    }

    @discardableResult
    func captureWindowAwaiting() async -> URL? {
        await performCaptureWindow()
    }

    @discardableResult
    func captureAreaAwaiting() async -> URL? {
        await performCaptureArea()
    }

    @discardableResult
    private func performCaptureFullscreen() async -> URL? {
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        PreviewWindowPlacement.shared.setTargetDisplayID(displayID)

        await CaptureCountdownPresenter.shared.runIfNeeded(
            seconds: ScreendropPreferences.captureDelaySeconds,
            displayID: displayID
        )
        guard let url = await ScreenshotManager.shared.captureFullscreen(displayID: displayID) else { return nil }
        return finishCapture(url: url, displayID: displayID)
    }

    @discardableResult
    private func performCaptureWindow() async -> URL? {
        // The self-timer is handled by screencapture's `-T` so the delay
        // happens *after* the window is picked, not before.
        guard let url = await ScreenshotManager.shared.captureWindow(
            includeShadow: ScreendropPreferences.captureWindowShadow,
            delaySeconds: ScreendropPreferences.captureDelaySeconds
        ) else { return nil }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        return finishCapture(url: url, displayID: displayID)
    }

    @discardableResult
    private func performCaptureArea() async -> URL? {
        // The self-timer is handled by screencapture's `-T` so the delay
        // happens *after* the area is drawn, not before.
        guard let url = await ScreenshotManager.shared.captureArea(
            delaySeconds: ScreendropPreferences.captureDelaySeconds
        ) else { return nil }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        return finishCapture(url: url, displayID: displayID)
    }

    private func performCaptureText() async {
        guard let url = await ScreenshotManager.shared.captureArea(
            delaySeconds: ScreendropPreferences.captureDelaySeconds
        ) else { return }
        defer { try? FileManager.default.removeItem(at: url) }

        let text = await ImageTextRecognizer.recognizeText(at: url)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if ScreendropPreferences.playSounds {
            CaptureFeedbackSound.play()
        }
    }

    func recordFullscreen(_ display: SCDisplay) {
        Task {
            await CaptureCountdownPresenter.shared.runIfNeeded(
                seconds: ScreendropPreferences.recordingStartDelaySeconds,
                displayID: display.displayID
            )
            ScreenRecordingManager.shared.startRecording(source: ScreenRecordingSource(kind: .fullscreen(display)))
        }
    }

    func recordWindow(_ window: SCWindow) {
        Task {
            let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
            await CaptureCountdownPresenter.shared.runIfNeeded(
                seconds: ScreendropPreferences.recordingStartDelaySeconds,
                displayID: displayID
            )
            ScreenRecordingManager.shared.startRecording(source: ScreenRecordingSource(kind: .window(window)))
        }
    }

    func recordArea(_ display: SCDisplay) {
        RecordingAreaSelectionPresenter.shared.selectArea(on: display) { rect in
            guard let rect else { return }
            Task {
                await CaptureCountdownPresenter.shared.runIfNeeded(
                    seconds: ScreendropPreferences.recordingStartDelaySeconds,
                    displayID: display.displayID
                )
                ScreenRecordingManager.shared.startRecording(
                    source: ScreenRecordingSource(kind: .area(display: display, rect: rect))
                )
            }
        }
    }
    
    // MARK: - Preview

    @discardableResult
    @MainActor
    private func finishCapture(url: URL, displayID: CGDirectDisplayID?) -> URL {
        if ScreendropPreferences.playSounds {
            CaptureFeedbackSound.play()
        }
        return showPreview(url: url, displayID: displayID)
    }

    @discardableResult
    private func showPreview(url: URL, displayID: CGDirectDisplayID?) -> URL {
        guard let onShowPreview else {
            let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url)
            ScreenshotPreviewStack.shared.add(url: historyURL)
            if AfterCaptureActions.isEnabled(.showOverlay, for: .screenshot) {
                PreviewPanelPresenter.shared.show(displayID: displayID)
            }
            return historyURL
        }

        return onShowPreview(url, displayID)
    }
}

@MainActor
private enum CaptureFeedbackSound {
    private static let sound: NSSound? = {
        let url = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif")
        return NSSound(contentsOf: url, byReference: true)
    }()

    static func play() {
        guard let sound else { return }

        sound.stop()
        sound.currentTime = 0
        sound.play()
    }
}
