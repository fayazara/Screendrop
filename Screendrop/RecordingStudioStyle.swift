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

/// The talking-head camera composited with the recording.
struct RecordingCameraBubbleSettings: Equatable {
    var isVisible = true
    /// Corner rounding of rectangular cameras as a fraction of their
    /// shorter side; 0.5 rounds them into a pill.
    var roundness: CGFloat = 0.25
    /// The arrangement outside any layout cue on the timeline.
    var layout = RecordingCameraLayout()
    /// A corner camera steps back a little while the screen is zoomed, so
    /// the eye goes where the action is.
    var shrinksDuringZoom = true
    /// How much smaller it gets once a zoom lands, as a fraction of its size.
    var zoomShrinkAmount: CGFloat = RecordingCameraBubbleSettings.defaultZoomShrinkAmount
    /// Face light and skin smoothing, applied to the camera's picture.
    var beauty = StudioCameraBeauty()

    static let defaultZoomShrinkAmount: CGFloat = 0.1
    static let zoomShrinkAmountRange: ClosedRange<CGFloat> = 0.05...0.4
}

struct RecordingEditDocument: Codable, Equatable {
    var formatVersion = 5
    var style: StoredRecordingStudioStyle
    var zoomEnabled: Bool
    var zoomCues: [ZoomCue]
    /// Stretches shown in a layout other than the style's default. Optional
    /// so projects saved before camera layouts decode with none.
    var cameraLayoutCues: [RecordingCameraLayoutCue]?
    /// Text over the recording and pixelated regions of it, both on the
    /// source clock. Optional so older projects decode with none.
    var textOverlays: [RecordingTextOverlay]?
    var redactions: [RecordingRedaction]?
    /// Images and GIFs over the canvas (source clock) and audio clips
    /// under the video (edited clock); their files live in the project's
    /// media folder.
    var imageOverlays: [RecordingImageOverlay]?
    var audioClips: [RecordingAudioClip]?
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
    /// The "2× ›››" badge over sped-up clips. Opt-in: projects saved before
    /// it existed, and new ones, decode with it off.
    var showsSpeedBadge: Bool?
    var speedBadgePlacement: RecordingKeystrokePlacement?
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
        case cameraLayoutCues
        case textOverlays
        case redactions
        case imageOverlays
        case audioClips
        case clips
        case trimStart
        case trimEnd
        case exportSettings
        case showsClickEffects
        case showsKeystrokes
        case keystrokePlacement
        case showsSpeedBadge
        case speedBadgePlacement
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
        cameraLayoutCues: [RecordingCameraLayoutCue]? = nil,
        textOverlays: [RecordingTextOverlay]? = nil,
        redactions: [RecordingRedaction]? = nil,
        imageOverlays: [RecordingImageOverlay]? = nil,
        audioClips: [RecordingAudioClip]? = nil,
        clipTimeline: RecordingClipTimeline? = nil,
        trimSelection: VideoTrimSelection? = nil,
        exportSettings: VideoCompressionSettings? = nil,
        showsClickEffects: Bool? = nil,
        showsKeystrokes: Bool? = nil,
        keystrokePlacement: RecordingKeystrokePlacement? = nil,
        showsSpeedBadge: Bool? = nil,
        speedBadgePlacement: RecordingKeystrokePlacement? = nil,
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
        self.cameraLayoutCues = cameraLayoutCues
        self.textOverlays = textOverlays
        self.redactions = redactions
        self.imageOverlays = imageOverlays
        self.audioClips = audioClips
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
        self.showsSpeedBadge = showsSpeedBadge
        self.speedBadgePlacement = speedBadgePlacement
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
        guard let videoCropRect else { return CropGeometry.unit }
        let crop = videoCropRect.standardized.intersection(CropGeometry.unit)
        guard crop.width > 0.0001, crop.height > 0.0001 else {
            return CropGeometry.unit
        }
        return crop
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        style = try container.decode(StoredRecordingStudioStyle.self, forKey: .style)
        zoomEnabled = try container.decodeIfPresent(Bool.self, forKey: .zoomEnabled) ?? true
        zoomCues = try container.decodeIfPresent([ZoomCue].self, forKey: .zoomCues) ?? []
        cameraLayoutCues = try container.decodeIfPresent(
            [RecordingCameraLayoutCue].self,
            forKey: .cameraLayoutCues
        )
        textOverlays = try container.decodeIfPresent([RecordingTextOverlay].self, forKey: .textOverlays)
        redactions = try container.decodeIfPresent([RecordingRedaction].self, forKey: .redactions)
        imageOverlays = try container.decodeIfPresent([RecordingImageOverlay].self, forKey: .imageOverlays)
        audioClips = try container.decodeIfPresent([RecordingAudioClip].self, forKey: .audioClips)
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
        showsSpeedBadge = try container.decodeIfPresent(Bool.self, forKey: .showsSpeedBadge)
        speedBadgePlacement = try container.decodeIfPresent(
            RecordingKeystrokePlacement.self,
            forKey: .speedBadgePlacement
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
        try container.encodeIfPresent(cameraLayoutCues, forKey: .cameraLayoutCues)
        try container.encodeIfPresent(textOverlays, forKey: .textOverlays)
        try container.encodeIfPresent(redactions, forKey: .redactions)
        try container.encodeIfPresent(imageOverlays, forKey: .imageOverlays)
        try container.encodeIfPresent(audioClips, forKey: .audioClips)
        try container.encodeIfPresent(clips, forKey: .clips)
        try container.encodeIfPresent(trimStart, forKey: .trimStart)
        try container.encodeIfPresent(trimEnd, forKey: .trimEnd)
        try container.encodeIfPresent(exportSettings, forKey: .exportSettings)
        try container.encodeIfPresent(showsClickEffects, forKey: .showsClickEffects)
        try container.encodeIfPresent(showsKeystrokes, forKey: .showsKeystrokes)
        try container.encodeIfPresent(keystrokePlacement, forKey: .keystrokePlacement)
        try container.encodeIfPresent(showsSpeedBadge, forKey: .showsSpeedBadge)
        try container.encodeIfPresent(speedBadgePlacement, forKey: .speedBadgePlacement)
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
    /// Optional so projects saved before cursor styles decode to the macOS
    /// arrow; nil while it is the macOS arrow.
    var cursorStyle: RecordingCursorStyle?
    /// Nil unless the vector pointers are inverted.
    var invertsCursor: Bool?
    var cameraIsVisible: Bool
    var cameraCenterX: Double
    var cameraCenterY: Double
    var cameraSize: Double
    var cameraRoundness: Double
    /// Optional so projects saved before camera layouts migrate their
    /// free-form bubble. The legacy center and size are still written for
    /// older builds.
    var cameraLayout: RecordingCameraLayout?
    /// Optional so projects saved before it decode with it on.
    var cameraShrinksDuringZoom: Bool?
    var cameraZoomShrinkAmount: Double?
    /// Optional so projects saved before touch-ups decode with them off;
    /// nil while off.
    var cameraFaceLight: Double?
    var cameraSkinSmoothing: Double?

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
        cursorStyle = style.cursorStyle == .system ? nil : style.cursorStyle
        invertsCursor = style.invertsCursor ? true : nil
        cameraIsVisible = style.camera.isVisible
        let legacyCenter = style.camera.layout.legacyCenter
        cameraCenterX = Double(legacyCenter.x)
        cameraCenterY = Double(legacyCenter.y)
        cameraSize = style.camera.layout.size
        cameraRoundness = Double(style.camera.roundness)
        cameraLayout = style.camera.layout
        cameraShrinksDuringZoom = style.camera.shrinksDuringZoom ? nil : false
        cameraZoomShrinkAmount = style.camera.zoomShrinkAmount == RecordingCameraBubbleSettings.defaultZoomShrinkAmount
            ? nil
            : Double(style.camera.zoomShrinkAmount)
        cameraFaceLight = style.camera.beauty.faceLight > 0 ? Double(style.camera.beauty.faceLight) : nil
        cameraSkinSmoothing = style.camera.beauty.skinSmoothing > 0 ? Double(style.camera.beauty.skinSmoothing) : nil
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
            cursorStyle: cursorStyle ?? .system,
            invertsCursor: invertsCursor ?? false,
            camera: RecordingCameraBubbleSettings(
                isVisible: cameraIsVisible,
                // A legacy circle becomes the circle shape; rectangular
                // layouts get the default rounding instead of a pill.
                roundness: CGFloat(cameraLayout == nil && cameraRoundness >= 0.49 ? 0.25 : cameraRoundness),
                layout: cameraLayout ?? .migrated(
                    center: CGPoint(x: cameraCenterX, y: cameraCenterY),
                    size: cameraSize,
                    roundness: cameraRoundness
                ),
                shrinksDuringZoom: cameraShrinksDuringZoom ?? true,
                zoomShrinkAmount: cameraZoomShrinkAmount.map {
                    min(max(CGFloat($0), RecordingCameraBubbleSettings.zoomShrinkAmountRange.lowerBound),
                        RecordingCameraBubbleSettings.zoomShrinkAmountRange.upperBound)
                } ?? RecordingCameraBubbleSettings.defaultZoomShrinkAmount,
                beauty: StudioCameraBeauty(
                    faceLight: CGFloat(min(max(cameraFaceLight ?? 0, 0), 1)),
                    skinSmoothing: CGFloat(min(max(cameraSkinSmoothing ?? 0, 0), 1))
                )
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
    var cursorStyle = RecordingCursorStyle.system
    /// Black vector pointers with a white outline.
    var invertsCursor = false
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
/// All rects are in the given canvas space with a top-left origin. `make`
/// produces the resting card; a camera layout frame then moves the card and
/// places the camera (RecordingCameraLayoutResolver).
nonisolated struct RecordingStudioLayout: Sendable, Equatable {
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
    /// Source region the layout frames, before any animated zoom.
    var contentCropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Set by a camera layout frame; the resting layout shows the screen
    /// and no camera until a frame is applied.
    var screenOpacity: CGFloat = 1
    var cameraOpacity: CGFloat = 1
    /// How far the camera is cut out of its background; see
    /// RecordingCameraLayoutFrame.cameraCutout.
    var cameraCutout: CGFloat = 0

    /// How content occupies a card whose aspect differs from the video's.
    enum ContentMode: Sendable {
        /// Aspect-fill: content covers the card and gets cropped.
        case fill
        /// Aspect-fit: the card itself shrinks to the content's aspect so
        /// the whole recording stays visible.
        case fit
    }

    /// Gap kept between a corner camera and the edge of the card.
    static func bubbleMargin(forMinDimension minDimension: CGFloat) -> CGFloat {
        (minDimension * 0.03).rounded()
    }

    static func make(
        canvasSize: CGSize,
        style: RecordingStudioStyle,
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

        var contentFillSize = cardRect.size
        if hasContentCrop {
            // Draw the full source behind the card at the scale where the
            // selected source rectangle fills it exactly. The viewport anchor
            // then positions that rectangle without touching other layers.
            // Pixel rounding can slightly change the card's aspect. Use one
            // uniform source scale for every output mode, including Fit.
            let fillHeight = max(
                cardRect.height / crop.height,
                cardRect.width / (crop.width * sourceAspect)
            )
            contentFillSize = CGSize(width: sourceAspect * fillHeight, height: fillHeight)
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
            bubbleRect: .zero,
            bubbleCornerRadius: 0,
            contentFillSize: contentFillSize,
            contentCropRect: crop,
            cameraOpacity: 0
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
