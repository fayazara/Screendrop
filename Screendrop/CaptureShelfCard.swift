//
//  CaptureShelfCard.swift
//  Screendrop
//
//  One capture as the floating preview: just the picture, as large as it can
//  be without cropping, with a compact CleanShot-style strip of controls that
//  appears on hover. The body drags the card (and the window under it) to a
//  new place; the grip at the start of the strip drags the file out to Finder,
//  Mail or any other app. Option-dragging the body does the same.
//
//  The controls are a single dark capsule that hugs its buttons rather than a
//  faint bar across the top of the card. Every action is also in the context
//  menu.
//

import AppKit
import SwiftUI

struct CaptureShelfCard: View {
    let item: ShelfItem
    let shelf: CaptureShelf

    @State private var isHovered = false
    @State private var uploader = CloudUploader.shared

    private var cardSize: CGSize { PreviewCardMetrics.tileSize }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: PreviewCardMetrics.cornerRadius(for: cardSize),
            style: .continuous
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
            Image(nsImage: item.thumbnail)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
        }
        .frame(width: cardSize.width, height: cardSize.height)
        // Dragging is handled by the window's hosting view
        // (NSWindow.performDrag), the same drag loop the title bar uses. A
        // SwiftUI gesture recomputing the frame per event is what made the
        // card trail the pointer and shimmer.
        .overlay { overlay }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.2), lineWidth: 1) }
        // The panel draws the shadow (see CaptureShelfPresenter), so moving
        // the window never re-renders a blurred view.
        .opacity(shelf.draggingID == item.id ? 0.4 : 1)
        .contentShape(shape)
        .onHover { hovering in
            isHovered = hovering
            shelf.setHovered(item.id, hovering)
        }
        #if DEBUG
        // Lets the preview self-test photograph the hover controls without
        // synthesising mouse movement (which needs Accessibility access).
        .onAppear {
            if UserDefaults.standard.bool(forKey: "previewForceHover") {
                isHovered = true
            }
        }
        #endif
        .pointerStyle(.grabIdle)
        .help(item.kind == .video ? "Drag to move · double-click to edit" : "Drag to move · double-click to annotate")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.kind == .video ? "Recording" : "Screenshot")
    }

    private var isUploading: Bool { uploader.uploadingItems.contains(item.id) }
    private var uploadedLink: String? { uploader.uploadedURLs[item.id] }
    private var showsActions: Bool { isHovered && shelf.draggingID == nil }

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
            hoverControls
                .transition(.opacity)
        } else if item.kind == .video {
            playBadge
        }
    }

    private func status<Icon: View>(_ title: String, @ViewBuilder icon: () -> Icon) -> some View {
        ZStack {
            scrim(0.42)
            VStack(spacing: 6) {
                icon()
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .lineLimit(2)
            .foregroundStyle(.white)
            .padding(8)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
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
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
            .transition(.blurPop)
    }

    private var uploadProgress: some View {
        ZStack {
            scrim(0.42)
            VStack(spacing: 8) {
                Text("Uploading")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                ProgressView(value: uploader.uploadProgress[item.id] ?? 0)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: max(40, min(96, cardSize.width - 48)))
            }
            PreviewToolbarButton(systemImage: "xmark", help: "Cancel upload") {
                uploader.cancelUpload(for: item.id)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(6)
        }
        .transition(.opacity)
    }

    private func scrim(_ opacity: Double) -> some View {
        Rectangle().fill(.black.opacity(opacity))
    }

    private var playBadge: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.black.opacity(0.85))
            .frame(width: 22, height: 22)
            .background(.white.opacity(0.92), in: .circle)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(8)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    // MARK: Hover controls

    /// The CleanShot-style hover layer: a big copy button in the middle,
    /// delete beside it, the other actions along the bottom, and close in the
    /// top-left corner.
    private var hoverControls: some View {
        ZStack {
            Color.black.opacity(0.1)
                .allowsHitTesting(false)

            // Copy above delete, as in CleanShot X, instead of the two
            // circles sitting shoulder to shoulder in the middle.
            VStack(spacing: 10) {
                primaryActionButton(
                    systemImage: "doc.on.doc",
                    help: "Copy to clipboard",
                    size: 38
                ) {
                    shelf.copy(id: item.id)
                }

                primaryActionButton(
                    systemImage: "trash",
                    help: "Delete screenshot",
                    size: 32,
                    tint: Color(red: 0.82, green: 0.24, blue: 0.18)
                ) {
                    confirmDelete()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 9)

            VStack {
                Spacer()
                HStack(spacing: 4) {
                    ForEach(bottomActions) { action in
                        PreviewToolbarButton(
                            systemImage: symbol(for: action),
                            help: help(for: action)
                        ) {
                            perform(action)
                        }
                        .disabled(isBlocked(action))
                    }
                }
                .padding(4)
                .background(Color(white: 0.94).opacity(0.94), in: Capsule())
                .overlay(Capsule().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                .padding(10)
            }
        }
        .overlay(alignment: .topLeading) {
            closeBadge
                .padding(8)
        }
    }

    private func primaryActionButton(
        systemImage: String,
        help: String,
        size: CGFloat,
        tint: Color = .black.opacity(0.75),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint.opacity(0.9))
                .frame(width: size, height: size)
                .background(Color(white: 0.94).opacity(0.94), in: Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var closeBadge: some View {
        Button {
            shelf.dismiss(id: item.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black.opacity(0.75))
                .frame(width: 24, height: 24)
                .background(Color(white: 0.94).opacity(0.94), in: Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Dismiss preview")
    }

    /// The actions that stay in the bottom capsule; copy and delete are the
    /// big centre buttons.
    private var bottomActions: [OverlayCardAction] {
        item.kind == .image ? [.upload, .pin, .save] : [.upload, .annotate, .save]
    }

    private func confirmDelete() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this screenshot?"
        alert.informativeText = "The captured image will be deleted."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        shelf.delete(id: item.id)
    }

    private func symbol(for action: OverlayCardAction) -> String {
        action == .upload && uploadedLink != nil ? "link" : action.symbol(for: item.kind)
    }

    private func help(for action: OverlayCardAction) -> String {
        if isBlocked(action) { return Self.deleteBlockedHelp }
        if action == .upload, uploadedLink != nil { return "Copy share link" }
        return action.help(for: item.kind)
    }

    /// Delete waits while the capture is open in an editor.
    private func isBlocked(_ action: OverlayCardAction) -> Bool {
        action == .delete && shelf.isOpenInEditor(id: item.id)
    }

    private static let deleteBlockedHelp = "Close its editor to delete it"

    private func perform(_ action: OverlayCardAction) {
        let id = item.id
        switch action {
        case .copy: shelf.copy(id: id)
        case .compress: shelf.compress(id: id)
        case .save: shelf.save(id: id)
        case .pin: shelf.pin(id: id)
        case .annotate: shelf.openEditor(id: id)
        case .view: shelf.quickLook(id: id)
        case .upload:
            if uploadedLink != nil {
                shelf.copyLink(id: id)
            } else if uploader.isConfigured {
                shelf.upload(id: id)
            } else {
                SettingsWindowController.show(tab: .cloud)
            }
        case .delete: shelf.delete(id: id)
        case .close: shelf.dismiss(id: id)
        }
    }

}

/// A small icon button in the preview's hover capsule: white on the card's
/// dark pill, so it reads over any screenshot in either appearance.
private struct PreviewToolbarButton: View {
    let systemImage: String
    let help: String
    var title: String?
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                if let title {
                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.black.opacity(isEnabled ? 0.75 : 0.3))
            .padding(.horizontal, title == nil ? 0 : 5)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                .black.opacity(isHovered && isEnabled ? 0.06 : 0),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .motion(.morphQuick, value: isHovered)
        .help(help)
        .accessibilityLabel(help)
    }
}
