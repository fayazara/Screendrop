//
//  CaptureAutoNamer.swift
//  Screendrop
//  Contributed by Rochak Agrawal (Screenshot X).
//
//  Gives a finished screenshot a descriptive file name. The text is read with
//  Vision and the title is written by Apple's on-device language model, so
//  nothing leaves the Mac. It reuses the Library's analysis pipeline instead of
//  prompting the model a second time.
//

import CoreGraphics
import Foundation

nonisolated enum CaptureAutoNamer {
    /// Longest file name the model's title may produce, before the date.
    private static let maximumTitleLength = 60

    /// A short, file-system-safe name for a capture, or nil when the image has
    /// no readable text and the model has nothing to say about it.
    static func fileName(for url: URL) async -> String? {
        let size = ScreenshotImageLoader.imageSize(at: url) ?? .zero
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let item = CaptureLibraryItem(
            id: url.path,
            historyIDs: [],
            name: url.lastPathComponent,
            fileURL: url,
            session: nil,
            createdAt: modified,
            modifiedAt: modified,
            pixelWidth: Int(size.width),
            pixelHeight: Int(size.height),
            duration: nil,
            isVideo: false,
            hasEdits: false,
            hasDraft: false,
            cloudURL: nil,
            source: nil,
            thumbnailKey: "\(url.path)-\(modified.timeIntervalSince1970)"
        )

        guard let read = await CaptureLibraryAnalyzer.read(item, previous: nil) else { return nil }
        guard !Task.isCancelled else { return nil }

        // The model writes the best title; the first readable line is a good
        // fallback when Apple Intelligence is unavailable for this language.
        let sorted = await CaptureLibraryAnalyzer.sort(read.analysis, item: item)
        let candidate = sorted.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? read.analysis.lines.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title = candidate, !title.isEmpty else { return nil }

        return sanitised(title)
    }

    /// Keeps letters, digits, spaces, hyphens and underscores; drops the rest
    /// so the name is valid on every file system and safe in a URL.
    static func sanitised(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_"))
        var cleaned = String(
            title.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        )
        cleaned = cleaned
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > maximumTitleLength {
            cleaned = String(cleaned.prefix(maximumTitleLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A name of only separators would be rejected by the file system.
        let meaningful = cleaned.contains { $0.isLetter || $0.isNumber }
        return meaningful ? cleaned : ""
    }
}
