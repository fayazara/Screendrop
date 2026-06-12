//
//  QuickLookPreviewPresenter.swift
//  Screendrop
//
//  Created by Codex on 26/04/26.
//

import AppKit
import QuickLookUI

@MainActor
final class QuickLookPreviewPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewPresenter()
    
    private var previewURL: NSURL?
    
    static var isShown: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }
    
    static func show(url: URL) {
        shared.show(url: url)
    }
    
    static func dismiss() {
        shared.dismiss()
    }
    
    private func show(url: URL) {
        previewURL = url as NSURL
        
        guard let panel = QLPreviewPanel.shared() else {
            ScreenshotPreviewStack.shared.expand()
            return
        }

        // Activate the app *before* presenting the panel so macOS considers
        // it the frontmost process. Without this, the QuickLook window opens
        // unfocused and videos won't autoplay until manually clicked.
        NSApp.activate()

        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        // Collapse the floating overlay into the peek tab so it doesn't sit on
        // top of the Quick Look window. Expanded again when Quick Look closes.
        ScreenshotPreviewStack.shared.collapse()
        if panel.isVisible {
            panel.refreshCurrentPreviewItem()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }

        // Re-assert key status on the next runloop pass. The window server
        // sometimes needs a tick to finish processing the activation, so an
        // immediate makeKey can be silently dropped when the app was inactive.
        DispatchQueue.main.async {
            panel.makeKeyAndOrderFront(nil)
        }
    }
    
    private func dismiss() {
        defer { ScreenshotPreviewStack.shared.expand() }

        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else {
            previewURL = nil
            return
        }
        panel.orderOut(nil)
        previewURL = nil
    }

    /// Fires when Quick Look closes on its own (e.g. the user clicks its close
    /// button or it loses key focus), which bypasses `dismiss()`.
    func windowWillClose(_ notification: Notification) {
        previewURL = nil
        ScreenshotPreviewStack.shared.expand()
    }
    
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            previewURL == nil ? 0 : 1
        }
    }
    
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            previewURL
        }
    }
}
