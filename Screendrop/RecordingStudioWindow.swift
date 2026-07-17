//
//  RecordingStudioWindow.swift
//  Screendrop
//
//  The recording studio: a Screen Studio-style editor for screen recordings.
//  Left/center is the composited live preview (background, padded rounded
//  card, zoom-follow-pointer, draggable camera bubble) over a timeline with
//  editable zoom cues; the trailing inspector uses the annotation
//  editor's design system.
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
        .task(id: url) {
            guard let url else { return }
            let newModel = RecordingStudioModel(url: url)
            model = newModel
            await newModel.load()
        }
        .onDisappear {
            model?.teardown()
        }
    }
}

private struct RecordingStudioContent: View {
    @Bindable var model: RecordingStudioModel
    @State private var isInspectorPresented = true

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
                StudioCanvas(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AnnotationEditorWorkspaceBackground())

                StudioTimelineEditor(model: model)
            }
        }
        .frame(minWidth: 980, minHeight: 720)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .inspector(isPresented: $isInspectorPresented) {
            StudioInspector(model: model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                exportStatus

                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
            }
        }
        .navigationTitle(model.sessionURL.deletingPathExtension().lastPathComponent)
        .onDeleteCommand {
            if model.selectedClipID != nil {
                model.deleteSelectedClip()
            } else if let selectedCueID = model.selectedCueID {
                model.removeZoomCue(id: selectedCueID)
            }
        }
        .onAppear {
            AppActivationPolicy.enter(hidePreview: true)
        }
        .onDisappear {
            AppActivationPolicy.leave(restorePreview: true)
        }
    }

    @ViewBuilder
    private var exportStatus: some View {
        switch model.exportState {
        case .idle:
            Button {
                model.export()
            } label: {
                Label("Export", systemImage: "arrow.down.circle")
                    .labelStyle(.titleAndIcon)
            }
            .tint(.accentColor)
            .disabled(!model.isLoaded)
        case .exporting(let progress):
            ExportProgressPill(progress: progress) {
                model.cancelExport()
            }
        case .finished(let url):
            HStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .help("Reveal exported recording in Finder")

                Button {
                    model.export()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .help("Export Again")
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Label("Export Failed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .help(message)

                Button {
                    model.export()
                } label: {
                    Text("Retry")
                }
            }
        }
    }
}

/// Single pill that replaces the old "Exporting…" button plus a separate
/// progress bar with one control: a ring showing percent complete, the
/// number itself, and a way to actually stop the export.
private struct ExportProgressPill: View {
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.15), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.03, min(1, progress)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            .animation(.easeOut(duration: 0.15), value: progress)

            Text("Exporting \(Int((progress * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize()
                .contentTransition(.numericText())

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel Export")
        }
        .padding(.leading, 6)
    }
}

// MARK: - Canvas

private struct StudioCanvas: View {
    @Bindable var model: RecordingStudioModel

    var body: some View {
        GeometryReader { proxy in
            let available = CGSize(
                width: max(proxy.size.width - 68, 100),
                height: max(proxy.size.height - 56, 100)
            )
            let canvasSize = Self.aspectFit(model.videoSize, into: available)
            let layout = RecordingStudioLayout.make(
                canvasSize: canvasSize,
                style: model.style,
                includeBubble: model.hasCameraVideo
            )

            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !model.isPlaying)) { _ in
                let state = model.viewportFrame(at: model.displayTime)

                ZStack {
                    // Fixed frame + clip so a scaledToFill wallpaper can never
                    // inflate the ZStack bounds and shift the card off-center.
                    StudioBackgroundView(style: model.style.background)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .clipped()

                    // The recording card: video with the virtual camera
                    // transform, clipped to the rounded padded card. The
                    // synthetic cursor overlays inside the same clip so it
                    // pans, zooms, and crops exactly like the pixels below.
                    StudioPlayerLayerView(player: model.screenPlayer, gravity: .resize)
                        .frame(width: layout.cardRect.width, height: layout.cardRect.height)
                        .scaleEffect(state.magnification)
                        .offset(
                            x: (0.5 - state.anchor.x) * state.magnification * layout.cardRect.width,
                            y: (0.5 - state.anchor.y) * state.magnification * layout.cardRect.height
                        )
                        .frame(width: layout.cardRect.width, height: layout.cardRect.height)
                        .overlay {
                            if let pointer = model.pointerFrame(at: model.displayTime) {
                                StudioCursorOverlay(
                                    pointer: pointer,
                                    artwork: model.artwork(id: pointer.artworkID),
                                    state: state,
                                    cardSize: layout.cardRect.size,
                                    cursorScale: model.style.cursorScale,
                                    showsClickEffect: model.showsPressEffects
                                )
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: layout.cardCornerRadius, style: .continuous))
                        .shadow(
                            color: .black.opacity(model.style.background == .none ? 0 : 0.55 * model.style.shadow),
                            radius: min(canvasSize.width, canvasSize.height) * 0.045 * model.style.shadow,
                            y: min(canvasSize.width, canvasSize.height) * 0.016 * model.style.shadow
                        )
                        .position(x: layout.cardRect.midX, y: layout.cardRect.midY)

                    if model.isCameraVisible(at: model.displayTime), layout.bubbleRect.width > 0 {
                        StudioCameraBubble(model: model, layout: layout)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    private static func aspectFit(_ size: CGSize, into bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Recorded pointer artwork, placed through the same viewport transform the
/// video card uses (see RecordingPointerTimeline for why it is reconstructed).
private struct StudioCursorOverlay: View {
    let pointer: PointerFrame
    let artwork: PointerArtwork?
    let state: ViewportFrame
    let cardSize: CGSize
    let cursorScale: CGFloat
    let showsClickEffect: Bool

    var body: some View {
        let tip = CGPoint(
            x: cardSize.width * (0.5 + state.magnification * (pointer.location.x - state.anchor.x)),
            y: cardSize.height * (0.5 + state.magnification * (pointer.location.y - state.anchor.y))
        )

        ZStack(alignment: .topLeading) {
            if showsClickEffect, let progress = pointer.pressPulse {
                let eased = 1 - pow(1 - progress, 3)
                let baseRadius = cardSize.height
                    * (16 / 1_080)
                    * state.magnification
                    * cursorScale
                Circle()
                    .stroke(
                        Color(red: 0, green: 122 / 255, blue: 1)
                            .opacity(1 - progress),
                        lineWidth: max(1, cardSize.height * (2 / 1_080) * state.magnification)
                    )
                    .frame(
                        width: baseRadius * 2 * (0.75 + 0.55 * eased),
                        height: baseRadius * 2 * (0.75 + 0.55 * eased)
                    )
                    .position(x: tip.x, y: tip.y)
            }

            if let artwork,
               let image = StudioCursorImageCache.image(for: artwork) {
                let anchor = artwork.normalizedAnchor
                let height = cardSize.height
                    * PointerArtworkMetrics.heightRatio
                    * state.magnification
                    * cursorScale
                    * artwork.intrinsicScale
                let size = CGSize(
                    width: height * artwork.aspectRatio,
                    height: height
                )
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(
                        CGFloat(pointer.magnification),
                        anchor: UnitPoint(x: anchor.x, y: anchor.y)
                    )
                    .rotationEffect(
                        .degrees(pointer.tiltDegrees),
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

private struct StudioCameraBubble: View {
    @Bindable var model: RecordingStudioModel
    let layout: RecordingStudioLayout

    @State private var dragStartCenter: CGPoint?

    var body: some View {
        StudioPlayerLayerView(player: model.cameraPlayer, gravity: .resizeAspectFill)
            .frame(width: layout.bubbleRect.width, height: layout.bubbleRect.height)
            .clipShape(RoundedRectangle(cornerRadius: layout.bubbleCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: layout.bubbleCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            .shadow(
                color: .black.opacity(0.35),
                radius: min(layout.canvasSize.width, layout.canvasSize.height) * 0.022,
                y: min(layout.canvasSize.width, layout.canvasSize.height) * 0.009
            )
            .position(x: layout.bubbleRect.midX, y: layout.bubbleRect.midY)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartCenter == nil {
                            dragStartCenter = model.style.camera.center
                        }
                        guard let dragStartCenter else { return }
                        let next = CGPoint(
                            x: dragStartCenter.x + value.translation.width / layout.canvasSize.width,
                            y: dragStartCenter.y + value.translation.height / layout.canvasSize.height
                        )
                        model.style.camera.center = CGPoint(
                            x: min(max(next.x, 0), 1),
                            y: min(max(next.y, 0), 1)
                        )
                    }
                    .onEnded { _ in
                        dragStartCenter = nil
                    }
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

// MARK: - Timeline

private struct StudioTimelineEditor: View {
    @Bindable var model: RecordingStudioModel

    var body: some View {
        VStack(spacing: StudioTimelineMetrics.rowSpacing) {
            transport

            VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                Color.clear
                    .frame(height: StudioTimelineMetrics.playheadLaneHeight)

                StudioTimelineRuler(duration: model.duration)
                    .frame(height: 16)

                RecordingClipTimelineView(
                    selectedClipID: $model.selectedClipID,
                    playheadTime: $model.currentTime,
                    timeline: model.clipTimeline,
                    sourceDuration: model.sourceDuration,
                    frames: model.timelineFrames,
                    onSelect: { model.selectClip(id: $0) },
                    onSeek: { time in
                        model.pause()
                        model.seek(to: time)
                    },
                    onHover: { time in
                        model.timelineHoverTime = time
                        model.hoverPreviewTime = time
                    },
                    onSplit: { model.splitClip(at: $0) },
                    onDelete: { model.deleteSelectedClip() },
                    onTrim: { model.trimClip($0) }
                )
                .frame(height: 52)

                StudioZoomLane(model: model)
                    .frame(height: 32)
            }
            .overlay {
                StudioTimelinePlayhead(
                    time: model.currentTime,
                    duration: model.duration
                ) { time in
                    model.pause()
                    model.seek(to: time)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
        }
    }

    private var transport: some View {
        ZStack {
            HStack(spacing: 2) {
                Spacer(minLength: 0)

                timelineButton("Split at Playhead", systemImage: "scissors") {
                    model.splitClip(at: model.currentTime)
                }

                timelineButton("Delete Selection", systemImage: "trash") {
                    deleteSelection()
                }
                .disabled(!canDeleteSelection)

                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 6)

                timelineButton("Undo", systemImage: "arrow.uturn.backward") {
                    model.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)

                timelineButton("Redo", systemImage: "arrow.uturn.forward") {
                    model.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)

                timelineButton("Reset Clips", systemImage: "arrow.counterclockwise") {
                    model.resetClips()
                }
                .disabled(!model.hasClipEdits)
            }

            HStack(spacing: 10) {
                Text(studioPreciseTimecode(model.displayTime))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary.opacity(0.9))

                HStack(spacing: 2) {
                    timelineButton("Back to Start", systemImage: "backward.end.fill") {
                        model.pause()
                        model.seek(to: 0)
                    }

                    Button {
                        model.togglePlayback()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.85))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.primary.opacity(0.07)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .help(model.isPlaying ? "Pause" : "Play")
                    .disabled(!model.isLoaded)

                    timelineButton("Skip to End", systemImage: "forward.end.fill") {
                        model.pause()
                        model.seek(to: model.duration)
                    }
                }

                Text(studioPreciseTimecode(model.duration))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 32)
    }

    private var canDeleteSelection: Bool {
        model.selectedCueID != nil || model.canDeleteSelectedClip
    }

    private func deleteSelection() {
        if let cueID = model.selectedCueID {
            model.removeZoomCue(id: cueID)
        } else if model.selectedClipID != nil {
            model.deleteSelectedClip()
        }
    }

    private func timelineButton(
        _ help: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(TransportIconButtonStyle())
        .help(help)
    }
}

private struct TransportIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                .primary.opacity(
                    isEnabled ? (configuration.isPressed ? 0.95 : 0.6) : 0.22
                )
            )
    }
}

private enum StudioTimelineMetrics {
    static let rowSpacing: CGFloat = 8
    static let playheadLaneHeight: CGFloat = 14
}

/// Full-height playhead with a grabbable crown pin in the lane above the
/// ruler. The crown is the only hit target — everywhere else the overlay
/// passes clicks through to the tracks underneath.
private struct StudioTimelinePlayhead: View {
    let time: TimeInterval
    let duration: TimeInterval
    let onScrub: (TimeInterval) -> Void

    private enum Metrics {
        static let crownWidth: CGFloat = 11
        static let crownHeight: CGFloat = 13
        static let hitWidth: CGFloat = 26
        static let hitHeight: CGFloat = 22
        static let lineWidth: CGFloat = 1.5
    }

    private static let coordinateSpace = "studio.playheadLane"

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = duration > 0 ? min(max(time / duration, 0), 1) : 0
            let x = CGFloat(fraction) * width

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(
                        width: Metrics.lineWidth,
                        height: max(0, proxy.size.height - Metrics.crownHeight + 2)
                    )
                    .offset(x: x - Metrics.lineWidth / 2, y: Metrics.crownHeight - 2)
                    .allowsHitTesting(false)

                Color.clear
                    .frame(width: Metrics.hitWidth, height: Metrics.hitHeight)
                    .contentShape(Rectangle())
                    .overlay(alignment: .top) {
                        PlayheadCrownShape()
                            .fill(Color.accentColor)
                            .frame(width: Metrics.crownWidth, height: Metrics.crownHeight)
                            .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    }
                    .offset(x: x - Metrics.hitWidth / 2, y: 0)
                    .gesture(
                        DragGesture(
                            minimumDistance: 0,
                            coordinateSpace: .named(Self.coordinateSpace)
                        )
                        .onChanged { value in
                            guard duration > 0 else { return }
                            let fraction = min(max(value.location.x / width, 0), 1)
                            onScrub(Double(fraction) * duration)
                        }
                    )
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
    }
}

/// Rounded flag with a pointed tail, the classic editor playhead pin.
private struct PlayheadCrownShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cornerRadius: CGFloat = 3
        let tailHeight: CGFloat = 4
        let bodyBottom = rect.maxY - tailHeight

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + cornerRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: bodyBottom - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - cornerRadius, y: bodyBottom),
            control: CGPoint(x: rect.maxX, y: bodyBottom)
        )
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: bodyBottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: bodyBottom - cornerRadius),
            control: CGPoint(x: rect.minX, y: bodyBottom)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Absolute-time ruler above the trim strip. Its endpoint labels are centered
/// over the trim handles, while the available width determines the interior
/// major and minor tick intervals.
private struct StudioTimelineRuler: View {
    let duration: Double

    var body: some View {
        Canvas { context, size in
            let timelineMinX: CGFloat = 2
            let timelineMaxX = size.width - 2
            let timelineWidth = timelineMaxX - timelineMinX
            guard duration > 0.2, timelineWidth > 60 else { return }

            let step = Self.labelStep(for: duration, width: timelineWidth)
            let pointsPerSecond = timelineWidth / CGFloat(duration)
            var lastLabelMaxX = -CGFloat.greatestFiniteMagnitude

            var minorTime = step / 2
            while minorTime < duration {
                context.fill(
                    Path(CGRect(
                        x: timelineMinX + CGFloat(minorTime) * pointsPerSecond - 0.5,
                        y: size.height - 2.5,
                        width: 1,
                        height: 2.5
                    )),
                    with: .color(.primary.opacity(0.16))
                )
                minorTime += step
            }

            let durationLabel = studioTimecode(duration)
            var time: Double = 0
            while time < duration {
                let x = timelineMinX + CGFloat(time) * pointsPerSecond
                context.fill(
                    Path(CGRect(x: x - 0.5, y: size.height - 4, width: 1, height: 4)),
                    with: .color(.primary.opacity(0.30))
                )

                // A final whole-second tick can format identically to a
                // fractional endpoint (for example 4.2 -> 00:04). Let the
                // actual endpoint own that label.
                let timeLabel = studioTimecode(time)
                if time == 0 || timeLabel != durationLabel {
                    let label = context.resolve(
                        Text(timeLabel)
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.secondary)
                    )
                    let labelSize = label.measure(in: size)
                    let labelX = time == 0 ? timelineMinX : x - labelSize.width / 2
                    if labelX >= lastLabelMaxX + 8 {
                        context.draw(label, in: CGRect(
                            x: labelX,
                            y: size.height - 5 - labelSize.height,
                            width: labelSize.width,
                            height: labelSize.height
                        ))
                        lastLabelMaxX = labelX + labelSize.width
                    }
                }

                time += step
            }

            context.fill(
                Path(CGRect(x: timelineMaxX - 0.5, y: size.height - 4, width: 1, height: 4)),
                with: .color(.primary.opacity(0.30))
            )

            let endpoint = context.resolve(
                Text(durationLabel)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.secondary)
            )
            let endpointSize = endpoint.measure(in: size)
            context.draw(endpoint, in: CGRect(
                x: timelineMaxX - endpointSize.width,
                y: size.height - 5 - endpointSize.height,
                width: endpointSize.width,
                height: endpointSize.height
            ))
        }
    }

    /// Smallest "nice" interval whose labels stay comfortably apart.
    private static func labelStep(for duration: Double, width: CGFloat) -> Double {
        let candidates: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        let pointsPerSecond = width / CGFloat(duration)
        for candidate in candidates where CGFloat(candidate) * pointsPerSecond >= 64 {
            return candidate
        }
        return candidates.last ?? 60
    }
}

private func studioTimecode(_ seconds: Double) -> String {
    let safe = max(0, seconds.isFinite ? seconds : 0)
    let total = Int(safe.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remainingSeconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        : String(format: "%02d:%02d", minutes, remainingSeconds)
}

private func studioPreciseTimecode(_ seconds: Double) -> String {
    let safe = max(0, seconds.isFinite ? seconds : 0)
    let totalMinutes = Int(safe) / 60
    let remaining = safe.truncatingRemainder(dividingBy: 60)
    return String(format: "%02d:%04.1f", totalMinutes, remaining)
}

private struct StudioZoomLane: View {
    @Bindable var model: RecordingStudioModel

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 10)
            let contentWidth = max(width - StudioZoomLaneMetrics.laneInset * 2, 1)
            let secondsPerPoint = model.duration > 0 ? model.duration / contentWidth : 0

            ZStack(alignment: .topLeading) {
                RoundedRectangle(
                    cornerRadius: StudioZoomLaneMetrics.laneCornerRadius,
                    style: .continuous
                )
                    .fill(Color.primary.opacity(0.055))
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: StudioZoomLaneMetrics.laneCornerRadius,
                            style: .continuous
                        )
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard secondsPerPoint > 0 else { return }
                                model.pause()
                                let contentX = min(max(
                                    value.location.x - StudioZoomLaneMetrics.laneInset,
                                    0
                                ), contentWidth)
                                model.seek(to: Double(contentX) * secondsPerPoint)
                            }
                    )

                ForEach(Array(model.visibleRecordedPressTimes.enumerated()), id: \.offset) { _, pressTime in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.38))
                        .frame(width: 1, height: 10)
                        .offset(
                            x: StudioZoomLaneMetrics.laneInset
                                + (model.duration > 0
                                    ? CGFloat(pressTime / model.duration) * contentWidth
                                    : 0),
                            y: 11
                        )
                        .allowsHitTesting(false)
                }

                ForEach(model.zoomTimelineSlices) { slice in
                    StudioZoomCueBlock(
                        model: model,
                        timelineSlice: slice,
                        secondsPerPoint: secondsPerPoint,
                        contentWidth: contentWidth
                    )
                }

            }
            .clipped()
        }
        .contextMenu {
            Button("Add Zoom at Playhead") {
                model.addZoomCue(at: model.currentTime)
            }
        }
    }
}

private enum StudioZoomLaneMetrics {
    static let laneInset: CGFloat = 4
    static let blockCornerRadius: CGFloat = 6
    static let laneCornerRadius = blockCornerRadius + laneInset
    static let selectionRingPadding: CGFloat = 1
    static let selectionRingCornerRadius = blockCornerRadius + selectionRingPadding
}

private struct StudioZoomCueBlock: View {
    @Bindable var model: RecordingStudioModel
    let timelineSlice: RecordingZoomTimelineSlice
    let secondsPerPoint: Double
    let contentWidth: CGFloat

    /// Frozen at drag start. The live slice re-derives on every model update,
    /// so measuring the drag against it would compound the translation each
    /// event and send the block flying.
    private struct DragBase {
        let cue: ZoomCue
        let editorStart: TimeInterval
        let editorEnd: TimeInterval
    }

    @State private var dragBase: DragBase?

    private var isSelected: Bool {
        model.selectedCueID == timelineSlice.cue.id
    }

    var body: some View {
        guard secondsPerPoint > 0 else { return AnyView(EmptyView()) }

        let cue = timelineSlice.cue
        let slice = timelineSlice.slice
        let sliceDuration = slice.editorEnd - slice.editorStart
        let width = min(contentWidth, max(24, CGFloat(sliceDuration / secondsPerPoint)))
        let naturalX = CGFloat(slice.editorStart / secondsPerPoint)
        let x = StudioZoomLaneMetrics.laneInset
            + min(max(naturalX, 0), max(0, contentWidth - width))

        return AnyView(
            HStack(spacing: 0) {
                resizeHandle(edge: .leading)
                Spacer(minLength: 0)
                Text(String(format: "%.1f×", cue.zoom))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                resizeHandle(edge: .trailing)
            }
            .frame(width: width, height: 24)
            .background(
                RoundedRectangle(
                    cornerRadius: StudioZoomLaneMetrics.blockCornerRadius,
                    style: .continuous
                )
                    .fill(Color.accentColor.opacity(isSelected ? 0.95 : 0.72))
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: StudioZoomLaneMetrics.selectionRingCornerRadius,
                        style: .continuous
                    )
                        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                        .padding(-StudioZoomLaneMetrics.selectionRingPadding)
                }
            }
            .offset(x: x, y: 4)
            .gesture(
                // Global coordinates: the block moves under the pointer while
                // dragging, so a local-space translation would chase its own
                // updates and jitter.
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = DragBase(
                                cue: cue,
                                editorStart: slice.editorStart,
                                editorEnd: slice.editorEnd
                            )
                            model.beginZoomCueEdit()
                            model.selectZoomCue(id: cue.id)
                        }
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * secondsPerPoint
                        var moved = dragBase.cue
                        let length = dragBase.cue.duration
                        let baseSliceDuration = dragBase.editorEnd - dragBase.editorStart
                        let editorStart = min(
                            max(0, dragBase.editorStart + delta),
                            max(0, model.duration - baseSliceDuration)
                        )
                        moved.start = min(
                            max(0, model.sourceTime(atEditorTime: editorStart)),
                            max(0, model.sourceDuration - length)
                        )
                        moved.end = min(model.sourceDuration, moved.start + length)
                        model.updateZoomCue(moved)
                    }
                    .onEnded { _ in
                        dragBase = nil
                        model.endZoomCueEdit(actionName: "Move Zoom")
                    }
            )
            .onTapGesture {
                model.selectZoomCue(id: cue.id)
            }
            .contextMenu {
                Button("Remove Zoom", role: .destructive) {
                    model.removeZoomCue(id: cue.id)
                }
            }
        )
    }

    private func resizeHandle(edge: HorizontalEdge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 10, height: 24)
            .overlay(alignment: .center) {
                Capsule()
                    .fill(Color.white.opacity(isSelected ? 0.9 : 0.45))
                    .frame(width: 2.5, height: 12)
            }
            .contentShape(Rectangle())
            .gesture(
                // Global coordinates — the handle itself moves while resizing,
                // so local-space translations feed back into the drag and jitter.
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = DragBase(
                                cue: timelineSlice.cue,
                                editorStart: timelineSlice.slice.editorStart,
                                editorEnd: timelineSlice.slice.editorEnd
                            )
                            model.beginZoomCueEdit()
                            model.selectZoomCue(id: timelineSlice.cue.id)
                        }
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * secondsPerPoint
                        var resized = dragBase.cue
                        switch edge {
                        case .leading:
                            let editorTime = dragBase.editorStart + delta
                            let sourceTime = model.sourceTime(atEditorTime: editorTime)
                            resized.start = min(max(0, sourceTime), dragBase.cue.end - 0.5)
                        case .trailing:
                            let editorTime = dragBase.editorEnd + delta
                            let sourceTime = model.sourceTime(atEditorTime: editorTime)
                            resized.end = max(
                                dragBase.cue.start + 0.5,
                                min(model.sourceDuration, sourceTime)
                            )
                        }
                        model.updateZoomCue(resized)
                    }
                    .onEnded { _ in
                        dragBase = nil
                        model.endZoomCueEdit(actionName: "Resize Zoom")
                    }
            )
    }
}

// MARK: - Inspector

private enum StudioBackgroundKind: String, CaseIterable, Identifiable {
    case color
    case gradient
    case wallpaper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .color: "Color"
        case .gradient: "Gradient"
        case .wallpaper: "Wallpaper"
        }
    }
}

private extension ZoomAnchorMode {
    var inspectorTitle: String {
        switch self {
        case .pointerAnchor: "Pointer"
        case .pinnedAnchor: "Fixed"
        }
    }
}

private enum StudioInspectorSection: Hashable {
    case background
    case layout
    case motion
    case cursor
    case camera
    case export
}

private struct StudioInspector: View {
    @Bindable var model: RecordingStudioModel
    @State private var wallpaperStore = AnnotationWallpaperStore.shared
    @State private var expandedSections: Set<StudioInspectorSection> = [
        .background, .layout, .motion
    ]
    @Environment(\.colorScheme) private var colorScheme

    private let swatchColumns = [GridItem(.adaptive(minimum: 30, maximum: 44), spacing: 6)]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                // Selection editing always surfaces at the top, the way object
                // inspectors do, so clicking a zoom block on the timeline maps
                // to one stable place and the sections below never reshuffle.
                if let selected = model.selectedCue {
                    InspectorSection(
                        title: "Selected Zoom",
                        accessory: {
                            Toggle(
                                "Use this zoom",
                                isOn: Binding(
                                    get: { selected.isEnabled },
                                    set: { isEnabled in
                                        var updated = selected
                                        updated.isEnabled = isEnabled
                                        model.updateZoomCue(updated)
                                    }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help("Use this zoom")
                        }
                    ) {
                        selectedZoomControls(for: selected)
                    }
                    InspectorSectionDivider()
                }

                InspectorDisclosureSection(
                    title: "Background",
                    isExpanded: expansionBinding(for: .background),
                    accessory: {
                        if model.style.background != .none {
                            InspectorClearButton(help: "Remove background") {
                                model.style.background = .none
                            }
                        }
                    }
                ) {
                    backgroundControls
                }

                InspectorDisclosureSection(
                    title: "Layout",
                    isExpanded: expansionBinding(for: .layout),
                    accessory: {
                        if !usesDefaultLayout {
                            InspectorClearButton(help: "Reset layout") {
                                model.style.padding = 0.06
                                model.style.cornerRadius = 0.02
                                model.style.shadow = 0.45
                            }
                        }
                    }
                ) {
                    layoutControls
                }

                InspectorDisclosureSection(
                    title: "Zoom & Clicks",
                    isExpanded: expansionBinding(for: .motion),
                    accessory: {
                        Toggle("Enable zooms", isOn: $model.zoomEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                ) {
                    zoomControls
                }

                if model.pointerIsSynthesized {
                    InspectorDisclosureSection(
                        title: "Cursor",
                        isExpanded: expansionBinding(for: .cursor),
                        accessory: {
                            if model.style.cursorScale != RecordingStudioStyle.defaultCursorScale {
                                InspectorClearButton(help: "Reset cursor size") {
                                    model.style.cursorScale = RecordingStudioStyle.defaultCursorScale
                                }
                            }
                        }
                    ) {
                        cursorControls
                    }
                }

                if model.hasCameraVideo {
                    InspectorDisclosureSection(
                        title: "Camera",
                        isExpanded: expansionBinding(for: .camera),
                        accessory: {
                            Toggle("Show camera", isOn: $model.style.camera.isVisible)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                        }
                    ) {
                        cameraControls
                    }
                }

                InspectorDisclosureSection(
                    "Export",
                    isExpanded: expansionBinding(for: .export)
                ) {
                    exportControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, PreviewPeekTab.pillHeight * 1.1)
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectSoftIfAvailable()
        .background(sidebarBackground)
        .inspectorColumnWidth(min: 260, ideal: 280, max: 440)
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await wallpaperStore.reload()
        }
    }

    // MARK: Background

    private var backgroundKind: StudioBackgroundKind? {
        switch model.style.background {
        case .none: nil
        case .solid: .color
        case .gradient: .gradient
        case .customWallpaper: .wallpaper
        }
    }

    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSegmented(
                options: StudioBackgroundKind.allCases,
                isSelected: { $0 == backgroundKind },
                onTap: { kind in
                    switch kind {
                    case .color:
                        model.style.background = .solid(.graphite)
                    case .gradient:
                        model.style.background = RecordingStudioStyle.defaultBackground
                    case .wallpaper:
                        if let wallpaper = availableWallpapers.first {
                            selectWallpaper(wallpaper)
                        } else {
                            pickWallpaper()
                        }
                    }
                },
                label: { Text($0.title).font(.inspectorLabel) }
            )

            if backgroundKind == .color {
                LazyVGrid(columns: swatchColumns, spacing: 6) {
                    ForEach(AnnotationBackgroundColor.plainPresets) { preset in
                        InspectorTile(
                            isSelected: model.style.background == .solid(preset),
                            action: { model.style.background = .solid(preset) }
                        ) {
                            preset.color
                        }
                    }
                }
            }

            if backgroundKind == .gradient {
                LazyVGrid(columns: swatchColumns, spacing: 6) {
                    ForEach(AnnotationBackgroundGradient.presets) { preset in
                        InspectorTile(
                            isSelected: model.style.background == .gradient(preset),
                            action: { model.style.background = .gradient(preset) }
                        ) {
                            LinearGradient(
                                colors: preset.colors.map(\.color),
                                startPoint: preset.startPoint,
                                endPoint: preset.endPoint
                            )
                        }
                    }
                }
            }

            if backgroundKind == .wallpaper {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 7)], spacing: 7) {
                    ForEach(availableWallpapers.prefix(12)) { wallpaper in
                        InspectorTile(
                            aspectRatio: 1.35,
                            isSelected: model.style.background == .customWallpaper(wallpaper),
                            action: { selectWallpaper(wallpaper) }
                        ) {
                            AnnotationCustomWallpaperPreview(wallpaper: wallpaper)
                        }
                        .help(wallpaper.title)
                    }
                }

                inspectorAction("Choose Image…", systemImage: "photo.badge.plus") {
                    pickWallpaper()
                }
            }
        }
    }

    private var availableWallpapers: [AnnotationCustomWallpaper] {
        let candidates = wallpaperStore.recentWallpapers
            + AnnotationWallpaperPack.builtIn.flatMap { wallpaperStore.wallpapers(for: $0) }
        var paths = Set<String>()
        return candidates.filter { wallpaper in
            paths.insert(wallpaper.url.standardizedFileURL.path).inserted
        }
    }

    private func selectWallpaper(_ wallpaper: AnnotationCustomWallpaper) {
        wallpaperStore.addRecentWallpaper(wallpaper.url)
        model.style.background = .customWallpaper(wallpaper)
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
            selectWallpaper(AnnotationCustomWallpaper(url: url))
        }
    }

    // MARK: Layout

    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSlider(
                "Padding",
                value: $model.style.padding,
                range: 0...0.18,
                format: .percent()
            )
            InspectorSlider(
                "Corners",
                value: $model.style.cornerRadius,
                range: 0...0.08,
                format: .percent()
            )
            InspectorSlider(
                "Shadow",
                value: $model.style.shadow,
                range: 0...1,
                format: .percent()
            )
        }
    }

    // MARK: Zoom

    private var zoomControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            let pressCount = model.recordedPressTimes.count
            Text(pressCount == 1 ? "1 recorded click" : "\(pressCount) recorded clicks")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)

            HStack(spacing: 7) {
                inspectorAction("Auto Zoom", systemImage: "pointer.arrow.rays") {
                    model.resynthesizeZoomCues()
                }
                .disabled(pressCount == 0)

                inspectorAction("Add Zoom", systemImage: "plus.magnifyingglass") {
                    model.addZoomCue(at: model.currentTime)
                }
            }

            if model.selectedCue == nil {
                Text(model.zoomCues.isEmpty
                    ? "Click Auto Zoom to turn recorded clicks into smooth camera moves."
                    : "Select a zoom block on the timeline to adjust it.")
                    .font(.inspectorLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!model.zoomEnabled)
        .opacity(model.zoomEnabled ? 1 : 0.48)
    }

    private func selectedZoomControls(for selected: ZoomCue) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Camera Focus")

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
                        model.updateZoomCue(updated)
                    },
                    label: { Text($0.inspectorTitle).font(.inspectorLabel) }
                )
            }

            InspectorSlider(
                "Zoom Amount",
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

            if selected.anchorMode == .pinnedAnchor {
                InspectorSlider(
                    "Target X",
                    value: Binding(
                        get: { selected.pinnedPoint.x },
                        set: { targetX in
                            var updated = selected
                            updated.pinnedPoint.x = targetX
                            model.updateZoomCue(updated)
                        }
                    ),
                    range: 0...1,
                    format: .percent()
                )
                InspectorSlider(
                    "Target Y",
                    value: Binding(
                        get: { selected.pinnedPoint.y },
                        set: { targetY in
                            var updated = selected
                            updated.pinnedPoint.y = targetY
                            model.updateZoomCue(updated)
                        }
                    ),
                    range: 0...1,
                    format: .percent()
                )
                inspectorAction("Set Target to Pointer", systemImage: "scope") {
                    guard let pointer = model.pointerLocation(at: model.currentTime) else { return }
                    var updated = selected
                    updated.pinnedPoint = pointer
                    model.updateZoomCue(updated)
                }
            } else {
                InspectorSlider(
                    "Edge in Frame",
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
            }

            inspectorAction(
                "Remove Zoom",
                systemImage: "trash",
                role: .destructive
            ) {
                model.removeZoomCue(id: selected.id)
            }
            .help("Remove the selected zoom")
        }
        .disabled(!model.zoomEnabled)
        .opacity(model.zoomEnabled ? 1 : 0.48)
    }

    // MARK: Cursor

    private var cursorControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSlider(
                "Size",
                value: $model.style.cursorScale,
                range: 1...4,
                format: .magnification(fractionDigits: 1)
            )
        }
    }

    // MARK: Camera

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSlider(
                "Size",
                value: $model.style.camera.size,
                range: 0.12...0.45,
                format: .percent()
            )
            InspectorSlider(
                "Rounding",
                value: $model.style.camera.roundness,
                range: 0.05...0.5,
                format: .percent()
            )

            Text("Drag the camera directly on the canvas to place it.")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!model.style.camera.isVisible)
        .opacity(model.style.camera.isVisible ? 1 : 0.48)
    }

    // MARK: Export

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorGroupLabel("Quality")
            InspectorSegmented(
                options: VideoCompressionQuality.allCases,
                isSelected: { $0 == model.exportSettings.quality },
                onTap: { model.exportSettings.quality = $0 },
                label: { Text($0.rawValue).font(.inspectorLabel) }
            )

            InspectorGroupLabel("Codec")
            InspectorSegmented(
                options: VideoCompressionCodec.allCases,
                isSelected: { $0 == model.exportSettings.codec },
                onTap: { model.exportSettings.codec = $0 },
                label: { Text($0.rawValue).font(.inspectorLabel) }
            )

            InspectorGroupLabel("Resolution")
            InspectorSegmented(
                options: VideoCompressionResolution.allCases,
                isSelected: { $0 == model.exportSettings.resolution },
                onTap: { model.exportSettings.resolution = $0 },
                label: { Text($0.rawValue).font(.inspectorLabel) }
            )

            HStack(spacing: 8) {
                Text("Include audio")
                    .font(.inspectorLabel)
                    .foregroundStyle(.primary.opacity(0.82))

                Spacer(minLength: 8)

                Toggle(
                    "Include audio",
                    isOn: Binding(
                        get: { !model.exportSettings.removeAudio },
                        set: { model.exportSettings.removeAudio = !$0 }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Text("Screen, camera, zooms, and selected audio are rendered together in one pass.")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usesDefaultLayout: Bool {
        abs(model.style.padding - 0.06) < 0.0001
            && abs(model.style.cornerRadius - 0.02) < 0.0001
            && abs(model.style.shadow - 0.45) < 0.0001
    }

    private var sidebarBackground: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white
    }

    private func expansionBinding(for section: StudioInspectorSection) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(section) },
            set: { isExpanded in
                if isExpanded {
                    expandedSections.insert(section)
                } else {
                    expandedSections.remove(section)
                }
            }
        )
    }

    private func inspectorAction(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.inspectorValue)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .inspectorField(height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red.opacity(0.88) : Color.primary)
    }
}
