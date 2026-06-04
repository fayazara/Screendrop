//
//  PreviewWindowCaptureExclusion.swift
//  Screendrop
//
//  Created by Codex on 27/04/26.
//

import AppKit
import SwiftUI

@MainActor
final class PreviewWindowCaptureExclusion {
    static let shared = PreviewWindowCaptureExclusion()

    /// When true, the preview panel is visible in screen recordings.
    /// Activated via the --demo-mode launch argument.
    static let isDemoMode = CommandLine.arguments.contains("--demo-mode")

    private weak var previewWindow: NSWindow?
    private var annotationHiddenWindow: NSWindow?
    private var annotationHideCount = 0
    
    private init() {}
    
    func attach(window: NSWindow?) {
        guard let window else { return }
        
        previewWindow = window
        if !Self.isDemoMode {
            window.sharingType = .none
        }
        PreviewWindowPlacement.shared.attach(window: window)
    }
    
    func hideForAnnotation() {
        annotationHideCount += 1
        guard annotationHideCount == 1 else { return }

        if let previewWindow, previewWindow.isVisible {
            annotationHiddenWindow = previewWindow
            previewWindow.orderOut(nil)
        }
    }

    func restoreAfterAnnotation() {
        annotationHideCount = max(0, annotationHideCount - 1)
        guard annotationHideCount == 0,
              let annotationHiddenWindow else {
            return
        }

        if !Self.isDemoMode { annotationHiddenWindow.sharingType = .none }
        PreviewWindowPlacement.shared.applyPlacement()
        PreviewWindowPlacement.shared.showAboveActiveSpace()
        self.annotationHiddenWindow = nil
    }
}

struct PreviewWindowCaptureExclusionView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        updateWindow(for: view)
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        updateWindow(for: nsView)
    }
    
    private func updateWindow(for view: NSView) {
        DispatchQueue.main.async {
            PreviewWindowCaptureExclusion.shared.attach(window: view.window)
        }
    }
}
