//
//  QuickLookPreviewPresenter.swift
//  OpenShot
//
//  Created by Codex on 26/04/26.
//

import AppKit
import QuickLookUI

@MainActor
final class QuickLookPreviewPresenter: NSObject, QLPreviewPanelDataSource {
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
        
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = nil
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        if panel.isVisible {
            panel.refreshCurrentPreviewItem()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
    
    private func dismiss() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        previewURL = nil

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
        panel.dataSource = nil
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
