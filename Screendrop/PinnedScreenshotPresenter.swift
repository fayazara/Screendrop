//
//  PinnedScreenshotPresenter.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Pins a screenshot to the screen as a floating, always-on-top window the user
/// can keep around for reference while they work. Supports multiple pins.
@MainActor
final class PinnedScreenshotPresenter {
    static let shared = PinnedScreenshotPresenter()

    private var panels: Set<NSPanel> = []

    private init() {}

    func pin(url: URL) {
        guard let image = ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: 1600) else {
            return
        }

        let contentSize = displaySize(forPixelSize: image.size)
        let panel = PinnedPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = contentSize
        panel.minSize = NSSize(width: 80, height: 80)

        panel.contentView = NSHostingView(
            rootView: PinnedScreenshotView(
                image: image,
                url: url,
                onClose: { [weak self, weak panel] in
                    guard let panel else { return }
                    self?.close(panel)
                }
            )
        )

        panel.setFrameOrigin(cascadedOrigin(for: contentSize))
        panel.orderFrontRegardless()
        panels.insert(panel)
    }

    private func close(_ panel: NSPanel) {
        panel.orderOut(nil)
        panel.contentView = nil
        panels.remove(panel)
    }

    /// Convert pixel dimensions to a sensible point size for the pinned window,
    /// scaled for the display and clamped so pins stay handy but readable.
    private func displaySize(forPixelSize pixelSize: CGSize) -> NSSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var width = pixelSize.width / scale
        var height = pixelSize.height / scale
        guard width > 0, height > 0 else { return NSSize(width: 320, height: 240) }

        let longest = max(width, height)
        let maxLongest: CGFloat = 560
        let minLongest: CGFloat = 160
        let target = min(max(longest, minLongest), maxLongest)
        let factor = target / longest
        width *= factor
        height *= factor
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    private func cascadedOrigin(for size: NSSize) -> CGPoint {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 100, y: 100, width: 800, height: 600)
        let offset = CGFloat(panels.count % 8) * 28
        return CGPoint(
            x: visible.midX - size.width / 2 + offset,
            y: visible.midY - size.height / 2 - offset
        )
    }
}

private final class PinnedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PinnedScreenshotView: View {
    let image: NSImage
    let url: URL
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var didCopy = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                if isHovered {
                    toolbar
                        .padding(8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .contextMenu {
                Button("Copy") { copy() }
                Button("Copy Text from Image") { copyText() }
                Button("Save…") { save() }
                Divider()
                Button("Close Pin") { onClose() }
            }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolbarButton(systemImage: "xmark", help: "Close pin", action: onClose)

            Spacer(minLength: 0)

            toolbarButton(
                systemImage: didCopy ? "checkmark" : "doc.on.doc",
                help: "Copy to clipboard",
                action: copy
            )
            toolbarButton(systemImage: "square.and.arrow.down", help: "Save…", action: save)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private func toolbarButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func copy() {
        do {
            try ScreenshotFileActions.copyPNGToClipboard(from: url)
            withAnimation { didCopy = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { didCopy = false }
            }
        } catch {
            print("Failed to copy pinned screenshot: \(error)")
        }
    }

    private func copyText() {
        let url = url
        Task {
            let text = await ImageTextRecognizer.recognizeText(at: url)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
        panel.nameFieldStringValue = ScreenshotFileActions.exportFileName(for: url)
        panel.canCreateDirectories = true
        panel.title = "Save Screenshot"
        panel.begin { response in
            guard response == .OK, let destURL = panel.url else { return }
            do {
                try ScreenshotFileActions.save(from: url, to: destURL)
            } catch {
                print("Failed to save pinned screenshot: \(error)")
            }
        }
    }
}
