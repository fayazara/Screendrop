//
//  CaptureShelfCard.swift
//  Screendrop
//
//  One capture on the shelf. At rest it is just the picture. On hover it
//  frosts and shows the actions placed on it in Settings → Overlay: a round
//  button in each corner and up to three equal-width labelled ones in the
//  middle. While it is busy (compressing, preparing a recording, uploading)
//  or has just finished something, that state takes the actions' place.
//  Every action is also in its context menu, and it drags out as a file.
//
//  The controls are solid light chips rather than the app's glass: they sit
//  on arbitrary screenshot content, where a fixed light-on-frost contrast
//  reads best, and the shelf's never-key panel would draw glass flat.
//

import AppKit
import SwiftUI

struct CaptureShelfCard: View {
    let item: ShelfItem
    let shelf: CaptureShelf
    let size: PreviewOverlaySize

    @State private var isHovered = false
    @State private var layoutStore = OverlayCardLayoutStore.shared
    @State private var uploader = CloudUploader.shared

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CaptureShelfMetrics.cardRadius, style: .continuous)
    }

    var body: some View {
        Image(nsImage: item.thumbnail)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.cardSize.width, height: size.cardSize.height)
            // Frosted under the controls, so they read on any screenshot.
            .blur(radius: isFrosted ? 6 : 0, opaque: true)
            .overlay { overlay }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Palette.strongHairline, lineWidth: 1) }
            // Flatten before the shadow, so the rounded clip and the stroke
            // move as one layer while the card slides.
            .compositingGroup()
            .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
            .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
            .opacity(isDragging ? 0.35 : 1)
            .contentShape(shape)
            .onHover { hovering in
                isHovered = hovering
                shelf.setHovered(item.id, hovering)
            }
            .motion(.morphQuick, value: showsActions)
            .motion(.morphQuick, value: item.flash)
            .motion(.morphQuick, value: item.activity)
            .simultaneousGesture(TapGesture(count: 2).onEnded { shelf.openEditor(id: item.id) })
            .draggable(item.url) {
                Image(nsImage: item.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.cardSize.width)
                    .clipShape(shape)
            }
            .onDragSessionUpdated { session in
                switch session.phase {
                case .active: shelf.beginDrag(id: item.id)
                case .ended: shelf.endDrag(id: item.id)
                default: break
                }
            }
            .contextMenu { contextMenu }
            .help(item.kind == .video ? "Double-click to edit" : "Double-click to annotate")
            .accessibilityElement(children: .contain)
            .accessibilityLabel(item.kind == .video ? "Recording" : "Screenshot")
    }

    private var isDragging: Bool { shelf.draggingID == item.id }
    private var isUploading: Bool { uploader.uploadingItems.contains(item.id) }
    private var uploadedLink: String? { uploader.uploadedURLs[item.id] }
    /// Held back while the shelf moves, then shown if the pointer is still
    /// over the card when it settles.
    private var showsActions: Bool { isHovered && !isDragging && !shelf.isMoving }
    private var isFrosted: Bool {
        showsActions || item.activity != nil || isUploading || item.flash != nil
    }

    // MARK: Overlay

    @ViewBuilder
    private var overlay: some View {
        if let activity = item.activity {
            status(activity == .compressing ? "Compressing" : "Preparing") {
                ProgressView().controlSize(.small)
            }
        } else if isUploading {
            uploadProgress
        } else if let flash = item.flash {
            flashView(flash)
        } else if showsActions {
            actions
                .transition(.opacity)
        } else if item.kind == .video {
            Image(systemName: "play.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.92), in: .circle)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(8)
                .transition(.opacity)
        }
    }

    private func status<Icon: View>(_ title: String, @ViewBuilder icon: () -> Icon) -> some View {
        ZStack {
            scrim(0.38)
            VStack(spacing: 7) {
                icon()
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
        }
        .transition(.opacity)
    }

    private func flashView(_ flash: ShelfFlash) -> some View {
        switch flash {
        case .linkCopied:
            status("Link Copied") { flashIcon("checkmark") }
        case .uploadFailed:
            status("Upload Failed") { flashIcon("exclamationmark.triangle.fill", tint: Palette.warning) }
        case .compressed(let summary):
            status("JPG Copied\n\(summary)") { flashIcon("checkmark") }
        }
    }

    private func flashIcon(_ systemImage: String, tint: Color = .white) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(tint)
            .transition(.blurPop)
    }

    private var uploadProgress: some View {
        ZStack {
            scrim(0.38)
            VStack(spacing: 9) {
                Text("Uploading")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                ProgressView(value: uploader.uploadProgress[item.id] ?? 0)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 96)
            }
            cornerButton("xmark", help: "Cancel upload") {
                uploader.cancelUpload(for: item.id)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(8)
        }
        .transition(.opacity)
    }

    /// Darkens the frosted picture a little: lightly under the controls,
    /// more under status text. The same in light and dark mode, because it
    /// sits on the screenshot, not on the window.
    private func scrim(_ opacity: Double) -> some View {
        Rectangle().fill(.black.opacity(opacity))
    }

    // MARK: Actions

    private var actions: some View {
        let layout = layoutStore.layout
        return ZStack {
            scrim(0.16)
            corner(layout.topLeading, .topLeading)
            corner(layout.topTrailing, .topTrailing)
            corner(layout.bottomLeading, .bottomLeading)
            corner(layout.bottomTrailing, .bottomTrailing)

            VStack(spacing: 6) {
                ForEach(layout.center.filter(isAvailable)) { action in
                    ShelfChipButton(help: centerHelp(for: action), width: Self.centerButtonWidth) {
                        perform(action)
                    } label: {
                        Text(centerTitle(for: action))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .disabled(isBlocked(action))
                }
            }
        }
    }

    @ViewBuilder
    private func corner(_ action: OverlayCardAction?, _ alignment: Alignment) -> some View {
        if let action, isAvailable(action) {
            cornerButton(cornerSymbol(for: action), help: cornerHelp(for: action)) {
                perform(action)
            }
            .disabled(isBlocked(action))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(7)
        }
    }

    private func cornerButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        ShelfChipButton(help: help, width: 26, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .bold))
        }
    }

    /// Every middle button is this wide whatever its label, so a column of
    /// them lines up however the layout is customised.
    private static let centerButtonWidth: CGFloat = 80

    private func isAvailable(_ action: OverlayCardAction) -> Bool {
        switch action {
        case .pin, .compress: item.kind == .image
        case .upload: uploader.isConfigured
        default: true
        }
    }

    private func cornerSymbol(for action: OverlayCardAction) -> String {
        action == .upload && uploadedLink != nil ? "link" : action.symbol(for: item.kind)
    }

    private func cornerHelp(for action: OverlayCardAction) -> String {
        if isBlocked(action) { return Self.deleteBlockedHelp }
        return action == .upload && uploadedLink != nil ? "Copy share link" : action.help(for: item.kind)
    }

    private func centerHelp(for action: OverlayCardAction) -> String {
        isBlocked(action) ? Self.deleteBlockedHelp : action.help(for: item.kind)
    }

    /// Delete waits while the capture is open in an editor.
    private func isBlocked(_ action: OverlayCardAction) -> Bool {
        action == .delete && shelf.isOpenInEditor(id: item.id)
    }

    private static let deleteBlockedHelp = "Close its editor to delete it"

    private func centerTitle(for action: OverlayCardAction) -> String {
        action == .upload && uploadedLink != nil ? "Copy Link" : action.label(for: item.kind)
    }

    private func perform(_ action: OverlayCardAction) {
        let id = item.id
        switch action {
        case .copy: shelf.copy(id: id)
        case .compress: shelf.compress(id: id)
        case .save: shelf.save(id: id)
        case .pin: shelf.pin(id: id)
        case .annotate: shelf.openEditor(id: id)
        case .view: shelf.quickLook(id: id)
        case .upload: uploadedLink == nil ? shelf.upload(id: id) : shelf.copyLink(id: id)
        case .delete: shelf.delete(id: id)
        case .close: shelf.dismiss(id: id)
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        let id = item.id
        let isImage = item.kind == .image

        Button(isImage ? "Annotate" : "Edit Recording") { shelf.openEditor(id: id) }
        Button("Quick Look") { shelf.quickLook(id: id) }

        Divider()

        Button("Copy") { shelf.copy(id: id) }
        if isImage {
            Button("Copy Text from Image") { shelf.copyText(id: id) }
            Button("Copy as Compressed JPG") { shelf.compress(id: id) }
        }
        Button("Save") { shelf.save(id: id) }
        Button("Save As…") { shelf.save(id: id, choosingLocation: true) }
        if isImage {
            Button("Pin to Screen") { shelf.pin(id: id) }
        }
        if uploader.isConfigured {
            if uploadedLink != nil {
                Button("Copy Share Link") { shelf.copyLink(id: id) }
            } else {
                Button("Upload and Copy Link") { shelf.upload(id: id) }
            }
        }

        Divider()

        Button("Dismiss") { shelf.dismiss(id: id) }
        Button(isImage ? "Delete Screenshot" : "Delete Recording", role: .destructive) {
            shelf.delete(id: id)
        }
        .disabled(shelf.isOpenInEditor(id: id))
    }
}

/// A solid light control over the frosted card: a circle when its width
/// matches its height, a capsule otherwise. Solid rather than glass: the
/// shelf's panel is never key, and glass in a non-key window draws flat.
/// Light on any screenshot, so it stays the same in dark mode.
private struct ShelfChipButton<Label: View>: View {
    let help: String
    let width: CGFloat
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    private var isCircle: Bool { width <= 30 }
    private var height: CGFloat { isCircle ? width : 26 }

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(.black.opacity(isEnabled ? 0.85 : 0.3))
                .padding(.horizontal, isCircle ? 0 : 8)
                .frame(width: width, height: height)
                .background(.white.opacity(isEnabled ? (isHovered ? 1 : 0.88) : 0.6), in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .scaleEffect(isHovered && isEnabled ? 1.04 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .motion(.morphQuick, value: isHovered)
        .help(help)
        .accessibilityLabel(help)
    }
}
