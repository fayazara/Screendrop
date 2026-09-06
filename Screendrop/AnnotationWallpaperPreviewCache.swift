//
//  AnnotationWallpaperPreviewCache.swift
//  Screendrop
//

import CoreGraphics
import Foundation
import ImageIO

actor AnnotationWallpaperPreviewCache {
    static let shared = AnnotationWallpaperPreviewCache()

    nonisolated private static let imageCache = BoundedCGImageCache(byteLimit: 32 * 1024 * 1024, countLimit: 48)
    private struct PendingImage {
        let id = UUID()
        let task: Task<CGImage?, Never>
    }
    private let decoder = WallpaperDecoder()
    private var inFlightImages: [String: PendingImage] = [:]

    nonisolated static func beginUse() -> BoundedCGImageCache.Lease { imageCache.beginUse() }

    func image(for url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let generation = Self.imageCache.generation
        let key = Self.cacheID(for: url, maxPixelSize: maxPixelSize)
        if let cachedImage = Self.imageCache.image(for: key) {
            return cachedImage
        }

        // Old completions must not remove a newer generation's work.
        let workKey = "\(generation):\(key)"
        let pending: PendingImage
        if let existing = inFlightImages[workKey] {
            pending = existing
        } else {
            let decoder = decoder
            pending = PendingImage(task: Task.detached(priority: .userInitiated) {
                await decoder.image(at: url, maxPixelSize: maxPixelSize, generation: generation)
            })
            inFlightImages[workKey] = pending
        }

        let image = await pending.task.value
        if inFlightImages[workKey]?.id == pending.id { inFlightImages[workKey] = nil }
        guard !Task.isCancelled else { return nil }

        if let image {
            Self.imageCache.insert(image, for: key, generation: generation)
        }

        return image
    }

    /// Stable identity for a downsampled image. Includes the file signature so
    /// a file replaced in place (same path) is treated as a distinct entry.
    /// Used both as the cache key and as the SwiftUI `.task(id:)` value so the
    /// preview reloads exactly when the cache would produce a different image.
    nonisolated static func cacheID(for url: URL, maxPixelSize: CGFloat) -> String {
        "\(url.standardizedFileURL.path)#\(Int(maxPixelSize.rounded(.up)))#\(fileSignature(for: url))"
    }

    private static func fileSignature(for url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return "unknown"
        }

        let fileSize = values.fileSize ?? 0
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(fileSize)-\(modified)"
    }

    /// A separate actor bounds thumbnail decoding to one image at a time.
    /// Jobs whose last consumer closed are skipped before allocating pixels.
    private actor WallpaperDecoder {
        func image(at url: URL, maxPixelSize: CGFloat, generation: UInt64) -> CGImage? {
            guard !Task.isCancelled, generation == AnnotationWallpaperPreviewCache.imageCache.generation else { return nil }
            return autoreleasepool {
                AnnotationWallpaperPreviewCache.downsampledCGImage(at: url, maxPixelSize: maxPixelSize)
            }
        }
    }

    nonisolated private static func downsampledCGImage(at url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up)))
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
