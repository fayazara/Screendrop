//
//  AnnotationBackgroundPresetTransfer.swift
//  Screendrop
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let screendropPreset = UTType(
        exportedAs: "com.fayazahmed.screendrop.preset",
        conformingTo: .json
    )
}

/// A portable, versioned preset document. This deliberately does not reuse
/// `StoredBackground`: that persistence model contains local wallpaper paths,
/// while a shared preset must not be able to represent a path or image asset.
struct AnnotationBackgroundPresetTransferFile: Codable {
    static let currentVersion = 1
    static let formatIdentifier = "screendrop-screenshot-presets"
    static let filenameExtension = "screendroppreset"
    static let maximumFileSize = 1_000_000
    static let maximumPresetCount = 100

    var format: String
    var version: Int
    var presets: [Preset]

    init(preset: AnnotationBackgroundPreset) {
        let portableSettings = PortableBackgroundSettings(preset.settings)
        format = Self.formatIdentifier
        version = Self.currentVersion
        presets = [
            Preset(
                name: preset.name,
                settings: portableSettings,
                omitted: portableSettings.didOmitWallpaper ? [.wallpaper] : []
            )
        ]
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func load(from url: URL) throws -> AnnotationBackgroundPresetTransferFile {
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= maximumFileSize else {
            throw AnnotationBackgroundPresetTransferError.fileTooLarge
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumFileSize else {
            throw AnnotationBackgroundPresetTransferError.fileTooLarge
        }

        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw AnnotationBackgroundPresetTransferError.invalidJSON
        }
    }

    func validatedPresets() throws -> [Preset] {
        guard format == Self.formatIdentifier else {
            throw AnnotationBackgroundPresetTransferError.invalidFormat
        }
        guard version == Self.currentVersion else {
            throw AnnotationBackgroundPresetTransferError.unsupportedVersion(version)
        }
        guard !presets.isEmpty else {
            throw AnnotationBackgroundPresetTransferError.emptyFile
        }
        guard presets.count <= Self.maximumPresetCount else {
            throw AnnotationBackgroundPresetTransferError.tooManyPresets
        }
        return presets
    }

    struct Preset: Codable {
        var name: String
        var settings: PortableBackgroundSettings
        var omitted: [Omission]

        enum CodingKeys: String, CodingKey {
            case name
            case settings
            case omitted
        }

        init(
            name: String,
            settings: PortableBackgroundSettings,
            omitted: [Omission]
        ) {
            self.name = name
            self.settings = settings
            self.omitted = omitted
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            settings = try container.decode(PortableBackgroundSettings.self, forKey: .settings)
            omitted = try container.decodeIfPresent([Omission].self, forKey: .omitted) ?? []
        }
    }

    enum Omission: String, Codable {
        case wallpaper
    }
}

struct PortableBackgroundSettings: Codable {
    var style: PortableBackgroundStyle
    var padding: Double
    var cornerRadius: Double
    var shadow: Double
    var shadowStyle: String?
    var aspectRatio: String
    var alignment: String
    var camera: StoredCameraSettings?
    var progressiveBlur: StoredProgressiveBlurSettings?
    var border: StoredScreenshotBorder?
    var watermark: StoredWatermark?

    private(set) var didOmitWallpaper = false

    private enum CodingKeys: String, CodingKey {
        case style
        case padding
        case cornerRadius
        case shadow
        case shadowStyle
        case aspectRatio
        case alignment
        case camera
        case progressiveBlur
        case border
        case watermark
    }

    init(_ settings: AnnotationBackgroundSettings) {
        switch settings.style {
        case .none:
            style = .none
        case .solid(let color):
            style = .solid(StoredColor(color))
        case .gradient(let gradient):
            style = .gradient(StoredGradient(gradient))
        case .customWallpaper:
            style = .none
            didOmitWallpaper = true
        }

        padding = Double(settings.padding)
        cornerRadius = Double(settings.cornerRadius)
        shadow = Double(settings.shadow)
        shadowStyle = settings.shadowStyle.rawValue
        aspectRatio = settings.aspectRatio.rawValue
        alignment = settings.alignment.rawValue
        camera = StoredCameraSettings(settings.camera)
        progressiveBlur = StoredProgressiveBlurSettings(settings.progressiveBlur)
        border = StoredScreenshotBorder(settings.border)
        watermark = StoredWatermark(settings.watermark)
    }

    var annotationSettings: AnnotationBackgroundSettings {
        var output = AnnotationBackgroundSettings()
        switch style {
        case .none:
            output.style = .none
        case .solid(let color):
            output.style = .solid(Self.sanitizedColor(color))
        case .gradient(let gradient):
            output.style = .gradient(Self.sanitizedGradient(gradient))
        }

        output.padding = CGFloat(Self.clamp(padding, to: 0.04...0.45))
        output.cornerRadius = CGFloat(Self.clamp(cornerRadius, to: 0...0.12))
        output.shadow = CGFloat(Self.clamp(shadow, to: 0...1))
        output.shadowStyle = shadowStyle.flatMap(AnnotationShadowStyle.init(rawValue:)) ?? .soft
        output.aspectRatio = AnnotationBackgroundAspectRatio(rawValue: aspectRatio) ?? .auto
        output.alignment = AnnotationBackgroundAlignment(rawValue: alignment) ?? .center
        output.customWallpaper = nil

        if var camera = camera?.settings {
            camera.panX = CGFloat(Self.clamp(Double(camera.panX), to: -0.5...0.5))
            camera.panY = CGFloat(Self.clamp(Double(camera.panY), to: -0.5...0.5))
            camera.tiltXDegrees = CGFloat(Self.clamp(Double(camera.tiltXDegrees), to: -45...45))
            camera.tiltYDegrees = CGFloat(Self.clamp(Double(camera.tiltYDegrees), to: -45...45))
            camera.rotationXDegrees = CGFloat(Self.clamp(Double(camera.rotationXDegrees), to: -60...60))
            camera.rotationYDegrees = CGFloat(Self.clamp(Double(camera.rotationYDegrees), to: -60...60))
            camera.rollDegrees = CGFloat(Self.clamp(Double(camera.rollDegrees), to: -45...45))
            camera.fieldOfViewDegrees = CGFloat(Self.clamp(Double(camera.fieldOfViewDegrees), to: 18...80))
            camera.zoom = CGFloat(Self.clamp(Double(camera.zoom), to: 0.4...2.5))
            output.camera = camera
        }

        if var blur = progressiveBlur?.settings {
            blur.strength = CGFloat(Self.clamp(Double(blur.strength), to: 0...40))
            blur.falloff = CGFloat(Self.clamp(Double(blur.falloff), to: 0...1))
            blur.focusSize = CGFloat(Self.clamp(Double(blur.focusSize), to: 0...1))
            blur.focusPosition.x = CGFloat(Self.clamp(Double(blur.focusPosition.x), to: 0...1))
            blur.focusPosition.y = CGFloat(Self.clamp(Double(blur.focusPosition.y), to: 0...1))
            blur.directionDegrees = CGFloat(Self.clamp(Double(blur.directionDegrees), to: 0...180))
            output.progressiveBlur = blur
        }

        if var border = border?.settings {
            border.thickness = CGFloat(Self.clamp(Double(border.thickness), to: 0.002...0.08))
            border.opacity = CGFloat(Self.clamp(Double(border.opacity), to: 0...1))
            output.border = border
        }

        if var watermark = watermark?.settings {
            watermark.text = String(watermark.text.prefix(500))
            watermark.density = CGFloat(Self.clamp(Double(watermark.density), to: 2...10))
            watermark.fontSize = CGFloat(Self.clamp(Double(watermark.fontSize), to: 8...160))
            watermark.rotationDegrees = CGFloat(Self.clamp(Double(watermark.rotationDegrees), to: -90...90))
            watermark.opacity = CGFloat(Self.clamp(Double(watermark.opacity), to: 0...0.75))
            watermark.color = AnnotationWatermarkColor(
                red: CGFloat(Self.clamp(Double(watermark.color.red), to: 0...1)),
                green: CGFloat(Self.clamp(Double(watermark.color.green), to: 0...1)),
                blue: CGFloat(Self.clamp(Double(watermark.color.blue), to: 0...1)),
                alpha: CGFloat(Self.clamp(Double(watermark.color.alpha), to: 0...1))
            )
            output.watermark = watermark
        }

        return output
    }

    private static func sanitizedColor(_ color: StoredColor) -> AnnotationBackgroundColor {
        AnnotationBackgroundColor(
            String(color.id.prefix(100)),
            title: String(color.title.prefix(100)),
            red: CGFloat(clamp(color.red, to: 0...1)),
            green: CGFloat(clamp(color.green, to: 0...1)),
            blue: CGFloat(clamp(color.blue, to: 0...1)),
            alpha: CGFloat(clamp(color.alpha, to: 0...1))
        )
    }

    private static func sanitizedGradient(_ gradient: StoredGradient) -> AnnotationBackgroundGradient {
        let colors = gradient.colors.prefix(8).map(sanitizedColor)
        return AnnotationBackgroundGradient(
            id: String(gradient.id.prefix(100)),
            title: String(gradient.title.prefix(100)),
            colors: colors.isEmpty ? [.graphite] : colors,
            startPoint: UnitPoint(
                x: CGFloat(clamp(gradient.startX, to: 0...1)),
                y: CGFloat(clamp(gradient.startY, to: 0...1))
            ),
            endPoint: UnitPoint(
                x: CGFloat(clamp(gradient.endX, to: 0...1)),
                y: CGFloat(clamp(gradient.endY, to: 0...1))
            )
        )
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

enum PortableBackgroundStyle: Codable {
    case none
    case solid(StoredColor)
    case gradient(StoredGradient)

    private enum CodingKeys: String, CodingKey {
        case type
        case color
        case gradient
    }

    private enum StyleType: String, Codable {
        case none
        case solid
        case gradient
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(StyleType.self, forKey: .type) {
        case .none:
            self = .none
        case .solid:
            self = .solid(try container.decode(StoredColor.self, forKey: .color))
        case .gradient:
            self = .gradient(try container.decode(StoredGradient.self, forKey: .gradient))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(StyleType.none, forKey: .type)
        case .solid(let color):
            try container.encode(StyleType.solid, forKey: .type)
            try container.encode(color, forKey: .color)
        case .gradient(let gradient):
            try container.encode(StyleType.gradient, forKey: .type)
            try container.encode(gradient, forKey: .gradient)
        }
    }
}

enum AnnotationBackgroundPresetTransferError: LocalizedError {
    case presetNotFound
    case invalidJSON
    case invalidFormat
    case unsupportedVersion(Int)
    case emptyFile
    case tooManyPresets
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .presetNotFound:
            "The selected preset no longer exists."
        case .invalidJSON:
            "This is not a valid Screendrop preset file."
        case .invalidFormat:
            "This JSON file is not a Screendrop screenshot preset."
        case .unsupportedVersion(let version):
            "This preset uses unsupported format version \(version)."
        case .emptyFile:
            "This preset file does not contain any presets."
        case .tooManyPresets:
            "This preset file contains too many presets."
        case .fileTooLarge:
            "This preset file is larger than 1 MB."
        }
    }
}
