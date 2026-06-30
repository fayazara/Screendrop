//
//  ScreenshotHistoryStore.swift
//  Screendrop
//
//  Created by Codex on 01/05/26.
//

import AppKit
import AVFoundation
@preconcurrency import CoreMedia
import Observation

struct ScreenshotHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var fileName: String
    var pixelWidth: Int
    var pixelHeight: Int
    var kind: PreviewMediaKind
    var duration: Double?
    var cloudURL: String?
    /// Whether this screenshot has an editable annotation sidecar document.
    var hasEdits: Bool

    var url: URL {
        ScreenshotHistoryStore.historyDirectory.appendingPathComponent(fileName)
    }

    var isVideo: Bool { kind == .video }

    // Backward-compatible decoding: existing history.json entries have no
    // `kind` or `duration` fields, so they default to .image / nil.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        fileName = try container.decode(String.self, forKey: .fileName)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        kind = try container.decodeIfPresent(PreviewMediaKind.self, forKey: .kind) ?? .image
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        cloudURL = try container.decodeIfPresent(String.self, forKey: .cloudURL)
        hasEdits = try container.decodeIfPresent(Bool.self, forKey: .hasEdits) ?? false
    }

    init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        fileName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        kind: PreviewMediaKind = .image,
        duration: Double? = nil,
        cloudURL: String? = nil,
        hasEdits: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.kind = kind
        self.duration = duration
        self.cloudURL = cloudURL
        self.hasEdits = hasEdits
    }
}

@MainActor
@Observable
final class ScreenshotHistoryStore {
    static let shared = ScreenshotHistoryStore()

    static var applicationSupportDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL.appendingPathComponent("Screendrop", isDirectory: true)
    }

    static var historyDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("History", isDirectory: true)
    }

    private static var metadataURL: URL {
        applicationSupportDirectory.appendingPathComponent("history.json")
    }

    /// Location of the editable annotation sidecar document for a display image,
    /// e.g. `Screendrop_2026.png` -> `Screendrop_2026.png.screendrop`.
    static func editDocumentURL(for displayURL: URL) -> URL {
        displayURL.appendingPathExtension("screendrop")
    }

    /// Location of the untouched base image for a display image,
    /// e.g. `Screendrop_2026.png` -> `Screendrop_2026.base.png`.
    static func baseImageURL(for displayURL: URL) -> URL {
        let ext = displayURL.pathExtension
        let stem = displayURL.deletingPathExtension().lastPathComponent
        let directory = displayURL.deletingLastPathComponent()
        let fileName = ext.isEmpty ? "\(stem).base" : "\(stem).base.\(ext)"
        return directory.appendingPathComponent(fileName)
    }

    /// Loads the editable annotation document for a screenshot, if one exists.
    func loadEditDocument(for displayURL: URL) -> AnnotationDocument? {
        let documentURL = Self.editDocumentURL(for: displayURL)
        guard let data = try? Data(contentsOf: documentURL),
              let document = try? JSONDecoder().decode(AnnotationDocument.self, from: data) else {
            return nil
        }
        return document
    }

    func hasEditDocument(for displayURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: Self.editDocumentURL(for: displayURL).path)
    }

    private(set) var items: [ScreenshotHistoryItem] = []

    var recentItems: [ScreenshotHistoryItem] {
        Array(items.prefix(5))
    }

    private init() {
        load()
    }

    @discardableResult
    func importScreenshot(from sourceURL: URL) -> URL {
        do {
            try FileManager.default.createDirectory(at: Self.historyDirectory, withIntermediateDirectories: true)
            let destinationURL = uniqueHistoryURL(for: sourceURL)

            if sourceURL != destinationURL {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }

            let imageSize = ScreenshotImageLoader.imageSize(at: destinationURL) ?? .zero
            let item = ScreenshotHistoryItem(
                id: UUID(),
                createdAt: Date(),
                updatedAt: Date(),
                fileName: destinationURL.lastPathComponent,
                pixelWidth: Int(imageSize.width),
                pixelHeight: Int(imageSize.height)
            )
            items.insert(item, at: 0)
            saveMetadata()
            return destinationURL
        } catch {
            print("Failed to import screenshot into history: \(error)")
            return sourceURL
        }
    }

    @discardableResult
    func importVideo(from sourceURL: URL) async -> URL {
        do {
            try FileManager.default.createDirectory(at: Self.historyDirectory, withIntermediateDirectories: true)
            let destinationURL = uniqueHistoryURL(for: sourceURL)

            if sourceURL != destinationURL {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }

            // Extract video metadata via AVFoundation
            let asset = AVURLAsset(url: destinationURL)
            var width = 0
            var height = 0
            var dur: Double?

            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                let size = try? await track.load(.naturalSize)
                let transform = try? await track.load(.preferredTransform)
                if let size, let transform {
                    let transformed = size.applying(transform)
                    width = Int(abs(transformed.width))
                    height = Int(abs(transformed.height))
                } else if let size {
                    width = Int(size.width)
                    height = Int(size.height)
                }
            }

            if let loadedDuration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(loadedDuration)
                if seconds.isFinite, seconds > 0 {
                    dur = seconds
                }
            }

            let item = ScreenshotHistoryItem(
                id: UUID(),
                createdAt: Date(),
                updatedAt: Date(),
                fileName: destinationURL.lastPathComponent,
                pixelWidth: width,
                pixelHeight: height,
                kind: .video,
                duration: dur
            )
            items.insert(item, at: 0)
            saveMetadata()
            return destinationURL
        } catch {
            print("Failed to import video into history: \(error)")
            return sourceURL
        }
    }

    /// Non-destructive annotation commit.
    ///
    /// - Preserves the untouched base image (lazily, on first edit) so future
    ///   edits always re-render from the original pixels.
    /// - Overwrites the display image with the freshly rendered composite.
    /// - Writes the editable `.screendrop` sidecar document so the annotations
    ///   can be re-opened and edited later.
    @discardableResult
    func commitAnnotations(
        displayURL: URL,
        baseURL: URL,
        renderedURL: URL,
        document: AnnotationDocument
    ) -> URL {
        guard isHistoryURL(displayURL) else {
            return importScreenshot(from: renderedURL)
        }

        do {
            let baseDestination = Self.baseImageURL(for: displayURL)

            // Keep the canonical base image (`<stem>.base.<ext>`) in sync with
            // the image the annotations actually render on top of.
            if baseURL.standardizedFileURL != baseDestination.standardizedFileURL {
                if baseURL.standardizedFileURL == displayURL.standardizedFileURL {
                    // First edit: snapshot the current (untouched) display image
                    // as the base, lazily.
                    if !FileManager.default.fileExists(atPath: baseDestination.path),
                       FileManager.default.fileExists(atPath: displayURL.path) {
                        try FileManager.default.copyItem(at: displayURL, to: baseDestination)
                    }
                } else {
                    // The base was replaced this session (e.g. by a crop). Persist
                    // the new base so re-opened edits render from the cropped pixels.
                    if FileManager.default.fileExists(atPath: baseDestination.path) {
                        try FileManager.default.removeItem(at: baseDestination)
                    }
                    try FileManager.default.copyItem(at: baseURL, to: baseDestination)
                }
            }

            // Overwrite the display image with the rendered composite.
            if FileManager.default.fileExists(atPath: displayURL.path) {
                try FileManager.default.removeItem(at: displayURL)
            }
            try FileManager.default.copyItem(at: renderedURL, to: displayURL)

            // Persist the editable sidecar document.
            var document = document
            document.baseImageFileName = baseDestination.lastPathComponent
            let data = try JSONEncoder().encode(document)
            try data.write(to: Self.editDocumentURL(for: displayURL), options: .atomic)

            if let index = items.firstIndex(where: { $0.fileName == displayURL.lastPathComponent }) {
                let imageSize = ScreenshotImageLoader.imageSize(at: displayURL) ?? .zero
                items[index].updatedAt = Date()
                items[index].pixelWidth = Int(imageSize.width)
                items[index].pixelHeight = Int(imageSize.height)
                items[index].hasEdits = true
                saveMetadata()
            }

            return displayURL
        } catch {
            print("Failed to commit annotations: \(error)")
            return renderedURL
        }
    }

    /// Restores the untouched base image into the display slot and removes the
    /// editable sidecar. Used when every annotation has been cleared.
    @discardableResult
    func removeAnnotations(displayURL: URL) -> URL {
        guard isHistoryURL(displayURL) else { return displayURL }

        let baseDestination = Self.baseImageURL(for: displayURL)
        let documentURL = Self.editDocumentURL(for: displayURL)

        do {
            if FileManager.default.fileExists(atPath: baseDestination.path) {
                if FileManager.default.fileExists(atPath: displayURL.path) {
                    try FileManager.default.removeItem(at: displayURL)
                }
                try FileManager.default.copyItem(at: baseDestination, to: displayURL)
                try FileManager.default.removeItem(at: baseDestination)
            }

            if FileManager.default.fileExists(atPath: documentURL.path) {
                try FileManager.default.removeItem(at: documentURL)
            }

            if let index = items.firstIndex(where: { $0.fileName == displayURL.lastPathComponent }) {
                let imageSize = ScreenshotImageLoader.imageSize(at: displayURL) ?? .zero
                items[index].updatedAt = Date()
                items[index].pixelWidth = Int(imageSize.width)
                items[index].pixelHeight = Int(imageSize.height)
                items[index].hasEdits = false
                saveMetadata()
            }
        } catch {
            print("Failed to remove annotations: \(error)")
        }

        return displayURL
    }

    func delete(_ item: ScreenshotHistoryItem) {
        let auxiliaryURLs = [
            item.url,
            Self.baseImageURL(for: item.url),
            Self.editDocumentURL(for: item.url)
        ]

        for url in auxiliaryURLs where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("Failed to delete history file: \(error)")
            }
        }

        items.removeAll { $0.id == item.id }
        saveMetadata()
    }

    @discardableResult
    func delete(url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        guard let item = items.first(where: { $0.url.standardizedFileURL == standardizedURL }) else {
            return false
        }

        delete(item)
        return true
    }

    func setCloudURL(for fileURL: URL, cloudURL: String) {
        let standardized = fileURL.standardizedFileURL
        guard let index = items.firstIndex(where: { $0.url.standardizedFileURL == standardized }) else {
            return
        }
        items[index].cloudURL = cloudURL
        items[index].updatedAt = Date()
        saveMetadata()
    }

    func reveal(_ item: ScreenshotHistoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func reload() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.metadataURL),
              let decoded = try? JSONDecoder().decode([ScreenshotHistoryItem].self, from: data) else {
            items = []
            return
        }

        items = decoded
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func saveMetadata() {
        do {
            try FileManager.default.createDirectory(at: Self.applicationSupportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            try data.write(to: Self.metadataURL, options: .atomic)
        } catch {
            print("Failed to save screenshot history: \(error)")
        }
    }

    private func uniqueHistoryURL(for sourceURL: URL) -> URL {
        let pathExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let fileName = ScreenshotFileNaming.fileName(extension: pathExtension)
        let initialURL = Self.historyDirectory.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: initialURL.path) else {
            return initialURL
        }

        let baseName = initialURL.deletingPathExtension().lastPathComponent
        for index in 1...10_000 {
            let candidateURL = Self.historyDirectory
                .appendingPathComponent("\(baseName)-\(index)")
                .appendingPathExtension(pathExtension)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return Self.historyDirectory
            .appendingPathComponent("Screendrop_\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    private func isHistoryURL(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(Self.historyDirectory.standardizedFileURL.path)
    }

}
