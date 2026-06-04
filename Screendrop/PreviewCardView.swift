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
    let onHoverChanged: (Bool) -> Void
    let onClose: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void
    let onAnnotate: () -> Void
    let onEditVideo: () -> Void
    let onUpload: () -> Void
    let onPin: () -> Void
    let onCopyText: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    @State private var isHovered = false
    @State private var isPresented = false
    @State private var cloudUploader = CloudUploader.shared
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
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 12)
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
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
                cornerButton(systemImage: "xmark.circle.fill", help: "Dismiss preview", action: onClose)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)

                cornerButton(
                    systemImage: "trash.circle.fill",
                    help: item.kind == .video ? "Delete recording" : "Delete screenshot",
                    action: onDelete
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)

                cornerButton(
                    systemImage: item.kind == .video ? "scissors.circle.fill" : "pencil.circle.fill",
                    help: item.kind == .video ? "Edit recording" : "Annotate screenshot",
                    action: item.kind == .video ? onEditVideo : onAnnotate
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(10)

                cloudUploadControl

                if cloudUploader.uploadingItems.contains(item.id) {
                    ProgressView(value: cloudUploader.uploadProgress[item.id] ?? 0)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .padding(.horizontal, 20)
                } else {
                    VStack(spacing: 8) {
                        actionPill("Copy", action: onCopy)
                        actionPill("Save", action: onSave)
                        if item.kind == .image {
                            actionPill("Pin", action: onPin)
                        }
                    }
                }
            }
        }
        .transition(.opacity)
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

    @ViewBuilder
    private var cloudUploadControl: some View {
        if cloudUploader.isConfigured {
            if cloudUploader.uploadingItems.contains(item.id) {
                cornerButton(
                    systemImage: "stop.circle.fill",
                    help: "Cancel upload",
                    action: { cloudUploader.cancelUpload(for: item.id) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(10)
            } else if cloudUploader.uploadedURLs[item.id] != nil {
                cornerButton(systemImage: "link.circle.fill", help: "Copy share link", action: copyUploadedURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(10)
            } else {
                cornerButton(systemImage: "cloud.circle.fill", help: "Upload to cloud", action: onUpload)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(10)
            }
        }
    }

    private var showOverlay: Bool {
        isHovered
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
                .font(.title2)
                .foregroundStyle(.black, .white)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func actionPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.background.opacity(0.8), in: .capsule)
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
