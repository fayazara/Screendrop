//
//  ScreenshotBasket.swift
//  Screendrop
//
//  A lightweight, session-scoped collection of screenshots that can be
//  dragged to another app as one multi-file operation.
//

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ScreenshotBasket {
    static let shared = ScreenshotBasket()

    private(set) var urls: [URL] = []

    var count: Int { urls.count }
    var isEmpty: Bool { urls.isEmpty }

    private init() {}

    func contains(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL
        return urls.contains { $0.standardizedFileURL == candidate }
    }

    func add(_ url: URL) {
        add(contentsOf: [url])
    }

    func add(contentsOf newURLs: [URL]) {
        var knownURLs = Set(urls.map(\.standardizedFileURL))

        for url in newURLs {
            let standardizedURL = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardizedURL.path),
                  isImageURL(standardizedURL),
                  knownURLs.insert(standardizedURL).inserted else {
                continue
            }
            urls.append(standardizedURL)
        }
    }

    func toggle(_ url: URL) {
        if contains(url) {
            remove(url)
        } else {
            add(url)
        }
    }

    func remove(_ url: URL) {
        let candidate = url.standardizedFileURL
        urls.removeAll { $0.standardizedFileURL == candidate }
    }

    func remove(contentsOf removedURLs: [URL]) {
        let candidates = Set(removedURLs.map(\.standardizedFileURL))
        urls.removeAll { candidates.contains($0.standardizedFileURL) }
    }

    func clear() {
        urls.removeAll()
    }

    /// Removes history entries that were deleted while the basket was open.
    func pruneMissingFiles() {
        urls.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
    }

    @discardableResult
    func copyAllToClipboard() -> Bool {
        pruneMissingFiles()
        guard !urls.isEmpty else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls.map(Self.pasteboardItem(for:)))
    }

    static func pasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        return item
    }

    private func isImageURL(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}

/// A reusable basket pill. Clicking it opens the contents, while dragging its
/// main surface starts one AppKit drag session containing every screenshot URL.
struct ScreenshotBasketShelf: View {
    @State private var basket = ScreenshotBasket.shared
    @State private var showsContents = false

    private let width: CGFloat = 165
    private let height: CGFloat = 44

    var body: some View {
        ZStack {
            shelfBackground

            HStack(spacing: 0) {
                Button {
                    showsContents = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "basket.fill")
                            .font(.system(size: 13, weight: .semibold))

                        Text("\(basket.count) in Basket")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.leading, 13)
                    .padding(.trailing, 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Review screenshot basket")
                .accessibilityHint("Contains \(basket.count) screenshots")

                Divider()
                    .frame(height: 16)

                Button {
                    basket.clear()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Clear basket")
            }
            .foregroundStyle(.secondary)
            .padding(.trailing, 7)

            HStack(spacing: 0) {
                ScreenshotBasketDragSource(
                    urls: basket.urls,
                    onClick: { showsContents = true }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .help("Drag all screenshots, or click to review the basket")
                .accessibilityHidden(true)

                Color.clear
                    .frame(width: 39)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
        .popover(isPresented: $showsContents, arrowEdge: .top) {
            ScreenshotBasketContentsView()
        }
        .onAppear {
            basket.pruneMissingFiles()
        }
    }

    private var shelfBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Color.clear
            .glassEffect(.regular.interactive(), in: shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
    }
}

private struct ScreenshotBasketContentsView: View {
    @State private var basket = ScreenshotBasket.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Screenshot Basket", systemImage: "basket.fill")
                    .font(.headline)

                Spacer()

                Text("\(basket.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button("Copy All", systemImage: "doc.on.doc") {
                    basket.copyAllToClipboard()
                }
                .help("Copy all screenshot files")
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(basket.urls, id: \.self) { url in
                        HStack(spacing: 10) {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)

                            Text(url.lastPathComponent)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 8)

                            Button {
                                basket.remove(url)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove from basket")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(width: 320, height: min(CGFloat(basket.count) * 38, 260))
        }
        .onAppear {
            basket.pruneMissingFiles()
        }
    }
}

private struct ScreenshotBasketDragSource: NSViewRepresentable {
    let urls: [URL]
    let onClick: () -> Void

    func makeNSView(context: Context) -> BasketDragSourceView {
        BasketDragSourceView()
    }

    func updateNSView(_ nsView: BasketDragSourceView, context: Context) {
        nsView.urls = urls
        nsView.onClick = onClick
        nsView.onMissingURLs = { ScreenshotBasket.shared.remove(contentsOf: $0) }
    }

    static func dismantleNSView(_ nsView: BasketDragSourceView, coordinator: Void) {
        nsView.urls = []
        nsView.onClick = nil
        nsView.onMissingURLs = nil
    }
}

private final class BasketDragSourceView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var onClick: (() -> Void)?
    var onMissingURLs: (([URL]) -> Void)?

    private var mouseDownPoint: NSPoint?
    private var startedDragging = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        startedDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDragging,
              let mouseDownPoint else {
            return
        }

        let currentPoint = convert(event.locationInWindow, from: nil)
        guard hypot(currentPoint.x - mouseDownPoint.x, currentPoint.y - mouseDownPoint.y) >= 4 else {
            return
        }

        let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        let missingURLs = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        if !missingURLs.isEmpty {
            onMissingURLs?(missingURLs)
        }
        guard !validURLs.isEmpty else { return }

        startedDragging = true
        let previewImage = Self.dragPreviewImage(count: validURLs.count)
        let previewFrame = NSRect(
            x: currentPoint.x - 34,
            y: currentPoint.y - 25,
            width: 68,
            height: 50
        )
        let draggingItems = validURLs.map { url in
            let item = NSDraggingItem(pasteboardWriter: ScreenshotBasket.pasteboardItem(for: url))
            item.setDraggingFrame(previewFrame, contents: previewImage)
            return item
        }

        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.draggingFormation = .stack
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            startedDragging = false
        }

        if !startedDragging {
            onClick?()
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    private static func dragPreviewImage(count: Int) -> NSImage {
        let size = NSSize(width: 68, height: 50)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 12, yRadius: 12).fill()

        let symbol = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)
        symbol?.draw(in: NSRect(x: 10, y: 13, width: 24, height: 24))

        let text = "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: 47 - textSize.width / 2, y: 25 - textSize.height / 2),
            withAttributes: attributes
        )

        image.unlockFocus()
        return image
    }
}
