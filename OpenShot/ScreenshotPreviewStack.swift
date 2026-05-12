//
//  ScreenshotPreviewStack.swift
//  OpenShot
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

    var itemIDs: [ScreenshotPreviewItem.ID] {
        items.map(\.id)
    }

    var hoveredItem: ScreenshotPreviewItem? {
        guard let hoveredItemID else { return nil }
        return items.first { $0.id == hoveredItemID }
    }

    private init() {}

    func add(url: URL) {
        guard let image = ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: 520) else {
            return
        }

        QuickLookPreviewPresenter.dismiss()

        var item = ScreenshotPreviewItem(url: url, previewImage: image)

        if OpenShotPreferences.autoSave {
            item.autoSavedURL = saveToDefaultLocation(from: url)
        }

        if OpenShotPreferences.autoCopy {
            _ = copyURLToClipboard(url)
        }

        items.insert(item, at: 0)
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

        var item = ScreenshotPreviewItem(
            url: url,
            previewImage: VideoPreviewImageLoader.placeholderImage(),
            kind: .video
        )
        let itemID = item.id

        if OpenShotPreferences.autoSave {
            item.autoSavedURL = saveVideoToDefaultLocation(from: url)
        }

        if OpenShotPreferences.autoCopy {
            _ = copyVideoURLToClipboard(url)
        }

        items.insert(item, at: 0)

        Task {
            guard let thumbnail = await VideoPreviewImageLoader.thumbnail(at: url, maxPixelSize: 520),
                  let index = items.firstIndex(where: { $0.id == itemID }) else {
                return
            }

            items[index].previewImage = thumbnail
        }
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
        removeImmediately(id: id)
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

        if OpenShotPreferences.autoSave {
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

    @discardableResult
    func replace(originalURL: URL, with annotatedURL: URL) -> Bool {
        let historyURL = ScreenshotHistoryStore.shared.replace(originalURL: originalURL, with: annotatedURL)

        guard let image = ScreenshotImageLoader.downsampledImage(at: historyURL, maxPixelSize: 520) else {
            return false
        }

        QuickLookPreviewPresenter.dismiss()

        if let index = items.firstIndex(where: { $0.url == originalURL }) {
            CloudUploader.shared.clearUploadState(for: items[index].id)
            items[index].url = historyURL
            items[index].previewImage = image
            items[index].autoSavedURL = nil
            return true
        } else {
            items.insert(ScreenshotPreviewItem(url: historyURL, previewImage: image), at: 0)
            return false
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
