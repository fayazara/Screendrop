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
    private var hiddenWindow: NSWindow?
    
    private init() {}
    
    func attach(window: NSWindow?) {
        guard let window else { return }
        
        previewWindow = window
        window.sharingType = .none
    }
    
    func hideForCapture() {
        guard let previewWindow,
              previewWindow.isVisible else {
            return
        }
        
        hiddenWindow = previewWindow
        previewWindow.orderOut(nil)
    }
    
    func restoreAfterCapture() {
        guard let hiddenWindow else { return }
        
        hiddenWindow.sharingType = .none
        hiddenWindow.orderFront(nil)
        self.hiddenWindow = nil
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
