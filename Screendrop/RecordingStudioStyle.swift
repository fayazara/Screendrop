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

struct RecordingProject: Codable, Equatable {
    var version = 1
    var style: StoredRecordingStudioStyle
    var zoomEnabled: Bool
    var zoomSegments: [***REMOVED***]
    var trimStart: TimeInterval?
    var trimEnd: TimeInterval?
    var exportSettings: VideoCompressionSettings?

    init(
        style: RecordingStudioStyle,
        zoomEnabled: Bool,
        zoomSegments: [***REMOVED***],
        trimSelection: VideoTrimSelection? = nil,
        exportSettings: VideoCompressionSettings? = nil
    ) {
        self.style = StoredRecordingStudioStyle(style)
        self.zoomEnabled = zoomEnabled
        self.zoomSegments = zoomSegments
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
    var background: AnnotationBackgroundStyle = .gradient(AnnotationBackgroundGradient.presets[0])
    /// Card inset as a fraction of the canvas's smaller dimension.
    var padding: CGFloat = 0.06
    /// Card corner radius as a fraction of the canvas's smaller dimension.
    var cornerRadius: CGFloat = 0.02
    /// Shadow strength 0...1.
    var shadow: CGFloat = 0.45
    var camera = RecordingCameraBubbleSettings()
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

    /// Where the (zoomed) screen video draws, given a camera state. The
    /// video fills the card at scale 1; zooming grows the draw rect while
    /// keeping the camera-path center point pinned to the card center.
    func videoDrawRect(for state: ***REMOVED***) -> CGRect {
        let drawWidth = cardRect.width * state.scale
        let drawHeight = cardRect.height * state.scale
        return CGRect(
            x: cardRect.midX - state.center.x * drawWidth,
            y: cardRect.midY - state.center.y * drawHeight,
            width: drawWidth,
            height: drawHeight
        )
    }
}
