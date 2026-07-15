//
//  RecordingStudioStyle.swift
//  Screendrop
//
//  Style settings and canvas layout for the recording studio. The layout
//  math is deterministic and shared verbatim between the live SwiftUI
//  preview and the offline exporter so what you see is what you export.
//

import CoreGraphics
import Foundation

/// The floating talking-head bubble composited over the recording.
struct RecordingCameraBubbleSettings: Equatable {
    var isVisible = true
    /// Normalized (0...1, top-left origin) bubble center on the canvas.
    var center = CGPoint(x: 0.85, y: 0.82)
    /// Bubble diameter as a fraction of the canvas's smaller dimension.
    var size: CGFloat = 0.26
    /// 0.5 = circle, smaller values square the bubble off.
    var roundness: CGFloat = 0.5
}

struct RecordingEditDocument: Codable, Equatable {
    var formatVersion = 1
    var style: StoredRecordingStudioStyle
    var zoomEnabled: Bool
    var zoomCues: [ZoomCue]
    var trimStart: TimeInterval?
    var trimEnd: TimeInterval?
    var exportSettings: VideoCompressionSettings?

    init(
        style: RecordingStudioStyle,
        zoomEnabled: Bool,
        zoomCues: [ZoomCue],
        trimSelection: VideoTrimSelection? = nil,
        exportSettings: VideoCompressionSettings? = nil
    ) {
        self.style = StoredRecordingStudioStyle(style)
        self.zoomEnabled = zoomEnabled
        self.zoomCues = zoomCues
        trimStart = trimSelection?.start
        trimEnd = trimSelection?.end
        self.exportSettings = exportSettings
    }
}

struct StoredRecordingStudioStyle: Codable, Equatable {
    var background: StoredBackgroundStyle
    var padding: Double
    var cornerRadius: Double
    var shadow: Double
    /// Optional so project files saved before cursor scaling decode to the
    /// current default.
    var cursorScale: Double?
    var cameraIsVisible: Bool
    var cameraCenterX: Double
    var cameraCenterY: Double
    var cameraSize: Double
    var cameraRoundness: Double

    init(_ style: RecordingStudioStyle) {
        switch style.background {
        case .none:
            background = .none
        case .solid(let color):
            background = .solid(StoredColor(color))
        case .gradient(let gradient):
            background = .gradient(StoredGradient(gradient))
        case .customWallpaper(let wallpaper):
            background = .customWallpaper(path: wallpaper.url.path)
        }
        padding = Double(style.padding)
        cornerRadius = Double(style.cornerRadius)
        shadow = Double(style.shadow)
        cursorScale = Double(style.cursorScale)
        cameraIsVisible = style.camera.isVisible
        cameraCenterX = Double(style.camera.center.x)
        cameraCenterY = Double(style.camera.center.y)
        cameraSize = Double(style.camera.size)
        cameraRoundness = Double(style.camera.roundness)
    }

    var value: RecordingStudioStyle {
        let backgroundValue: AnnotationBackgroundStyle
        switch background {
        case .none:
            backgroundValue = .none
        case .solid(let color):
            backgroundValue = .solid(color.backgroundColor)
        case .gradient(let gradient):
            backgroundValue = .gradient(gradient.backgroundGradient)
        case .customWallpaper(let path):
            backgroundValue = .customWallpaper(AnnotationCustomWallpaper(url: URL(fileURLWithPath: path)))
        }

        return RecordingStudioStyle(
            background: backgroundValue,
            padding: CGFloat(padding),
            cornerRadius: CGFloat(cornerRadius),
            shadow: CGFloat(shadow),
            cursorScale: CGFloat(cursorScale ?? RecordingStudioStyle.defaultCursorScale),
            camera: RecordingCameraBubbleSettings(
                isVisible: cameraIsVisible,
                center: CGPoint(x: cameraCenterX, y: cameraCenterY),
                size: CGFloat(cameraSize),
                roundness: CGFloat(cameraRoundness)
            )
        )
    }
}

struct RecordingStudioStyle: Equatable {
    static let defaultCursorScale: CGFloat = 1.7

    static var defaultBackground: AnnotationBackgroundStyle {
        guard let gradient = AnnotationBackgroundGradient.presets.last else { return .none }
        return .gradient(gradient)
    }

    var background: AnnotationBackgroundStyle = RecordingStudioStyle.defaultBackground
    /// Card inset as a fraction of the canvas's smaller dimension.
    var padding: CGFloat = 0.06
    /// Card corner radius as a fraction of the canvas's smaller dimension.
    var cornerRadius: CGFloat = 0.02
    /// Shadow strength 0...1.
    var shadow: CGFloat = 0.45
    /// Synthetic cursor magnification (1 = natural size, up to 4).
    var cursorScale: CGFloat = RecordingStudioStyle.defaultCursorScale
    var camera = RecordingCameraBubbleSettings()
}

/// Cross-video defaults for Studio choices that should follow the user from
/// one recording to the next. Per-recording project files still win whenever
/// a video has already been edited.
enum RecordingStudioDefaults {
    private static let backgroundKey = "recordingStudio.lastUsedBackground.v1"

    static var background: AnnotationBackgroundStyle {
        get {
            guard let data = UserDefaults.standard.data(forKey: backgroundKey),
                  let stored = try? JSONDecoder().decode(StoredBackgroundStyle.self, from: data) else {
                return RecordingStudioStyle.defaultBackground
            }
            return backgroundStyle(from: stored)
        }
        set {
            let stored = storedBackgroundStyle(from: newValue)
            guard let data = try? JSONEncoder().encode(stored) else { return }
            UserDefaults.standard.set(data, forKey: backgroundKey)
        }
    }

    private static func storedBackgroundStyle(
        from style: AnnotationBackgroundStyle
    ) -> StoredBackgroundStyle {
        switch style {
        case .none:
            .none
        case .solid(let color):
            .solid(StoredColor(color))
        case .gradient(let gradient):
            .gradient(StoredGradient(gradient))
        case .customWallpaper(let wallpaper):
            .customWallpaper(path: wallpaper.url.path)
        }
    }

    private static func backgroundStyle(
        from stored: StoredBackgroundStyle
    ) -> AnnotationBackgroundStyle {
        switch stored {
        case .none:
            .none
        case .solid(let color):
            .solid(color.backgroundColor)
        case .gradient(let gradient):
            .gradient(gradient.backgroundGradient)
        case .customWallpaper(let path):
            .customWallpaper(AnnotationCustomWallpaper(url: URL(fileURLWithPath: path)))
        }
    }
}

/// Deterministic canvas layout shared by the preview and the exporter.
/// All rects are in the given canvas space with a top-left origin.
nonisolated struct RecordingStudioLayout: Sendable {
    let canvasSize: CGSize
    let cardRect: CGRect
    let cardCornerRadius: CGFloat
    let bubbleRect: CGRect
    let bubbleCornerRadius: CGFloat

    static func make(
        canvasSize: CGSize,
        style: RecordingStudioStyle,
        includeBubble: Bool
    ) -> RecordingStudioLayout {
        let minDimension = min(canvasSize.width, canvasSize.height)
        let inset = (style.padding * minDimension).rounded()
        // Shrink the card uniformly so it keeps the video's aspect ratio —
        // insetting both axes by the same amount would stretch the recording.
        let cardScale = max(0.05, 1 - 2 * inset / minDimension)
        let cardSize = CGSize(
            width: (canvasSize.width * cardScale).rounded(),
            height: (canvasSize.height * cardScale).rounded()
        )
        let cardRect = CGRect(
            x: ((canvasSize.width - cardSize.width) / 2).rounded(),
            y: ((canvasSize.height - cardSize.height) / 2).rounded(),
            width: cardSize.width,
            height: cardSize.height
        )
        let cardCornerRadius = style.cornerRadius * minDimension

        var bubbleRect = CGRect.zero
        var bubbleCornerRadius: CGFloat = 0
        if includeBubble, style.camera.isVisible {
            let diameter = max(24, style.camera.size * minDimension)
            var center = CGPoint(
                x: style.camera.center.x * canvasSize.width,
                y: style.camera.center.y * canvasSize.height
            )
            center.x = min(max(center.x, diameter / 2), canvasSize.width - diameter / 2)
            center.y = min(max(center.y, diameter / 2), canvasSize.height - diameter / 2)
            bubbleRect = CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            bubbleCornerRadius = max(4, style.camera.roundness * diameter)
        }

        return RecordingStudioLayout(
            canvasSize: canvasSize,
            cardRect: cardRect,
            cardCornerRadius: cardCornerRadius,
            bubbleRect: bubbleRect,
            bubbleCornerRadius: bubbleCornerRadius
        )
    }

    /// Where the (zoomed) screen video draws, given a viewport frame. The
    /// video fills the card at magnification 1; zooming grows the draw rect
    /// while keeping the viewport anchor point pinned to the card center.
    func frameRect(for viewport: ViewportFrame) -> CGRect {
        let drawWidth = cardRect.width * viewport.magnification
        let drawHeight = cardRect.height * viewport.magnification
        return CGRect(
            x: cardRect.midX - viewport.anchor.x * drawWidth,
            y: cardRect.midY - viewport.anchor.y * drawHeight,
            width: drawWidth,
            height: drawHeight
        )
    }
}
