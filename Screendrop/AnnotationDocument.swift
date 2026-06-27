//
//  AnnotationDocument.swift
//  Screendrop
//
//  Codable sidecar document that stores the editable annotation state for a
//  screenshot. Persisted next to the rendered image as `<image>.screendrop`
//  so annotations remain non-destructive and can be re-opened for editing.
//

import AppKit
import Foundation
import SwiftUI

/// The persisted edit document for a single screenshot.
struct AnnotationDocument: Codable, Equatable {
    /// Schema version, for forward-compatible migrations.
    var version: Int
    /// File name of the untouched base image stored in the same directory.
    var baseImageFileName: String
    var items: [StoredAnnotationItem]
    var background: StoredBackground

    init(
        items: [AnnotationItem],
        background: AnnotationBackgroundSettings,
        baseImageFileName: String = "",
        version: Int = 1
    ) {
        self.version = version
        self.baseImageFileName = baseImageFileName
        self.items = items.map(StoredAnnotationItem.init)
        self.background = StoredBackground(background)
    }

    var annotationItems: [AnnotationItem] {
        items.map(\.annotationItem)
    }

    var backgroundSettings: AnnotationBackgroundSettings {
        background.settings
    }
}

// MARK: - Annotation item

struct StoredAnnotationItem: Codable, Equatable {
    var id: UUID
    var tool: AnnotationTool
    var rect: CGRect
    var points: [CGPoint]
    var swatch: CodableSwatch
    var strokeWidth: Double
    var redactionDensity: Double
    var text: String
    var textLineHeight: Double
    var fontName: String
    var isBold: Bool
    var isItalic: Bool
    var isUnderline: Bool
    var textAlignment: Int

    init(_ item: AnnotationItem) {
        id = item.id
        tool = item.tool
        rect = item.rect
        points = item.points
        swatch = CodableSwatch(swatch: item.swatch)
        strokeWidth = Double(item.strokeWidth)
        redactionDensity = Double(item.redactionDensity)
        text = item.text
        textLineHeight = Double(item.textLineHeight)
        fontName = item.fontName
        isBold = item.isBold
        isItalic = item.isItalic
        isUnderline = item.isUnderline
        textAlignment = item.textAlignment.rawValue
    }

    var annotationItem: AnnotationItem {
        AnnotationItem(
            id: id,
            tool: tool,
            rect: rect,
            points: points,
            swatch: swatch.annotationSwatch,
            strokeWidth: CGFloat(strokeWidth),
            redactionDensity: CGFloat(redactionDensity),
            text: text,
            textLineHeight: CGFloat(textLineHeight),
            fontName: fontName,
            isBold: isBold,
            isItalic: isItalic,
            isUnderline: isUnderline,
            textAlignment: NSTextAlignment(rawValue: textAlignment) ?? .left
        )
    }
}

// MARK: - Background

struct StoredBackground: Codable, Equatable {
    var style: StoredBackgroundStyle
    var padding: Double
    var cornerRadius: Double
    var shadow: Double
    var aspectRatio: String
    var alignment: String
    var customWallpaperPath: String?
    var watermark: StoredWatermark?

    init(_ settings: AnnotationBackgroundSettings) {
        switch settings.style {
        case .none:
            style = .none
        case .solid(let color):
            style = .solid(StoredColor(color))
        case .gradient(let gradient):
            style = .gradient(StoredGradient(gradient))
        case .customWallpaper(let wallpaper):
            style = .customWallpaper(path: wallpaper.url.path)
        }

        padding = Double(settings.padding)
        cornerRadius = Double(settings.cornerRadius)
        shadow = Double(settings.shadow)
        aspectRatio = settings.aspectRatio.rawValue
        alignment = settings.alignment.rawValue
        customWallpaperPath = settings.customWallpaper?.url.path
        watermark = StoredWatermark(settings.watermark)
    }

    var settings: AnnotationBackgroundSettings {
        var output = AnnotationBackgroundSettings()
        switch style {
        case .none:
            output.style = .none
        case .solid(let color):
            output.style = .solid(color.backgroundColor)
        case .gradient(let gradient):
            output.style = .gradient(gradient.backgroundGradient)
        case .customWallpaper(let path):
            output.style = .customWallpaper(AnnotationCustomWallpaper(url: URL(fileURLWithPath: path)))
        }

        output.padding = CGFloat(padding)
        output.cornerRadius = CGFloat(cornerRadius)
        output.shadow = CGFloat(shadow)
        output.aspectRatio = AnnotationBackgroundAspectRatio(rawValue: aspectRatio) ?? .auto
        output.alignment = AnnotationBackgroundAlignment(rawValue: alignment) ?? .center
        if let customWallpaperPath {
            output.customWallpaper = AnnotationCustomWallpaper(url: URL(fileURLWithPath: customWallpaperPath))
        }
        if let watermark {
            output.watermark = watermark.settings
        }
        return output
    }
}

enum StoredBackgroundStyle: Codable, Equatable {
    case none
    case solid(StoredColor)
    case gradient(StoredGradient)
    case customWallpaper(path: String)
}

struct StoredColor: Codable, Equatable {
    var id: String
    var title: String
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(_ color: AnnotationBackgroundColor) {
        id = color.id
        title = color.title
        red = Double(color.red)
        green = Double(color.green)
        blue = Double(color.blue)
        alpha = Double(color.alpha)
    }

    var backgroundColor: AnnotationBackgroundColor {
        AnnotationBackgroundColor(
            id,
            title: title,
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}

struct StoredGradient: Codable, Equatable {
    var id: String
    var title: String
    var colors: [StoredColor]
    var startX: Double
    var startY: Double
    var endX: Double
    var endY: Double

    init(_ gradient: AnnotationBackgroundGradient) {
        id = gradient.id
        title = gradient.title
        colors = gradient.colors.map(StoredColor.init)
        startX = Double(gradient.startPoint.x)
        startY = Double(gradient.startPoint.y)
        endX = Double(gradient.endPoint.x)
        endY = Double(gradient.endPoint.y)
    }

    var backgroundGradient: AnnotationBackgroundGradient {
        AnnotationBackgroundGradient(
            id: id,
            title: title,
            colors: colors.map(\.backgroundColor),
            startPoint: UnitPoint(x: CGFloat(startX), y: CGFloat(startY)),
            endPoint: UnitPoint(x: CGFloat(endX), y: CGFloat(endY))
        )
    }
}

struct StoredWatermark: Codable, Equatable {
    var isEnabled: Bool
    var text: String
    var density: Double
    var fontSize: Double
    var rotationDegrees: Double
    var opacity: Double
    var color: StoredWatermarkColor

    init(_ settings: AnnotationWatermarkSettings) {
        isEnabled = settings.isEnabled
        text = settings.text
        density = Double(settings.density)
        fontSize = Double(settings.fontSize)
        rotationDegrees = Double(settings.rotationDegrees)
        opacity = Double(settings.opacity)
        color = StoredWatermarkColor(settings.color)
    }

    var settings: AnnotationWatermarkSettings {
        AnnotationWatermarkSettings(
            isEnabled: isEnabled,
            text: text,
            density: CGFloat(density),
            fontSize: CGFloat(fontSize),
            rotationDegrees: CGFloat(rotationDegrees),
            opacity: CGFloat(opacity),
            color: color.watermarkColor
        )
    }
}

struct StoredWatermarkColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(_ color: AnnotationWatermarkColor) {
        red = Double(color.red)
        green = Double(color.green)
        blue = Double(color.blue)
        alpha = Double(color.alpha)
    }

    var watermarkColor: AnnotationWatermarkColor {
        AnnotationWatermarkColor(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}
