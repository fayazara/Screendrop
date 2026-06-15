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

struct PreviewWindowView: View {
    private let onRequestClose: (() -> Void)?
    private let onAnnotate: ((URL) -> Void)?
    private let onEditVideo: ((URL) -> Void)?

    @State private var previewStack = ScreenshotPreviewStack.shared
    @State private var keyMonitor: Any?
    @State private var globalKeyMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var isOverlayTransitioning = false
    @State private var transitionResetTask: Task<Void, Never>?
    @State private var stackHeight: CGFloat = 500
    @State private var peekHeight: CGFloat = 64
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

    private var stackIsHidden: Bool {
        previewStack.isCollapsed || previewStack.isExiting
    }

    private var peekIsVisible: Bool {
        previewStack.isCollapsed && !previewStack.isExiting
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

            // Both the stack and the peek tab stay mounted; collapsing/expanding
            // just slides them vertically (the window clips them at the bottom
            // edge). Keeping them mounted means the cards don't re-run their
            // horizontal entrance slide on expand — the whole stack moves as one
            // along a single vertical axis, and the peek pill slides in as the
            // stack slides out.
            ZStack {
                stackContent
                    .frame(width: previewCardSize.width)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stackHeight = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: stackAlignment)
                    .padding(.leading, previewPosition == .left ? previewTrailingPadding : 0)
                    .padding(.trailing, previewPosition == .right ? previewTrailingPadding : 0)
                    .padding(.bottom, previewStackEdgePadding)
                    .offset(y: stackIsHidden ? stackHiddenOffset : 0)

                peekTab
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { peekHeight = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: stackAlignment)
                    .padding(.leading, previewPosition == .left ? peekHorizontalPadding : 0)
                    .padding(.trailing, previewPosition == .right ? peekHorizontalPadding : 0)
                    .offset(y: peekIsVisible ? 0 : peekHiddenOffset)
            }
            // Only animate card add/remove while the stack is expanded. When
            // collapsed the stack is slid off-screen and its hidden offset is
            // derived from the (geometry-driven) stack height; animating an item
            // change there makes the offset animate against a stale height for a
            // frame, briefly peeking the stack above the bottom edge before it
            // slides back down. Removing items instantly in peek mode keeps the
            // dismissal fully behind the scenes.
            .animation(previewStack.isCollapsed ? nil : previewStackAnimation, value: previewStack.itemIDs)
            .animation(previewStackAnimation, value: previewStack.isCollapsed)
            .animation(previewStackAnimation, value: previewStack.isExiting)
            .onAppear {
                previewStack.setVisibleCapacity(visibleCapacity)
            }
            .onChange(of: previewStack.itemIDs) { _, _ in
                previewStack.dismissOverflowItems(visibleCapacity: visibleCapacity)
            }
            .onChange(of: visibleCapacity) { _, capacity in
                previewStack.setVisibleCapacity(capacity)
            }
            .onChange(of: previewStack.isCollapsed) { _, _ in
                scheduleTransitionReset()
            }
            .onChange(of: previewStack.isExiting) { _, _ in
                scheduleTransitionReset()
            }
            .onPreferenceChange(InteractiveRectsKey.self) { rects in
                Task { @MainActor in
                    ScreenshotPreviewStack.shared.interactiveRects = rects
                }
            }
        }
        .onAppear {
            installKeyMonitors()
            installScrollMonitor()
        }
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

    private var stackContent: some View {
        VStack(spacing: previewStackSpacing) {
            ForEach(previewStack.items) { item in
                PreviewCardView(
                    item: item,
                    isHidden: previewStack.draggingItemID == item.id,
                    isDismissing: previewStack.dismissingItemIDs.contains(item.id),
                    slideDirection: slideDirection,
                    suppressHoverActions: isOverlayTransitioning,
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
        // Report the whole column as one interactive region (rather than each
        // card) so the passthrough hosting view treats the inter-card gaps and
        // edges as interactive too — otherwise the cursor flickers in and out of
        // the hit area while moving across the stack and hover feels glitchy.
        // Only while expanded, so the off-screen stack doesn't capture clicks.
        .reportsInteractiveRect(active: !previewStack.isCollapsed && !previewStack.isExiting)
    }

    private var peekTab: some View {
        PreviewPeekTab(
            title: peekTitle,
            onExpand: {
                withAnimation(previewStackAnimation) {
                    previewStack.expand()
                }
            },
            onDismissAll: {
                previewStack.dismissAll()
            }
        )
        // Report the pill's own frame (not the full panel) as interactive, and
        // only while collapsed, so the rest of the screen stays click-through.
        .reportsInteractiveRect(active: previewStack.isCollapsed && !previewStack.isExiting)
    }

    /// "1 Screenshot" / "3 Screenshots" — or "Captures" when the stack also
    /// holds recordings, so the label stays accurate.
    private var peekTitle: String {
        let count = previewStack.items.count
        let hasVideo = previewStack.items.contains { $0.kind == .video }
        let noun = hasVideo ? "Capture" : "Screenshot"
        return count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }

    /// The peek tab matches the card width, so it uses the same edge inset as
    /// the cards to line up on the same x-position.
    private var peekHorizontalPadding: CGFloat {
        previewTrailingPadding
    }

    /// Distance to slide the stack straight down so it clears the bottom edge
    /// (and is clipped by the window) when collapsed.
    private var stackHiddenOffset: CGFloat {
        stackHeight + previewStackEdgePadding + 24
    }

    /// Distance to slide the peek pill down below the bottom edge when expanded.
    private var peekHiddenOffset: CGFloat {
        peekHeight + 24
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

    /// Scrolling/swiping while hovering the stack drives two gestures: a
    /// downward swipe tucks the stack into the peek tab, and an outward
    /// horizontal swipe dismisses the hovered card.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleScroll(event)
            return event
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard !previewStack.isCollapsed, !previewStack.isExiting, let hoveredID = previewStack.hoveredItemID else { return }

        let horizontal = event.scrollingDeltaX
        let vertical = event.scrollingDeltaY

        // A predominantly horizontal swipe toward the docked edge (the same
        // direction the card exits in) flicks that card away. `slideDirection`
        // is +1 when docked right and -1 when docked left, so multiplying by it
        // normalises "outward" to a positive value for either side.
        if abs(horizontal) > abs(vertical) {
            if horizontal * slideDirection > 8 {
                withAnimation(previewStackAnimation) {
                    previewStack.dismiss(id: hoveredID)
                }
            }
            return
        }

        // A downward swipe (positive deltaY with natural scrolling) collapses
        // the stack into the peek tab. Threshold avoids accidental triggers.
        if vertical > 6 {
            withAnimation(previewStackAnimation) {
                previewStack.collapse()
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

        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }

        keyMonitor = nil
        globalKeyMonitor = nil
        scrollMonitor = nil
        QuickLookPreviewPresenter.dismiss()
    }

    private func scheduleTransitionReset() {
        isOverlayTransitioning = true
        transitionResetTask?.cancel()
        transitionResetTask = Task {
            try? await Task.sleep(for: .milliseconds(340))
            guard !Task.isCancelled else { return }
            isOverlayTransitioning = false
        }
    }
    
    private func handlePreviewKey(_ event: NSEvent) -> Bool {
        guard !previewStack.isExiting else { return false }

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
