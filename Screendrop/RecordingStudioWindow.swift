//
//  RecordingStudioWindow.swift
//  Screendrop
//
//  The recording studio: a Screen Studio-style editor for screen recordings.
//  The stage shows the composited live preview (background, padded rounded
//  card, zoom-follow-pointer, draggable camera bubble) on the editor
//  workspace; the timeline dock sits under it, and the tabbed inspector runs
//  the full height beside both. Chrome is Liquid Glass throughout and moves
//  with the shared spring in Motion.swift: modes such as crop arrive as
//  floating glass bars rather than swapping the toolbar out.
//

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct RecordingStudioWindow: View {
    @Binding var url: URL?

    @State private var model: RecordingStudioModel?

    var body: some View {
        Group {
            if let model {
                RecordingStudioContent(model: model)
            } else {
                ProgressView()
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .modifier(CaptureLibraryEditorRegistration(url: url))
        .task(id: url) {
            guard let url else { return }
            model?.teardown()
            let newModel = RecordingStudioModel(url: url)
            model = newModel
            await newModel.load()
            guard !Task.isCancelled else {
                newModel.teardown()
                return
            }
            if model === newModel, newModel.isLoaded {
                CaptureShelf.shared.dismissVideo(for: newModel.sessionURL)
            }
        }
        .onDisappear {
            model?.teardown()
            model = nil
        }
    }
}

private struct RecordingStudioContent: View {
    @Bindable var model: RecordingStudioModel
    @State private var isInspectorPresented = true
    @State private var closeGuard = EditorCloseGuard()

    var body: some View {
        VStack(spacing: 0) {
            if let loadError = model.loadError {
                ContentUnavailableView(
                    "Couldn't open recording",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                stage
                StudioTimelineDock(model: model)
            }
        }
        .frame(minWidth: 980, minHeight: 720)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .inspector(isPresented: $isInspectorPresented) {
            StudioInspector(model: model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation(.morphIfAllowed) {
                        model.beginVideoCrop()
                    }
                } label: {
                    Label("Crop", systemImage: "crop")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!model.isLoaded || model.isCroppingVideo || model.exportState.isExporting)
                .help("Crop the finished video canvas")

                if model.isProject {
                    saveButton
                }

                Button {
                    withAnimation(.morphIfAllowed) {
                        isInspectorPresented.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
            }
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .onWindowChange { window in
            guard let window else {
                closeGuard.detach()
                return
            }
            configureCloseGuard()
            closeGuard.attach(to: window)
            closeGuard.refreshDocumentEdited()
        }
        .onChange(of: model.hasUnsavedChanges) {
            closeGuard.refreshDocumentEdited()
        }
        .onDeleteCommand {
            withAnimation(.morphIfAllowed) {
                if let textID = model.selectedTextID {
                    model.removeText(id: textID)
                } else if let imageID = model.selectedImageID {
                    model.removeImage(id: imageID)
                } else if let audioClipID = model.selectedAudioClipID {
                    model.removeAudioClip(id: audioClipID)
                } else if let redactionID = model.selectedRedactionID {
                    model.removeRedaction(id: redactionID)
                } else if let selectedCueID = model.selectedCueID {
                    model.removeZoomCue(id: selectedCueID)
                } else if let selectedLayoutCueID = model.selectedLayoutCueID {
                    model.removeLayoutCue(id: selectedLayoutCueID)
                } else if model.selectedClipID != nil {
                    model.deleteSelectedClip()
                }
            }
        }
        .onAppear {
            AppActivationPolicy.enter(hidePreview: true)
        }
        .onDisappear {
            closeGuard.detach()
            AppActivationPolicy.leave(restorePreview: true)
        }
    }

    /// The workspace with the canvas, plus the floating glass that belongs
    /// to it: the crop bar while cropping, and the Share/Export actions while
    /// the inspector that normally holds them is hidden. Either one reserves
    /// a strip under the canvas so it never covers the picture.
    private var stage: some View {
        StudioCanvas(model: model, bottomReserve: floatsChrome ? 72 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AnnotationEditorWorkspaceBackground())
            .overlay(alignment: .bottom) {
                if model.isCroppingVideo {
                    GlassCropBar(
                        aspect: model.videoCropAspect,
                        onAspectChange: { aspect in
                            withAnimation(.morphIfAllowed) { model.setVideoCropAspect(aspect) }
                        },
                        onReset: {
                            withAnimation(.morphIfAllowed) { model.resetVideoCrop() }
                        },
                        onCancel: {
                            withAnimation(.morphIfAllowed) { model.cancelVideoCrop() }
                        },
                        onApply: {
                            withAnimation(.morphIfAllowed) { model.applyVideoCrop() }
                        },
                        resetHelp: "Reset the selection to the whole video"
                    )
                    .padding(.bottom, 18)
                    .transition(.rise)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isInspectorPresented, !model.isCroppingVideo {
                    StudioActionFooter(model: model, showsStatus: false)
                        .frame(width: 300)
                        .padding(.trailing, 6)
                        .transition(.rise)
                }
            }
            .motion(.morph, value: model.isCroppingVideo)
            .motion(.morph, value: isInspectorPresented)
    }

    private var floatsChrome: Bool {
        model.isCroppingVideo || !isInspectorPresented
    }

    /// Save stays a toolbar button rather than a menu command: Studio is
    /// reached from a menu-bar app, where the main menu isn't a reliable
    /// place to look for ⌘S. Its glyph turns into a check when a save lands.
    private var saveButton: some View {
        Button {
            model.saveProject()
        } label: {
            Label(
                model.saveFlash ? "Saved" : "Save",
                systemImage: model.saveFlash ? "checkmark" : "square.and.arrow.down"
            )
            .labelStyle(.iconOnly)
            .contentTransition(.symbolEffect(.replace.downUp))
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!model.hasUnsavedChanges && !model.saveFlash)
        .help(model.hasUnsavedChanges ? "Save this project (⌘S)" : "All changes saved")
        .motion(.morphQuick, value: model.saveFlash)
    }

    /// AppKit already paints the unsaved dot in the close button; the title
    /// says it in words for anyone who reads the title bar first.
    private var windowTitle: String {
        let name = Self.friendlyTitle(for: model.projectDisplayName)
        return model.hasUnsavedChanges ? "\(name) - Edited" : name
    }

    /// Length of the edited cut and the source resolution.
    private var windowSubtitle: String {
        guard model.isLoaded else { return "" }
        let total = Int(model.duration.rounded())
        let clock = String(format: "%d:%02d", total / 60, total % 60)
        let size = model.videoSize
        return "\(clock) · \(Int(size.width))×\(Int(size.height))"
    }

    /// Unrenamed recordings are named `Screendrop_<timestamp>_<id>` on disk;
    /// the title shows when it was recorded instead of the raw file name.
    private static func friendlyTitle(for name: String) -> String {
        let parts = name.split(separator: "_")
        guard parts.count >= 2, parts[0] == "Screendrop" else { return name }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: String(parts[1])) else { return name }
        return "Recording · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func configureCloseGuard() {
        closeGuard.hasUnsavedChanges = { [weak model] in model?.hasUnsavedChanges ?? false }
        closeGuard.offersDelete = { [weak model] in model?.hasNeverBeenSaved ?? false }
        closeGuard.projectName = { [weak model] in model?.projectDisplayName ?? "this recording" }
        closeGuard.onDecision = { [weak model] decision, done in
            guard let model else { return }
            switch decision {
            case .save:
                if model.saveProject() { done() }
            case .discard:
                Task {
                    await model.discardChanges()
                    done()
                }
            case .delete:
                model.deleteProject()
                done()
            case .cancel:
                break
            }
        }
    }
}

// MARK: - Canvas

private struct StudioCanvas: View {
    @Bindable var model: RecordingStudioModel
    /// Height kept clear under the canvas for floating stage chrome.
    var bottomReserve: CGFloat = 0

    /// A play/pause glyph that blooms in the middle of the canvas after a
    /// click toggles playback, then fades.
    private struct PlaybackFlash: Equatable {
        let id = UUID()
        let systemImage: String
    }

    @State private var playbackFlash: PlaybackFlash?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let available = CGSize(
                width: max(proxy.size.width - 68, 100),
                height: max(proxy.size.height - 56 - bottomReserve, 100)
            )
            let canvasSize = Self.aspectFit(model.previewCanvasSize, into: available)
            let cropEditingLayout = RecordingStudioLayout.make(
                canvasSize: canvasSize,
                style: model.style,
                usesUniformPadding: model.exportAspect == .original,
                contentAspect: model.sourceVideoAspect,
                contentMode: .fit
            )

            ZStack(alignment: .topLeading) {
                StudioCanvasComposition(
                    model: model,
                    canvasSize: canvasSize,
                    isEditingVideoCrop: model.isCroppingVideo
                )
                // Clicking the picture plays or pauses, like a player.
                // The camera bubble and zoom target keep their own drags.
                .contentShape(Rectangle())
                .gesture(
                    TapGesture().onEnded(togglePlayback),
                    including: model.isCroppingVideo ? .subviews : .all
                )

                if model.isCroppingVideo {
                    VideoCropOverlay(
                        model: model,
                        canvasSize: canvasSize,
                        videoFrame: cropEditingLayout.cardRect
                    )

                    CropResolutionBadge(size: model.videoCropPixelSize)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .allowsHitTesting(false)
                } else if let skimTime {
                    StudioSkimBadge(time: skimTime)
                        .padding(10)
                        .allowsHitTesting(false)
                        .transition(.blurPop)
                }

                if let playbackFlash {
                    StudioPlaybackFlashView(systemImage: playbackFlash.systemImage)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .id(playbackFlash.id)
                        .allowsHitTesting(false)
                        .transition(.blurPop)
                }
            }
            .coordinateSpace(name: VideoCropOverlay.coordinateSpaceName)
            .frame(width: canvasSize.width, height: canvasSize.height)
            // Square like the exported video, lifted off the workspace by a
            // hairline and a soft shadow instead of a rounded mask that also
            // clipped the camera bubble.
            .clipped()
            .overlay {
                Rectangle()
                    .strokeBorder(canvasEdge, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .background {
                Rectangle()
                    .fill(Color.black)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 14, y: 5)
            }
            .motion(.morphQuick, value: skimTime == nil)
            .position(x: proxy.size.width / 2, y: (proxy.size.height - bottomReserve) / 2)
        }
    }

    /// The hovered timeline moment while the preview skims away from the
    /// playhead; nil when the canvas shows the playhead frame.
    private var skimTime: TimeInterval? {
        guard !model.isPlaying,
              let hover = model.hoverPreviewTime,
              abs(hover - model.currentTime) > 0.05 else { return nil }
        return hover
    }

    private var canvasEdge: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }

    private func togglePlayback() {
        guard model.isLoaded else { return }
        model.togglePlayback()
        let flash = PlaybackFlash(systemImage: model.isPlaying ? "play.fill" : "pause.fill")
        withAnimation(.morphQuickIfAllowed) {
            playbackFlash = flash
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(560))
            guard playbackFlash == flash else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                playbackFlash = nil
            }
        }
    }

    private static func aspectFit(_ size: CGSize, into bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Small dark capsule for transient canvas status.
private struct StudioCanvasBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.62)))
    }
}

/// The paused-preview time while skimming the timeline, on clear glass so
/// the frame underneath stays readable.
private struct StudioSkimBadge: View {
    let time: TimeInterval

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "eye")
                .font(.system(size: 10, weight: .semibold))
            Text(studioPreciseTimecode(time))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .glassEffect(.clear.tint(.black.opacity(0.25)), in: .capsule)
    }
}

private struct StudioPlaybackFlashView: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 60, height: 60)
            .glassEffect(.clear.tint(.black.opacity(0.2)), in: .circle)
    }
}

/// The complete canvas composition. A video crop changes only the screen card
/// layout and viewport; background, camera and captions remain in canvas space.
/// Original sizes that canvas to the visible source plus an equal border.
///
/// The camera layout timeline moves the card and the camera every frame, the
/// same way the exporter resolves them. An edit made while paused (picking a
/// layout, adding a cue) morphs from what was on screen into the new frame
/// instead of jumping.
private struct StudioCanvasComposition: View {
    @Bindable var model: RecordingStudioModel
    let canvasSize: CGSize
    let isEditingVideoCrop: Bool

    private struct LayoutMorph: Equatable {
        let id = UUID()
        let from: RecordingCameraLayoutFrame
        let fromViewport: ViewportFrame
        let start: Date
    }

    /// The viewport last drawn, which a morph starts from. A reference, so
    /// recording it while drawing doesn't draw the canvas again.
    private final class ShownViewport {
        private(set) var frame = ViewportFrame.identity

        func show(_ frame: ViewportFrame) -> ViewportFrame {
            self.frame = frame
            return frame
        }
    }

    private static let editMorphDuration: TimeInterval = 0.45

    @State private var layoutMorph: LayoutMorph?
    /// The layout timeline the canvas draws. An edit reaches the model a
    /// pass before onChange can start its morph; drawing the edit's layout
    /// for that pass would drop a cutout's layer, and its readiness with
    /// it, so the framed camera would show in full all the way to a split.
    @State private var shownTimeline: RecordingCameraLayoutTimeline?
    @State private var shownViewport = ShownViewport()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var baseLayout: RecordingStudioLayout {
        RecordingStudioLayout.make(
            canvasSize: canvasSize,
            style: model.style,
            usesUniformPadding: model.exportAspect == .original,
            contentAspect: isEditingVideoCrop ? model.sourceVideoAspect : model.previewContentAspect,
            contentMode: isEditingVideoCrop ? .fit : model.previewContentMode,
            contentCropRect: isEditingVideoCrop ? CropGeometry.unit : model.videoCropRect
        )
    }

    private var resolver: RecordingCameraLayoutResolver {
        RecordingCameraLayoutResolver(
            base: baseLayout, style: model.style, showsCamera: model.showsCameraLayer,
            cameraAspect: model.cameraVideoAspect
        )
    }

    /// Where the layout timeline puts everything at the playhead. Cropping
    /// works on the bare screen.
    private func targetFrame(
        _ resolver: RecordingCameraLayoutResolver,
        timeline: RecordingCameraLayoutTimeline
    ) -> RecordingCameraLayoutFrame {
        if !isEditingVideoCrop, timeline == model.cameraLayoutTimeline,
           let frame = model.motionTimeline.layoutFrame(at: model.displayTime, canvasSize: canvasSize) {
            return frame
        }
        return isEditingVideoCrop
            ? resolver.frame(for: .screenOnly)
            : resolver.frame(
                for: timeline.state(at: model.displayTime),
                zoomProgress: model.zoomProgress(at: model.displayTime)
            )
    }

    var body: some View {
        let resolver = resolver

        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !model.isPlaying && layoutMorph == nil)) { context in
            let target = targetFrame(resolver, timeline: shownTimeline ?? model.cameraLayoutTimeline)
            let progress = layoutMorph.map { morph in
                CGFloat(RecordingCameraLayoutTimeline.ease(
                    context.date.timeIntervalSince(morph.start) / Self.editMorphDuration
                ))
            } ?? 1
            let frame = layoutMorph.map { morph in
                RecordingCameraLayoutFrame.interpolate(morph.from, target, progress: progress)
            } ?? target
            let layout = resolver.base.applying(frame)
            let zoomTarget = zoomTargetCue
            // While a zoom's target is on show the frame stays unzoomed, so
            // the target reads against the whole picture.
            let viewport = isEditingVideoCrop || zoomTarget != nil
                ? ViewportFrame.identity
                : model.previewViewportFrame(at: model.displayTime)
            // The viewport follows an edit as soon as the model has it: a
            // split's side-aligned crop in a card still the old width would
            // slide the screen off one side. It holds until the morph
            // starts, then blends along with the card.
            let isEditPending = shownTimeline != nil && shownTimeline != model.cameraLayoutTimeline
            let state = shownViewport.show(
                isEditPending
                    ? shownViewport.frame
                    : layoutMorph.map { $0.fromViewport.blended(to: viewport, progress) } ?? viewport
            )

            ZStack {
                StudioBackgroundView(style: model.previewBackground ?? model.style.background)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .clipped()

                screenCard(layout: layout, state: state)
                    .opacity(layout.screenOpacity)

                if model.showsCameraLayer, layout.bubbleRect.width > 0, layout.cameraOpacity > 0.001 {
                    let settled = model.cameraLayoutTimeline.state(at: model.displayTime).settledLayout
                    StudioCameraBubble(
                        model: model,
                        layout: layout,
                        isMovable: !isEditingVideoCrop && !model.isPlaying && frame == target
                            && settled?.kind == .pictureInPicture,
                        destination: { corner in
                            var moved = settled ?? model.style.camera.layout
                            moved.corner = corner
                            let destination = resolver.frame(
                                for: moved,
                                zoomProgress: model.zoomProgress(at: model.displayTime)
                            )
                            return (destination.cameraRect, destination.cameraCornerRadius)
                        },
                        onDrop: { dropped, corner in
                            dropCamera(at: dropped, into: corner, from: frame)
                        }
                    )
                    .opacity(layout.cameraOpacity)
                }

                // Images and text sit on the canvas above the camera and
                // under the subtitles, as in the export.
                if !isEditingVideoCrop {
                    let texts = model.texts(atEditorTime: model.displayTime)
                    let images = overlayImages
                    if !texts.isEmpty || !images.isEmpty {
                        StudioCanvasOverlayLayer(
                            images: images,
                            texts: texts,
                            sourceTime: model.sourceTime(atEditorTime: model.displayTime),
                            canvasSize: canvasSize
                        )
                    }
                }

                if let subtitle = model.subtitleText(at: model.displayTime) {
                    StudioSubtitleBarView(
                        text: subtitle,
                        karaokeLine: model.subtitleKaraokeLine(at: model.displayTime),
                        style: model.subtitleStyle,
                        canvasSize: canvasSize
                    )
                }

                if let zoomTarget, layout.screenOpacity > 0.5 {
                    StudioZoomTargetOverlay(
                        model: model,
                        cue: zoomTarget,
                        layout: layout,
                        canvasSize: canvasSize
                    )
                }

                // Regions and texts can be picked and arranged while paused;
                // playing, a click on the picture still means pause.
                if !isEditingVideoCrop, !model.isPlaying {
                    if layout.screenOpacity > 0.5 {
                        let regions = model.redactions(atEditorTime: model.displayTime)
                        if !regions.isEmpty {
                            StudioRedactionEditingLayer(
                                model: model,
                                redactions: regions,
                                pictureRect: layout.frameRect(for: state),
                                canvasSize: canvasSize
                            )
                        }
                    }
                    let images = model.images(atEditorTime: model.displayTime)
                    if !images.isEmpty {
                        StudioImageEditingLayer(model: model, images: images, canvasSize: canvasSize)
                    }
                    let texts = model.texts(atEditorTime: model.displayTime)
                    if !texts.isEmpty {
                        StudioTextEditingLayer(model: model, texts: texts, canvasSize: canvasSize)
                    }
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            // The canvas animates layout changes itself, frame by frame. An
            // animated edit from the inspector would otherwise also spring
            // the card and camera toward each frame, overshooting the morph.
            .transaction { $0.animation = nil }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .onAppear { shownTimeline = model.cameraLayoutTimeline }
        .onChange(of: model.cameraLayoutTimeline) { old, new in
            shownTimeline = new
            morphFromEdit(previous: targetFrame(resolver, timeline: old), resolver: resolver)
        }
        .onChange(of: model.showsCameraLayer) { old, _ in
            let previous = RecordingCameraLayoutResolver(
                base: resolver.base, style: model.style, showsCamera: old, cameraAspect: model.cameraVideoAspect
            )
            morphFromEdit(previous: targetFrame(previous, timeline: model.cameraLayoutTimeline), resolver: resolver)
        }
    }

    /// Moves the corner camera to `corner` of whichever layout is showing,
    /// settling from where it was let go.
    private func dropCamera(at dropped: CGRect, into corner: RecordingCameraLayout.Corner, from frame: RecordingCameraLayoutFrame) {
        if !reduceMotion {
            var from = frame
            from.cameraRect = dropped
            startMorph(from: from)
        }
        model.editLayout(atEditorTime: model.displayTime, actionName: "Move Camera") { $0.corner = corner }
    }

    private func startMorph(from: RecordingCameraLayoutFrame) {
        let morph = LayoutMorph(from: from, fromViewport: shownViewport.frame, start: Date())
        layoutMorph = morph
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.editMorphDuration))
            if layoutMorph == morph { layoutMorph = nil }
        }
    }

    /// Starts a short morph from what the canvas showed before an edit.
    /// Playback already moves through the timeline's own morphs.
    private func morphFromEdit(previous: RecordingCameraLayoutFrame, resolver: RecordingCameraLayoutResolver) {
        guard !model.isPlaying, !reduceMotion else { return }
        let now = Date()
        // Mid-morph, start from where the canvas is rather than where the
        // interrupted morph began.
        let from = layoutMorph.map { morph in
            RecordingCameraLayoutFrame.interpolate(
                morph.from,
                previous,
                progress: CGFloat(RecordingCameraLayoutTimeline.ease(
                    now.timeIntervalSince(morph.start) / Self.editMorphDuration
                ))
            )
        } ?? previous
        guard from != targetFrame(resolver, timeline: model.cameraLayoutTimeline) else { return }
        startMorph(from: from)
    }

    private func screenCard(layout: RecordingStudioLayout, state: ViewportFrame) -> some View {
        StudioPlayerLayerView(player: model.screenPlayer, gravity: .resize)
            .frame(
                width: layout.contentFillSize.width,
                height: layout.contentFillSize.height
            )
            .scaleEffect(state.magnification)
            .offset(
                x: (0.5 - state.anchor.x) * state.magnification * layout.contentFillSize.width,
                y: (0.5 - state.anchor.y) * state.magnification * layout.contentFillSize.height
            )
            .frame(width: layout.cardRect.width, height: layout.cardRect.height)
            .overlay {
                if let pointer = model.pointerFrame(at: model.displayTime) {
                    StudioCursorOverlay(
                        pointer: pointer,
                        artwork: model.artwork(id: pointer.artworkID),
                        state: state,
                        cardSize: layout.cardRect.size,
                        contentSize: layout.contentFillSize,
                        cursorScale: model.style.cursorScale,
                        showsClickEffect: model.showsPressEffects
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: layout.cardCornerRadius, style: .continuous))
            .overlay {
                if let caption = model.keystrokeCaption(at: model.displayTime) {
                    StudioKeystrokeCaptionView(
                        caption: caption,
                        placement: model.keystrokePlacement,
                        cardSize: layout.cardRect.size
                    )
                }
            }
            .overlay {
                if let badge = model.speedBadge(at: model.displayTime) {
                    StudioSpeedBadgeView(
                        badge: badge,
                        placement: model.speedBadgePlacement,
                        cardSize: layout.cardRect.size
                    )
                }
            }
            .shadow(
                color: .black.opacity((model.previewBackground ?? model.style.background) == .none ? 0 : 0.55 * model.style.shadow),
                radius: min(canvasSize.width, canvasSize.height) * 0.045 * model.style.shadow,
                y: min(canvasSize.width, canvasSize.height) * 0.016 * model.style.shadow
            )
            .position(x: layout.cardRect.midX, y: layout.cardRect.midY)
    }

    /// The showing images whose files have been decoded. Reading the
    /// revision redraws the canvas as decoding finishes.
    private var overlayImages: [(overlay: RecordingImageOverlay, image: RecordingOverlayImage)] {
        _ = model.overlayImageRevision
        return model.images(atEditorTime: model.displayTime).compactMap { overlay in
            guard let url = model.overlayImageURL(for: overlay),
                  let image = model.overlayImages.cachedImage(at: url) else { return nil }
            return (overlay, image)
        }
    }

    /// The selected zoom, shown as a target on the paused canvas.
    private var zoomTargetCue: ZoomCue? {
        guard !isEditingVideoCrop,
              !model.isPlaying,
              model.zoomEnabled,
              let cue = model.selectedCue,
              cue.isEnabled else { return nil }
        return cue
    }
}

/// Where the selected zoom will look, drawn over the unzoomed frame with
/// everything outside it dimmed. Fixed zooms can be dragged to re-aim them;
/// pointer and smart zooms follow the pointer, so their target is shown at
/// the pointer's position under the playhead and can't be moved.
private struct StudioZoomTargetOverlay: View {
    @Bindable var model: RecordingStudioModel
    let cue: ZoomCue
    let layout: RecordingStudioLayout
    let canvasSize: CGSize

    @State private var dragStartPoint: CGPoint?
    @State private var isHovering = false

    private var isMovable: Bool {
        cue.anchorMode == .pinnedAnchor
    }

    private var target: CGPoint {
        if isMovable { return cue.pinnedPoint }
        return model.pointerLocation(at: model.displayTime) ?? CGPoint(x: 0.5, y: 0.5)
    }

    var body: some View {
        let card = layout.cardRect
        let content = layout.contentFillSize
        let magnification = max(CGFloat(cue.zoom), 1)
        let size = CGSize(width: card.width / magnification, height: card.height / magnification)
        let center = CGPoint(
            x: card.midX + content.width * (target.x - 0.5),
            y: card.midY + content.height * (target.y - 0.5)
        )
        let rect = CGRect(
            x: min(max(center.x - size.width / 2, card.minX), card.maxX - size.width),
            y: min(max(center.y - size.height / 2, card.minY), card.maxY - size.height),
            width: size.width,
            height: size.height
        )
        let isActive = isHovering || dragStartPoint != nil

        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRoundedRect(
                    in: card,
                    cornerSize: CGSize(width: layout.cardCornerRadius, height: layout.cardCornerRadius),
                    style: .continuous
                )
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(isActive ? 1 : 0.9),
                    style: StrokeStyle(lineWidth: isActive ? 2.5 : 2, dash: isMovable ? [] : [6, 4])
                )
                .background(Color.white.opacity(0.001))
                .shadow(color: .black.opacity(0.35), radius: 2)
                .overlay(alignment: .topLeading) {
                    StudioCanvasBadge(
                        text: isMovable
                            ? InspectorValueFormat.magnification(fractionDigits: 1).displayString(for: magnification)
                            : "Follows pointer"
                    )
                    .padding(6)
                    .allowsHitTesting(false)
                }
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 && isMovable }
                .pointerStyle(isMovable ? (dragStartPoint == nil ? PointerStyle.grabIdle : .grabActive) : nil)
                .onTapGesture {}
                .gesture(moveGesture(contentSize: content), including: isMovable ? .all : .none)
                .help(isMovable ? "Drag to aim this zoom" : "Switch Camera Focus to Fixed to aim this zoom by hand")
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private func moveGesture(contentSize: CGSize) -> some Gesture {
        // Global coordinates: the target moves under the pointer, so local
        // translations would chase their own updates.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if dragStartPoint == nil {
                    dragStartPoint = cue.pinnedPoint
                    model.beginZoomCueEdit()
                }
                guard let start = dragStartPoint,
                      contentSize.width > 0,
                      contentSize.height > 0 else { return }
                var updated = cue
                updated.pinnedPoint = CGPoint(
                    x: min(max(start.x + value.translation.width / contentSize.width, 0), 1),
                    y: min(max(start.y + value.translation.height / contentSize.height, 0), 1)
                )
                model.updateZoomCue(updated)
            }
            .onEnded { _ in
                dragStartPoint = nil
                model.endZoomCueEdit(actionName: "Aim Zoom")
            }
    }
}

private struct VideoCropOverlay: View {
    static let coordinateSpaceName = "VideoCropSpace"

    @Bindable var model: RecordingStudioModel
    let canvasSize: CGSize
    /// The uncropped screen-video card inside the surrounding canvas.
    let videoFrame: CGRect
    @State private var moveStartCrop: CGRect?
    @State private var resizeStartCrop: CGRect?

    private var cropViewRect: CGRect {
        let crop = model.workingVideoCropRect.standardized
        return CGRect(
            x: videoFrame.minX + crop.minX * videoFrame.width,
            y: videoFrame.minY + crop.minY * videoFrame.height,
            width: crop.width * videoFrame.width,
            height: crop.height * videoFrame.height
        )
    }

    private var visibleHandles: [CropHandle] {
        model.videoCropAspect.locksAspect
            ? CropHandle.allCases.filter(\.isCorner)
            : CropHandle.allCases
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(videoFrame)
                path.addRect(cropViewRect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { path in
                for index in 1...2 {
                    let x = cropViewRect.minX + cropViewRect.width * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: cropViewRect.minY))
                    path.addLine(to: CGPoint(x: x, y: cropViewRect.maxY))
                    let y = cropViewRect.minY + cropViewRect.height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: cropViewRect.minX, y: y))
                    path.addLine(to: CGPoint(x: cropViewRect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                .frame(width: cropViewRect.width, height: cropViewRect.height)
                .position(x: cropViewRect.midX, y: cropViewRect.midY)
                .shadow(color: .black.opacity(0.3), radius: 1)
                .allowsHitTesting(false)

            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: max(cropViewRect.width, 1), height: max(cropViewRect.height, 1))
                .position(x: cropViewRect.midX, y: cropViewRect.midY)
                .gesture(moveGesture)

            ForEach(visibleHandles, id: \.self) { handle in
                VideoCropHandleView(handle: handle)
                    .position(handlePoint(handle))
                    .gesture(handleGesture(handle))
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                let start = moveStartCrop ?? model.workingVideoCropRect.standardized
                if moveStartCrop == nil { moveStartCrop = start }
                guard videoFrame.width > 0, videoFrame.height > 0 else { return }
                model.moveVideoCrop(
                    from: start,
                    byNormalized: CGSize(
                        width: value.translation.width / videoFrame.width,
                        height: value.translation.height / videoFrame.height
                    )
                )
            }
            .onEnded { _ in moveStartCrop = nil }
    }

    private func handleGesture(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                let start = resizeStartCrop ?? model.workingVideoCropRect.standardized
                if resizeStartCrop == nil { resizeStartCrop = start }
                guard videoFrame.width > 0, videoFrame.height > 0 else { return }
                model.resizeVideoCrop(
                    from: start,
                    handle: handle,
                    byNormalized: CGSize(
                        width: value.translation.width / videoFrame.width,
                        height: value.translation.height / videoFrame.height
                    )
                )
            }
            .onEnded { _ in resizeStartCrop = nil }
    }

    private func handlePoint(_ handle: CropHandle) -> CGPoint {
        let unit = handle.unitPoint
        return CGPoint(
            x: cropViewRect.minX + cropViewRect.width * unit.x,
            y: cropViewRect.minY + cropViewRect.height * unit.y
        )
    }
}

private struct VideoCropHandleView: View {
    let handle: CropHandle

    var body: some View {
        ZStack {
            Color.white.opacity(0.001)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())

            if handle.isCorner {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 13, height: 13)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            } else {
                let isHorizontal = handle == .top || handle == .bottom
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white)
                    .frame(width: isHorizontal ? 26 : 7, height: isHorizontal ? 7 : 26)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            }
        }
    }
}

/// Recorded pointer artwork, placed through the same viewport transform the
/// video card uses (see RecordingPointerTimeline for why it is reconstructed).
private struct StudioCursorOverlay: View {
    let pointer: PointerFrame
    let artwork: PointerArtwork?
    let state: ViewportFrame
    let cardSize: CGSize
    /// The video's draw size at magnification 1 - equal to the card
    /// normally, larger when a reframe aspect-fills it.
    var contentSize: CGSize?
    let cursorScale: CGFloat
    let showsClickEffect: Bool

    var body: some View {
        let content = contentSize ?? cardSize
        let tip = CGPoint(
            x: cardSize.width / 2 + content.width * state.magnification * (pointer.location.x - state.anchor.x),
            y: cardSize.height / 2 + content.height * state.magnification * (pointer.location.y - state.anchor.y)
        )

        ZStack(alignment: .topLeading) {
            if showsClickEffect, let press = pointer.press {
                let pressTip = CGPoint(
                    x: cardSize.width / 2
                        + content.width * state.magnification * (press.location.x - state.anchor.x),
                    y: cardSize.height / 2
                        + content.height * state.magnification * (press.location.y - state.anchor.y)
                )
                let effect = PointerPressEffectStyle.geometry(
                    progress: press.progress,
                    referenceHeight: content.height,
                    cursorScale: cursorScale
                )
                let accent = PointerPressEffectStyle.color
                Circle()
                    .fill(
                        Color(red: accent.red, green: accent.green, blue: accent.blue)
                            .opacity(effect.impactOpacity)
                    )
                    .frame(width: effect.impactRadius * 2, height: effect.impactRadius * 2)
                    .position(x: pressTip.x, y: pressTip.y)
                Circle()
                    .stroke(
                        Color(red: accent.red, green: accent.green, blue: accent.blue)
                            .opacity(effect.rippleOpacity),
                        lineWidth: effect.rippleLineWidth
                    )
                    .frame(width: effect.rippleRadius * 2, height: effect.rippleRadius * 2)
                    .position(x: pressTip.x, y: pressTip.y)
            }

            if let artwork,
               let image = StudioCursorImageCache.image(for: artwork) {
                let anchor = artwork.normalizedAnchor
                let height = content.height
                    * PointerArtworkMetrics.heightRatio
                    * cursorScale
                    * artwork.intrinsicScale
                let size = CGSize(
                    width: height * artwork.aspectRatio,
                    height: height
                )
                let material = PointerShape(artworkID: artwork.artworkID)?.material
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .background {
                        if let material {
                            PointerMaterialView(
                                material: material,
                                diameter: size.width * PointerShape.circleRadiusRatio * 2
                            )
                        }
                    }
                    .scaleEffect(
                        CGFloat(pointer.magnification),
                        anchor: UnitPoint(x: anchor.x, y: anchor.y)
                    )
                    .rotationEffect(
                        .degrees(artwork.leans ? pointer.tiltDegrees : 0),
                        anchor: UnitPoint(x: anchor.x, y: anchor.y)
                    )
                    .position(
                        x: tip.x + (0.5 - anchor.x) * size.width,
                        y: tip.y + (0.5 - anchor.y) * size.height
                    )
                    .opacity(pointer.opacity)
                    .blur(radius: CGFloat(pointer.blurRadius))
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .allowsHitTesting(false)
    }
}

/// The keystroke caption pill: one rounded container with the chord's
/// modifiers and key. Geometry comes from KeystrokeCaptionMetrics so the
/// exporter draws the identical pill.
private struct StudioKeystrokeCaptionView: View {
    let caption: KeystrokeCaptionFrame
    let placement: RecordingKeystrokePlacement
    let cardSize: CGSize

    var body: some View {
        let metrics = KeystrokeCaptionMetrics(cardHeight: cardSize.height)
        let (modifiers, key) = KeystrokeCaptionMetrics.text(for: caption)

        (Text(modifiers).foregroundStyle(.white.opacity(KeystrokeCaptionMetrics.modifierAlpha))
            + Text(key).foregroundStyle(.white))
            .font(.system(size: metrics.fontSize, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, metrics.paddingHorizontal)
            .padding(.vertical, metrics.paddingVertical)
            .background(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(.black.opacity(KeystrokeCaptionMetrics.backgroundAlpha))
            )
            .scaleEffect(caption.scale)
            .opacity(caption.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement.alignment)
            .padding(metrics.margin)
            .frame(width: cardSize.width, height: cardSize.height)
            .allowsHitTesting(false)
    }
}

/// The "2× ›››" badge over a sped-up clip. Geometry comes from
/// SpeedBadgeMetrics and its animation from the editor time, so the exporter
/// draws the identical badge on the identical frame.
private struct StudioSpeedBadgeView: View {
    let badge: SpeedBadgeFrame
    let placement: RecordingKeystrokePlacement
    let cardSize: CGSize

    var body: some View {
        let metrics = SpeedBadgeMetrics(cardHeight: cardSize.height)

        HStack(spacing: metrics.textGap) {
            Text(badge.title)
                .font(.system(size: metrics.fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()

            Canvas { context, size in
                for index in 0..<SpeedBadgeMetrics.chevronCount {
                    let path = Path(metrics.chevronPath(
                        minX: metrics.chevronLineWidth / 2 + metrics.chevronAdvance * CGFloat(index),
                        midY: size.height / 2
                    ))
                    context.stroke(
                        path,
                        with: .color(.white.opacity(badge.chevronAlpha(index))),
                        style: StrokeStyle(
                            lineWidth: metrics.chevronLineWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
            .frame(
                width: metrics.chevronsWidth + metrics.chevronLineWidth,
                height: metrics.chevronHeight + metrics.chevronLineWidth
            )
        }
        .padding(.horizontal, metrics.paddingHorizontal)
        .padding(.vertical, metrics.paddingVertical)
        .background(
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .fill(.black.opacity(SpeedBadgeMetrics.backgroundAlpha))
        )
        .scaleEffect(badge.scale)
        .opacity(badge.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement.alignment)
        .padding(metrics.margin)
        .frame(width: cardSize.width, height: cardSize.height)
        .allowsHitTesting(false)
    }
}

/// The narration subtitle bar: rounded black bar, white text, center-locked
/// horizontally at the style's vertical position on the full canvas
/// (background included). Geometry comes from SubtitleBarMetrics so the
/// exporter draws the identical bar.
private struct StudioSubtitleBarView: View {
    let text: String
    var karaokeLine: KaraokeTimeline.Line?
    let style: SubtitleBarStyle
    let canvasSize: CGSize

    var body: some View {
        let metrics = SubtitleBarMetrics(canvasSize: canvasSize, style: style)

        barText
            .font(.system(size: metrics.fontSize, weight: .semibold, design: .rounded))
            // Long lines wrap into centered lines on narrow canvases,
            // matching the exporter's framesetter layout; the scale
            // factor only kicks in past the shared line cap.
            .lineLimit(SubtitleBarMetrics.maximumLineCount)
            .multilineTextAlignment(.center)
            .lineSpacing(metrics.fontSize * (SubtitleBarMetrics.lineSpacingFactor - 1))
            .minimumScaleFactor(0.4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, metrics.paddingHorizontal)
            .padding(.vertical, metrics.paddingVertical)
            .background(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(.black.opacity(SubtitleBarMetrics.backgroundAlpha))
            )
            // Invisible width cap: constrains where the text wraps while
            // the pill above hugs the text, so the bar never spans the
            // canvas.
            .frame(
                maxWidth: metrics.maximumTextWidth(canvasWidth: canvasSize.width)
                    + metrics.paddingHorizontal * 2
            )
            .position(
                x: canvasSize.width / 2,
                y: canvasSize.height * CGFloat(style.clampedVerticalPosition)
            )
            .frame(width: canvasSize.width, height: canvasSize.height)
            .allowsHitTesting(false)
    }

    /// Plain white cue text, or karaoke-colored words matching the
    /// exporter's palette exactly (SubtitleBarMetrics.karaoke*).
    private var barText: Text {
        guard let karaokeLine, !karaokeLine.words.isEmpty else {
            return Text(text).foregroundStyle(.white)
        }
        var combined = Text(verbatim: "")
        for (index, word) in karaokeLine.words.enumerated() {
            let color: Color
            if index == karaokeLine.activeIndex {
                color = Color(cgColor: SubtitleBarMetrics.karaokeAccent)
            } else if index < karaokeLine.spokenCount {
                color = .white
            } else {
                color = .white.opacity(SubtitleBarMetrics.karaokeUpcomingAlpha)
            }
            let piece = Text(verbatim: index > 0 ? " \(word)" : word)
                .foregroundStyle(color)
            combined = combined + piece
        }
        return combined
    }
}


private extension RecordingKeystrokePlacement {
    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topCenter: .top
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomRight: .bottomTrailing
        }
    }
}

/// A circle pointer's material in the preview: the light window-chrome
/// material. Export draws its own match from the frame.
struct PointerMaterialView: View {
    let material: PointerMaterial
    let diameter: CGFloat

    var body: some View {
        switch material {
        case .frosted:
            StudioChromeMaterial()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
        }
    }
}

/// Blends within the window so it frosts the video, not the desktop, and
/// stays light so it matches the export in either appearance.
private struct StudioChromeMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .withinWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

@MainActor
private enum StudioCursorImageCache {
    private static var capturedImages: [String: NSImage] = [:]

    static func image(for artwork: PointerArtwork) -> NSImage? {
        let cacheKey = "\(artwork.artworkID)-\(artwork.imageData.hashValue)"
        if let cached = capturedImages[cacheKey] {
            return cached
        }
        guard let image = NSImage(data: artwork.imageData) else { return nil }
        capturedImages[cacheKey] = image
        return image
    }
}

/// The camera on the canvas. A corner camera can be picked up and dropped
/// anywhere; it settles into whichever corner of the screen card it was let
/// go nearest, with that corner previewed while dragging. Other layouts
/// place the camera themselves, so there it takes no clicks at all.
///
/// A cutout draws the person into a layer over the framed picture, which
/// fades out as far as the camera is cut out. Until the cutout's first
/// frame is ready the framed picture stays, so the camera never blinks out.
private struct StudioCameraBubble: View {
    @Bindable var model: RecordingStudioModel
    let layout: RecordingStudioLayout
    let isMovable: Bool
    /// Where the camera would land in each corner.
    let destination: (RecordingCameraLayout.Corner) -> (rect: CGRect, radius: CGFloat)
    /// Called with the rect it was let go at and the corner it snaps to.
    let onDrop: (CGRect, RecordingCameraLayout.Corner) -> Void

    private static let hoverRingPadding: CGFloat = 3

    @State private var dragOffset: CGSize?
    @State private var isHovering = false
    @State private var isCutoutReady = false

    var body: some View {
        let rect = layout.bubbleRect.offsetBy(dx: dragOffset?.width ?? 0, dy: dragOffset?.height ?? 0)
        let canvas = layout.canvasSize
        let isActive = isMovable && (isHovering || dragOffset != nil)
        let radius = layout.bubbleCornerRadius
        let cutout = layout.cameraCutout
        let showsCutout = cutout > 0.001
        let framedOpacity = showsCutout && isCutoutReady ? 1 - cutout : 1

        ZStack(alignment: .topLeading) {
            if dragOffset != nil {
                let target = destination(corner(for: rect))
                RoundedRectangle(cornerRadius: target.radius, style: .continuous)
                    .fill(Palette.highlight.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: target.radius, style: .continuous)
                            .strokeBorder(Palette.highlight.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                    .frame(width: target.rect.width, height: target.rect.height)
                    .offset(x: target.rect.minX, y: target.rect.minY)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            ZStack(alignment: .topLeading) {
                StudioPlayerLayerView(player: model.cameraPlayer, gravity: .resizeAspectFill)
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    }
                    .overlay {
                        if isActive {
                            // Nested radius: the ring sits `hoverRingPadding` outside.
                            RoundedRectangle(
                                cornerRadius: radius + Self.hoverRingPadding,
                                style: .continuous
                            )
                            .strokeBorder(Palette.highlight, lineWidth: 2)
                            .padding(-Self.hoverRingPadding)
                            .allowsHitTesting(false)
                        }
                    }
                    .shadow(
                        color: .black.opacity(0.35),
                        radius: min(canvas.width, canvas.height) * 0.022,
                        y: min(canvas.width, canvas.height) * 0.009
                    )
                    .opacity(framedOpacity)
                    .animation(.easeOut(duration: 0.15), value: isCutoutReady)
                    .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .onHover { isHovering = $0 }
                    .pointerStyle(isMovable ? (dragOffset == nil ? PointerStyle.grabIdle : .grabActive) : nil)
                    // Swallow clicks so they don't toggle playback underneath.
                    .onTapGesture {}
                    .gesture(dragGesture, including: isMovable ? .all : .none)
                    .help(isMovable ? "Drag the camera to another corner" : "")
                    // A camera the layout places (full frame, split) lets clicks
                    // through to the canvas, which plays and pauses.
                    .allowsHitTesting(isMovable)
                    .offset(x: rect.minX, y: rect.minY)

                if showsCutout {
                    StudioCameraCutoutView(
                        player: model.cameraPlayer,
                        parameters: cutoutParameters(rect: rect, radius: radius, cutout: cutout),
                        onReady: { isCutoutReady = true }
                    )
                    .frame(width: rect.width, height: rect.height)
                    .allowsHitTesting(false)
                    .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            // A cutout can stand wider than the canvas, which crops it as
            // the export does.
            .clipShape(StudioCanvasClip(clips: showsCutout))
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .onChange(of: showsCutout) { _, shows in
            if !shows { isCutoutReady = false }
        }
    }

    /// The export's feather and shadow for where the picture sits now.
    private func cutoutParameters(rect: CGRect, radius: CGFloat, cutout: CGFloat) -> StudioCutoutLayerParameters {
        let aspect = model.cameraVideoAspect
        let fill = max(rect.width / aspect, rect.height)
        let picture = CGRect(
            x: rect.midX - fill * aspect / 2, y: rect.midY - fill / 2, width: fill * aspect, height: fill
        )
        return StudioCutoutLayerParameters(
            cornerRadius: radius,
            feather: StudioCutoutStyle.feather(picture: picture, canvas: layout.canvasSize),
            shadowAlpha: StudioCutoutStyle.shadowAlpha * cutout
        )
    }

    /// The card corner nearest the camera's center.
    private func corner(for rect: CGRect) -> RecordingCameraLayout.Corner {
        let card = layout.cardRect
        switch (rect.midX < card.midX, rect.midY < card.midY) {
        case (true, true): return .topLeading
        case (false, true): return .topTrailing
        case (true, false): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }

    private var dragGesture: some Gesture {
        // Global coordinates: the camera moves under the pointer, so local
        // translations would chase their own updates.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let dropped = layout.bubbleRect.offsetBy(dx: value.translation.width, dy: value.translation.height)
                dragOffset = nil
                onDrop(dropped, corner(for: dropped))
            }
    }
}

/// The canvas when `clips`; otherwise far past it, so a corner camera
/// dragged over the edge still shows whole. One shape either way keeps the
/// camera's player layer in place when a cutout comes and goes.
private struct StudioCanvasClip: Shape {
    var clips: Bool

    func path(in rect: CGRect) -> Path {
        Path(clips ? rect : rect.insetBy(dx: -100_000, dy: -100_000))
    }
}

private extension ViewportFrame {
    func blended(to other: ViewportFrame, _ t: CGFloat) -> ViewportFrame {
        ViewportFrame(
            magnification: magnification + (other.magnification - magnification) * Double(t),
            anchor: CGPoint(
                x: anchor.x + (other.anchor.x - anchor.x) * t,
                y: anchor.y + (other.anchor.y - anchor.y) * t
            )
        )
    }
}

/// Renders an AnnotationBackgroundStyle as a live SwiftUI layer.
private struct StudioBackgroundView: View {
    let style: AnnotationBackgroundStyle

    var body: some View {
        switch style {
        case .none:
            Color(white: 0.04)
        case .solid(let color):
            color.color
        case .gradient(let gradient):
            LinearGradient(
                colors: gradient.colors.map(\.color),
                startPoint: gradient.startPoint,
                endPoint: gradient.endPoint
            )
        case .customWallpaper(let wallpaper):
            if let image = NSImage(contentsOf: wallpaper.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.04)
            }
        }
    }
}

/// AVPlayerLayer host for the preview canvas.
private struct StudioPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> StudioPlayerContainerView {
        let view = StudioPlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateNSView(_ nsView: StudioPlayerContainerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        nsView.playerLayer.videoGravity = gravity
    }
}

final class StudioPlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
