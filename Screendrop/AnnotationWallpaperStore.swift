//
//  AnnotationWallpaperStore.swift
//  Screendrop
//

import Foundation
import Observation

struct AnnotationWallpaperPack: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let remoteURL: URL
    let authorName: String
    let authorURL: URL

    static let builtIn: [AnnotationWallpaperPack] = [
        AnnotationWallpaperPack(
            id: "uihssn",
            title: "UIHSSN",
            subtitle: "Wallpaper Pack",
            remoteURL: URL(string: "https://static.fayazahmed.com/uihssn-wallpaper-pack.zip")!,
            authorName: "Ahmed Hassan",
            authorURL: URL(string: "https://x.com/uihssn")!
        ),
        AnnotationWallpaperPack(
            id: "fayaz",
            title: "Fayazara",
            subtitle: "Author Picks",
            remoteURL: URL(string: "https://static.fayazahmed.com/fayaz-wallpaper-pack.zip")!,
            authorName: "Fayaz Ahmed",
            authorURL: URL(string: "https://x.com/fayazara")!
        )
    ]
}

@MainActor
@Observable
final class AnnotationWallpaperStore {
    static let shared = AnnotationWallpaperStore()

    static var wallpapersDirectory: URL {
        ScreenshotHistoryStore.applicationSupportDirectory.appendingPathComponent("Wallpapers", isDirectory: true)
    }

    nonisolated private static let recentWallpaperPathsKey = "annotationBackground.recentWallpaperPaths"
    nonisolated private static let maxRecentWallpaperCount = 24
    nonisolated private static let supportedImageExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]

    private(set) var recentWallpapers: [AnnotationCustomWallpaper] = []
    private(set) var installedWallpapersByPackID: [String: [AnnotationCustomWallpaper]] = [:]
    private(set) var installingPackIDs: Set<String> = []
    private(set) var packErrorsByID: [String: String] = [:]

    private init() {
        Task { await reload() }
    }

    /// Refreshes the recent + installed wallpaper lists. The filesystem
    /// enumeration runs off the main actor so large pack directories never
    /// stall the UI; only the resulting state assignment happens on-main.
    func reload() async {
        let wallpapersDirectory = Self.wallpapersDirectory
        let packDirectories = AnnotationWallpaperPack.builtIn.map { pack in
            (pack.id, wallpapersDirectory.appendingPathComponent(pack.id, isDirectory: true))
        }

        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.loadURLSnapshot(wallpapersDirectory: wallpapersDirectory, packDirectories: packDirectories)
        }.value

        recentWallpapers = snapshot.recent.map { AnnotationCustomWallpaper(url: $0) }
        installedWallpapersByPackID = snapshot.installed.mapValues { urls in
            urls.map { AnnotationCustomWallpaper(url: $0) }
        }
    }

    func wallpapers(for pack: AnnotationWallpaperPack) -> [AnnotationCustomWallpaper] {
        installedWallpapersByPackID[pack.id] ?? []
    }

    func isInstalling(_ pack: AnnotationWallpaperPack) -> Bool {
        installingPackIDs.contains(pack.id)
    }

    func errorMessage(for pack: AnnotationWallpaperPack) -> String? {
        packErrorsByID[pack.id]
    }

    func isAvailable(_ wallpaper: AnnotationCustomWallpaper) -> Bool {
        Self.isSupportedImageFile(wallpaper.url)
    }

    func addRecentWallpaper(_ url: URL) {
        let standardizedPath = url.standardizedFileURL.path
        let standardizedURL = URL(fileURLWithPath: standardizedPath)
        guard Self.isSupportedImageFile(standardizedURL) else { return }

        var paths = UserDefaults.standard.stringArray(forKey: Self.recentWallpaperPathsKey) ?? []
        paths.removeAll { $0 == standardizedPath }
        paths.insert(standardizedPath, at: 0)

        let filteredPaths = paths
            .filter { path in
                let url = URL(fileURLWithPath: path)
                return Self.isSupportedImageFile(url)
            }
            .prefix(Self.maxRecentWallpaperCount)
        let recentPaths = Array(filteredPaths)

        UserDefaults.standard.set(recentPaths, forKey: Self.recentWallpaperPathsKey)
        recentWallpapers = recentPaths.map { AnnotationCustomWallpaper(url: URL(fileURLWithPath: $0)) }
        Task { await reload() }
    }

    func installPack(_ pack: AnnotationWallpaperPack) async {
        guard !isInstalling(pack) else { return }

        installingPackIDs.insert(pack.id)
        packErrorsByID[pack.id] = nil

        let remoteURL = pack.remoteURL
        let wallpapersDirectory = Self.wallpapersDirectory
        let targetURL = wallpapersDirectory.appendingPathComponent(pack.id, isDirectory: true)

        do {
            try await Self.downloadAndInstall(
                remoteURL: remoteURL,
                wallpapersDirectory: wallpapersDirectory,
                targetURL: targetURL
            )
            await reload()
        } catch {
            packErrorsByID[pack.id] = error.localizedDescription
        }

        installingPackIDs.remove(pack.id)
    }

    // MARK: - Off-main filesystem work

    nonisolated private struct WallpaperURLSnapshot: Sendable {
        let recent: [URL]
        let installed: [String: [URL]]
    }

    nonisolated private static func loadURLSnapshot(
        wallpapersDirectory: URL,
        packDirectories: [(String, URL)]
    ) -> WallpaperURLSnapshot {
        let installed = Dictionary(uniqueKeysWithValues: packDirectories.map { id, directory in
            (id, wallpaperURLs(in: directory))
        })
        return WallpaperURLSnapshot(
            recent: loadRecentWallpaperURLs(),
            installed: installed
        )
    }

    nonisolated private static func loadRecentWallpaperURLs() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: recentWallpaperPathsKey) ?? []
        let availablePaths = paths.filter { path in
            let url = URL(fileURLWithPath: path)
            return isSupportedImageFile(url)
        }

        if availablePaths != paths {
            UserDefaults.standard.set(availablePaths, forKey: recentWallpaperPathsKey)
        }

        return availablePaths.map { URL(fileURLWithPath: $0) }
    }

    nonisolated private static func downloadAndInstall(
        remoteURL: URL,
        wallpapersDirectory: URL,
        targetURL: URL
    ) async throws {
        let (downloadedURL, response) = try await URLSession.shared.download(from: remoteURL)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw AnnotationWallpaperStoreError.downloadFailed(httpResponse.statusCode)
        }

        // This function is `nonisolated`, so the synchronous extraction and
        // large-file moves below run on the global executor rather than the
        // main actor — the UI never stalls while `ditto` unpacks the archive.
        try installDownloadedArchive(
            downloadedURL: downloadedURL,
            wallpapersDirectory: wallpapersDirectory,
            targetURL: targetURL
        )
    }

    nonisolated private static func installDownloadedArchive(
        downloadedURL: URL,
        wallpapersDirectory: URL,
        targetURL: URL
    ) throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("Screendrop-Wallpapers-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = tempRoot.appendingPathComponent("pack.zip")
        let extractedURL = tempRoot.appendingPathComponent("Extracted", isDirectory: true)

        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        try fileManager.moveItem(at: downloadedURL, to: archiveURL)
        try extractZip(at: archiveURL, to: extractedURL)

        guard !wallpaperURLs(in: extractedURL).isEmpty else {
            throw AnnotationWallpaperStoreError.emptyPack
        }

        try fileManager.createDirectory(at: wallpapersDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try fileManager.moveItem(at: extractedURL, to: targetURL)
    }

    nonisolated private static func extractZip(at archiveURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()

        // Drain the pipe before waiting so a chatty `ditto` cannot fill the
        // fixed-size pipe buffer and deadlock against `waitUntilExit()`.
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AnnotationWallpaperStoreError.extractionFailed(output)
        }
    }

    nonisolated private static func wallpaperURLs(in directoryURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter(isSupportedImageFile)
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }

    nonisolated private static func isSupportedImageFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard !url.lastPathComponent.hasPrefix("._") else { return false }
        guard !url.pathComponents.contains("__MACOSX") else { return false }
        return supportedImageExtensions.contains(url.pathExtension.lowercased())
    }

}

nonisolated private enum AnnotationWallpaperStoreError: LocalizedError {
    case downloadFailed(Int)
    case emptyPack
    case extractionFailed(String?)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let statusCode):
            "Download failed with HTTP \(statusCode)."
        case .emptyPack:
            "No supported images were found in this pack."
        case .extractionFailed(let output):
            if let output, !output.isEmpty {
                "Could not unpack the wallpaper pack. \(output)"
            } else {
                "Could not unpack the wallpaper pack."
            }
        }
    }
}
