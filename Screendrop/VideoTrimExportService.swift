//
//  VideoTrimExportService.swift
//  Screendrop
//

import AVFoundation
@preconcurrency import CoreMedia
import Foundation

enum VideoTrimExportError: LocalizedError {
    case invalidRange
    case exportUnavailable
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            "Choose a longer trim range."
        case .exportUnavailable:
            "This recording cannot be exported."
        case .invalidDuration:
            "Unable to read the recording duration."
        }
    }
}

enum VideoTrimExportService {
    static func exportTrim(sourceURL: URL, selection: VideoTrimSelection, to outputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw VideoTrimExportError.invalidDuration
        }

        let boundedSelection = selection.clamped(to: durationSeconds)
        guard boundedSelection.duration >= VideoTrimSelection.minimumDuration else {
            throw VideoTrimExportError.invalidRange
        }

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let exportSession = try makeExportSession(asset: asset)
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: boundedSelection.start, preferredTimescale: 600),
            duration: CMTime(seconds: boundedSelection.duration, preferredTimescale: 600)
        )
        exportSession.shouldOptimizeForNetworkUse = true

        try await exportSession.export(to: outputURL, as: .mov)
        return outputURL
    }

    static func temporaryURL(for sourceURL: URL) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Screendrop/TrimmedRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return directory
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + "-trim-\(UUID().uuidString.prefix(6))")
            .appendingPathExtension("mov")
    }

    static func suggestedFileName(for sourceURL: URL, selection: VideoTrimSelection) -> String {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let start = Int(selection.start.rounded(.down))
        let end = Int(selection.end.rounded(.up))
        return "\(baseName)-trim-\(start)-\(end)s.mov"
    }

    private static func makeExportSession(asset: AVAsset) throws -> AVAssetExportSession {
        let presets = [
            AVAssetExportPresetPassthrough,
            AVAssetExportPresetHEVCHighestQuality,
            AVAssetExportPresetHighestQuality
        ]

        for preset in presets {
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset),
                  exportSession.supportedFileTypes.contains(.mov) else {
                continue
            }

            return exportSession
        }

        throw VideoTrimExportError.exportUnavailable
    }
}
