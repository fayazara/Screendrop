//
//  ScreenshotHistoryStore.swift
//  OpenShot
//
//  Created by Codex on 01/05/26.
//

import AppKit
import Observation

struct ScreenshotHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var fileName: String
    var pixelWidth: Int
    var pixelHeight: Int

    var url: URL {
        ScreenshotHistoryStore.historyDirectory.appendingPathComponent(fileName)
    }
}

@MainActor
@Observable
final class ScreenshotHistoryStore {
    static let shared = ScreenshotHistoryStore()

    static var applicationSupportDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL.appendingPathComponent("OpenShot", isDirectory: true)
    }

    static var historyDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("History", isDirectory: true)
    }

    private static var metadataURL: URL {
        applicationSupportDirectory.appendingPathComponent("history.json")
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
    func replace(originalURL: URL, with sourceURL: URL) -> URL {
        guard isHistoryURL(originalURL) else {
            return importScreenshot(from: sourceURL)
        }

        do {
            if FileManager.default.fileExists(atPath: originalURL.path) {
                try FileManager.default.removeItem(at: originalURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: originalURL)

            if let index = items.firstIndex(where: { $0.fileName == originalURL.lastPathComponent }) {
                let imageSize = ScreenshotImageLoader.imageSize(at: originalURL) ?? .zero
                items[index].updatedAt = Date()
                items[index].pixelWidth = Int(imageSize.width)
                items[index].pixelHeight = Int(imageSize.height)
                saveMetadata()
            }

            return originalURL
        } catch {
            print("Failed to update screenshot history item: \(error)")
            return sourceURL
        }
    }

    func delete(_ item: ScreenshotHistoryItem) {
        do {
            if FileManager.default.fileExists(atPath: item.url.path) {
                try FileManager.default.removeItem(at: item.url)
            }
        } catch {
            print("Failed to delete history file: \(error)")
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
            .appendingPathComponent("OpenShot_\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    private func isHistoryURL(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(Self.historyDirectory.standardizedFileURL.path)
    }

}
