//
//  QuickLookPreviewPresenter.swift
//  OpenShot
//
//  Created by Codex on 26/04/26.
//

import AppKit
import QuickLookUI

@MainActor
final class QuickLookPreviewPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewPresenter()
    
    private var previewURL: NSURL?
    private weak var sourceView: NSView?
    private var sourceImage: NSImage?
    
    static var isShown: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }
    
    static func show(url: URL, sourceView: NSView?, sourceImage: NSImage?) {
        shared.show(url: url, sourceView: sourceView, sourceImage: sourceImage)
    }
    
    static func dismiss() {
        shared.dismiss()
    }
    
    private func show(url: URL, sourceView: NSView?, sourceImage: NSImage?) {
        previewURL = url as NSURL
        self.sourceView = sourceView
        self.sourceImage = sourceImage
        
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }
    
    private func dismiss() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        QLPreviewPanel.shared()?.orderOut(nil)
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
    
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        MainActor.assumeIsolated {
            guard let sourceView,
                  let window = sourceView.window else {
                return .zero
            }
            
            let rectInWindow = sourceView.convert(sourceView.bounds, to: nil)
            return window.convertToScreen(rectInWindow)
        }
    }
    
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        MainActor.assumeIsolated {
            if let sourceImage {
                contentRect?.pointee = NSRect(origin: .zero, size: sourceImage.size)
            }
            
            return sourceImage
        }
    }
}
