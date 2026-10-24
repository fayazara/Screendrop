//
//  RecordingStudioInspector.swift
//  Screendrop
//
//  The Studio inspector is one short list: saved styles, the canvas shape,
//  the frame around the video, each feature as a section whose switch
//  folds its few controls away, and the sound. The two things too big to
//  sit in the list get a page of their own - the captions editor, and a
//  zoom clicked on the timeline - with a back link to the list. Pages swap
//  in place with no transition. Export and Share stay pinned below.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension ZoomAnchorMode {
    var inspectorTitle: String {
        switch self {
        case .pointerAnchor: "Pointer"
        case .smartAnchor: "Smart"
        case .pinnedAnchor: "Fixed"
        }
    }
}

private enum StudioTranscriptTab: Hashable {
    case captions
    case edit
}

/// A page too big for the list, opened from its section.
private enum StudioInspectorPage: Hashable {
    case captions

    var title: String { "Captions" }
    var systemImage: String { "captions.bubble" }
}

/// What the inspector is showing, so the scroll position starts over when
/// it changes.
private enum StudioInspectorContent: Hashable {
    case look
    case page(StudioInspectorPage)
    case zoom(UUID)
    case layout(UUID)
    case text(UUID)
    case redaction(UUID)
    case image(UUID)
    case audio(UUID)
}

struct StudioInspector: View {
    @Bindable var model: RecordingStudioModel
    @State private var wallpaperStore = AnnotationWallpaperStore.shared
    @State private var stylePresetStore = RecordingStudioStylePresetStore.shared
    @State private var transcriptTab: StudioTranscriptTab = .captions
    @State private var isAudioExportOptionsPresented = false
    @State private var page: StudioInspectorPage?
    /// Sections folded to their one-line summary, kept across projects and
    /// launches. Comma-separated section names; everything else is open.
    @AppStorage("StudioInspectorFoldedSections") private var foldedSectionNames = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                switch content {
                case .look:
                    lookPage
                case .page(let page):
                    featurePage(page)
                case .zoom:
                    if let cue = model.selectedCue {
                        selectedZoomPage(for: cue)
                    }
                case .layout:
                    if let cue = model.selectedLayoutCue {
                        selectedLayoutPage(for: cue)
                    }
                case .text:
                    if let text = model.selectedText {
                        selectedTextPage(for: text)
                    }
                case .redaction:
                    if let redaction = model.selectedRedaction {
                        selectedRedactionPage(for: redaction)
                    }
                case .image:
                    if let image = model.selectedImage {
                        selectedImagePage(for: image)
                    }
                case .audio:
                    if let clip = model.selectedAudioClip {
                        selectedAudioPage(for: clip)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 12)
        }
        // Each page opens at its top.
        .id(content)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectSoftIfAvailable()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Backed like the panel, so the list never shows through the
            // buttons as it scrolls.
            StudioActionFooter(model: model)
                .background(sidebarBackground)
        }
        .background(sidebarBackground)
        .onChange(of: availablePages) { _, available in
            // A page whose feature went away (its only sped-up clip was
            // reset, say) folds back to the Look.
            if let page, !available.contains(page) {
                self.page = nil
            }
        }
        .inspectorColumnWidth(
            min: InspectorMetrics.columnMinWidth,
            ideal: InspectorMetrics.columnIdealWidth,
            max: InspectorMetrics.columnMaxWidth
        )
        .frame(
            minWidth: InspectorMetrics.columnMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .task {
            await wallpaperStore.reload()
        }
    }

    /// A selected zoom wins: clicking one is always a request to edit it.
    private var content: StudioInspectorContent {
        if let cue = model.selectedCue { return .zoom(cue.id) }
        if let cue = model.selectedLayoutCue { return .layout(cue.id) }
        if let text = model.selectedText { return .text(text.id) }
        if let redaction = model.selectedRedaction { return .redaction(redaction.id) }
        if let image = model.selectedImage { return .image(image.id) }
        if let clip = model.selectedAudioClip { return .audio(clip.id) }
        if let page, availablePages.contains(page) { return .page(page) }
        return .look
    }

    private var hasCaptions: Bool {
        model.canTranscribe || model.hasSubtitles
    }

    private var availablePages: Set<StudioInspectorPage> {
        hasCaptions ? [.captions] : []
    }

    private func open(_ page: StudioInspectorPage) {
        self.page = page
    }

    // MARK: Look

    @ViewBuilder
    private var lookPage: some View {
        RecordingStudioStyleStrip(model: model, presetStore: stylePresetStore)

        InspectorSection("Canvas") {
            canvasControls
        }

        InspectorSection(
            "Frame",
            summary: frameSummary,
            isExpanded: expansion("Frame"),
            accessory: {
                if !usesDefaultLayout {
                    InspectorResetButton(help: "Reset padding, corners and shadow") {
                        withAnimation(.morphIfAllowed) {
                            model.style.padding = 0.06
                            model.style.cornerRadius = 0.02
                            model.style.shadow = 0.45
                        }
                    }
                    .transition(.blurPop)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorBackgroundRow(
                    style: $model.style.background,
                    wallpaperStore: wallpaperStore,
                    onPickWallpaper: pickWallpaper,
                    onPreview: { model.previewBackground($0, isHovering: $1) },
                    onEndPreview: { model.previewBackground = nil }
                )
                frameControls
            }
        }

        featureSections

        audioSection
    }

    /// Everything drawn over or done to the video. Each switch folds its
    /// section's controls away, so what is off costs one line.
    @ViewBuilder
    private var featureSections: some View {
        if model.hasCameraVideo {
            InspectorSection(
                "Camera",
                summary: model.style.camera.isVisible ? cameraSummary : nil,
                isOn: $model.style.camera.isVisible,
                toggleTitle: "Show camera",
                isExpanded: expansion("Camera")
            ) {
                cameraControls
            }
        }

        InspectorSection(
            "Zoom",
            summary: model.zoomEnabled ? zoomSummary : nil,
            isOn: $model.zoomEnabled,
            toggleTitle: "Enable zooms",
            isExpanded: expansion("Zoom")
        ) {
            zoomControls
        }

        if model.pointerIsSynthesized {
            InspectorSection(
                "Cursor",
                summary: model.style.hidesCursor ? nil : cursorSummary,
                isOn: Binding(
                    get: { !model.style.hidesCursor },
                    set: { model.style.hidesCursor = !$0 }
                ),
                toggleTitle: "Show mouse pointer",
                isExpanded: expansion("Cursor"),
                accessory: {
                    if model.style.cursorScale != RecordingStudioStyle.defaultCursorScale,
                       !model.style.hidesCursor {
                        InspectorResetButton(help: "Reset cursor size") {
                            withAnimation(.morphIfAllowed) {
                                model.style.cursorScale = RecordingStudioStyle.defaultCursorScale
                            }
                        }
                        .transition(.blurPop)
                    }
                }
            ) {
                cursorControls
            }
        }

        if hasCaptions {
            captionsSection
        }

        if model.hasKeystrokes {
            InspectorSection(
                "Keystrokes",
                summary: model.showsKeystrokes ? placementSummary(model.keystrokePlacement) : nil,
                isOn: $model.showsKeystrokes,
                toggleTitle: "Show keystrokes",
                isExpanded: expansion("Keystrokes")
            ) {
                keystrokeControls
            }
        }

        // Only offered once some clip actually plays faster than recorded.
        if model.hasSpedUpClips {
            InspectorSection(
                "Speed Badge",
                summary: model.showsSpeedBadge ? placementSummary(model.speedBadgePlacement) : nil,
                isOn: $model.showsSpeedBadge,
                toggleTitle: "Show speed badge",
                isExpanded: expansion("Speed Badge")
            ) {
                speedBadgeControls
            }
            .transition(AnyTransition(.blurReplace).combined(with: .opacity))
        }

        // Always the selected clip, or the one under the playhead, so the
        // section never comes and goes - the clip lane selects on every
        // scrub, and a section appearing would shove the list about.
        if let clip = shownClip {
            InspectorSection("Clip", summary: clipSummary(for: clip), isExpanded: expansion("Clip")) {
                clipControls(for: clip)
            }
        }
    }

    /// Captions in the list are a status and a way in: the editor itself
    /// needs the whole panel.
    private var captionsSection: some View {
        InspectorSection(
            "Captions",
            summary: captionsToggle?.wrappedValue == false ? nil : captionsSummary,
            isOn: captionsToggle,
            toggleTitle: "Show subtitles",
            isExpanded: expansion("Captions"),
            accessory: {
                if model.transcriptionState.isTranscribing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 24, height: 24)
                        .transition(.blurPop)
                }
            }
        ) {
            switch model.transcriptionState {
            case .transcribing:
                InspectorHint("Transcribing narration on this Mac…")
            case .failed(let message):
                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    InspectorHint(message, tint: .orange)
                    InspectorActionButton("Try Again", systemImage: "waveform") {
                        model.transcribe()
                    }
                }
            case .idle:
                if model.hasSubtitles {
                    InspectorActionButton(
                        "Edit \(captionsSummary ?? "Captions")",
                        systemImage: "text.bubble"
                    ) {
                        open(.captions)
                    }
                    .help("Fix lines, style the captions, or cut the video by its transcript")
                } else {
                    InspectorActionButton("Transcribe Narration", systemImage: "waveform") {
                        withAnimation(.morphIfAllowed) { model.transcribe() }
                    }
                    .help("Turn your microphone narration into subtitles, transcribed on this Mac")
                }
            }
        }
    }

    private var captionsSummary: String? {
        switch model.transcriptionState {
        case .transcribing: return "Transcribing…"
        case .failed: return "Failed"
        case .idle:
            return model.hasSubtitles
                ? "\(model.subtitleCues.count) Line\(model.subtitleCues.count == 1 ? "" : "s")"
                : "Transcribe"
        }
    }

    /// Captions have a switch only once there is something to show.
    private var captionsToggle: Binding<Bool>? {
        guard model.hasSubtitles, case .idle = model.transcriptionState else { return nil }
        return $model.showsSubtitles
    }

    // MARK: Folding

    private var foldedSections: Set<String> {
        Set(foldedSectionNames.split(separator: ",").map(String.init))
    }

    /// Whether a section is open; folding one keeps it folded next time.
    private func expansion(_ section: String) -> Binding<Bool> {
        Binding(
            get: { !foldedSections.contains(section) },
            set: { isOpen in
                var folded = foldedSections
                if isOpen { folded.remove(section) } else { folded.insert(section) }
                foldedSectionNames = folded.sorted().joined(separator: ",")
            }
        )
    }

    private var frameSummary: String {
        let background = (model.previewBackground ?? model.style.background).displayTitle
        let padding = InspectorValueFormat.percent().displayString(for: model.style.padding)
        return "\(background) · \(padding)"
    }

    /// The default layout's name and where it puts the camera.
    private var cameraSummary: String {
        let layout = model.style.camera.layout
        return switch layout.kind {
        case .pictureInPicture: "\(layout.title) · \(layout.corner.title)"
        case .cutout: "\(layout.title) · \(layout.placement.title)"
        case .screen, .camera, .split: layout.title
        }
    }

    private var zoomSummary: String {
        let count = model.zoomTimelineBlocks.count
        return count == 0 ? "None yet" : count == 1 ? "1 zoom" : "\(count) zooms"
    }

    private var cursorSummary: String {
        let size = InspectorValueFormat.magnification(fractionDigits: 1).displayString(for: model.style.cursorScale)
        return model.canShowPressEffects && model.showsClickEffects ? "\(size) · Clicks" : size
    }

    private func placementSummary(_ placement: RecordingKeystrokePlacement) -> String {
        "\(placement.isTop ? "Top" : "Bottom") \(placement.title.lowercased())"
    }

    private var audioSummary: String? {
        if let replacement = model.replacementAudio { return replacement.displayName }
        guard model.hasAudio else { return nil }
        return InspectorValueFormat.percent().displayString(for: model.audioVolume)
    }

    /// The selected clip, or else the one under the playhead.
    private var shownClip: RecordingClipSegment? {
        if let selected = model.selectedClip { return selected }
        guard let location = model.clipTimeline.location(at: model.currentTime) else {
            return model.clipTimeline.segments.first
        }
        return model.clipTimeline.segments.first { $0.id == location.segmentID }
    }

    private func clipSummary(for clip: RecordingClipSegment) -> String {
        let segments = model.clipTimeline.segments
        let speed = RecordingClipSegment.speedTitle(clip.speed)
        guard segments.count > 1,
              let index = segments.firstIndex(where: { $0.id == clip.id }) else {
            return speed
        }
        return "\(index + 1) of \(segments.count) · \(speed)"
    }

    // MARK: Pages

    /// The top of every page: a way back, the page's title, and its switch.
    private func pageHeader<Accessory: View>(
        _ title: String,
        systemImage: String,
        backTitle: String = "Look",
        isOn: Binding<Bool>? = nil,
        toggleTitle: String = "",
        onBack: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text(backTitle)
                            .font(.inspectorValue)
                    }
                    .foregroundStyle(Palette.secondaryLabel)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to \(backTitle)")
                // Escape belongs to the crop bar while cropping.
                .keyboardShortcut(model.isCroppingVideo ? nil : .cancelAction)

                Spacer(minLength: 0)

                accessory()
            }

            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.label)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.label)
                Spacer(minLength: 0)
                if let isOn {
                    InspectorToggle(
                        toggleTitle.isEmpty ? title : toggleTitle,
                        isOn: Binding(
                            get: { isOn.wrappedValue },
                            set: { value in
                                withAnimation(.morphIfAllowed) { isOn.wrappedValue = value }
                            }
                        ),
                        size: .regular
                    )
                }
            }
        }
        .padding(.horizontal, InspectorMetrics.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// A page's controls. A feature that is switched off keeps its controls
    /// on show, dimmed, so the page still says what turning it on would do.
    private func pageBody<Content: View>(
        isActive: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, InspectorMetrics.horizontalPadding)
            .padding(.top, InspectorMetrics.headerSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!isActive)
            .opacity(isActive ? 1 : 0.45)
    }

    private func backToLook() {
        page = nil
    }

    @ViewBuilder
    private func featurePage(_ page: StudioInspectorPage) -> some View {
        switch page {
        case .captions:
            pageHeader(
                page.title,
                systemImage: page.systemImage,
                isOn: captionsToggle,
                toggleTitle: "Show subtitles",
                onBack: backToLook
            ) {
                if model.transcriptionState.isTranscribing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 24, height: 24)
                }
            }
            pageBody(isActive: captionsToggle?.wrappedValue ?? true) {
                transcriptionControls
            }
        }
    }

    private var audioSection: some View {
        InspectorSection(
            "Audio",
            summary: audioSummary,
            isExpanded: expansion("Audio"),
            accessory: {
                if model.replacementAudio != nil {
                    Group {
                        if model.hasRecordedAudio {
                            InspectorResetButton(help: "Use the recorded audio again") {
                                withAnimation(.morphIfAllowed) { model.removeReplacementAudio() }
                            }
                        } else {
                            InspectorClearButton(help: "Remove this audio") {
                                withAnimation(.morphIfAllowed) { model.removeReplacementAudio() }
                            }
                        }
                    }
                    .transition(.blurPop)
                }
            }
        ) {
            audioControls
        }
    }

    // MARK: Style

    private var canvasControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSegmented(
                options: ExportAspectPreset.allCases,
                isSelected: { $0 == model.exportAspect },
                onTap: { aspect in
                    withAnimation(.morphIfAllowed) { model.exportAspect = aspect }
                },
                label: { preset in
                    Text(preset.title)
                        .font(.inspectorSegment)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help(preset.help)
                }
            )

            if model.exportAspect != .original {
                InspectorSegmented(
                    options: ExportAspectContentMode.allCases,
                    isSelected: { $0 == model.exportAspectMode },
                    onTap: { mode in
                        withAnimation(.morphIfAllowed) { model.exportAspectMode = mode }
                    },
                    label: { mode in
                        Text(mode.title)
                            .font(.inspectorSegment)
                            .help(mode.help)
                    }
                )
                .transition(AnyTransition(.blurReplace).combined(with: .move(edge: .top)))
            }
        }
    }

    private func pickWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Video Background Wallpaper"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            wallpaperStore.addRecentWallpaper(url)
            model.style.background = .customWallpaper(AnnotationCustomWallpaper(url: url))
        }
    }

    private var frameControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorFieldPair {
                InspectorSlider(
                    "Padding",
                    value: $model.style.padding,
                    range: 0...0.18,
                    format: .percent()
                )
            } trailing: {
                InspectorSlider(
                    "Corners",
                    value: $model.style.cornerRadius,
                    range: 0...0.08,
                    format: .percent()
                )
            }

            InspectorHalfField {
                InspectorSlider(
                    "Shadow",
                    value: $model.style.shadow,
                    range: 0...1,
                    format: .percent()
                )
                // The shadow falls on the background; with none there is
                // nothing for it to fall on.
                .disabled(model.style.background == .none)
                .opacity(model.style.background == .none ? 0.4 : 1)
            }
        }
    }

    /// The default layout. Cues on the timeline's Layout lane switch to
    /// another one for part of the video.
    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupSpacing) {
            StudioCameraLayoutPicker(model: model, layout: model.style.camera.layout) { layout, isContinuous in
                if isContinuous {
                    model.style.camera.layout = layout
                } else {
                    withAnimation(.morphQuickIfAllowed) { model.style.camera.layout = layout }
                }
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Touch up")
                InspectorFieldPair {
                    InspectorSlider(
                        "Face light",
                        value: $model.style.camera.beauty.faceLight,
                        range: 0...1,
                        format: .percent()
                    )
                    .help("Brightens the face's shadows and midtones, like a soft light in front of you")
                } trailing: {
                    InspectorSlider(
                        "Smooth skin",
                        value: $model.style.camera.beauty.skinSmoothing,
                        range: 0...1,
                        format: .percent()
                    )
                    .help("Evens out skin and softens blemishes, keeping eyes, brows and lips sharp")
                }
            }
        }
    }

    // MARK: Layout cue

    private func selectedLayoutPage(for selected: RecordingCameraLayoutCue) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(
                "Layout",
                systemImage: selected.layout.systemImage,
                backTitle: page?.title ?? "Look",
                onBack: {
                    model.selectedLayoutCueID = nil
                }
            ) {
                InspectorIconButton(systemName: "trash", help: "Remove Layout") {
                    withAnimation(.morphIfAllowed) { model.removeLayoutCue(id: selected.id) }
                }
            }

            pageBody(isActive: model.showsCameraLayer) {
                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    if !model.showsCameraLayer {
                        InspectorHint("The camera is turned off for this recording.")
                    }
                    StudioCameraLayoutPicker(model: model, layout: selected.layout) { layout, isContinuous in
                        var updated = selected
                        updated.layout = layout
                        if isContinuous {
                            model.resizeLayoutCue(updated)
                        } else {
                            model.updateLayoutCue(updated, actionName: "Change Layout")
                        }
                    }
                    InspectorHint("Morphs in at the start of this stretch and back to the default at its end.")
                }
            }
        }
    }

    // MARK: Text and pixelate

    private func selectedTextPage(for text: RecordingTextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(
                "Text",
                systemImage: "textformat",
                backTitle: page?.title ?? "Look",
                onBack: { model.selectedTextID = nil }
            ) {
                InspectorIconButton(systemName: "trash", help: "Remove Text") {
                    withAnimation(.morphIfAllowed) { model.removeText(id: text.id) }
                }
            }

            pageBody {
                StudioTextInspectorControls(model: model, text: text)
            }
        }
    }

    private func selectedRedactionPage(for redaction: RecordingRedaction) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(
                redaction.style.title,
                systemImage: redaction.style.systemImage,
                backTitle: page?.title ?? "Look",
                onBack: { model.selectedRedactionID = nil }
            ) {
                InspectorIconButton(systemName: "trash", help: "Remove \(redaction.style.title)") {
                    withAnimation(.morphIfAllowed) { model.removeRedaction(id: redaction.id) }
                }
            }

            pageBody {
                StudioRedactionInspectorControls(model: model, redaction: redaction)
            }
        }
    }

    private func selectedImagePage(for image: RecordingImageOverlay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(
                image.isAnimated ? "GIF" : "Image",
                systemImage: image.isAnimated ? "photo.stack" : "photo",
                backTitle: page?.title ?? "Look",
                onBack: { model.selectedImageID = nil }
            ) {
                InspectorIconButton(systemName: "trash", help: "Remove Image") {
                    withAnimation(.morphIfAllowed) { model.removeImage(id: image.id) }
                }
            }

            pageBody {
                StudioImageInspectorControls(model: model, image: image)
            }
        }
    }

    private func selectedAudioPage(for clip: RecordingAudioClip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(
                clip.displayName,
                systemImage: "music.note",
                backTitle: page?.title ?? "Look",
                onBack: { model.selectedAudioClipID = nil }
            ) {
                InspectorIconButton(systemName: "trash", help: "Remove Audio") {
                    withAnimation(.morphIfAllowed) { model.removeAudioClip(id: clip.id) }
                }
            }

            pageBody {
                StudioAudioClipInspectorControls(model: model, clip: clip)
            }
        }
    }

    // MARK: Motion

    private var zoomControls: some View {
        let pressCount = model.recordedPressTimes.count
        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            HStack(spacing: InspectorMetrics.rowSpacing) {
                InspectorActionButton("Auto Zoom", systemImage: "pointer.arrow.rays") {
                    withAnimation(.morphIfAllowed) { model.resynthesizeZoomCues() }
                }
                .disabled(pressCount == 0)
                .help(
                    pressCount == 0
                        ? "No clicks were recorded"
                        : "Turn the \(pressCount == 1 ? "recorded click" : "\(pressCount) recorded clicks") into smooth camera moves"
                )

                InspectorActionButton("Add Zoom", systemImage: "plus.magnifyingglass") {
                    withAnimation(.morphIfAllowed) { model.addZoomCue(at: model.currentTime) }
                }
                .help("Add a zoom at the playhead, or drag across the zoom lane")
            }
        }
    }

    private var cursorControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            StudioCursorStylePicker(
                selection: $model.style.cursorStyle,
                inverted: model.style.invertsCursor
            )

            if let shape = model.style.cursorStyle.shape, !shape.isCircle {
                InspectorToggleRow("Invert colors", isOn: $model.style.invertsCursor)
            }

            InspectorHalfField {
                InspectorSlider(
                    "Size",
                    value: $model.style.cursorScale,
                    range: 1...4,
                    format: .magnification(fractionDigits: 1)
                )
            }

            if model.canShowPressEffects {
                InspectorToggleRow("Click highlights", isOn: $model.showsClickEffects)
            }
        }
    }

    // MARK: Selection

    /// A zoom clicked on the timeline. Its switch turns just this zoom on or
    /// off; going back lets go of the selection and returns to wherever the
    /// panel was, the Zoom page included.
    @ViewBuilder
    private func selectedZoomPage(for selected: ZoomCue) -> some View {
        pageHeader(
            "Zoom",
            systemImage: selected.anchorMode == .pinnedAnchor ? "scope" : "plus.magnifyingglass",
            backTitle: page?.title ?? "Look",
            isOn: Binding(
                get: { selected.isEnabled },
                set: { isEnabled in
                    var updated = selected
                    updated.isEnabled = isEnabled
                    model.updateZoomCue(updated)
                }
            ),
            toggleTitle: "Use this zoom",
            onBack: {
                model.selectedCueID = nil
            }
        ) {
            InspectorIconButton(systemName: "trash", help: "Remove Zoom") {
                withAnimation(.morphIfAllowed) { model.removeZoomCue(id: selected.id) }
            }
        }

        if !model.zoomEnabled {
            pageBody {
                HStack(spacing: InspectorMetrics.rowSpacing) {
                    InspectorHint("Zooms are off for this recording.")
                    Spacer(minLength: 0)
                    Button("Turn On") {
                        withAnimation(.morphIfAllowed) { model.zoomEnabled = true }
                    }
                    .buttonStyle(.plain)
                    .font(.inspectorValue)
                    .foregroundStyle(Palette.label)
                }
            }
        } else {
            pageBody(isActive: selected.isEnabled) {
                selectedZoomControls(for: selected)
            }
        }
    }

    private func selectedZoomControls(for selected: ZoomCue) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupSpacing) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Camera focus")

                InspectorSegmented(
                    options: ZoomAnchorMode.allCases,
                    isSelected: { $0 == selected.anchorMode },
                    onTap: { anchorMode in
                        var updated = selected
                        updated.anchorMode = anchorMode
                        if anchorMode == .pinnedAnchor,
                           let pointer = model.pointerLocation(at: model.currentTime) {
                            updated.pinnedPoint = pointer
                        }
                        withAnimation(.morphIfAllowed) { model.updateZoomCue(updated) }
                    },
                    label: { Text($0.inspectorTitle).font(.inspectorSegment) }
                )
            }

            if selected.anchorMode == .pinnedAnchor {
                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    zoomAmountSlider(for: selected)

                    VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                        HStack(spacing: 8) {
                            InspectorGroupLabel("Target position")
                            Spacer(minLength: 0)
                            Text(zoomTargetPositionText(selected.pinnedPoint))
                                .font(.inspectorNumeric)
                                .foregroundStyle(.tertiary)
                        }

                        RecordingZoomFocusPad(
                            position: Binding(
                                get: { selected.pinnedPoint },
                                set: { target in
                                    var updated = selected
                                    updated.pinnedPoint = target
                                    model.updateZoomCue(updated)
                                }
                            ),
                            magnification: selected.zoom
                        )
                    }

                    InspectorActionButton("Target Pointer", systemImage: "scope") {
                        guard let pointer = model.pointerLocation(at: model.currentTime) else { return }
                        var updated = selected
                        updated.pinnedPoint = pointer
                        withAnimation(.morphIfAllowed) { model.updateZoomCue(updated) }
                    }
                    .help("Aim the zoom at the pointer's position under the playhead")
                }
                .transition(AnyTransition(.blurReplace))
            } else {
                InspectorFieldPair {
                    zoomAmountSlider(for: selected)
                } trailing: {
                    InspectorSlider(
                        "Edge",
                        value: Binding(
                            get: { CGFloat(selected.boundsBias) },
                            set: { boundsBias in
                                var updated = selected
                                updated.boundsBias = Double(boundsBias)
                                model.updateZoomCue(updated)
                            }
                        ),
                        range: 0...1,
                        format: .percent()
                    )
                    .help("How much of the frame's edge stays in view while zoomed")
                }
                .transition(AnyTransition(.blurReplace))
            }
        }
    }

    private func zoomAmountSlider(for selected: ZoomCue) -> some View {
        InspectorSlider(
            "Zoom",
            value: Binding(
                get: { CGFloat(selected.zoom) },
                set: { newValue in
                    var updated = selected
                    updated.zoom = Double(newValue)
                    model.updateZoomCue(updated)
                }
            ),
            range: 1.1...3,
            format: .magnification(fractionDigits: 1)
        )
    }

    private func zoomTargetPositionText(_ position: CGPoint) -> String {
        let x = Int((position.x * 100).rounded())
        let y = Int((position.y * 100).rounded())
        return "\(x), \(y)"
    }

    /// The clip under the playhead: its speed, and deleting it.
    private func clipControls(for clip: RecordingClipSegment) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            HStack(spacing: InspectorMetrics.rowSpacing) {
                InspectorSegmented(
                    options: RecordingClipSegment.speedPresets,
                    isSelected: { abs($0 - clip.speed) < 0.001 },
                    onTap: { model.setClipSpeed($0, forClipID: clip.id) },
                    label: { speed in
                        Text(RecordingClipSegment.speedTitle(speed))
                            .font(.inspectorSegment)
                    }
                )
                .help("Speed of the clip under the playhead. Audio speeds up with it.")

                if model.canDeleteSelectedClip {
                    InspectorIconButton(systemName: "trash", help: "Delete Clip") {
                        withAnimation(.morphIfAllowed) { model.deleteSelectedClip() }
                    }
                }
            }

            if clip.speed > 1.001, !model.showsSpeedBadge {
                InspectorToggleRow(
                    "Show speed badge",
                    isOn: Binding(
                        get: { model.showsSpeedBadge },
                        set: { value in
                            withAnimation(.morphIfAllowed) { model.showsSpeedBadge = value }
                        }
                    )
                )
                .transition(AnyTransition(.blurReplace).combined(with: .opacity))
            }
        }
    }

    // MARK: Text

    private var keystrokeControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorRow("Top") {
                keystrokePlacementRow([.topLeft, .topCenter, .topRight])
            }
            InspectorRow("Bottom") {
                keystrokePlacementRow([.bottomLeft, .bottomCenter, .bottomRight])
            }
        }
        .help("Shortcuts you pressed while recording appear as a caption")
    }

    private var speedBadgeControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorRow("Top") {
                placementRow([.topLeft, .topCenter, .topRight], selection: $model.speedBadgePlacement)
            }
            InspectorRow("Bottom") {
                placementRow([.bottomLeft, .bottomCenter, .bottomRight], selection: $model.speedBadgePlacement)
            }
        }
        .help("Sped-up clips carry a “2× ›››” badge while they play")
    }

    private func placementRow(
        _ options: [RecordingKeystrokePlacement],
        selection: Binding<RecordingKeystrokePlacement>
    ) -> some View {
        InspectorSegmented(
            options: options,
            isSelected: { $0 == selection.wrappedValue },
            onTap: { selection.wrappedValue = $0 },
            label: { Text($0.title).font(.inspectorSegment) }
        )
    }

    private func keystrokePlacementRow(
        _ options: [RecordingKeystrokePlacement]
    ) -> some View {
        InspectorSegmented(
            options: options,
            isSelected: { $0 == model.keystrokePlacement },
            onTap: { model.keystrokePlacement = $0 },
            label: { Text($0.title).font(.inspectorSegment) }
        )
    }

    @ViewBuilder
    private var transcriptionControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            switch model.transcriptionState {
            case .transcribing:
                InspectorHint("Transcribing narration on this Mac…")
                    .transition(AnyTransition(.blurReplace))
            case .failed(let message):
                InspectorHint(message, tint: .orange)

                InspectorActionButton("Try Again", systemImage: "waveform") {
                    model.transcribe()
                }
            case .idle:
                if model.hasSubtitles {
                    subtitleEditor
                    transcriptionActions
                } else {
                    InspectorActionButton("Transcribe Narration", systemImage: "waveform") {
                        withAnimation(.morphIfAllowed) { model.transcribe() }
                    }
                    .help("Turn your microphone narration into subtitles, transcribed on this Mac")
                }
            }
        }
    }

    private var transcriptionActions: some View {
        HStack(spacing: InspectorMetrics.rowSpacing) {
            if model.canTranscribe {
                InspectorActionButton("Transcribe Again", systemImage: "arrow.clockwise") {
                    withAnimation(.morphIfAllowed) { model.transcribe() }
                }
            }

            InspectorActionButton("Remove", systemImage: "trash", role: .destructive) {
                withAnimation(.morphIfAllowed) { model.removeTranscription() }
            }
            .help("Remove the subtitles")
        }
    }

    private var subtitleEditor: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSegmented(
                options: [StudioTranscriptTab.captions, .edit],
                isSelected: { $0 == transcriptTab },
                onTap: { tab in
                    withAnimation(.morphQuickIfAllowed) { transcriptTab = tab }
                },
                label: { tab in
                    Text(tab == .captions ? "Captions" : "Edit Video")
                        .font(.inspectorSegment)
                }
            )

            ZStack(alignment: .top) {
                switch transcriptTab {
                case .captions:
                    captionControls
                        .transition(AnyTransition(.blurReplace))
                case .edit:
                    transcriptEditControls
                        .transition(AnyTransition(.blurReplace))
                }
            }
        }
    }

    private var captionControls: some View {
        let verticalRange = SubtitleBarStyle.verticalRange
        let fontScaleRange = SubtitleBarStyle.fontScaleRange
        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorFieldPair {
                InspectorSlider(
                    "Position",
                    value: Binding(
                        get: { CGFloat(model.subtitleStyle.verticalPosition) },
                        set: { model.subtitleStyle.verticalPosition = Double($0) }
                    ),
                    range: CGFloat(verticalRange.lowerBound)...CGFloat(verticalRange.upperBound),
                    format: .percent()
                )
            } trailing: {
                InspectorSlider(
                    "Size",
                    value: Binding(
                        get: { CGFloat(model.subtitleStyle.fontScale) },
                        set: { model.subtitleStyle.fontScale = Double($0) }
                    ),
                    range: CGFloat(fontScaleRange.lowerBound)...CGFloat(fontScaleRange.upperBound),
                    format: .magnification(fractionDigits: 1)
                )
            }

            if model.hasTranscriptWords {
                InspectorToggleRow(
                    "Highlight spoken word",
                    isOn: $model.subtitleStyle.highlightsSpokenWord
                )
            }

            subtitleList
                .help("Click a timestamp to jump there. Edit any line to fix the transcription.")
        }
    }

    @ViewBuilder
    private var transcriptEditControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if model.hasTranscriptWords {
                StudioTranscriptEditPanel(model: model)

                if model.removableFillerWordCount > 0 || model.trimmableSilenceCount > 0 {
                    HStack(spacing: InspectorMetrics.rowSpacing) {
                        if model.removableFillerWordCount > 0 {
                            InspectorActionButton(
                                "Fillers (\(model.removableFillerWordCount))",
                                systemImage: "scissors"
                            ) {
                                withAnimation(.morphIfAllowed) { model.removeFillerWords() }
                            }
                            .help("Cut every filler word, like “um” and “uh”")
                            .transition(.blurPop)
                        }

                        if model.trimmableSilenceCount > 0 {
                            InspectorActionButton(
                                "Silences (\(model.trimmableSilenceCount))",
                                systemImage: "waveform.badge.minus"
                            ) {
                                withAnimation(.morphIfAllowed) { model.trimNarrationSilences() }
                            }
                            .help("Trim long pauses in the narration")
                            .transition(.blurPop)
                        }
                    }
                }

                InspectorHint("Click a word to jump there. Shift-click to select a passage, then cut it.")
            } else {
                InspectorHint("This transcription predates editing by text. Transcribe again to cut the video from its transcript.")
            }
        }
    }

    private var subtitleList: some View {
        let shape = RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    let cues = model.subtitleCues
                    ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                        StudioSubtitleRow(
                            model: model,
                            cue: cue,
                            isActive: model.activeSubtitleCue?.id == cue.id
                        )
                        .id(cue.id)

                        if index < cues.count - 1 {
                            Divider()
                                .padding(.leading, 10)
                                .opacity(0.6)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
            .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
            .clipShape(shape)
            .onChange(of: model.activeSubtitleCue?.id) { _, activeID in
                // Follow playback through the list, but never yank the list
                // around while the user is scrubbing or editing.
                guard let activeID, model.isPlaying else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(activeID, anchor: .center)
                }
            }
        }
    }

    // MARK: Audio

    /// The round trip around tools that clean up speech but offer no API:
    /// write the cut's soundtrack out, run it through the tool, bring the
    /// result back in as the project's audio. Two buttons and a file chip -
    /// the explaining is left to tooltips.
    private var audioControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            // A silent recording has nothing to send out, but it can still
            // be given a soundtrack - so only the export half is withheld.
            if model.hasAudio {
                InspectorHalfField {
                    InspectorSlider("Volume", value: $model.audioVolume, range: 0...2, format: .percent())
                }
            }

            HStack(spacing: InspectorMetrics.rowSpacing) {
                if model.hasAudio {
                    audioExportButton
                }

                InspectorActionButton(
                    model.hasRecordedAudio ? "Replace" : "Add",
                    systemImage: "waveform.badge.plus"
                ) {
                    pickReplacementAudio()
                }
                .help(
                    model.hasRecordedAudio
                        ? "Swap in an audio file, aligned to the start of the edited timeline"
                        : "Lay an audio file over this silent recording"
                )
            }

            if let replacement = model.replacementAudio {
                replacementChip(for: replacement)
                    .transition(.blurPop)
            }

            if let message = model.replacementAudioError {
                InspectorHint(message, tint: .orange)
                    .transition(AnyTransition(.blurReplace))
            }
        }
        .motion(.morph, value: model.replacementAudio?.displayName)
    }

    /// One button carrying the whole export state, so progress and results
    /// never cost the section an extra row. The format is asked for at export
    /// time, the same way video export asks for its options.
    @ViewBuilder
    private var audioExportButton: some View {
        Group {
            switch model.audioExportState {
            case .idle:
                InspectorActionButton("Export…", systemImage: "arrow.down.circle") {
                    isAudioExportOptionsPresented = true
                }
                .help("Export just the soundtrack of the current cut")
                .popover(isPresented: $isAudioExportOptionsPresented, arrowEdge: .bottom) {
                    StudioAudioExportOptions(format: $model.audioExportFormat) {
                        isAudioExportOptionsPresented = false
                        model.exportAudio()
                    }
                }
            case .exporting(let progress):
                audioExportChrome(help: "Cancel") {
                    model.cancelAudioExport()
                } label: {
                    StudioProgressRing(progress: progress, size: 12)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.inspectorValue.monospacedDigit())
                        .contentTransition(.numericText())
                }
            case .finished(let url):
                audioExportChrome(help: "Reveal \(url.lastPathComponent) in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                    Text("Reveal")
                        .font(.inspectorValue)
                }
            case .failed(let message):
                audioExportChrome(help: message) {
                    model.exportAudio()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                    Text("Retry")
                        .font(.inspectorValue)
                }
            }
        }
        .transition(AnyTransition(.blurReplace))
        .motion(.morphQuick, value: model.audioExportState.phase)
    }

    /// Matches `InspectorActionButton`'s chrome for the export button's
    /// non-idle states, which carry richer content than a symbol and a title.
    private func audioExportChrome<Label: View>(
        help: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label()
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .inspectorField()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func replacementChip(for replacement: RecordingReplacementAudio) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.highlight)

            Text(replacement.displayName)
                .font(.inspectorValue)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let drift = model.replacementAudioDrift {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .help(
                        drift > 0
                            ? "Runs \(Self.spanText(drift)) longer than the cut - the tail is dropped"
                            : "Runs \(Self.spanText(-drift)) shorter than the cut - the end plays silent"
                    )
            }

            Text(Self.clockText(replacement.duration))
                .font(.inspectorLabel.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorField()
        .help(replacement.displayName)
    }

    private func pickReplacementAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = RecordingAudioFormat.importContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Replacement Audio"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.replaceAudio(with: url)
        }
    }

    private static func clockText(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Short spans read better in seconds than as 0:00 timecode.
    private static func spanText(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        return value < 60 ? String(format: "%.1fs", value) : clockText(value)
    }

    // MARK: Helpers

    private var usesDefaultLayout: Bool {
        abs(model.style.padding - 0.06) < 0.0001
            && abs(model.style.cornerRadius - 0.02) < 0.0001
            && abs(model.style.shadow - 0.45) < 0.0001
    }

    private var sidebarBackground: Color {
        InspectorControlPalette.panelBackground(for: colorScheme)
    }
}

private extension RecordingStudioExportState {
    /// The state's kind without its payload, so progress ticks don't count
    /// as a change of state.
    var phase: Int {
        switch self {
        case .idle: 0
        case .exporting: 1
        case .finished: 2
        case .failed: 3
        }
    }
}


// MARK: - Transcript

/// One editable subtitle line: a timestamp plus the cue text as a free-form
/// field. Hovering a row skims the preview to that cue, clicking or editing
/// commits the playhead there (paused), and the row under the playhead is
/// highlighted so the list follows the video.
private struct StudioSubtitleRow: View {
    @Bindable var model: RecordingStudioModel
    let cue: RecordingSubtitleCue
    let isActive: Bool

    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                model.seekToSubtitle(cue)
            } label: {
                Text(timestamp ?? "–:––")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(isActive ? Palette.highlight : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(editorTime == nil)
            .help(editorTime == nil ? "This subtitle's audio was cut out" : "Jump to this subtitle")

            TextField(
                "Subtitle",
                text: Binding(
                    get: { cue.text },
                    set: { model.updateSubtitleText(id: cue.id, text: $0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.inspectorValue)
            .focused($isEditing)
            .onChange(of: isEditing) { _, editing in
                // Starting to edit parks the paused preview on this cue so
                // the correction is visible in context while typing.
                if editing {
                    model.seekToSubtitle(cue)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isActive ? Palette.highlight.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .opacity(editorTime == nil ? 0.5 : 1)
        .onTapGesture {
            model.seekToSubtitle(cue)
        }
        .onHover { hovering in
            // Hover skims the paused preview like the timeline strip does;
            // leaving hands the frame back to the real playhead.
            guard !model.isPlaying, let editorTime else { return }
            if hovering {
                model.hoverPreviewTime = editorTime
            } else if model.hoverPreviewTime == editorTime {
                model.hoverPreviewTime = nil
            }
        }
    }

    /// Where this cue lands on the edited timeline; nil when its audio was
    /// cut out entirely.
    private var editorTime: TimeInterval? {
        model.editorTime(forSourceTime: cue.start)
            ?? model.editorTime(forSourceTime: (cue.start + cue.end) / 2)
    }

    private var timestamp: String? {
        guard let editorTime else { return nil }
        let total = max(0, Int(editorTime.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Descript-style transcript editing: the narration as flowing words.
/// Clicking a word jumps the playhead there, shift-clicking selects a
/// passage, and cutting the selection removes that stretch of the video.
/// Words whose footage is already cut render struck-through; filler words
/// carry a dotted underline so the bulk action's targets are visible.
private struct StudioTranscriptEditPanel: View {
    @Bindable var model: RecordingStudioModel

    @State private var selection: ClosedRange<Int>?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    transcriptFlow
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: 260)
                .background(
                    RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous)
                        .fill(InspectorControlPalette.trackFill(for: colorScheme))
                )
                .clipShape(RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous))
                .onChange(of: model.activeTranscriptWordIndex) { _, activeIndex in
                    // Follow playback through the transcript, but never yank
                    // it around while the user is selecting a passage.
                    guard let activeIndex, model.isPlaying, selection == nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(activeIndex, anchor: .center)
                    }
                }
            }

            if let selection {
                cutSelectionRow(selection)
            }
        }
        .onDeleteCommand(perform: cutSelection)
        .onExitCommand { selection = nil }
    }

    private var transcriptFlow: some View {
        let activeIndex = model.activeTranscriptWordIndex
        return TranscriptFlowLayout() {
            ForEach(model.transcriptWords.indices, id: \.self) { index in
                StudioTranscriptWordView(
                    text: model.transcriptWords[index].displayText,
                    isSelected: selection?.contains(index) ?? false,
                    isActive: index == activeIndex,
                    isCut: !model.transcriptWordSurvives(index),
                    isFiller: model.isFillerWord(index)
                ) {
                    handleTap(on: index)
                }
                .id(index)
            }
        }
    }

    private func cutSelectionRow(_ selection: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            InspectorActionButton(
                selection.count == 1 ? "Cut Word" : "Cut \(selection.count) Words",
                systemImage: "scissors",
                role: .destructive,
                action: cutSelection
            )

            InspectorClearButton(help: "Clear selection") {
                self.selection = nil
            }
        }
    }

    private func handleTap(on index: Int) {
        let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if shiftHeld, let selection {
            self.selection = min(selection.lowerBound, index)...max(selection.upperBound, index)
        } else {
            selection = index...index
            model.seekToTranscriptWord(at: index)
        }
    }

    private func cutSelection() {
        guard let selection else { return }
        model.cutTranscriptWords(in: selection)
        self.selection = nil
    }
}

/// One word in the transcript editor, drawn so the flow reads as a plain
/// paragraph: the chip's side padding doubles as the inter-word space
/// (layout spacing is zero), which also makes a multi-word selection's
/// highlight contiguous like real text selection. The font weight never
/// changes with state - a width change would reflow the whole paragraph
/// on every playback tick. Kept to plain stored values so ticks only
/// re-render the words whose state actually changed.
private struct StudioTranscriptWordView: View {
    let text: String
    let isSelected: Bool
    let isActive: Bool
    let isCut: Bool
    let isFiller: Bool
    let action: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(foreground)
            .strikethrough(isCut, color: .secondary.opacity(0.6))
            .padding(.horizontal, 1.5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private var foreground: Color {
        isCut ? Color.secondary.opacity(0.45) : Color.primary
    }

    private var background: Color {
        if isSelected {
            Palette.highlight.opacity(isCut ? 0.12 : 0.24)
        } else if isActive, !isCut {
            Palette.highlight.opacity(0.2)
        } else if isFiller, !isCut {
            Color.orange.opacity(0.16)
        } else {
            Color.clear
        }
    }
}

/// Minimal left-aligned wrapping layout for the transcript's word chips.
/// Horizontal spacing lives inside the chips (see StudioTranscriptWordView),
/// so the layout only separates lines.
private struct TranscriptFlowLayout: Layout {
    var spacingX: CGFloat = 0
    var spacingY: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacingY
                rowHeight = 0
            }
            x += size.width + spacingX
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacingY
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacingX
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Audio export options

/// Asks for the soundtrack format at export time.
private struct StudioAudioExportOptions: View {
    @Binding var format: RecordingAudioFormat
    let onExport: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        InspectorPopover(
            title: "Export Audio",
            confirmTitle: "Export",
            width: 260,
            onCancel: { dismiss() },
            onConfirm: onExport
        ) {
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorSegmented(
                    options: RecordingAudioFormat.allCases,
                    isSelected: { $0 == format },
                    onTap: { format = $0 },
                    label: { Text($0.title).font(.inspectorSegment) }
                )

                InspectorHint(
                    format == .m4a
                        ? "Compact AAC audio, accepted by most enhancement tools."
                        : "Uncompressed, for tools that accept nothing else."
                )
            }
        }
    }
}

/// One tile per arrow. Each pointer keeps its size relative to the others,
/// so the tiles compare like the video, and sits centered by what it draws:
/// the macOS arrow's image is mostly empty padding.
private struct StudioCursorStylePicker: View {
    @Binding var selection: RecordingCursorStyle
    /// Shows the vector arrows black inside a white outline.
    let inverted: Bool

    private struct Preview {
        var image: NSImage
        var size: CGSize
        /// The drawn part of the image, as fractions of its size.
        var glyph: CGRect
    }

    private struct PreviewKey: Hashable {
        var style: RecordingCursorStyle
        var inverted: Bool
    }

    private static let previews: [PreviewKey: Preview] = {
        var previews: [PreviewKey: Preview] = [:]
        for style in RecordingCursorStyle.allCases {
            for inverted in [false, true] {
                let artwork = style.shape?.artwork(inverted: inverted) ?? PointerArtworkCapture.defaultArtwork()
                if let artwork, let image = NSImage(data: artwork.imageData) {
                    previews[PreviewKey(style: style, inverted: inverted)] = Preview(
                        image: image,
                        size: CGSize(width: artwork.referenceSize.width, height: artwork.referenceSize.height),
                        glyph: opaqueBounds(of: image)
                    )
                }
            }
        }
        return previews
    }()

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
            ForEach(RecordingCursorStyle.allCases, id: \.self) { style in
                InspectorTile(title: style.title, isSelected: selection == style) {
                    selection = style
                } content: {
                    preview(style)
                }
            }
        }
    }

    private func preview(_ style: RecordingCursorStyle) -> some View {
        GeometryReader { proxy in
            if let preview = Self.previews[PreviewKey(style: style, inverted: inverted)] {
                let scale = proxy.size.width / 40
                let size = CGSize(width: preview.size.width * scale, height: preview.size.height * scale)
                let shape = style.shape
                if shape?.isCircle == true {
                    textLines(in: proxy.size)
                }
                Image(nsImage: preview.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .background {
                        if let material = shape?.material {
                            PointerMaterialView(
                                material: material,
                                diameter: size.width * PointerShape.circleRadiusRatio * 2
                            )
                        }
                    }
                    .offset(
                        x: proxy.size.width / 2 - preview.glyph.midX * size.width,
                        y: proxy.size.height / 2 - preview.glyph.midY * size.height
                    )
            }
        }
        .background(Color.primary.opacity(0.05))
    }

    /// Something for a see-through circle to show, blur, or bend.
    private func textLines(in size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: size.height * 0.1) {
            ForEach([0.62, 0.48, 0.56], id: \.self) { fraction in
                Capsule()
                    .fill(Color.primary.opacity(0.4))
                    .frame(width: size.width * fraction, height: size.height * 0.08)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private static func opaqueBounds(of image: NSImage) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                data: nil,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: cgImage.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
              ) else {
            return full
        }
        let width = cgImage.width
        let height = cgImage.height
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return full }

        // Rows run top-down in memory, matching the view's top-left origin.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] > 64 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return full }
        return CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
    }
}
