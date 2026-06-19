//
//  PreviewCardView.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct PreviewCardView: View {
    let item: ScreenshotPreviewItem
    let isHidden: Bool
    let isDismissing: Bool
    var slideDirection: CGFloat = 1
    /// Suppresses the hover action overlay while the whole stack is animating
    /// in or out (collapsing to / expanding from the peek tab), so actions don't
    /// flash over cards mid-transition.
    var suppressHoverActions: Bool = false
    let onHoverChanged: (Bool) -> Void
    let onClose: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void
    let onAnnotate: () -> Void
    let onEditVideo: () -> Void
    let onUpload: () -> Void
    let onPin: () -> Void
    let onView: () -> Void
    let onCopyText: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    @State private var isHovered = false
    @State private var isPresented = false
    @State private var cloudUploader = CloudUploader.shared
    @State private var layoutStore = OverlayCardLayoutStore.shared
    @State private var shakeOffset: CGFloat = 0
    @State private var showUploadFailed = false
    @State private var showCheckmark = false

    var body: some View {
        Image(nsImage: item.previewImage)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: previewCardSize.width, height: previewCardSize.height)
            .clipped()
            .overlay {
                if item.kind == .video {
                    videoPlayIndicator
                }
            }
            .overlay {
                if showOverlay {
                    hoveredContent
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            // Flatten the rounded-clipped image + border into a single layer so
            // the collapse/expand offset animation transforms the already-rounded
            // result. Without this the fill image can briefly overflow the
            // rounded corners mid-animation, making the card look square/janky.
            .compositingGroup()
            .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 6)
            .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 1)
            .opacity(isHidden ? 0 : 1)
            .offset(x: horizontalOffset + shakeOffset)
            .onChange(of: cloudUploader.failedItemIDs.contains(item.id)) { _, failed in
                guard failed else { return }
                shakeCard()
                showUploadFailed = true
                cloudUploader.clearFailed(for: item.id)
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(.easeOut(duration: 0.25)) {
                        showUploadFailed = false
                    }
                }
            }
            .onChange(of: cloudUploader.uploadedURLs[item.id] != nil) { _, uploaded in
                guard uploaded else { return }
                showCheckmark = true
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation(.easeOut(duration: 0.25)) {
                        showCheckmark = false
                    }
                }
            }
            .draggable(item.url) {
                Image(nsImage: item.previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: cornerRadius))
            }
            .onDragSessionUpdated { session in
                switch session.phase {
                case .active:
                    onDragBegan()
                case .ended:
                    onDragEnded()
                default:
                    break
                }
            }
            .onHover { status in
                withAnimation(previewStackAnimation) {
                    isHovered = status
                    onHoverChanged(status)
                }
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    if item.kind == .video {
                        onEditVideo()
                    } else {
                        onAnnotate()
                    }
                }
            )
            .onAppear {
                isPresented = false

                DispatchQueue.main.async {
                    withAnimation(previewStackAnimation) {
                        isPresented = true
                    }
                }
            }
            .animation(previewStackAnimation, value: isDismissing)
            .contextMenu {
                if item.kind == .image {
                    Button("Copy Text from Image") { onCopyText() }
                }
            }
    }

    private var layout: OverlayCardLayout {
        layoutStore.layout
    }

    private var hoveredContent: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)

            if showCheckmark {
                linkCopiedOverlay
            } else if showUploadFailed {
                uploadFailedOverlay
            } else {
                cornerSlot(layout.topLeading, alignment: .topLeading)
                cornerSlot(layout.topTrailing, alignment: .topTrailing)
                cornerSlot(layout.bottomLeading, alignment: .bottomLeading)
                cornerSlot(layout.bottomTrailing, alignment: .bottomTrailing)

                centerStack
            }
        }
        .transition(.opacity)
    }

    /// Renders the action assigned to a corner, if any and currently available.
    @ViewBuilder
    private func cornerSlot(_ action: OverlayCardAction?, alignment: Alignment) -> some View {
        if let action, isAvailable(action) {
            cornerView(for: action)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                .padding(10)
        }
    }

    @ViewBuilder
    private func cornerView(for action: OverlayCardAction) -> some View {
        if action == .upload {
            cloudCornerButton
        } else {
            cornerButton(
                systemImage: action.symbol(for: item.kind),
                help: action.help(for: item.kind),
                action: handler(for: action)
            )
        }
    }

    @ViewBuilder
    private var centerStack: some View {
        if cloudUploader.uploadingItems.contains(item.id) {
            ProgressView(value: cloudUploader.uploadProgress[item.id] ?? 0)
                .progressViewStyle(.linear)
                .tint(.white)
                .padding(.horizontal, 20)
        } else {
            let actions = layout.center.filter { isAvailable($0) }
            if !actions.isEmpty {
                VStack(spacing: 6) {
                    ForEach(actions) { action in
                        centerPill(for: action)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func centerPill(for action: OverlayCardAction) -> some View {
        if action == .upload, cloudUploader.uploadedURLs[item.id] != nil {
            actionPill("Copy Link", action: copyUploadedURL)
        } else {
            actionPill(action.label(for: item.kind), action: handler(for: action))
        }
    }

    /// Whether an action should be shown for the current item.
    private func isAvailable(_ action: OverlayCardAction) -> Bool {
        switch action {
        case .pin: item.kind == .image
        case .upload: cloudUploader.isConfigured
        default: true
        }
    }

    private func handler(for action: OverlayCardAction) -> () -> Void {
        switch action {
        case .copy: onCopy
        case .save: onSave
        case .pin: onPin
        case .annotate: item.kind == .video ? onEditVideo : onAnnotate
        case .view: onView
        case .upload: onUpload
        case .delete: onDelete
        case .close: onClose
        }
    }

    private var linkCopiedOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)

            Text("Link copied")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private var uploadFailedOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "xmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.red)

            Text("Upload failed")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private var videoPlayIndicator: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92), .black.opacity(0.35))
            .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 2)
    }

    /// The cloud action's corner button, whose icon/behaviour reflects the
    /// current upload state. Availability (cloud configured) is gated by the
    /// caller via `isAvailable(.upload)`.
    @ViewBuilder
    private var cloudCornerButton: some View {
        if cloudUploader.uploadingItems.contains(item.id) {
            cornerButton(
                systemImage: "stop.fill",
                help: "Cancel upload",
                action: { cloudUploader.cancelUpload(for: item.id) }
            )
        } else if cloudUploader.uploadedURLs[item.id] != nil {
            cornerButton(systemImage: "link", help: "Copy share link", action: copyUploadedURL)
        } else {
            cornerButton(systemImage: "cloud", help: "Upload to cloud", action: onUpload)
        }
    }

    private var showOverlay: Bool {
        (isHovered && !suppressHoverActions)
        || cloudUploader.uploadingItems.contains(item.id)
        || showCheckmark
        || showUploadFailed
    }

    private var cornerRadius: CGFloat {
        16
    }

    private var horizontalOffset: CGFloat {
        isPresented && !isDismissing ? 0 : previewCardSlideOffset * slideDirection
    }

    private func cornerButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(.white, in: .circle)
                .shadow(color: .black.opacity(0.22), radius: 2.5, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func actionPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(.background.opacity(0.85), in: .capsule)
                .shadow(color: .black.opacity(0.22), radius: 2.5, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func copyUploadedURL() {
        guard let url = cloudUploader.uploadedURLs[item.id] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    private func shakeCard() {
        let steps: [(CGFloat, Double)] = [
            (-8, 0.06), (7, 0.06), (-5, 0.05), (4, 0.05), (-2, 0.04), (0, 0.04)
        ]
        var delay = 0.0
        for (offset, duration) in steps {
            delay += duration
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeInOut(duration: duration)) {
                    shakeOffset = offset
                }
            }
        }
    }
}
