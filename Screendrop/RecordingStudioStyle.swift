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

nonisolated enum RecordingCameraAspectRatio: String, Codable, CaseIterable, Sendable {
    case square = "1:1"
    case portrait3x4 = "3:4"
    case landscape4x3 = "4:3"

    var title: String { rawValue }

    var help: String {
        switch self {
        case .square: "Square 1:1"
        case .portrait3x4: "Portrait 3:4"
        case .landscape4x3: "Landscape 4:3"
        }
    }

    var ratio: CGFloat {
        switch self {
        case .square: 1.0
        case .portrait3x4: 3.0 / 4.0
        case .landscape4x3: 4.0 / 3.0
        }
    }
}

/// The floating talking-head bubble composited over the recording.
struct RecordingCameraBubbleSettings: Equatable {
    var isVisible = true
    /// Normalized (0...1, top-left origin) bubble center on the canvas.
    var center = CGPoint(x: 0.85, y: 0.82)
    /// Bubble diameter as a fraction of the canvas's smaller dimension.
    var size: CGFloat = 0.26
    /// 0.5 = circle, smaller values square the bubble off.
    var roundness: CGFloat = 0.25
    var aspectRatio: RecordingCameraAspectRatio = .square
}

struct RecordingEditDocument: Codable, Equatable {
    var formatVersion = 5
    var style: StoredRecordingStudioStyle
    var zoomEnabled: Bool
    var zoomCues: [ZoomCue]
    /// Ordered source ranges that make up the edited movie. Optional so v1
    /// projects continue to decode through their single trim range.
    var clips: [RecordingClipSegment]?
    var trimStart: TimeInterval?
    var trimEnd: TimeInterval?
    var exportSettings: VideoCompressionSettings?
    /// Optional so projects saved before post-record input feedback decode
    /// to the defaults (clicks and keystrokes shown, bottom-center caption).
    var showsClickEffects: Bool?
    var showsKeystrokes: Bool?
    var keystrokePlacement: RecordingKeystrokePlacement?
    /// Optional so projects saved before transcription decode with no
    /// subtitles and the toggle defaulting on.
    var showsSubtitles: Bool?
    var subtitleCues: [RecordingSubtitleCue]?
    /// Word-level timing behind the cues; optional so projects transcribed
    /// before transcript editing decode with cues only.
    var subtitleWords: [RecordingTranscriptWord]?
    var subtitleVerticalPosition: Double?
    var subtitleFontScale: Double?
    var subtitleWordHighlight: Bool?
    /// Raw ExportAspectPreset value; optional so older projects keep the
    /// original aspect.
    var exportAspect: String?
    /// Raw ExportAspectContentMode value; defaults to fill (crop).
    var exportAspectMode: String?
    /// Normalized top-left crop of the screen-video source. Optional so
    /// projects saved before video cropping show their entire recording.
    var videoCropRect: CGRect?
    /// File name, inside the session folder, of a soundtrack imported to
    /// stand in for the recording's own audio; nil when none was imported.
    var replacementAudioFileName: String?
    /// The imported file's original name, for the inspector.
    var replacementAudioDisplayName: String?
    /// Raw RecordingAudioFormat value for the audio-only export.
    var audioExportFormat: String?
    var audioVolume: Double?

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case style
        case zoomEnabled
        case zoomCues
        case clips
        case trimStart
        case trimEnd
        case exportSettings
        case showsClickEffects
        case showsKeystrokes
        case keystrokePlacement
        case showsSubtitles
        case subtitleCues
        case subtitleWords
        case subtitleVerticalPosition
        case subtitleFontScale
        case subtitleWordHighlight
        case exportAspect
        case exportAspectMode
        case videoCropRect
        /// Read compatibility for the initial local implementation, which
        /// incorrectly described this as a crop of the composed canvas.
        case canvasCropRect
        case replacementAudioFileName
        case replacementAudioDisplayName
        case audioExportFormat
        case audioVolume
    }

    init(
        style: RecordingStudioStyle,
        zoomEnabled: Bool,
        zoomCues: [ZoomCue],
        clipTimeline: RecordingClipTimeline? = nil,
        trimSelection: VideoTrimSelection? = nil,
        exportSettings: VideoCompressionSettings? = nil,
        showsClickEffects: Bool? = nil,
        showsKeystrokes: Bool? = nil,
        keystrokePlacement: RecordingKeystrokePlacement? = nil,
        showsSubtitles: Bool? = nil,
        subtitleCues: [RecordingSubtitleCue]? = nil,
        subtitleWords: [RecordingTranscriptWord]? = nil,
        subtitleStyle: SubtitleBarStyle? = nil,
        exportAspect: ExportAspectPreset? = nil,
        exportAspectMode: ExportAspectContentMode? = nil,
        videoCropRect: CGRect? = nil,
        replacementAudioFileName: String? = nil,
        replacementAudioDisplayName: String? = nil,
        audioExportFormat: RecordingAudioFormat? = nil,
        audioVolume: Double? = nil
    ) {
        self.style = StoredRecordingStudioStyle(style)
        self.zoomEnabled = zoomEnabled
        self.zoomCues = zoomCues
        clips = clipTimeline?.segments
        if let clip = clipTimeline?.segments.only {
            // Keep the legacy envelope populated for older Screendrop builds.
            trimStart = clip.sourceStart
            trimEnd = clip.sourceEnd
        } else {
            trimStart = trimSelection?.start
            trimEnd = trimSelection?.end
        }
        self.exportSettings = exportSettings
        self.showsClickEffects = showsClickEffects
        self.showsKeystrokes = showsKeystrokes
        self.keystrokePlacement = keystrokePlacement
        self.showsSubtitles = showsSubtitles
        self.subtitleCues = subtitleCues
        self.subtitleWords = subtitleWords
        subtitleVerticalPosition = subtitleStyle?.verticalPosition
        subtitleFontScale = subtitleStyle?.fontScale
        subtitleWordHighlight = subtitleStyle?.highlightsSpokenWord
        self.exportAspect = exportAspect.map(\.rawValue)
        self.exportAspectMode = exportAspectMode.map(\.rawValue)
        self.videoCropRect = videoCropRect
        self.replacementAudioFileName = replacementAudioFileName
        self.replacementAudioDisplayName = replacementAudioDisplayName
        self.audioExportFormat = audioExportFormat.map(\.rawValue)
        self.audioVolume = audioVolume
    }

    var audioExportFormatValue: RecordingAudioFormat {
        audioExportFormat.flatMap(RecordingAudioFormat.init(rawValue:)) ?? .m4a
    }

    var subtitleStyle: SubtitleBarStyle {
        var style = SubtitleBarStyle()
        if let subtitleVerticalPosition {
            style.verticalPosition = subtitleVerticalPosition
        }
        if let subtitleFontScale {
            style.fontScale = subtitleFontScale
        }
        if let subtitleWordHighlight {
            style.highlightsSpokenWord = subtitleWordHighlight
        }
        return style
    }

    var exportAspectPreset: ExportAspectPreset {
        exportAspect.flatMap(ExportAspectPreset.init(rawValue:)) ?? .original
    }

    var exportAspectContentMode: ExportAspectContentMode {
        exportAspectMode.flatMap(ExportAspectContentMode.init(rawValue:)) ?? .fill
    }

    var normalizedVideoCropRect: CGRect {
        guard let videoCropRect else { return CropRectEditor.unit }
        let crop = videoCropRect.standardized.intersection(CropRectEditor.unit)
        guard crop.width > 0.0001, crop.height > 0.0001 else {
            return CropRectEditor.unit
        }
        return crop
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        style = try container.decode(StoredRecordingStudioStyle.self, forKey: .style)
        zoomEnabled = try container.decodeIfPresent(Bool.self, forKey: .zoomEnabled) ?? true
        zoomCues = try container.decodeIfPresent([ZoomCue].self, forKey: .zoomCues) ?? []
        clips = try container.decodeIfPresent([RecordingClipSegment].self, forKey: .clips)
        trimStart = try container.decodeIfPresent(TimeInterval.self, forKey: .trimStart)
        trimEnd = try container.decodeIfPresent(TimeInterval.self, forKey: .trimEnd)
        exportSettings = try container.decodeIfPresent(
            VideoCompressionSettings.self,
            forKey: .exportSettings
        )
        showsClickEffects = try container.decodeIfPresent(Bool.self, forKey: .showsClickEffects)
        showsKeystrokes = try container.decodeIfPresent(Bool.self, forKey: .showsKeystrokes)
        keystrokePlacement = try container.decodeIfPresent(
            RecordingKeystrokePlacement.self,
            forKey: .keystrokePlacement
        )
        showsSubtitles = try container.decodeIfPresent(Bool.self, forKey: .showsSubtitles)
        subtitleCues = try container.decodeIfPresent(
            [RecordingSubtitleCue].self,
            forKey: .subtitleCues
        )
        subtitleWords = try container.decodeIfPresent(
            [RecordingTranscriptWord].self,
            forKey: .subtitleWords
        )
        subtitleVerticalPosition = try container.decodeIfPresent(
            Double.self,
            forKey: .subtitleVerticalPosition
        )
        subtitleFontScale = try container.decodeIfPresent(Double.self, forKey: .subtitleFontScale)
        subtitleWordHighlight = try container.decodeIfPresent(Bool.self, forKey: .subtitleWordHighlight)
        exportAspect = try container.decodeIfPresent(String.self, forKey: .exportAspect)
        exportAspectMode = try container.decodeIfPresent(String.self, forKey: .exportAspectMode)
        videoCropRect = try container.decodeIfPresent(CGRect.self, forKey: .videoCropRect)
            ?? container.decodeIfPresent(CGRect.self, forKey: .canvasCropRect)
        replacementAudioFileName = try container.decodeIfPresent(
            String.self,
            forKey: .replacementAudioFileName
        )
        replacementAudioDisplayName = try container.decodeIfPresent(
            String.self,
            forKey: .replacementAudioDisplayName
        )
        audioExportFormat = try container.decodeIfPresent(String.self, forKey: .audioExportFormat)
        audioVolume = try container.decodeIfPresent(Double.self, forKey: .audioVolume)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(style, forKey: .style)
        try container.encode(zoomEnabled, forKey: .zoomEnabled)
        try container.encode(zoomCues, forKey: .zoomCues)
        try container.encodeIfPresent(clips, forKey: .clips)
        try container.encodeIfPresent(trimStart, forKey: .trimStart)
        try container.encodeIfPresent(trimEnd, forKey: .trimEnd)
        try container.encodeIfPresent(exportSettings, forKey: .exportSettings)
        try container.encodeIfPresent(showsClickEffects, forKey: .showsClickEffects)
        try container.encodeIfPresent(showsKeystrokes, forKey: .showsKeystrokes)
        try container.encodeIfPresent(keystrokePlacement, forKey: .keystrokePlacement)
        try container.encodeIfPresent(showsSubtitles, forKey: .showsSubtitles)
        try container.encodeIfPresent(subtitleCues, forKey: .subtitleCues)
        try container.encodeIfPresent(subtitleWords, forKey: .subtitleWords)
        try container.encodeIfPresent(subtitleVerticalPosition, forKey: .subtitleVerticalPosition)
        try container.encodeIfPresent(subtitleFontScale, forKey: .subtitleFontScale)
        try container.encodeIfPresent(subtitleWordHighlight, forKey: .subtitleWordHighlight)
        try container.encodeIfPresent(exportAspect, forKey: .exportAspect)
        try container.encodeIfPresent(exportAspectMode, forKey: .exportAspectMode)
        try container.encodeIfPresent(videoCropRect, forKey: .videoCropRect)
        try container.encodeIfPresent(replacementAudioFileName, forKey: .replacementAudioFileName)
        try container.encodeIfPresent(
            replacementAudioDisplayName,
            forKey: .replacementAudioDisplayName
        )
        try container.encodeIfPresent(audioExportFormat, forKey: .audioExportFormat)
        try container.encodeIfPresent(audioVolume, forKey: .audioVolume)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
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
    var hidesCursor: Bool?
    var cameraIsVisible: Bool
    var cameraCenterX: Double
    var cameraCenterY: Double
    var cameraSize: Double
    var cameraRoundness: Double
    var cameraAspectRatio: String?

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
        hidesCursor = style.hidesCursor ? true : nil
        cameraIsVisible = style.camera.isVisible
        cameraCenterX = Double(style.camera.center.x)
        cameraCenterY = Double(style.camera.center.y)
        cameraSize = Double(style.camera.size)
        cameraRoundness = Double(style.camera.roundness)
        cameraAspectRatio = style.camera.aspectRatio.rawValue
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
            hidesCursor: hidesCursor ?? false,
            camera: RecordingCameraBubbleSettings(
                isVisible: cameraIsVisible,
                center: CGPoint(x: cameraCenterX, y: cameraCenterY),
                size: CGFloat(cameraSize),
                roundness: CGFloat(cameraRoundness),
                aspectRatio: cameraAspectRatio.flatMap(RecordingCameraAspectRatio.init(rawValue:)) ?? .square
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
    var hidesCursor = false
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
    /// Original follows the visible source, then adds an equal border without
    /// stretching the video. Padding remains a fraction of the canvas's short side.
    static func originalCanvasSize(
        sourceSize: CGSize,
        style: RecordingStudioStyle,
        contentCropRect: CGRect
    ) -> CGSize {
        let crop = RecordingVideoCropGeometry.isCropped(contentCropRect)
            ? RecordingVideoCropGeometry.normalized(contentCropRect)
            : RecordingVideoCropGeometry.unit
        let visibleSize = CGSize(
            width: sourceSize.width * crop.width,
            height: sourceSize.height * crop.height
        )
        let padding = min(max(style.padding, 0), 0.475)
        let inset = min(visibleSize.width, visibleSize.height) * padding / (1 - 2 * padding)
        return CGSize(width: visibleSize.width + 2 * inset, height: visibleSize.height + 2 * inset)
    }

    let canvasSize: CGSize
    let cardRect: CGRect
    let cardCornerRadius: CGFloat
    let bubbleRect: CGRect
    let bubbleCornerRadius: CGFloat
    /// The video's base draw size at magnification 1. Equal to the card
    /// when the content shares its aspect (the normal case); when a
    /// reframe export renders into a different aspect, this is the
    /// aspect-fill size so the content covers the card without stretching.
    let contentFillSize: CGSize

    /// How content occupies a card whose aspect differs from the video's.
    enum ContentMode: Sendable {
        /// Aspect-fill: content covers the card and gets cropped.
        case fill
        /// Aspect-fit: the card itself shrinks to the content's aspect so
        /// the whole recording stays visible.
        case fit
    }

    static func make(
        canvasSize: CGSize,
        style: RecordingStudioStyle,
        includeBubble: Bool,
        usesUniformPadding: Bool = false,
        contentAspect: CGFloat? = nil,
        contentMode: ContentMode = .fill,
        contentCropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> RecordingStudioLayout {
        let minDimension = min(canvasSize.width, canvasSize.height)
        let inset = usesUniformPadding
            ? min(max(style.padding, 0), 0.475) * minDimension
            : (style.padding * minDimension).rounded()
        // Fixed presets retain their existing scale-based layout. Original's
        // canvas already includes the border, so inset each edge equally.
        let cardScale = max(0.05, 1 - 2 * inset / minDimension)
        var cardSize = usesUniformPadding ? CGSize(
            width: canvasSize.width - 2 * inset,
            height: canvasSize.height - 2 * inset
        ) : CGSize(
            width: (canvasSize.width * cardScale).rounded(),
            height: (canvasSize.height * cardScale).rounded()
        )
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let normalizedCrop = contentCropRect.standardized.intersection(unit)
        let crop = normalizedCrop.width > 0.0001 && normalizedCrop.height > 0.0001
            ? normalizedCrop
            : unit
        let hasContentCrop = crop.minX > 0.0005
            || crop.minY > 0.0005
            || crop.width < 0.999
            || crop.height < 0.999
        let sourceAspect = contentAspect ?? (canvasSize.height > 0 ? canvasSize.width / canvasSize.height : 1)
        let cardAspect: CGFloat? = if hasContentCrop {
            sourceAspect * crop.width / crop.height
        } else if case .fit = contentMode {
            contentAspect
        } else {
            nil
        }
        if let cardAspect, cardAspect > 0, !usesUniformPadding {
            // Fixed presets keep their canvas; Original already follows the crop.
            let fitHeight = min(cardSize.height, cardSize.width / cardAspect)
            cardSize = CGSize(
                width: (cardAspect * fitHeight).rounded(),
                height: fitHeight.rounded()
            )
        }
        let cardRect = CGRect(
            x: usesUniformPadding ? (canvasSize.width - cardSize.width) / 2
                : ((canvasSize.width - cardSize.width) / 2).rounded(),
            y: usesUniformPadding ? (canvasSize.height - cardSize.height) / 2
                : ((canvasSize.height - cardSize.height) / 2).rounded(),
            width: cardSize.width,
            height: cardSize.height
        )
        let cardCornerRadius = style.cornerRadius * minDimension

        var bubbleRect = CGRect.zero
        var bubbleCornerRadius: CGFloat = 0
        if includeBubble, style.camera.isVisible {
            let baseSize = max(24, style.camera.size * minDimension)
            let ratio = style.camera.aspectRatio.ratio
            let bubbleWidth = (baseSize * sqrt(ratio)).rounded()
            let bubbleHeight = (baseSize / sqrt(ratio)).rounded()
            var center = CGPoint(
                x: style.camera.center.x * canvasSize.width,
                y: style.camera.center.y * canvasSize.height
            )
            center.x = min(max(center.x, bubbleWidth / 2), canvasSize.width - bubbleWidth / 2)
            center.y = min(max(center.y, bubbleHeight / 2), canvasSize.height - bubbleHeight / 2)
            bubbleRect = CGRect(
                x: center.x - bubbleWidth / 2,
                y: center.y - bubbleHeight / 2,
                width: bubbleWidth,
                height: bubbleHeight
            )
            bubbleCornerRadius = max(4, style.camera.roundness * min(bubbleWidth, bubbleHeight))
        }

        var contentFillSize = cardRect.size
        if hasContentCrop {
            // Draw the full source behind the card at the scale where the
            // selected source rectangle fills it exactly. The viewport anchor
            // then positions that rectangle without touching other layers.
            if usesUniformPadding {
                // Even-pixel export rounding can slightly change the canvas
                // aspect. Fill that fraction of a pixel instead of exposing
                // wallpaper at zero padding or stretching the source.
                let fillHeight = max(
                    cardRect.height / crop.height,
                    cardRect.width / (crop.width * sourceAspect)
                )
                contentFillSize = CGSize(width: sourceAspect * fillHeight, height: fillHeight)
            } else {
                contentFillSize = CGSize(
                    width: cardRect.width / crop.width,
                    height: cardRect.height / crop.height
                )
            }
        } else if let contentAspect, contentAspect > 0, cardRect.height > 0 {
            let fillHeight = max(cardRect.height, cardRect.width / contentAspect)
            contentFillSize = CGSize(
                width: contentAspect * fillHeight,
                height: fillHeight
            )
        }

        return RecordingStudioLayout(
            canvasSize: canvasSize,
            cardRect: cardRect,
            cardCornerRadius: cardCornerRadius,
            bubbleRect: bubbleRect,
            bubbleCornerRadius: bubbleCornerRadius,
            contentFillSize: contentFillSize
        )
    }

    /// Where the (zoomed) screen video draws, given a viewport frame. The
    /// video fills the card at magnification 1 (aspect-filling when the
    /// content and card aspects differ); zooming grows the draw rect while
    /// keeping the viewport anchor point pinned to the card center.
    func frameRect(for viewport: ViewportFrame) -> CGRect {
        let drawWidth = contentFillSize.width * viewport.magnification
        let drawHeight = contentFillSize.height * viewport.magnification
        return CGRect(
            x: cardRect.midX - viewport.anchor.x * drawWidth,
            y: cardRect.midY - viewport.anchor.y * drawHeight,
            width: drawWidth,
            height: drawHeight
        )
    }
}

/// Maps the existing zoom camera into a manually selected source crop. The
/// card's base draw size already makes the crop fill at magnification 1; this
/// only supplies the crop center and keeps later zoom anchors inside it.
nonisolated enum RecordingVideoCropGeometry {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func normalized(_ requested: CGRect) -> CGRect {
        let crop = requested.standardized.intersection(unit)
        guard crop.width > 0.0001, crop.height > 0.0001 else { return unit }
        return crop
    }

    static func isCropped(_ requested: CGRect) -> Bool {
        let crop = normalized(requested)
        return crop.minX > 0.0005
            || crop.minY > 0.0005
            || crop.width < 0.999
            || crop.height < 0.999
    }

    static func viewport(_ base: ViewportFrame, crop requested: CGRect) -> ViewportFrame {
        let crop = normalized(requested)
        guard isCropped(crop) else { return base }

        let magnification = max(base.magnification, 1)
        let center = CGPoint(x: crop.midX, y: crop.midY)
        let halfWidth = crop.width / CGFloat(2 * magnification)
        let halfHeight = crop.height / CGFloat(2 * magnification)
        let target = CGPoint(
            x: min(max(base.anchor.x, crop.minX + halfWidth), crop.maxX - halfWidth),
            y: min(max(base.anchor.y, crop.minY + halfHeight), crop.maxY - halfHeight)
        )
        // At 1x the manual crop owns the camera center. Blend quickly into
        // the existing smoothed zoom anchor as the zoom begins.
        let progress = CGFloat(min(max((magnification - 1) / 0.12, 0), 1))
        return ViewportFrame(
            magnification: magnification,
            anchor: CGPoint(
                x: center.x + (target.x - center.x) * progress,
                y: center.y + (target.y - center.y) * progress
            )
        )
    }
}
