//
//  CaptureCoordinator.swift
//  OpenShot
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

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
            await MainActor.run { self.showPreview(url: url) }
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
            await MainActor.run { self.showPreview(url: url) }
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
            await MainActor.run { self.showPreview(url: url) }
        }
    }
    
    // MARK: - Preview
    
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
