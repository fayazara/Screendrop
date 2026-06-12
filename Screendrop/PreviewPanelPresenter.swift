//
//  PreviewPanelPresenter.swift
//  Screendrop
//
//  Created by Codex on 30/04/26.
//

import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class PreviewPanelPresenter {
    static let shared = PreviewPanelPresenter()

    var onAnnotate: ((URL) -> Void)?
    var onEditVideo: ((URL) -> Void)?

    private var panel: NSPanel?

    private init() {}

    func show(displayID: CGDirectDisplayID?) {
        let panel = panel ?? makePanel()

        PreviewWindowCaptureExclusion.shared.attach(window: panel)
        PreviewWindowPlacement.shared.setTargetDisplayID(displayID)
        PreviewWindowPlacement.shared.showAboveActiveSpaceAfterOpening()
    }

    func closeIfEmpty() {
        guard ScreenshotPreviewStack.shared.items.isEmpty else { return }

        QuickLookPreviewPresenter.dismiss()
        destroyPanel()
    }

    private func destroyPanel() {
        guard let panel else { return }

        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
    }

    private func makePanel() -> NSPanel {
        let frame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let panel = PreviewPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        if !PreviewWindowCaptureExclusion.isDemoMode {
            panel.sharingType = .none
        }

        panel.contentView = PassthroughPreviewHostingView(
            rootView: PreviewWindowView(
                onRequestClose: {
                    PreviewPanelPresenter.shared.closeIfEmpty()
                },
                onAnnotate: { url in
                    PreviewPanelPresenter.shared.onAnnotate?(url)
                },
                onEditVideo: { url in
                    PreviewPanelPresenter.shared.onEditVideo?(url)
                }
            )
        )

        self.panel = panel
        return panel
    }
}

private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
