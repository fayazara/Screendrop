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

    /// Reasons the floating preview overlay is currently hidden.
    ///
    /// The panel is a full-screen, high-level floating window. For most cases
    /// (e.g. the annotation editor) it now stays visible and collapses into a
    /// peek tab instead — see `ScreenshotPreviewStack.collapse()`. Quick Look,
    /// however, is a system-owned key window we don't control, so we still order
    /// the overlay out entirely while it's up.
    enum SuppressionReason: Hashable {
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
        // appear on top of the Quick Look window.
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
        // Re-show with retries (matching the initial capture path). Ordering a
        // high-level floating panel to the front is unreliable while the app is
        // still transitioning activation policy and the Quick Look window is
        // tearing down, so a single orderFront can be dropped by the window
        // server. The retries recover from that race.
        PreviewWindowPlacement.shared.showAboveActiveSpaceAfterOpening()
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
