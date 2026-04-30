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
    var onShowPreview: ((URL) -> Void)?
    
    private init() {}
    
    // MARK: - Capture Actions
    
    func captureFullscreen() {
        Task {
            await prepareForCapture()
            defer {
                Task { @MainActor in
                    PreviewWindowCaptureExclusion.shared.restoreAfterCapture()
                }
            }
            
            guard let url = await ScreenshotManager.shared.captureFullscreen() else { return }
            await MainActor.run { self.finishCapture(url: url) }
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
            await MainActor.run { self.finishCapture(url: url) }
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
            await MainActor.run { self.finishCapture(url: url) }
        }
    }
    
    // MARK: - Preview

    @MainActor
    private func finishCapture(url: URL) {
        CaptureFeedbackSound.play()
        showPreview(url: url)
    }
    
    private func showPreview(url: URL) {
        guard let onShowPreview else {
            print("CaptureCoordinator: onShowPreview not set")
            return
        }
        onShowPreview(url)
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
