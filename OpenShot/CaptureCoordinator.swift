//
//  CaptureCoordinator.swift
//  OpenShot
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit
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
            await prepareForCapture()
            defer {
                Task { @MainActor in
                    PreviewWindowCaptureExclusion.shared.restoreAfterCapture()
                }
            }
            
            guard let url = await ScreenshotManager.shared.captureFullscreen(displayID: displayID) else { return }
            await MainActor.run { self.finishCapture(url: url, displayID: displayID) }
        }
    }
    
    func captureWindow() {
        Task {
            await prepareForCapture()
            defer {
                Task { @MainActor in
                    PreviewWindowCaptureExclusion.shared.restoreAfterCapture()
                }
            }
            
            guard let url = await ScreenshotManager.shared.captureWindow() else { return }
            let displayID = await MainActor.run {
                ActiveDisplayResolver.activeDisplayID(preferPointer: true)
            }
            await MainActor.run { self.finishCapture(url: url, displayID: displayID) }
        }
    }
    
    func captureArea() {
        Task {
            await prepareForCapture()
            defer {
                Task { @MainActor in
                    PreviewWindowCaptureExclusion.shared.restoreAfterCapture()
                }
            }
            
            guard let url = await ScreenshotManager.shared.captureArea() else { return }
            let displayID = await MainActor.run {
                ActiveDisplayResolver.activeDisplayID(preferPointer: true)
            }
            await MainActor.run { self.finishCapture(url: url, displayID: displayID) }
        }
    }
    
    // MARK: - Preview

    @MainActor
    private func finishCapture(url: URL, displayID: CGDirectDisplayID?) {
        CaptureFeedbackSound.play()
        showPreview(url: url, displayID: displayID)
    }
    
    private func showPreview(url: URL, displayID: CGDirectDisplayID?) {
        guard let onShowPreview else {
            ScreenshotPreviewStack.shared.add(url: url)
            PreviewPanelPresenter.shared.show(displayID: displayID)
            return
        }

        onShowPreview(url, displayID)
    }
    
    private func prepareForCapture() async {
        await MainActor.run {
            PreviewWindowCaptureExclusion.shared.hideForCapture()
        }
        
        try? await Task.sleep(for: .milliseconds(200))
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
