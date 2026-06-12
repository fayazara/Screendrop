//
//  ScreenshotPreviewStack.swift
//  Screendrop
//

import AppKit
import Observation
import SwiftUI

enum PreviewMediaKind: String, Equatable, Codable {
    case image
    case video
}

struct ScreenshotPreviewItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var previewImage: NSImage
    var kind: PreviewMediaKind = .image
    var autoSavedURL: URL?

    static func == (lhs: ScreenshotPreviewItem, rhs: ScreenshotPreviewItem) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
@Observable
final class ScreenshotPreviewStack {
    static let shared = ScreenshotPreviewStack()

    private(set) var items: [ScreenshotPreviewItem] = []
    var hoveredItemID: ScreenshotPreviewItem.ID?
    var draggingItemID: ScreenshotPreviewItem.ID?
    var dismissingItemIDs: Set<ScreenshotPreviewItem.ID> = []

    /// When true the overlay is tucked into a small "peek" tab at the bottom
    /// edge instead of showing the full stack. The overlay window itself stays
    /// visible the whole time — this only changes what it renders. Used while an
    /// editor is open and when the user scrolls the stack down to hide it.
    var isCollapsed = false

    /// Screen-space (SwiftUI `.global`) frames of the currently interactive
    /// elements (cards, or the peek tab). The overlay's hosting view reads these
    /// to pass mouse events through every other (transparent) region so the
    /// always-on panel never blocks the windows beneath it.
    var interactiveRects: [CGRect] = []

    private var visibleCapacity: Int?

    var itemIDs: [ScreenshotPreviewItem.ID] {
        items.map(\.id)
    }

    var hoveredItem: ScreenshotPreviewItem? {
        guard let hoveredItemID else { return nil }
        return items.first { $0.id == hoveredItemID }
    }

    private init() {}

    /// Tuck the overlay into the peek tab (no-op when there's nothing to show).
    func collapse() {
        guard !items.isEmpty else { return }
        isCollapsed = true
    }

    /// Expand the overlay back into the full stack.
    func expand() {
        isCollapsed = false
    }

    func add(url: URL) {
        QuickLookPreviewPresenter.dismiss()

        if AfterCaptureActions.isEnabled(.showOverlay, for: .screenshot),
           let image = ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: 520) {
            var item = ScreenshotPreviewItem(url: url, previewImage: image)
            if AfterCaptureActions.isEnabled(.save, for: .screenshot) {
                item.autoSavedURL = saveToDefaultLocation(from: url)
            }
            prepareForInsertedPreview()
            items.insert(item, at: 0)
            runAfterCaptureActions(type: .screenshot, url: url, itemID: item.id)
            scheduleAutoClose(id: item.id)
        } else {
            if AfterCaptureActions.isEnabled(.save, for: .screenshot) {
                _ = saveToDefaultLocation(from: url)
            }
            runAfterCaptureActions(type: .screenshot, url: url, itemID: UUID())
        }
    }

    /// Runs the non-save after-capture actions (copy / upload / annotate / pin /
    /// open editor). Save is handled by the caller so it can track the
    /// auto-saved URL on the preview item.
    private func runAfterCaptureActions(type: AfterCaptureType, url: URL, itemID: UUID) {
        if AfterCaptureActions.isEnabled(.copy, for: type) {
            switch type {
            case .screenshot: _ = copyURLToClipboard(url)
            case .recording: _ = copyVideoURLToClipboard(url)
            }
        }

        if AfterCaptureActions.isEnabled(.upload, for: type) {
            autoUpload(itemID: itemID, url: url)
        }

        switch type {
        case .screenshot:
            if AfterCaptureActions.isEnabled(.annotate, for: type) {
                PreviewPanelPresenter.shared.onAnnotate?(url)
            }
            if AfterCaptureActions.isEnabled(.pin, for: type) {
                PinnedScreenshotPresenter.shared.pin(url: url)
            }
        case .recording:
            if AfterCaptureActions.isEnabled(.openVideoEditor, for: type) {
                PreviewPanelPresenter.shared.onEditVideo?(url)
            }
        }
    }

    private func autoUpload(itemID: UUID, url: URL) {
        guard CloudUploader.shared.isConfigured else { return }
        Task {
            do {
                let result = try await CloudUploader.shared.upload(itemID: itemID, fileURL: url)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.url, forType: .string)
                ScreenshotHistoryStore.shared.setCloudURL(for: url, cloudURL: result.url)
            } catch {
                print("Auto cloud upload failed: \(error)")
            }
        }
    }

    func previewExistingImage(url: URL) {
        guard let image = ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: 520) else {
            return
        }

        QuickLookPreviewPresenter.dismiss()

        if let index = items.firstIndex(where: { $0.url == url && $0.kind == .image }) {
            var item = items.remove(at: index)
            item.previewImage = image
            item.autoSavedURL = nil
            items.insert(item, at: 0)
            return
        }

        prepareForInsertedPreview()
        items.insert(ScreenshotPreviewItem(url: url, previewImage: image), at: 0)
    }

    func previewExistingVideo(url: URL) {
        QuickLookPreviewPresenter.dismiss()

        if let index = items.firstIndex(where: { $0.url == url && $0.kind == .video }) {
            let item = items.remove(at: index)
            items.insert(item, at: 0)
            return
        }

        let item = ScreenshotPreviewItem(
            url: url,
            previewImage: VideoPreviewImageLoader.placeholderImage(),
            kind: .video
        )
        let itemID = item.id
        prepareForInsertedPreview()
        items.insert(item, at: 0)

        Task {
            guard let thumbnail = await VideoPreviewImageLoader.thumbnail(at: url, maxPixelSize: 520),
                  let index = items.firstIndex(where: { $0.id == itemID }) else {
                return
            }
            items[index].previewImage = thumbnail
        }
    }

    func addVideo(url: URL) {
        QuickLookPreviewPresenter.dismiss()

        guard AfterCaptureActions.isEnabled(.showOverlay, for: .recording) else {
            if AfterCaptureActions.isEnabled(.save, for: .recording) {
                _ = saveVideoToDefaultLocation(from: url)
            }
            runAfterCaptureActions(type: .recording, url: url, itemID: UUID())
            return
        }

        var item = ScreenshotPreviewItem(
            url: url,
            previewImage: VideoPreviewImageLoader.placeholderImage(),
            kind: .video
        )
        let itemID = item.id

        if AfterCaptureActions.isEnabled(.save, for: .recording) {
            item.autoSavedURL = saveVideoToDefaultLocation(from: url)
        }

        prepareForInsertedPreview()
        items.insert(item, at: 0)
        runAfterCaptureActions(type: .recording, url: url, itemID: itemID)
        scheduleAutoClose(id: itemID)

        Task {
            guard let thumbnail = await VideoPreviewImageLoader.thumbnail(at: url, maxPixelSize: 520),
                  let index = items.firstIndex(where: { $0.id == itemID }) else {
                return
            }

            items[index].previewImage = thumbnail
        }
    }

    /// Dismisses a preview card after the configured delay, unless the user is
    /// interacting with it (hovering, dragging, or uploading).
    private func scheduleAutoClose(id: ScreenshotPreviewItem.ID) {
        guard ScreendropPreferences.previewAutoCloseSeconds > 0 else { return }
        let seconds = ScreendropPreferences.previewAutoCloseSeconds
        Task {
            try? await Task.sleep(for: .seconds(Double(seconds)))
            autoCloseIfIdle(id: id)
        }
    }

    private func autoCloseIfIdle(id: ScreenshotPreviewItem.ID) {
        guard items.contains(where: { $0.id == id }) else { return }

        if hoveredItemID == id
            || draggingItemID == id
            || CloudUploader.shared.uploadingItems.contains(id) {
            Task {
                try? await Task.sleep(for: .seconds(2))
                autoCloseIfIdle(id: id)
            }
            return
        }

        dismiss(id: id)
    }

    func setHovered(_ id: ScreenshotPreviewItem.ID, isHovered: Bool) {
        if isHovered {
            hoveredItemID = id
        } else if hoveredItemID == id {
            hoveredItemID = nil
        }
    }

    func beginDrag(id: ScreenshotPreviewItem.ID) {
        QuickLookPreviewPresenter.dismiss()
        draggingItemID = id
    }

    func finishDrag(id: ScreenshotPreviewItem.ID) {
        if ScreendropPreferences.previewCloseAfterDragging {
            removeImmediately(id: id)
        } else {
            draggingItemID = nil
        }
    }

    func dismiss(id: ScreenshotPreviewItem.ID) {
        guard items.contains(where: { $0.id == id }),
              !dismissingItemIDs.contains(id) else {
            return
        }

        QuickLookPreviewPresenter.dismiss()

        withAnimation(previewStackAnimation) {
            dismissingItemIDs.insert(id)
            if hoveredItemID == id {
                hoveredItemID = nil
            }

            if draggingItemID == id {
                draggingItemID = nil
            }
        }

        Task {
            try? await Task.sleep(for: .milliseconds(320))
            removeImmediately(id: id)
        }
    }

    func setVisibleCapacity(_ capacity: Int) {
        guard capacity > 0, capacity < Int.max else { return }

        visibleCapacity = capacity
        dismissOverflowItems(visibleCapacity: capacity)
    }

    func dismissOverflowItems(visibleCapacity: Int) {
        guard visibleCapacity > 0 else { return }

        let stableItemCount = items.filter { !dismissingItemIDs.contains($0.id) }.count
        let overflowCount = stableItemCount - visibleCapacity
        dismissOldestStableItems(count: overflowCount)
    }

    private func prepareForInsertedPreview() {
        // A freshly captured (or re-previewed) item should always be visible,
        // so surface the full stack even if it was tucked into the peek tab.
        isCollapsed = false

        guard let visibleCapacity else { return }

        let stableItemCount = items.filter { !dismissingItemIDs.contains($0.id) }.count
        let overflowCount = stableItemCount + 1 - visibleCapacity
        dismissOldestStableItems(count: overflowCount)
    }

    private func dismissOldestStableItems(count: Int) {
        guard count > 0 else { return }

        let overflowItems = items
            .reversed()
            .filter { !dismissingItemIDs.contains($0.id) }
            .prefix(count)

        for item in overflowItems {
            dismiss(id: item.id)
        }
    }

    func copyToClipboard(id: ScreenshotPreviewItem.ID) {
        guard let item = items.first(where: { $0.id == id }) else { return }

        let didCopy: Bool
        switch item.kind {
        case .image:
            didCopy = copyURLToClipboard(item.url)
        case .video:
            didCopy = copyVideoURLToClipboard(item.url)
        }
        guard didCopy else { return }
        dismiss(id: id)
    }

    /// Runs OCR on the item's image and copies the recognised text to the
    /// clipboard. No-op for videos or images without detectable text.
    func copyText(id: ScreenshotPreviewItem.ID) {
        guard let item = items.first(where: { $0.id == id }), item.kind == .image else { return }
        let url = item.url
        Task {
            let text = await ImageTextRecognizer.recognizeText(at: url)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func deleteScreenshot(id: ScreenshotPreviewItem.ID) {
        guard let item = items.first(where: { $0.id == id }) else { return }

        if ScreenshotHistoryStore.shared.delete(url: item.url) {
            // The history store owns this file and has already removed it.
        } else {
            deleteFile(at: item.url)
        }

        if let autoSavedURL = item.autoSavedURL, autoSavedURL != item.url {
            deleteFile(at: autoSavedURL)
        }

        dismiss(id: id)
    }

    func save(id: ScreenshotPreviewItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let kind = items[index].kind

        if ScreendropPreferences.autoSave {
            if items[index].autoSavedURL == nil {
                items[index].autoSavedURL = kind == .video
                    ? saveVideoToDefaultLocation(from: items[index].url)
                    : saveToDefaultLocation(from: items[index].url)
            }

            dismiss(id: id)
            return
        }

        let url = items[index].url
        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind == .video ? VideoFileActions.exportContentType : ScreenshotFileActions.exportContentType]
        panel.nameFieldStringValue = kind == .video ? VideoFileActions.exportFileName(for: url) : ScreenshotFileActions.exportFileName(for: url)
        panel.canCreateDirectories = true
        panel.title = kind == .video ? "Save Recording" : "Save Screenshot"

        panel.begin { response in
            if response == .OK, let destURL = panel.url {
                do {
                    if kind == .video {
                        try VideoFileActions.save(from: url, to: destURL)
                    } else {
                        try ScreenshotFileActions.save(from: url, to: destURL)
                    }
                } catch {
                    print("Failed to save preview: \(error)")
                }
            }
        }
    }

    /// Refreshes a preview item after a (non-destructive) annotation commit and
    /// re-publishes the latest version: re-copying it to the clipboard and
    /// overwriting the existing auto-saved file so we never leave a stale copy
    /// behind or accumulate duplicates.
    @discardableResult
    func applyAnnotation(originalURL: URL, historyURL: URL) -> Bool {
        guard let image = ScreenshotImageLoader.downsampledImage(at: historyURL, maxPixelSize: 520) else {
            return false
        }

        QuickLookPreviewPresenter.dismiss()

        if let index = items.firstIndex(where: { $0.url == originalURL }) {
            CloudUploader.shared.clearUploadState(for: items[index].id)
            items[index].url = historyURL
            items[index].previewImage = image
            republishLatestVersion(at: index)
            return true
        } else {
            prepareForInsertedPreview()
            items.insert(ScreenshotPreviewItem(url: historyURL, previewImage: image), at: 0)
            republishLatestVersion(at: 0)
            return false
        }
    }

    /// Re-copies the current image to the clipboard (when auto-copy is on) and
    /// overwrites the existing auto-saved file in place (when auto-save is on),
    /// keeping the clipboard and exported file in sync with the latest edit.
    private func republishLatestVersion(at index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]

        if ScreendropPreferences.autoSave {
            if let existingURL = item.autoSavedURL {
                do {
                    try ScreenshotFileActions.save(from: item.url, to: existingURL)
                } catch {
                    print("Failed to update auto-saved screenshot: \(error)")
                }
            } else {
                items[index].autoSavedURL = saveToDefaultLocation(from: item.url)
            }
        }

        if ScreendropPreferences.autoCopy {
            _ = copyURLToClipboard(item.url)
        }
    }

    @discardableResult
    func replaceVideo(originalURL: URL, with editedURL: URL) -> Bool {
        QuickLookPreviewPresenter.dismiss()

        guard let index = items.firstIndex(where: { $0.url == originalURL && $0.kind == .video }) else {
            addVideo(url: editedURL)
            return false
        }

        let oldURL = items[index].url
        let itemID = items[index].id
        CloudUploader.shared.clearUploadState(for: itemID)
        items[index].url = editedURL
        items[index].previewImage = VideoPreviewImageLoader.placeholderImage()
        items[index].autoSavedURL = nil

        Task {
            guard let thumbnail = await VideoPreviewImageLoader.thumbnail(at: editedURL, maxPixelSize: 520),
                  let index = items.firstIndex(where: { $0.id == itemID }) else {
                return
            }

            items[index].previewImage = thumbnail
        }

        deleteTemporaryFileIfNeeded(at: oldURL, preserving: editedURL)
        return true
    }

    private func removeImmediately(id: ScreenshotPreviewItem.ID) {
        QuickLookPreviewPresenter.dismiss()
        items.removeAll { $0.id == id }
        dismissingItemIDs.remove(id)

        if hoveredItemID == id {
            hoveredItemID = nil
        }

        if draggingItemID == id {
            draggingItemID = nil
        }

        // Don't leave the overlay stuck in the peek state once it's empty; the
        // panel is torn down and the next capture should open expanded.
        if items.isEmpty {
            isCollapsed = false
        }
    }

    private func deleteFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("Failed to delete screenshot: \(error)")
        }
    }

    private func deleteTemporaryFileIfNeeded(at url: URL, preserving preservedURL: URL) {
        guard url != preservedURL,
              url.path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).path) else {
            return
        }

        deleteFile(at: url)
    }

    private func copyURLToClipboard(_ url: URL) -> Bool {
        do {
            try ScreenshotFileActions.copyPNGToClipboard(from: url)
            return true
        } catch {
            print("Failed to copy screenshot: \(error)")
            return false
        }
    }

    private func saveToDefaultLocation(from url: URL) -> URL? {
        do {
            return try ScreenshotFileActions.saveToDefaultLocation(from: url)
        } catch {
            print("Failed to auto save: \(error)")
            return nil
        }
    }

    private func copyVideoURLToClipboard(_ url: URL) -> Bool {
        do {
            try VideoFileActions.copyToClipboard(from: url)
            return true
        } catch {
            print("Failed to copy recording: \(error)")
            return false
        }
    }

    private func saveVideoToDefaultLocation(from url: URL) -> URL? {
        do {
            return try VideoFileActions.saveToDefaultLocation(from: url)
        } catch {
            print("Failed to auto save recording: \(error)")
            return nil
        }
    }
}
