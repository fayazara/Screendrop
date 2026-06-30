//
//  HistoryThumbnailStore.swift
//  Screendrop
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated enum HistoryThumbnailStore {
    private static let maxPixelSize: CGFloat = 160
    private static let compressionQuality: CGFloat = 0.82

    static var thumbnailsDirectory: URL {
        ScreendropApplicationPaths.historyThumbnailsDirectory
    }

    static func thumbnailURL(for item: ScreenshotHistoryItem) -> URL {
        thumbnailURL(for: item.id, updatedAt: item.updatedAt)
    }

    static func thumbnail(for item: ScreenshotHistoryItem) async -> NSImage? {
        let id = item.id
        let updatedAt = item.updatedAt
        let sourceURL = item.url
        let isVideo = item.isVideo

        let task = Task.detached(priority: .utility) {
            await thumbnail(id: id, updatedAt: updatedAt, sourceURL: sourceURL, isVideo: isVideo)
        }

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func generateThumbnail(for item: ScreenshotHistoryItem) {
        let id = item.id
        let updatedAt = item.updatedAt
        let sourceURL = item.url
        let isVideo = item.isVideo

        Task.detached(priority: .utility) {
            _ = await thumbnail(id: id, updatedAt: updatedAt, sourceURL: sourceURL, isVideo: isVideo)
        }
    }

    static func regenerateThumbnail(for item: ScreenshotHistoryItem) {
        let id = item.id
        let updatedAt = item.updatedAt
        let sourceURL = item.url
        let isVideo = item.isVideo

        Task.detached(priority: .utility) {
            let thumbnailURL = thumbnailURL(for: id, updatedAt: updatedAt)
            _ = await makeThumbnail(sourceURL: sourceURL, isVideo: isVideo, destinationURL: thumbnailURL)
            deleteThumbnails(for: id, preserving: thumbnailURL)
        }
    }

    static func deleteThumbnail(for item: ScreenshotHistoryItem) {
        let id = item.id

        Task.detached(priority: .utility) {
            deleteThumbnails(for: id)
        }
    }

    private static func thumbnail(id: UUID, updatedAt: Date, sourceURL: URL, isVideo: Bool) async -> NSImage? {
        guard !Task.isCancelled else { return nil }

        let thumbnailURL = thumbnailURL(for: id, updatedAt: updatedAt)
        if let existing = loadThumbnail(at: thumbnailURL) {
            deleteThumbnails(for: id, preserving: thumbnailURL)
            return existing
        }

        let image = await makeThumbnail(sourceURL: sourceURL, isVideo: isVideo, destinationURL: thumbnailURL)
        deleteThumbnails(for: id, preserving: thumbnailURL)
        return image
    }

    private static func makeThumbnail(sourceURL: URL, isVideo: Bool, destinationURL: URL) async -> NSImage? {
        guard !Task.isCancelled else { return nil }

        let image: NSImage?
        if isVideo {
            image = await VideoPreviewImageLoader.thumbnail(at: sourceURL, maxPixelSize: maxPixelSize)
        } else {
            image = ScreenshotImageLoader.downsampledImage(at: sourceURL, maxPixelSize: maxPixelSize)
        }

        guard let image, !Task.isCancelled else { return nil }

        do {
            try writeThumbnail(image, to: destinationURL)
        } catch {
            print("Failed to write history thumbnail: \(error)")
        }

        return image
    }

    private static func loadThumbnail(at url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: maxPixelSize)
    }

    private static func thumbnailURL(for id: UUID, updatedAt: Date) -> URL {
        let version = Int64((updatedAt.timeIntervalSince1970 * 1_000_000).rounded())
        return thumbnailsDirectory
            .appendingPathComponent("\(id.uuidString)-\(version)")
            .appendingPathExtension("jpg")
    }

    private static func deleteThumbnails(for id: UUID, preserving preservedURL: URL? = nil) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: thumbnailsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let prefix = id.uuidString
        for url in urls where url.lastPathComponent.hasPrefix(prefix) && url != preservedURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func writeThumbnail(_ image: NSImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        let temporaryURL = url
            .deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
              let destination = CGImageDestinationCreateWithURL(
                temporaryURL as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let options = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ] as CFDictionary

        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }
}
