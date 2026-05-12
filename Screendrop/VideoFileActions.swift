//
//  VideoFileActions.swift
//  Screendrop
//
//  Created by Codex on 01/05/26.
//

import AppKit
import AVFoundation
import UniformTypeIdentifiers

enum VideoPreviewImageLoader {
    static func thumbnail(at url: URL, maxPixelSize: CGFloat) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)

        let cgImage = await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
                continuation.resume(returning: image)
            }
        }

        guard let cgImage else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    static func placeholderImage() -> NSImage {
        let size = CGSize(width: 520, height: 390)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

        if let symbol = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil) {
            symbol.size = CGSize(width: 96, height: 96)
            symbol.draw(
                in: CGRect(
                    x: (size.width - 96) / 2,
                    y: (size.height - 96) / 2,
                    width: 96,
                    height: 96
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 0.85
            )
        }

        image.unlockFocus()
        return image
    }
}

enum VideoFileActions {
    static let exportContentType: UTType = .quickTimeMovie

    static func copyToClipboard(from url: URL) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    @discardableResult
    static func saveToDefaultLocation(from url: URL) throws -> URL {
        let destinationDirectory = ScreendropPreferences.exportDirectory
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = uniqueDestinationURL(
            for: exportFileName(for: url),
            in: destinationDirectory
        )
        try save(from: url, to: destinationURL)
        return destinationURL
    }

    static func save(from sourceURL: URL, to destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    static func exportFileName(for sourceURL: URL) -> String {
        sourceURL
            .deletingPathExtension()
            .appendingPathExtension("mov")
            .lastPathComponent
    }

    private static func uniqueDestinationURL(for fileName: String, in directory: URL) -> URL {
        let originalURL = directory.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            return originalURL
        }

        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let pathExtension = originalURL.pathExtension

        for index in 1...10_000 {
            let numberedName = "\(baseName) \(index)"
            let candidateURL = directory
                .appendingPathComponent(numberedName)
                .appendingPathExtension(pathExtension)

            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return directory
            .appendingPathComponent("\(baseName) \(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }
}
