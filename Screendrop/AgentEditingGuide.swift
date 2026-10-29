//
//  AgentEditingGuide.swift
//  Screendrop
//
//  The reference `get_editing_guide` returns. Enum values are read from
//  the types themselves and examples are encoded from real defaults, so the
//  guide can't drift from what the decoders accept.
//

import Foundation

@MainActor
enum AgentEditingGuide {
    static var text: String {
        var sections: [String] = []

        sections.append("""
        # Screendrop editing guide

        Times are seconds. Zooms, text, redactions, camera layouts, captions and images are on the \
        source clock (raw recording); audio clips are on the edited clock. Tools convert for you when \
        you pass "clock": "edited". Positions are normalized 0...1 from the top-left; points are \
        [x, y], rects are [[x, y], [width, height]], colors are {red, green, blue, alpha} in 0...1.
        Text and image positions are on the output canvas; redaction rects and zoom points are on the \
        recorded picture (what get_frame shows).
        """)

        sections.append("""
        ## Allowed values
        zoom.anchorMode: \(values(ZoomAnchorMode.self)) (pointerAnchor follows the cursor; pinnedAnchor frames pinnedPoint)
        text.font: \(values(RecordingTextFont.self))
        text.animationIn/animationOut.effect: \(values(RecordingTextAnimation.Effect.self))
        text.animation unit: \(values(RecordingTextAnimation.Unit.self)); order: \(values(RecordingTextAnimation.Order.self)); ease: \(values(RecordingTextAnimation.Ease.self))
        redaction.style: \(values(RecordingRedaction.Style.self))
        camera layout kind: \(values(RecordingCameraLayout.Kind.self))
        camera layout corner: \(values(RecordingCameraLayout.Corner.self)); shape: \(values(RecordingCameraLayout.Shape.self)); side: \(values(RecordingCameraLayout.Side.self)); placement: \(values(RecordingCameraLayout.Placement.self)); screenFit: \(values(RecordingCameraLayout.ScreenFit.self))
        keystrokePlacement / speedBadgePlacement: \(values(RecordingKeystrokePlacement.self))
        exportAspect: \(values(ExportAspectPreset.self))
        exportAspectMode: \(values(ExportAspectContentMode.self))
        style.cursorStyle: \(values(RecordingCursorStyle.self))
        exportSettings.quality: \(values(VideoCompressionQuality.self))
        exportSettings.speed: \(values(VideoCompressionSpeed.self))
        exportSettings.codec: \(values(VideoCompressionCodec.self))
        exportSettings.resolution: \(values(VideoCompressionResolution.self))
        exportSettings.container: \(values(VideoExportContainer.self))
        exportSettings.frameRate: \(values(VideoExportFrameRate.self))
        audioExportFormat (export_audio format): \(values(RecordingAudioFormat.self))
        """)

        sections.append("""
        ## Project fields (update_project)
        style: background, padding, cornerRadius, shadow, cursorScale, hidesCursor, cursorStyle, \
        invertsCursor, cameraIsVisible, cameraRoundness, cameraLayout, cameraShrinksDuringZoom, \
        cameraZoomShrinkAmount, cameraFaceLight, cameraSkinSmoothing.
        Toggles: zoomEnabled, showsClickEffects, showsKeystrokes, showsSpeedBadge, showsSubtitles, \
        subtitleWordHighlight. Subtitle look: subtitleVerticalPosition (0.1-0.95), subtitleFontScale (0.6-1.8).
        Output: exportAspect, exportAspectMode, videoCropRect (normalized crop of the recording), \
        audioVolume (0-2), exportSettings.
        clips: the ordered list of {sourceStart, sourceEnd, speed} that makes up the edited movie. \
        Replacing it with one clip covering the whole recording undoes every cut.
        """)

        sections.append("## Item defaults (fields you may set)\n" + examples())
        sections.append("## Backgrounds (set style.background to one of these)\n" + backgrounds())
        return sections.joined(separator: "\n\n")
    }

    private static func values<T: CaseIterable & RawRepresentable>(_ type: T.Type) -> String where T.RawValue == String {
        T.allCases.map(\.rawValue).joined(separator: ", ")
    }

    private static func examples() -> String {
        func line(_ label: String, _ value: some Encodable) -> String {
            guard var json = try? JSONValue(encoding: value) else { return "" }
            json = json.merging(["id": .null])
            return "\(label): \(json.compactString)"
        }
        return [
            line("zoom", ZoomCue(start: 0, end: 3)),
            line("text", RecordingTextOverlay(start: 0, end: 3)),
            line("redaction", RecordingRedaction(start: 0, end: 3)),
            line("camera_layout", RecordingCameraLayoutCue(start: 0, end: 3, layout: RecordingCameraLayout())),
            line("caption", RecordingSubtitleCue(start: 0, end: 3, text: "Hello")),
            line("exportSettings", VideoCompressionSettings()),
        ].joined(separator: "\n")
    }

    private static func backgrounds() -> String {
        var options: [String] = []
        if let none = try? JSONValue(encoding: StoredBackgroundStyle.none) {
            options.append("none: \(none.compactString)")
        }
        let solid = StoredBackgroundStyle.solid(StoredColor(
            AnnotationBackgroundColor("custom", title: "Custom", red: 0.08, green: 0.09, blue: 0.12)
        ))
        if let json = try? JSONValue(encoding: solid) {
            options.append("solid (any RGB): \(json.compactString)")
        }
        for gradient in AnnotationBackgroundGradient.presets {
            if let json = try? JSONValue(encoding: StoredBackgroundStyle.gradient(StoredGradient(gradient))) {
                options.append("\(gradient.title): \(json.compactString)")
            }
        }
        return options.joined(separator: "\n")
    }
}

extension JSONValue {
    nonisolated var compactString: String {
        guard let data = try? JSONValue.encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
