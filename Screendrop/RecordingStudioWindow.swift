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
                    model.export()
                } label: {
                    if model.exportState.isExporting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Exporting…")
                        }
                    } else {
                        Label("Export", systemImage: "arrow.down.circle")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .tint(.accentColor)
                .disabled(!model.isLoaded || model.exportState.isExporting)

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
            guard let selectedCueID = model.selectedCueID else { return }
            model.removeZoomCue(id: selectedCueID)
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
            EmptyView()
        case .exporting(let progress):
            ProgressView(value: progress)
                .frame(width: 92)
        case .finished(let url):
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Reveal", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .help("Reveal exported recording in Finder")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(message)
        }
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
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(model.isPlaying ? "Pause" : "Play")
                .disabled(!model.isLoaded)

                VideoTrimTimelineView(
                    selection: Binding(
                        get: { model.trimSelection },
                        set: { model.setTrimSelection($0) }
                    ),
                    playheadTime: $model.currentTime,
                    duration: model.duration,
                    frames: model.timelineFrames,
                    onSeek: { time in
                        model.pause()
                        model.seek(to: time)
                    }
                )
                .frame(height: 54)

                Button {
                    model.resetTrim()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.58))
                .help("Reset trim")
                .disabled(!model.isTrimmed)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)

            HStack(spacing: 10) {
                Label("Zoom", systemImage: "plus.magnifyingglass")
                    .font(.inspectorLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)

                StudioZoomLane(model: model)
                    .frame(height: 32)

                Button {
                    model.addZoomCue(at: model.currentTime)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 28)
                }
                .buttonStyle(.plain)
                .help("Add zoom at playhead")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
        }
    }
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

                ForEach(Array(model.recordedPressTimes.enumerated()), id: \.offset) { _, pressTime in
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

                ForEach(model.zoomCues.filter { !$0.isImplicit }) { cue in
                    StudioZoomCueBlock(
                        model: model,
                        cue: cue,
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
    let cue: ZoomCue
    let secondsPerPoint: Double
    let contentWidth: CGFloat

    @State private var dragBase: ZoomCue?

    private var isSelected: Bool {
        model.selectedCueID == cue.id
    }

    var body: some View {
        guard secondsPerPoint > 0 else { return AnyView(EmptyView()) }

        let width = min(contentWidth, max(24, CGFloat(cue.duration / secondsPerPoint)))
        let naturalX = CGFloat(cue.start / secondsPerPoint)
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
                            dragBase = cue
                            model.selectedCueID = cue.id
                        }
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * secondsPerPoint
                        var moved = dragBase
                        let length = dragBase.duration
                        moved.start = min(max(0, dragBase.start + delta), max(0, model.duration - length))
                        moved.end = moved.start + length
                        model.updateZoomCue(moved)
                    }
                    .onEnded { _ in
                        dragBase = nil
                    }
            )
            .onTapGesture {
                model.selectedCueID = cue.id
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
                            dragBase = cue
                            model.selectedCueID = cue.id
                        }
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * secondsPerPoint
                        var resized = dragBase
                        switch edge {
                        case .leading:
                            resized.start = min(max(0, dragBase.start + delta), dragBase.end - 0.5)
                        case .trailing:
                            resized.end = max(dragBase.start + 0.5, min(model.duration, dragBase.end + delta))
                        }
                        model.updateZoomCue(resized)
                    }
                    .onEnded { _ in
                        dragBase = nil
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
        .background, .motion, .camera
    ]
    @Environment(\.colorScheme) private var colorScheme

    private let swatchColumns = [GridItem(.adaptive(minimum: 30, maximum: 44), spacing: 6)]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                clipSection
                InspectorSectionDivider()

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

    // MARK: Clip

    private var clipSection: some View {
        InspectorSection("Clip") {
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorRow("Start") {
                    Text(timecode(model.trimSelection.start))
                        .font(.inspectorNumeric)
                }
                InspectorRow("End") {
                    Text(timecode(model.trimSelection.end))
                        .font(.inspectorNumeric)
                }
                InspectorRow("Length") {
                    Text(timecode(model.trimSelection.duration))
                        .font(.inspectorNumeric)
                }

                if model.isTrimmed {
                    inspectorAction("Reset Trim", systemImage: "arrow.counterclockwise") {
                        model.resetTrim()
                    }
                }
            }
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

            if let selected = model.selectedCue {
                HStack(spacing: 8) {
                    Text("Use this zoom")
                        .font(.inspectorLabel)
                        .foregroundStyle(.primary.opacity(0.82))

                    Spacer(minLength: 8)

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
                    .controlSize(.small)
                }

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
            } else {
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

            Toggle(
                "Include audio",
                isOn: Binding(
                    get: { !model.exportSettings.removeAudio },
                    set: { model.exportSettings.removeAudio = !$0 }
                )
            )
            .font(.inspectorLabel)
            .toggleStyle(.switch)
            .controlSize(.small)

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

    private func timecode(_ seconds: Double) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        let total = Int(safe.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainingSeconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%02d:%02d", minutes, remainingSeconds)
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
