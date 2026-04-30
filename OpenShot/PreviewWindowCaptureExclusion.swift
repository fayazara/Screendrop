//
//  PreviewWindowCaptureExclusion.swift
//  OpenShot
//
//  Created by Codex on 27/04/26.
//

import AppKit
import SwiftUI

@MainActor
final class PreviewWindowCaptureExclusion {
    static let shared = PreviewWindowCaptureExclusion()
    
    private weak var previewWindow: NSWindow?
    private var captureHiddenWindow: NSWindow?
    private var annotationHiddenWindow: NSWindow?
    private var annotationHideCount = 0
    
    private init() {}
    
    func attach(window: NSWindow?) {
        guard let window else { return }
        
        previewWindow = window
        window.sharingType = .none
        PreviewWindowPlacement.shared.attach(window: window)
    }
    
    func hideForCapture() {
        guard let previewWindow,
              previewWindow.isVisible else {
            return
        }
        
        captureHiddenWindow = previewWindow
        previewWindow.orderOut(nil)
    }
    
    func restoreAfterCapture() {
        guard let captureHiddenWindow else { return }
        guard annotationHideCount == 0 else {
            self.captureHiddenWindow = nil
            return
        }
        
        captureHiddenWindow.sharingType = .none
        PreviewWindowPlacement.shared.applyPlacement()
        PreviewWindowPlacement.shared.showAboveActiveSpace()
        self.captureHiddenWindow = nil
    }

    func hideForAnnotation() {
        annotationHideCount += 1
        guard annotationHideCount == 1 else { return }

        if let previewWindow, previewWindow.isVisible {
            annotationHiddenWindow = previewWindow
            previewWindow.orderOut(nil)
        } else if let captureHiddenWindow {
            annotationHiddenWindow = captureHiddenWindow
        }
    }

    func restoreAfterAnnotation() {
        annotationHideCount = max(0, annotationHideCount - 1)
        guard annotationHideCount == 0,
              captureHiddenWindow == nil,
              let annotationHiddenWindow else {
            return
        }

        annotationHiddenWindow.sharingType = .none
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
