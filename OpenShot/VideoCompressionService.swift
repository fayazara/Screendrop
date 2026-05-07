//
//  VideoCompressionService.swift
//  OpenShot
//

import Foundation

enum VideoCompressionError: LocalizedError {
    case ffmpegNotFound
    case invalidRange
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            "FFmpeg is not installed."
        case .invalidRange:
            "Choose a longer range to compress."
        case .processFailed(let message):
            message.isEmpty ? "Compression failed." : message
        }
    }
}

enum VideoCompressionService {
    static func compress(
        sourceURL: URL,
        duration: Double,
        selection: VideoTrimSelection,
        settings: VideoCompressionSettings,
        outputURL: URL,
        ffmpegPath: String,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> VideoCompressionResult {
        let boundedSelection = selection.clamped(to: duration)
        guard boundedSelection.duration >= VideoTrimSelection.minimumDuration else {
            throw VideoCompressionError.invalidRange
        }

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let inputSize = fileSize(at: sourceURL)
        let arguments = compressionArguments(
            sourceURL: sourceURL,
            selection: boundedSelection,
            settings: settings,
            outputURL: outputURL
        )

        try await runFFmpeg(
            path: ffmpegPath,
            arguments: arguments,
            selectedDuration: boundedSelection.duration,
            progress: progress
        )

        return VideoCompressionResult(
            outputURL: outputURL,
            inputSize: inputSize,
            outputSize: fileSize(at: outputURL)
        )
    }

    static func temporaryURL(for sourceURL: URL, settings: VideoCompressionSettings) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenShot/CompressedRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return directory
            .appendingPathComponent(compressedBaseName(for: sourceURL, settings: settings) + "-\(UUID().uuidString.prefix(6))")
            .appendingPathExtension("mov")
    }

    static func suggestedFileName(
        for sourceURL: URL,
        selection: VideoTrimSelection,
        duration: Double,
        settings: VideoCompressionSettings
    ) -> String {
        let rangeSuffix = selectionRangeSuffix(selection: selection.clamped(to: duration), duration: duration)
        return "\(compressedBaseName(for: sourceURL, settings: settings))\(rangeSuffix).mov"
    }

    private static func compressedBaseName(for sourceURL: URL, settings: VideoCompressionSettings) -> String {
        let codec = settings.codec == .hevc ? "hevc" : "h264"
        return "\(sourceURL.deletingPathExtension().lastPathComponent)-compressed-\(codec)-\(settings.quality.rawValue.lowercased())"
    }

    private static func selectionRangeSuffix(selection: VideoTrimSelection, duration: Double) -> String {
        guard duration > 0,
              selection.start > 0.001 || abs(selection.end - duration) > 0.001 else {
            return ""
        }

        let start = Int(selection.start.rounded(.down))
        let end = Int(selection.end.rounded(.up))
        return "-\(start)-\(end)s"
    }

    private static func compressionArguments(
        sourceURL: URL,
        selection: VideoTrimSelection,
        settings: VideoCompressionSettings,
        outputURL: URL
    ) -> [String] {
        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", sourceURL.path,
            "-ss", String(format: "%.3f", selection.start),
            "-t", String(format: "%.3f", selection.duration),
            "-map", "0:v:0",
            "-map", "0:a?",
            "-c:v", settings.codec.encoder,
            "-preset", settings.speed.ffmpegPreset,
            "-crf", String(settings.quality.crf),
            "-pix_fmt", "yuv420p"
        ]

        if let scale = settings.resolution.scaleFilter {
            arguments += ["-vf", "scale=\(scale)"]
        }

        if settings.codec == .hevc {
            arguments += ["-tag:v", "hvc1"]
        }

        if settings.removeAudio {
            arguments += ["-an"]
        } else {
            arguments += ["-c:a", "aac", "-b:a", settings.quality.audioBitrate]
        }

        arguments += [
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            outputURL.path
        ]

        return arguments
    }

    private static func runFFmpeg(
        path: String,
        arguments: [String],
        selectedDuration: Double,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw VideoCompressionError.ffmpegNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let output = String(data: data, encoding: .utf8) else {
                return
            }

            for line in output.components(separatedBy: .newlines) {
                guard line.hasPrefix("out_time_us=") else { continue }
                let rawValue = line.replacingOccurrences(of: "out_time_us=", with: "")
                guard let microseconds = Double(rawValue), selectedDuration > 0 else { continue }
                let value = min(max((microseconds / 1_000_000) / selectedDuration, 0), 1)
                Task { @MainActor in
                    progress(value)
                }
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            let lastLine = errorOutput
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .last ?? "FFmpeg exited with code \(process.terminationStatus)."
            throw VideoCompressionError.processFailed(lastLine)
        }

        await MainActor.run {
            progress(1)
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
    }
}
