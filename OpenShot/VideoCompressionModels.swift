//
//  VideoCompressionModels.swift
//  OpenShot
//

import Foundation

enum VideoCompressionQuality: String, CaseIterable, Identifiable, Sendable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    var id: String { rawValue }

    var crf: Int {
        switch self {
        case .high:
            20
        case .medium:
            26
        case .low:
            32
        }
    }

    var audioBitrate: String {
        switch self {
        case .high:
            "192k"
        case .medium:
            "128k"
        case .low:
            "96k"
        }
    }
}

enum VideoCompressionSpeed: String, CaseIterable, Identifiable, Sendable {
    case ultrafast = "Ultrafast"
    case fast = "Fast"
    case medium = "Medium"
    case slow = "Slow"

    var id: String { rawValue }

    var ffmpegPreset: String {
        rawValue.lowercased()
    }
}

enum VideoCompressionCodec: String, CaseIterable, Identifiable, Sendable {
    case h264 = "H.264"
    case hevc = "HEVC"

    var id: String { rawValue }

    var encoder: String {
        switch self {
        case .h264:
            "libx264"
        case .hevc:
            "libx265"
        }
    }
}

enum VideoCompressionResolution: String, CaseIterable, Identifiable, Sendable {
    case original = "Original"
    case p1080 = "1080p"
    case p720 = "720p"
    case p480 = "480p"

    var id: String { rawValue }

    var scaleFilter: String? {
        switch self {
        case .original:
            nil
        case .p1080:
            "-2:1080"
        case .p720:
            "-2:720"
        case .p480:
            "-2:480"
        }
    }
}

struct VideoCompressionSettings: Equatable, Sendable {
    var quality: VideoCompressionQuality = .medium
    var speed: VideoCompressionSpeed = .fast
    var codec: VideoCompressionCodec = .h264
    var resolution: VideoCompressionResolution = .original
    var removeAudio = false
}

struct VideoCompressionResult: Sendable {
    let outputURL: URL
    let inputSize: Int64
    let outputSize: Int64

    var reduction: Double? {
        guard inputSize > 0 else { return nil }
        return 1 - Double(outputSize) / Double(inputSize)
    }
}
