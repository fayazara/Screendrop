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
    
    /// Set by the App to open the preview window.
    var onShowPreview: ((URL, CGDirectDisplayID?) -> Void)?
    
    private init() {}
    
    // MARK: - Capture Actions
    
    func captureFullscreen() {
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        PreviewWindowPlacement.shared.setTargetDisplayID(displayID)

        Task {
            await CaptureCountdownPresenter.shared.runIfNeeded(displayID: displayID)
            guard let url = await ScreenshotManager.shared.captureFullscreen(displayID: displayID) else { return }
            await MainActor.run { self.finishCapture(url: url, displayID: displayID) }
        }
    }
    
    func captureWindow() {
        Task {
            // The self-timer is handled by screencapture's `-T` so the delay
            // happens *after* the window is picked, not before.
            guard let url = await ScreenshotManager.shared.captureWindow(
                includeShadow: ScreendropPreferences.captureWindowShadow,
                delaySeconds: ScreendropPreferences.captureDelaySeconds
            ) else { return }
            let displayID = await MainActor.run {
                ActiveDisplayResolver.activeDisplayID(preferPointer: true)
            }
            await MainActor.run { self.finishCapture(url: url, displayID: displayID) }
        }
    }
    
    func captureArea() {
        Task {
            // The self-timer is handled by screencapture's `-T` so the delay
            // happens *after* the area is drawn, not before.
            guard let url = await ScreenshotManager.shared.captureArea(
                delaySeconds: ScreendropPreferences.captureDelaySeconds
            ) else { return }
            let displayID = await MainActor.run {
                ActiveDisplayResolver.activeDisplayID(preferPointer: true)
            }
            await MainActor.run { self.finishCapture(url: url, displayID: displayID) }
        }
    }

    func recordScreen() {
        if ScreendropPreferences.showRecordingSetupHUD {
            RecordingSetupPresenter.shared.begin()
            return
        }

        // "Show options before recording" is off — capture full screen immediately.
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        Task {
            do {
                let content = try await ScreenRecordingCapture.availableContent()
                guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return }
                await MainActor.run {
                    self.recordFullscreen(display)
                }
            } catch {
                print("Failed to load recording display: \(error)")
            }
        }
    }

    func recordFullscreen(_ display: SCDisplay) {
        ScreenRecordingManager.shared.startRecording(source: ScreenRecordingSource(kind: .fullscreen(display)))
    }

    func recordWindow(_ window: SCWindow) {
        ScreenRecordingManager.shared.startRecording(source: ScreenRecordingSource(kind: .window(window)))
    }

    func recordArea(_ display: SCDisplay) {
        RecordingAreaSelectionPresenter.shared.selectArea(on: display) { rect in
            guard let rect else { return }
            ScreenRecordingManager.shared.startRecording(source: ScreenRecordingSource(kind: .area(display: display, rect: rect)))
        }
    }
    
    // MARK: - Preview

    @MainActor
    private func finishCapture(url: URL, displayID: CGDirectDisplayID?) {
        if ScreendropPreferences.playSounds {
            CaptureFeedbackSound.play()
        }
        showPreview(url: url, displayID: displayID)
    }
    
    private func showPreview(url: URL, displayID: CGDirectDisplayID?) {
        guard let onShowPreview else {
            let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url)
            ScreenshotPreviewStack.shared.add(url: historyURL)
            if AfterCaptureActions.isEnabled(.showOverlay, for: .screenshot) {
                PreviewPanelPresenter.shared.show(displayID: displayID)
            }
            return
        }

        onShowPreview(url, displayID)
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
