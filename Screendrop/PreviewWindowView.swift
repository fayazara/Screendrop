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
let previewStackSpacing: CGFloat = 15
let previewStackEdgePadding: CGFloat = 32
let previewStackAnimation = Animation.smooth(duration: 0.3, extraBounce: 0)
let previewCardSlideOffset = previewCardSize.width + previewTrailingPadding + 48
let previewCardScrollOutOffset = previewCardSize.height + previewStackEdgePadding + 48

struct PreviewWindowView: View {
    private let onRequestClose: (() -> Void)?
    private let onAnnotate: ((URL) -> Void)?
    private let onEditVideo: ((URL) -> Void)?

    @State private var previewStack = ScreenshotPreviewStack.shared
    @State private var keyMonitor: Any?
    @State private var globalKeyMonitor: Any?
    @AppStorage(ScreendropPreferences.previewPositionKey) private var previewPositionRaw = PreviewOverlayPosition.right.rawValue
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismissWindow

    private var previewPosition: PreviewOverlayPosition {
        PreviewOverlayPosition(rawValue: previewPositionRaw) ?? .right
    }

    private var stackAlignment: Alignment {
        previewPosition == .left ? .bottomLeading : .bottomTrailing
    }

    private var slideDirection: CGFloat {
        previewPosition == .left ? -1 : 1
    }

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
        GeometryReader { proxy in
            let visibleCapacity = visibleItemCapacity(for: proxy.size.height)

            VStack(spacing: previewStackSpacing) {
                ForEach(previewStack.items) { item in
                    PreviewCardView(
                        item: item,
                        isHidden: previewStack.draggingItemID == item.id,
                        isDismissing: previewStack.dismissingItemIDs.contains(item.id),
                        dismissalStyle: previewStack.overflowDismissingItemIDs.contains(item.id) ? .scrollOut : .slideOut,
                        slideDirection: slideDirection,
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
                        onPin: {
                            guard item.kind == .image else { return }
                            QuickLookPreviewPresenter.dismiss()
                            PinnedScreenshotPresenter.shared.pin(url: item.url)
                            previewStack.dismiss(id: item.id)
                        },
                        onCopyText: {
                            previewStack.copyText(id: item.id)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: stackAlignment)
            .padding(.leading, previewPosition == .left ? previewTrailingPadding : 0)
            .padding(.trailing, previewPosition == .right ? previewTrailingPadding : 0)
            .padding(.bottom, previewStackEdgePadding)
            .animation(previewStackAnimation, value: previewStack.itemIDs)
            .onAppear {
                previewStack.dismissOverflowItems(visibleCapacity: visibleCapacity)
            }
            .onChange(of: previewStack.itemIDs) { _, _ in
                previewStack.dismissOverflowItems(visibleCapacity: visibleCapacity)
            }
            .onChange(of: visibleCapacity) { _, capacity in
                previewStack.dismissOverflowItems(visibleCapacity: capacity)
            }
        }
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

    private func visibleItemCapacity(for height: CGFloat) -> Int {
        guard height > 0 else { return Int.max }

        let availableHeight = max(0, height - (previewStackEdgePadding * 2))
        let itemStride = previewCardSize.height + previewStackSpacing
        let capacity = Int((availableHeight + previewStackSpacing) / itemStride)
        return max(1, capacity)
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
