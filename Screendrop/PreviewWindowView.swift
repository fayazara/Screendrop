//
//  PreviewWindowView.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//
//  Floating screenshot preview stack.
//

import AppKit
import SwiftUI

let previewCardSize = CGSize(width: 165, height: 124)
let previewTrailingPadding: CGFloat = 28
let previewStackAnimation = Animation.smooth(duration: 0.3, extraBounce: 0)
let previewCardSlideOffset = previewCardSize.width + previewTrailingPadding + 48

struct PreviewWindowView: View {
    private let onRequestClose: (() -> Void)?
    private let onAnnotate: ((URL) -> Void)?
    private let onEditVideo: ((URL) -> Void)?

    @State private var previewStack = ScreenshotPreviewStack.shared
    @State private var keyMonitor: Any?
    @State private var globalKeyMonitor: Any?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismissWindow

    init(
        onRequestClose: (() -> Void)? = nil,
        onAnnotate: ((URL) -> Void)? = nil,
        onEditVideo: ((URL) -> Void)? = nil
    ) {
        self.onRequestClose = onRequestClose
        self.onAnnotate = onAnnotate
        self.onEditVideo = onEditVideo
    }
    
    var body: some View {
        VStack(spacing: 15) {
            ForEach(previewStack.items) { item in
                PreviewCardView(
                    item: item,
                    isHidden: previewStack.draggingItemID == item.id,
                    isDismissing: previewStack.dismissingItemIDs.contains(item.id),
                    onHoverChanged: { isHovered in
                        previewStack.setHovered(item.id, isHovered: isHovered)
                    },
                    onClose: {
                        previewStack.dismiss(id: item.id)
                    },
                    onDelete: {
                        previewStack.deleteScreenshot(id: item.id)
                    },
                    onCopy: {
                        previewStack.copyToClipboard(id: item.id)
                    },
                    onSave: {
                        previewStack.save(id: item.id)
                    },
                    onAnnotate: {
                        guard item.kind == .image else { return }
                        QuickLookPreviewPresenter.dismiss()
                        if let onAnnotate {
                            onAnnotate(item.url)
                        } else {
                            openWindow(id: "ANNOTATION_EDITOR", value: item.url)
                        }
                    },
                    onEditVideo: {
                        guard item.kind == .video else { return }
                        QuickLookPreviewPresenter.dismiss()
                        if let onEditVideo {
                            onEditVideo(item.url)
                        } else {
                            openWindow(id: "VIDEO_EDITOR", value: item.url)
                        }
                    },
                    onUpload: {
                        Task {
                            do {
                                let result = try await CloudUploader.shared.upload(itemID: item.id, fileURL: item.url)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(result.url, forType: .string)
                                ScreenshotHistoryStore.shared.setCloudURL(for: item.url, cloudURL: result.url)
                            } catch {
                                print("Cloud upload failed: \(error)")
                            }
                        }
                    },
                    onDragBegan: {
                        previewStack.beginDrag(id: item.id)
                    },
                    onDragEnded: {
                        withAnimation(previewStackAnimation) {
                            previewStack.finishDrag(id: item.id)
                        }
                    }
                )
            }
        }
        .frame(width: previewCardSize.width)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, previewTrailingPadding)
        .padding(.bottom, 32)
        .animation(previewStackAnimation, value: previewStack.itemIDs)
        .onAppear(perform: installKeyMonitors)
        .onDisappear(perform: tearDown)
        .onChange(of: previewStack.items.count) { _, count in
            if count == 0 {
                if let onRequestClose {
                    onRequestClose()
                } else {
                    dismissWindow()
                }
            }
        }
    }
    
    // MARK: - Keyboard
    
    private func installKeyMonitors() {
        guard keyMonitor == nil, globalKeyMonitor == nil else { return }
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if handlePreviewKey(event) {
                return nil
            }
            
            return event
        }
        
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if previewStack.hoveredItemID != nil || QuickLookPreviewPresenter.isShown {
                _ = handlePreviewKey(event)
            }
        }
    }
    
    private func tearDown() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        
        keyMonitor = nil
        globalKeyMonitor = nil
        QuickLookPreviewPresenter.dismiss()
    }
    
    private func handlePreviewKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, QuickLookPreviewPresenter.isShown {
            QuickLookPreviewPresenter.dismiss()
            return true
        }
        
        if event.keyCode == 49, let hoveredItem = previewStack.hoveredItem {
            QuickLookPreviewPresenter.show(url: hoveredItem.url)
            return true
        }
        
        return false
    }
}
