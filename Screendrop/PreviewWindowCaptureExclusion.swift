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

    /// Reasons the floating preview overlay is currently hidden. The panel is a
    /// full-screen, high-level floating window, so while an editor or Quick Look
    /// window is up we order it out entirely — that's the only reliable way to
    /// keep it from sitting on top of and intercepting events for those windows.
    enum SuppressionReason: Hashable {
        case editor
        case quickLook
    }

    private weak var previewWindow: NSWindow?
    private var suppressionReasons: Set<SuppressionReason> = []

    private var isSuppressed: Bool { !suppressionReasons.isEmpty }

    private init() {}

    func attach(window: NSWindow?) {
        guard let window else { return }

        previewWindow = window
        if !Self.isDemoMode {
            window.sharingType = .none
        }
        // A panel shown (or re-shown) while suppression is active must not
        // appear on top of the editor / Quick Look window.
        if isSuppressed {
            window.orderOut(nil)
        }
        PreviewWindowPlacement.shared.attach(window: window)
    }

    /// Hide the overlay for the given reason. Reasons stack, so the overlay
    /// stays hidden until every reason has been cleared via `restoreOverlay`.
    func suppressOverlay(reason: SuppressionReason) {
        let wasSuppressed = isSuppressed
        suppressionReasons.insert(reason)
        guard !wasSuppressed else { return }

        previewWindow?.orderOut(nil)
    }

    /// Clear a single hide reason. When the last reason is cleared the overlay
    /// is placed and shown again (unless it has since been torn down).
    func restoreOverlay(reason: SuppressionReason) {
        suppressionReasons.remove(reason)
        guard !isSuppressed else { return }

        guard let previewWindow,
              !ScreenshotPreviewStack.shared.items.isEmpty else { return }

        if !Self.isDemoMode { previewWindow.sharingType = .none }
        PreviewWindowPlacement.shared.applyPlacement()
        PreviewWindowPlacement.shared.showAboveActiveSpace()
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
