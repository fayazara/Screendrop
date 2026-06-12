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

    private init() {}

    /// Excludes the overlay panel from screen capture (unless in demo mode) and
    /// wires it into the placement manager.
    ///
    /// The overlay no longer hides itself for editors or Quick Look — it stays
    /// mounted and collapses into the peek tab instead (see
    /// `ScreenshotPreviewStack.collapse()`), and the passthrough hosting view
    /// keeps it from intercepting clicks meant for the windows beneath it.
    func attach(window: NSWindow?) {
        guard let window else { return }

        if !Self.isDemoMode {
            window.sharingType = .none
        }
        PreviewWindowPlacement.shared.attach(window: window)
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
