//
//  RecordingStudioTimelineDock.swift
//  Screendrop
//
//  The Studio timeline: a glass control row over the tracks. Edit tools sit
//  on the left, transport in the middle, timeline zoom on the right - each a
//  cluster of glass shapes in its own container. Tools that only mean
//  something in context are born out of their neighbour when they start to
//  apply and melt back into it when they stop: Delete grows out of Split
//  once something is selected, Reset appears beside Undo once the cut has
//  edits, and the fit chip grows out of the zoom buttons once the lanes are
//  zoomed.
//
//  Under the row the tracks follow the web editor: a gutter of glyphs names
//  each track, every track is a flat full-width row, and the ruler labels
//  its major ticks from their leading edge.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StudioTimelineDock: View {
    @Bindable var model: RecordingStudioModel

    /// Horizontal scale of the lanes, as a multiplier over "the whole
    /// recording fits the viewport". Zoom 1 is the timeline's original
    /// fixed-width layout; anything above it scrolls.
    @State private var zoom: Double = 1
    @State private var viewportWidth: CGFloat = 1
    @State private var scrollX: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var isResetClipsConfirmationPresented = false
    /// The pointer's position over the lanes, in viewport points.
    @State private var skimX: CGFloat?
    /// The playhead is being dragged along the ruler, the clips or an
    /// empty track, which opens its head into the time readout.
    @State private var isScrubbing = false
    /// The + has opened into the things that can be added.
    @State private var isAddOpen = false
    /// Files being dragged over the tracks: which tracks they'll land on,
    /// and when.
    @State private var mediaDrop: StudioMediaDrop?
    /// The height the tracks were given by dragging the dock's top edge,
    /// kept across projects and launches; 0 shows every track.
    @AppStorage("StudioTimelineTracksHeight") private var storedTracksHeight: Double = 0
    /// The tracks' height when a resize drag began.
    @State private var resizeBase: CGFloat?
    /// How far the tracks are scrolled down, which the gutter follows.
    @State private var scrollY: CGFloat = 0
    @State private var verticalScrollPosition = ScrollPosition(edge: .top)
    @Namespace private var glass

    /// Below this track width the opened + shows bare glyphs, so the edit
    /// tools never run under the transport.
    private static let addLabelsMinimumWidth: CGFloat = 820
    /// Step per zoom button press / keyboard shortcut.
    private static let zoomStep: Double = 1.6
    /// How close to the viewport edge the playhead may drift before the
    /// lanes scroll to keep it in sight.
    private static let followMargin: CGFloat = 48

    private var scale: StudioTimelineScale {
        StudioTimelineScale(
            viewportWidth: viewportWidth,
            duration: model.duration,
            zoom: zoom
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            controlRow
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            // As in the web editor, a hairline closes the tool row off from
            // the tracks edge to edge, and the gutter's own line runs from
            // it to the bottom of the dock.
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                trackGutter
                lanes
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
        }
        .overlay(alignment: .top) { resizeHandle }
    }

    // MARK: Height

    /// Every track, with the room after the last.
    private var fullTracksHeight: CGFloat {
        StudioTimelineMetrics.scrollingLanesHeight(tracks: tracks)
    }

    /// The height the tracks get: what the dock was dragged to, never more
    /// than every track needs and never less than the clips.
    private var visibleTracksHeight: CGFloat {
        let full = fullTracksHeight
        guard storedTracksHeight > 0 else { return full }
        return min(full, max(StudioTimelineMetrics.minimumTracksHeight, CGFloat(storedTracksHeight)))
    }

    /// The dock's top edge trades height between the preview and the
    /// tracks, following the pointer exactly. A double-click opens it back
    /// up to every track.
    private var resizeHandle: some View {
        Color.clear
            .frame(height: 7)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .top))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = resizeBase ?? visibleTracksHeight
                        if resizeBase == nil { resizeBase = base }
                        let full = fullTracksHeight
                        let height = min(full, max(StudioTimelineMetrics.minimumTracksHeight, base - value.translation.height))
                        // Dragged all the way open means "every track", so a
                        // track that appears later still shows.
                        storedTracksHeight = height >= full - 0.5 ? 0 : Double(height)
                        keepClipsInView(height: height)
                    }
                    .onEnded { _ in resizeBase = nil }
            )
            .onTapGesture(count: 2) {
                withAnimation(.fold) { storedTracksHeight = 0 }
            }
            .help("Drag to resize the timeline. Double-click to show every track.")
            .offset(y: -3)
    }

    /// Shrinking the tracks scrolls them so the clips stay on screen.
    private func keepClipsInView(height: CGFloat) {
        var top: CGFloat = 0
        for track in tracks {
            if track == .clips { break }
            top += track.height + StudioTimelineMetrics.trackSpacing
        }
        let bottom = top + StudioTrack.clips.height
        if scrollY > top {
            scrollY = top
            verticalScrollPosition.scrollTo(y: top)
        } else if scrollY + height < bottom {
            scrollY = bottom - height
            verticalScrollPosition.scrollTo(y: bottom - height)
        }
    }

    // MARK: Control row

    private var controlRow: some View {
        ZStack {
            HStack(spacing: 0) {
                editCluster
                Spacer(minLength: 0)
                zoomCluster
            }

            transport
        }
        .frame(height: 38)
        .motion(.morph, value: clusterKey)
    }

    /// Changes when a contextual tool appears or leaves, so the clusters
    /// morph once per change rather than on every model update.
    private var clusterKey: [Bool] {
        [canDeleteSelection, isAddOpen, model.canUndo, model.canRedo, zoom > 1.0001]
    }

    private var editCluster: some View {
        GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
            HStack(spacing: GlassMetrics.gap) {
                GlassIconButton(systemImage: "scissors", help: "Split at Playhead (⌘B)") {
                    model.splitClip(at: model.currentTime)
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!model.isLoaded)
                .glassEffectID("split", in: glass)

                addTools

                if canDeleteSelection {
                    GlassIconButton(systemImage: "trash", help: "Delete Selection (⌫)") {
                        deleteSelection()
                    }
                    .glassEffectID("delete", in: glass)
                }

                GlassIconButton(systemImage: "arrow.uturn.backward", help: "Undo (⌘Z)") {
                    model.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
                .glassEffectID("undo", in: glass)
                .padding(.leading, 6)

                GlassIconButton(systemImage: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") {
                    model.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
                .glassEffectID("redo", in: glass)
            }
        }
        .confirmationDialog(
            "Reset all clip edits?",
            isPresented: $isResetClipsConfirmationPresented
        ) {
            Button("Reset Clips", role: .destructive) {
                model.resetClips()
            }
        } message: {
            Text("Every split, trim, deletion and speed change goes back to the original recording. You can undo this.")
        }
    }

    /// One + that opens into the things that can be added over the video,
    /// melting out of it the way Delete grows out of Split, and folding
    /// back once one is picked. Labels show when the row has room for them.
    @ViewBuilder
    private var addTools: some View {
        GlassIconButton(
            systemImage: isAddOpen ? "xmark" : "plus",
            help: isAddOpen ? "Close" : "Add Text, Pixelate or Media"
        ) {
            withAnimation(.morphIfAllowed) { isAddOpen.toggle() }
        }
        .disabled(!model.isLoaded)
        .motion(.morphQuick, value: isAddOpen)
        .glassEffectID("add", in: glass)

        if isAddOpen {
            addTool("Text", systemImage: "textformat", help: "Add Text at Playhead") {
                model.addText(atEditorTime: model.currentTime)
            }
            .glassEffectID("text", in: glass)

            addTool("Pixelate", systemImage: "squareshape.split.3x3", help: "Pixelate Part of the Picture") {
                model.addRedaction(atEditorTime: model.currentTime)
            }
            .glassEffectID("pixelate", in: glass)

            addTool(
                "Media",
                systemImage: "photo.badge.plus",
                help: model.mediaDirectoryURL == nil
                    ? "Save this recording as a project to add images and audio"
                    : "Add Images, GIFs or Audio at Playhead"
            ) {
                pickMedia()
            }
            .disabled(!model.canImportMedia)
            .glassEffectID("media", in: glass)
        }
    }

    @ViewBuilder
    private func addTool(
        _ title: String,
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        let run = {
            model.pause()
            withAnimation(.morphIfAllowed) {
                isAddOpen = false
                action()
            }
        }
        if viewportWidth >= Self.addLabelsMinimumWidth {
            GlassCapsuleButton(title: title, systemImage: systemImage, action: run)
                .help(help)
        } else {
            GlassIconButton(systemImage: systemImage, help: help, action: run)
        }
    }

    /// Current time, the three playback buttons, and the cut's length. The
    /// play button is the one large shape; its glyph swaps with a symbol
    /// replace so the glass itself never jumps.
    private var transport: some View {
        HStack(spacing: 12) {
            Text(studioPreciseTimecode(model.displayTime))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.9))
                .frame(width: 58, alignment: .trailing)

            GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
                HStack(spacing: GlassMetrics.gap) {
                    GlassIconButton(systemImage: "backward.end.fill", help: "Back to Start") {
                        model.pause()
                        model.seek(to: 0)
                    }

                    GlassIconButton(
                        systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                        help: model.isPlaying ? "Pause (Space)" : "Play (Space)",
                        size: 38,
                        symbolSize: 15
                    ) {
                        model.togglePlayback()
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .motion(.morphQuick, value: model.isPlaying)

                    GlassIconButton(systemImage: "forward.end.fill", help: "Skip to End") {
                        model.pause()
                        model.seek(to: model.duration)
                    }
                }
            }
            .disabled(!model.isLoaded)

            Text(studioPreciseTimecode(model.duration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
        }
    }

    private var zoomCluster: some View {
        GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
            HStack(spacing: GlassMetrics.gap) {
                if zoom > 1.0001 {
                    GlassCapsuleButton(
                        title: String(format: "%.1f×", zoom),
                        systemImage: "arrow.left.and.right"
                    ) {
                        fitTimeline()
                    }
                    .keyboardShortcut("0", modifiers: .command)
                    .help("Fit Timeline (⌘0)")
                    .glassEffectID("fit", in: glass)
                }

                GlassIconButton(systemImage: "minus.magnifyingglass", help: "Zoom Out (⌘-)") {
                    applyZoom(factor: 1 / Self.zoomStep, anchorTime: buttonZoomAnchor)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoom <= 1.0001)
                .glassEffectID("zoomOut", in: glass)

                GlassIconButton(systemImage: "plus.magnifyingglass", help: "Zoom In (⌘=)") {
                    applyZoom(factor: Self.zoomStep, anchorTime: buttonZoomAnchor)
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(zoom >= scale.maxZoom - 0.0001)
                .glassEffectID("zoomIn", in: glass)
            }
        }
    }

    // MARK: Tracks

    /// The tracks top to bottom: what goes over the picture above the clips,
    /// what changes the camera below them, sound last. Layouts arrange the
    /// camera, so a recording without one has no layout track.
    private var tracks: [StudioTrack] {
        var tracks: [StudioTrack] = [.text, .overlay, .clips, .zooms]
        if model.hasCameraVideo { tracks.append(.layouts) }
        tracks.append(.audio)
        return tracks
    }

    /// One glyph per track beside its row, over a hairline that keeps the
    /// column apart from the tracks.
    private var trackGutter: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: StudioTimelineMetrics.headerHeight + StudioTimelineMetrics.trackSpacing)
            // The glyphs ride the tracks' vertical scroll, so each stays
            // beside its row in a short timeline.
            VStack(spacing: StudioTimelineMetrics.trackSpacing) {
                ForEach(tracks) { track in
                    Image(systemName: track.systemImage)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Palette.secondaryLabel)
                        .frame(maxWidth: .infinity)
                        .frame(height: track.height)
                        .contentShape(Rectangle())
                        .help(track.title)
                        .accessibilityLabel(track.title)
                }
            }
            .offset(y: -scrollY)
            .frame(height: visibleTracksHeight, alignment: .top)
            .clipped()
        }
        .frame(width: StudioTimelineMetrics.gutterWidth)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Palette.hairline)
                .frame(width: 1)
        }
    }

    private var lanes: some View {
        GeometryReader { proxy in
            // The proxy width leads the stored one by a frame, so lay the
            // lanes out from it and keep the state copy for the controls.
            let scale = StudioTimelineScale(
                viewportWidth: max(proxy.size.width, 1),
                duration: model.duration,
                zoom: zoom
            )

            VStack(spacing: StudioTimelineMetrics.trackSpacing) {
                // Clicking or dragging along the ruler, or the strip above
                // it, moves the playhead there.
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: StudioTimelineMetrics.playheadLaneHeight)

                    StudioTimelineRuler(
                        duration: model.duration,
                        pointsPerSecond: scale.pointsPerSecond,
                        scrollX: scrollX
                    )
                    .frame(height: StudioTimelineMetrics.rulerHeight)
                }
                .contentShape(Rectangle())
                .gesture(scrubGesture(scale: scale, scrollX: scrollX))

                // The ruler stays put while the tracks scroll under it when
                // the dock is shorter than they are.
                ScrollView(.vertical) {
                    scrollingLanes(scale: scale)
                }
                .scrollPosition($verticalScrollPosition)
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, offset in
                    if abs(offset - scrollY) > 0.01 {
                        scrollY = offset
                    }
                }
                .frame(height: visibleTracksHeight)
            }
            // Hovering anywhere over the timeline - ruler, clips or zoom
            // lane - skims the preview to that moment.
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    skimX = location.x
                    let time = scale.time(forX: location.x + scrollX)
                    model.timelineHoverTime = time
                    model.hoverPreviewTime = time
                case .ended:
                    skimX = nil
                    model.timelineHoverTime = nil
                    model.hoverPreviewTime = nil
                }
            }
            .overlay {
                StudioTimelinePlayhead(
                    time: model.currentTime,
                    scale: scale,
                    scrollX: scrollX,
                    skimX: skimX,
                    showsSkim: !model.isPlaying,
                    isScrubbing: isScrubbing
                ) { time in
                    model.pause()
                    model.seek(to: time)
                }
                .transaction { $0.animation = nil }
            }
            .onChange(of: proxy.size.width, initial: true) { _, width in
                viewportWidth = max(width, 1)
                clampZoom()
            }
            // Images and audio dropped from Finder land where they're let
            // go; while they're dragged over, the track each kind will land
            // on lights up with a mark at the drop point.
            .onDrop(of: [.fileURL], delegate: StudioMediaDropDelegate(
                canDrop: model.canImportMedia,
                time: { scale.time(forX: $0.x + scrollX) },
                onPreview: { preview in
                    if preview != mediaDrop { mediaDrop = preview }
                },
                onDrop: { urls, time in
                    model.importMedia(urls, atEditorTime: time)
                }
            ))
        }
        .frame(height: StudioTimelineMetrics.headerHeight + StudioTimelineMetrics.trackSpacing + visibleTracksHeight)
        .alert(
            "Some files weren't added",
            isPresented: Binding(
                get: { model.mediaImportError != nil },
                set: { if !$0 { model.mediaImportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.mediaImportError = nil }
        } message: {
            Text(model.mediaImportError ?? "")
        }
        .onChange(of: model.duration) { _, _ in clampZoom() }
        .onChange(of: model.currentTime) { _, time in followPlayhead(to: time) }
    }

    /// Press-and-drag that moves the playhead, for the ruler and for tracks
    /// with nothing under the pointer. `offset` turns the gesture's x into
    /// timeline x: the viewport's scroll for the ruler, zero inside the
    /// scrolled tracks.
    private func scrubGesture(
        scale: StudioTimelineScale,
        scrollX offset: CGFloat,
        deselects: Bool = false
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isScrubbing {
                    isScrubbing = true
                    model.pause()
                    if deselects { deselectAll() }
                }
                model.seek(to: scale.time(forX: value.location.x + offset))
            }
            .onEnded { _ in isScrubbing = false }
    }

    /// The tracks that carry real edit targets live in a horizontal scroll
    /// view sized to the zoomed timeline. The ruler, playhead and track
    /// grounds stay viewport-sized and redraw against `scrollX` instead - a
    /// shape or Canvas tens of thousands of points wide would be a single
    /// oversized layer, while an AppKit view only ever draws its visible rect.
    private func scrollingLanes(scale: StudioTimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: StudioTimelineMetrics.trackSpacing) {
                ForEach(tracks) { track in
                    let isDropTarget = mediaDrop?.tracks.contains(track) == true
                    StudioTrackGround(
                        hint: isDropTarget ? dropHint(for: track) : hint(for: track),
                        dropX: isDropTarget ? mediaDrop.map { scale.x(for: $0.time) - scrollX } : nil
                    )
                    .frame(height: track.height)
                }
                Color.clear
                    .frame(height: StudioTimelineMetrics.scrollerGutter)
            }

            ScrollView(.horizontal) {
                VStack(spacing: StudioTimelineMetrics.trackSpacing) {
                    ForEach(tracks) { track in
                        laneContent(for: track, scale: scale)
                            .frame(width: scale.contentWidth, height: track.height)
                    }

                    Color.clear
                        .frame(height: StudioTimelineMetrics.scrollerGutter)
                }
            }
            .scrollPosition($scrollPosition)
            // Blocks and clips land where an edit puts them, even when the
            // edit came from an animated inspector or tool-row action.
            .transaction { $0.animation = nil }
            .scrollIndicators(scale.isScrollable ? .visible : .never)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, offset in
                if abs(offset - scrollX) > 0.01 {
                    scrollX = offset
                }
            }
        }
        .frame(height: StudioTimelineMetrics.scrollingLanesHeight(tracks: tracks))
    }

    @ViewBuilder
    private func laneContent(for track: StudioTrack, scale: StudioTimelineScale) -> some View {
        switch track {
        case .clips:
            clipLane
        case .zooms:
            StudioZoomLane(
                model: model,
                scale: scale,
                visibleRange: scale.visibleRange(scrollX: scrollX)
            )
        case .layouts:
            StudioLayoutLane(
                model: model,
                scale: scale,
                visibleRange: scale.visibleRange(scrollX: scrollX)
            )
        case .text:
            StudioTextLane(
                model: model,
                scale: scale,
                visibleRange: scale.visibleRange(scrollX: scrollX),
                onScrubbing: { isScrubbing = $0 }
            )
        case .overlay:
            StudioRedactionLane(
                model: model,
                scale: scale,
                visibleRange: scale.visibleRange(scrollX: scrollX),
                onScrubbing: { isScrubbing = $0 }
            )
        case .audio:
            StudioAudioLane(
                model: model,
                scale: scale,
                visibleRange: scale.visibleRange(scrollX: scrollX),
                onScrubbing: { isScrubbing = $0 }
            )
        }
    }

    /// What a track says while files that will land on it are dragged over.
    private func dropHint(for track: StudioTrack) -> String? {
        switch track {
        case .overlay: "Drop to add over the video"
        case .audio: "Drop to add under the video"
        default: nil
        }
    }

    /// An empty track explains itself at its leading edge instead of
    /// reading as dead space.
    private func hint(for track: StudioTrack) -> String? {
        switch track {
        case .zooms:
            model.zoomEnabled && model.zoomTimelineBlocks.isEmpty ? "Drag across to add a zoom" : nil
        case .layouts:
            model.cameraLayoutCues.isEmpty ? "Drag across to change the camera layout" : nil
        case .text:
            model.textOverlays.isEmpty ? "Drag across to add text" : nil
        case .overlay:
            model.redactions.isEmpty && model.imageOverlays.isEmpty
                ? "Add images and GIFs, or pixelate part of the picture, with +"
                : nil
        case .audio:
            model.audioClips.isEmpty ? "Drop music or sound here, or add it with +" : nil
        case .clips:
            nil
        }
    }

    private func deselectAll() {
        model.clearTimelineSelection()
    }

    private var clipLane: some View {
        RecordingClipTimelineView(
            selectedClipID: $model.selectedClipID,
            playheadTime: $model.currentTime,
            timeline: model.clipTimeline,
            sourceDuration: model.sourceDuration,
            thumbnails: model.timelineThumbnails,
            onSelect: { model.selectClip(id: $0) },
            onSeek: { time in
                model.pause()
                model.seek(to: time)
            },
            onHover: { time in
                // The lanes' own hover tracking owns skimming and clears it
                // on leaving the timeline; this only backs it up while the
                // pointer is over the AppKit strip.
                guard let time else { return }
                model.timelineHoverTime = time
                model.hoverPreviewTime = time
            },
            onSplit: { model.splitClip(at: $0) },
            onDelete: { deleteSelection() },
            onTrim: { model.trimClip($0) },
            onZoom: { factor, anchorTime in
                applyZoom(factor: factor, anchorTime: anchorTime)
            },
            onStep: { seconds in
                model.pause()
                model.seek(to: model.currentTime + seconds)
            },
            onSetSpeed: { clipID, speed in
                model.setClipSpeed(speed, forClipID: clipID)
            },
            title: model.projectDisplayName,
            onScrubbing: { isScrubbing = $0 },
            // Rarely needed, so it waits in the clips' own menu rather
            // than taking a place in the tool row.
            onResetAll: model.hasClipEdits ? { isResetClipsConfirmationPresented = true } : nil
        )
    }

    // MARK: Zoom & scroll

    /// Rescales around `anchorTime`, keeping that moment under the same
    /// screen position so pinching or ⌘-scrolling doesn't shove the edit
    /// you were aiming at out of the viewport.
    private func applyZoom(factor: Double, anchorTime: TimeInterval?) {
        let current = scale
        guard current.duration > 0, factor.isFinite, factor > 0 else { return }
        let anchor = anchorTime ?? current.time(forX: scrollX + viewportWidth / 2)
        let anchorViewportX = current.x(for: anchor) - scrollX
        let next = min(max(zoom * factor, 1), current.maxZoom)
        guard abs(next - zoom) > 0.0001 else { return }

        // A pinch arrives as dozens of small steps; let the storyboard scale
        // with the lane and resample once the gesture settles.
        model.timelineThumbnails.deferSampling()
        zoom = next
        var zoomed = current
        zoomed.zoom = next
        scroll(to: zoomed.x(for: anchor) - anchorViewportX, in: zoomed)
    }

    private func fitTimeline() {
        guard zoom > 1 else { return }
        zoom = 1
        scrollX = 0
        scrollPosition.scrollTo(edge: .leading)
    }

    /// Keeps the zoom inside range after the viewport or the edited duration
    /// changes - a cut or a wider window can leave the old scale past the cap.
    private func clampZoom() {
        let clamped = min(max(zoom, 1), scale.maxZoom)
        if abs(clamped - zoom) > 0.0001 {
            zoom = clamped
        }
    }

    private func followPlayhead(to time: TimeInterval) {
        let current = scale
        guard current.isScrollable else { return }
        let x = current.x(for: time)
        guard x < scrollX + Self.followMargin
            || x > scrollX + viewportWidth - Self.followMargin else { return }
        // While playing, land the playhead a third in so there is room to
        // watch what is coming; a seek just centers it.
        let inset = model.isPlaying ? viewportWidth / 3 : viewportWidth / 2
        scroll(to: x - inset, in: current)
    }

    private func scroll(to x: CGFloat, in scale: StudioTimelineScale) {
        let clamped = min(max(x, 0), max(0, scale.contentWidth - scale.viewportWidth))
        scrollX = clamped
        scrollPosition.scrollTo(x: clamped)
    }

    /// Zoom buttons keep the playhead pinned when it is on screen, so the
    /// scale grows around the edit point rather than the viewport middle.
    private var buttonZoomAnchor: TimeInterval {
        let x = scale.x(for: model.currentTime)
        if x >= scrollX, x <= scrollX + viewportWidth {
            return model.currentTime
        }
        return scale.time(forX: scrollX + viewportWidth / 2)
    }

    /// Images, GIFs and audio to place at the playhead.
    private func pickMedia() {
        model.pause()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .audio]
        panel.prompt = "Add"
        panel.message = "Images and GIFs go over the video; audio plays under it."
        let time = model.currentTime
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        model.importMedia(panel.urls, atEditorTime: time)
    }

    private var canDeleteSelection: Bool {
        model.selectedCueID != nil || model.selectedLayoutCueID != nil
            || model.selectedTextID != nil || model.selectedRedactionID != nil
            || model.selectedImageID != nil || model.selectedAudioClipID != nil
            || model.canDeleteSelectedClip
    }

    private func deleteSelection() {
        if let textID = model.selectedTextID {
            model.removeText(id: textID)
        } else if let imageID = model.selectedImageID {
            model.removeImage(id: imageID)
        } else if let audioClipID = model.selectedAudioClipID {
            model.removeAudioClip(id: audioClipID)
        } else if let redactionID = model.selectedRedactionID {
            model.removeRedaction(id: redactionID)
        } else if let cueID = model.selectedCueID {
            model.removeZoomCue(id: cueID)
        } else if let cueID = model.selectedLayoutCueID {
            model.removeLayoutCue(id: cueID)
        } else if model.selectedClipID != nil {
            model.deleteSelectedClip()
        }
    }
}

private enum StudioTimelineMetrics {
    /// Between one track and the next, as in the web editor.
    static let trackSpacing: CGFloat = 4
    static let gutterWidth: CGFloat = 40
    static let playheadLaneHeight: CGFloat = 18
    static let rulerHeight: CGFloat = 20
    /// The playhead's lane and the ruler, above the first track.
    static let headerHeight = playheadLaneHeight + rulerHeight
    /// Room under the last track - with the gap after it, about what the
    /// web editor leaves - which the gutter's line runs through and the
    /// horizontal scroller uses while scrolling.
    static let scrollerGutter: CGFloat = 6
    /// The shortest the tracks get when the dock is dragged down: the clips
    /// and the space around them.
    static let minimumTracksHeight: CGFloat = 64

    static func scrollingLanesHeight(tracks: [StudioTrack]) -> CGFloat {
        tracks.reduce(scrollerGutter) { $0 + $1.height + trackSpacing }
    }
}

/// A row of the timeline, named by its glyph in the gutter.
private enum StudioTrack: String, Identifiable {
    case text
    case overlay
    case clips
    case zooms
    case layouts
    case audio

    var id: String { rawValue }

    var height: CGFloat {
        switch self {
        case .clips: 52
        case .audio: 36
        case .text, .overlay, .zooms, .layouts: 30
        }
    }

    var systemImage: String {
        switch self {
        case .text: "character.textbox"
        case .overlay: "square.3.layers.3d"
        case .clips: "video"
        case .zooms: "magnifyingglass"
        case .layouts: "person.crop.rectangle"
        case .audio: "music.note"
        }
    }

    var title: String {
        switch self {
        case .text: "Text"
        case .overlay: "Images and Effects"
        case .clips: "Clips"
        case .zooms: "Zooms"
        case .layouts: "Camera Layouts"
        case .audio: "Audio"
        }
    }
}

/// Shared horizontal scale for every lane in the Studio timeline. `zoom` is a
/// multiplier over "the whole recording fits the viewport", so zoom 1 keeps
/// the original fixed-width timeline and higher values widen the lanes into a
/// scrolling surface where cuts, trim handles and zoom blocks stay grabbable
/// on long recordings.
struct StudioTimelineScale: Equatable {
    /// Finest scale worth offering; past this a single frame is wider than a
    /// thumbnail tile.
    static let maximumPointsPerSecond: CGFloat = 240
    /// Ceiling on lane width, which is what actually bounds the scale on long
    /// recordings. A 30-minute take still reaches ~55 points per second here.
    static let maximumContentWidth: CGFloat = 100_000

    var viewportWidth: CGFloat
    var duration: TimeInterval
    var zoom: Double

    var contentWidth: CGFloat {
        max(viewportWidth, viewportWidth * CGFloat(zoom))
    }

    var pointsPerSecond: CGFloat {
        duration > 0 ? contentWidth / CGFloat(duration) : 0
    }

    var secondsPerPoint: Double {
        pointsPerSecond > 0 ? 1 / Double(pointsPerSecond) : 0
    }

    var isScrollable: Bool {
        contentWidth > viewportWidth + 0.5
    }

    var maxZoom: Double {
        guard duration > 0, viewportWidth > 1 else { return 1 }
        let widest = min(
            Self.maximumContentWidth,
            Self.maximumPointsPerSecond * CGFloat(duration)
        )
        return max(1, Double(widest / viewportWidth))
    }

    func x(for time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time, 0), duration)) * pointsPerSecond
    }

    func time(forX x: CGFloat) -> TimeInterval {
        guard pointsPerSecond > 0 else { return 0 }
        return min(max(Double(x / pointsPerSecond), 0), duration)
    }

    /// Editor time span currently on screen, padded a little so lane content
    /// culled against it never pops in at the edges.
    func visibleRange(scrollX: CGFloat) -> ClosedRange<TimeInterval> {
        let margin: CGFloat = 120
        let lower = time(forX: scrollX - margin)
        let upper = time(forX: scrollX + viewportWidth + margin)
        return lower...max(lower, upper)
    }
}

/// Full-height playhead drawn as one pin: a soft rounded head above the
/// ruler whose underside flows into the stem through concave fillets. At
/// rest the head is a small tab; hovered or dragged it widens into a
/// readout of the time, then folds back. The head is the only hit target -
/// everywhere else the overlay passes clicks through to the tracks
/// underneath. The pointer's skim line is drawn here too, so it runs
/// through every lane rather than just the clip strip.
private struct StudioTimelinePlayhead: View {
    let time: TimeInterval
    let scale: StudioTimelineScale
    let scrollX: CGFloat
    /// The pointer's position while skimming, in viewport points.
    let skimX: CGFloat?
    let showsSkim: Bool
    /// The playhead is being scrubbed from the ruler, the clips or an empty
    /// track; the head opens into its readout as if it were dragged.
    var isScrubbing = false
    let onScrub: (TimeInterval) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private enum Metrics {
        static let headSize = CGSize(width: 17, height: 12)
        static let readoutSize = CGSize(width: 56, height: 17)
        static let hitSize = CGSize(width: 28, height: StudioTimelineMetrics.playheadLaneHeight + 4)
    }

    private static let coordinateSpace = "studio.playheadLane"

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let laneHeight = StudioTimelineMetrics.playheadLaneHeight
            // Viewport space: the playhead overlay never scrolls, it just
            // tracks the scrolled lanes underneath it.
            let x = scale.x(for: time) - scrollX
            let isVisible = x >= -2 && x <= width + 2
            let isExpanded = isHovering || isDragging || isScrubbing
            let head = isExpanded ? Metrics.readoutSize : Metrics.headSize
            // The stem stays on the true time. At the start the head
            // overhangs the track gutter; at the end the inspector column
            // would clip it, so it stops at the edge and the stem slides
            // across to its trailing side.
            let headX = min(x, width - head.width / 2)
            // The head hangs from the top of its lane, so the readout grows
            // downward toward the ruler rather than off the dock.
            let headTop = laneHeight - Metrics.headSize.height - 1

            ZStack(alignment: .topLeading) {
                if showsSkim, let skimX, !isDragging, !isScrubbing {
                    Rectangle()
                        .fill(Color.primary.opacity(0.32))
                        .frame(width: 1, height: max(0, proxy.size.height - laneHeight))
                        .offset(x: skimX - 0.5, y: laneHeight)
                        .allowsHitTesting(false)
                }

                PlayheadPinShape(
                    headHeight: head.height,
                    stemOffset: x - headX
                )
                .fill(Palette.highlight)
                .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                .overlay {
                    if isExpanded {
                        Text(studioPreciseTimecode(time))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .fixedSize()
                            .frame(width: head.width, height: head.height)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .transition(AnyTransition(.blurReplace))
                    }
                }
                .frame(width: head.width, height: max(0, proxy.size.height - headTop))
                .offset(x: headX - head.width / 2, y: headTop)
                .allowsHitTesting(false)
                .opacity(isVisible ? 1 : 0)

                Color.clear
                    .frame(width: max(Metrics.hitSize.width, head.width), height: Metrics.hitSize.height)
                    .contentShape(Rectangle())
                    .onHover { isHovering = $0 }
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(
                            minimumDistance: 0,
                            coordinateSpace: .named(Self.coordinateSpace)
                        )
                        .onChanged { value in
                            isDragging = true
                            onScrub(scale.time(forX: value.location.x + scrollX))
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                    )
                    .position(x: headX, y: Metrics.hitSize.height / 2 - 2)
                    .allowsHitTesting(isVisible)
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        // Opening into the readout and folding back is the one spring left
        // on the timeline.
        .motion(.morphQuick, value: isHovering || isDragging || isScrubbing)
    }
}

/// A playhead pin in one outline: a rounded head across the top of the
/// rect, a stem down to the bottom, and concave fillets where the head's
/// underside meets the stem so the two read as a single soft piece. The
/// stem can sit right of centre, up to the head's trailing edge; as it gets
/// there that side's corners close up, so the pin becomes a flag.
private struct PlayheadPinShape: Shape {
    var headHeight: CGFloat
    var stemOffset: CGFloat = 0
    var stemWidth: CGFloat = 2
    var cornerRadius: CGFloat = 4
    var filletRadius: CGFloat = 3.5

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(headHeight, stemOffset) }
        set {
            headHeight = newValue.first
            stemOffset = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let head = min(headHeight, rect.height)
        let corner = min(cornerRadius, head / 2, rect.width / 2)
        let halfStem = stemWidth / 2
        let stemX = min(
            max(rect.midX + stemOffset, rect.minX + corner + halfStem),
            rect.maxX - halfStem
        )
        // Head left between the stem and the trailing edge. The trailing
        // corners shrink with it, reaching square when the stem is flush.
        let trailingRoom = rect.maxX - (stemX + halfStem)
        let trailingCorner = min(corner, trailingRoom)
        // A fillet can't reach past the head's own rounded corners.
        let leadingFillet = max(0, min(
            filletRadius,
            stemX - halfStem - (rect.minX + corner),
            rect.height - head
        ))
        let trailingFillet = max(0, min(
            filletRadius,
            trailingRoom - trailingCorner,
            rect.height - head
        ))
        let headBottom = rect.minY + head

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + corner, y: rect.minY))
        // Under a point of room the lip would read as a notch, so the
        // pin is already a flag.
        if trailingRoom > 1 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: headBottom),
                radius: trailingCorner
            )
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: headBottom),
                tangent2End: CGPoint(x: stemX + halfStem, y: headBottom),
                radius: trailingCorner
            )
            // Underside into the stem's right edge, curving down.
            path.addArc(
                tangent1End: CGPoint(x: stemX + halfStem, y: headBottom),
                tangent2End: CGPoint(x: stemX + halfStem, y: rect.maxY),
                radius: trailingFillet
            )
        } else {
            // Flush: the top edge turns straight down into the stem.
            path.addLine(to: CGPoint(x: stemX + halfStem, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: stemX + halfStem, y: rect.maxY))
        path.addLine(to: CGPoint(x: stemX - halfStem, y: rect.maxY))
        // Back up the stem's left edge and out along the underside.
        path.addArc(
            tangent1End: CGPoint(x: stemX - halfStem, y: headBottom),
            tangent2End: CGPoint(x: rect.minX, y: headBottom),
            radius: leadingFillet
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: headBottom),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY),
            radius: corner
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: corner
        )
        path.closeSubpath()
        return path
    }
}

/// Absolute-time ruler above the tracks, drawn like the web editor's: each
/// major tick is a hairline the full height of the ruler with its time just
/// after it, minor ticks stand along the floor, and a hairline closes the
/// ruler off from the tracks. The ruler itself never scrolls: it draws only
/// the time span currently on screen, so a deeply zoomed timeline costs the
/// same to render as a fitted one.
private struct StudioTimelineRuler: View {
    let duration: Double
    let pointsPerSecond: CGFloat
    let scrollX: CGFloat

    private static let minorTickHeight: CGFloat = 5
    private static let labelInset = CGPoint(x: 5, y: 2)

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)),
                with: .color(Palette.hairline)
            )
            guard duration > 0.2, pointsPerSecond > 0, size.width > 60 else { return }

            let step = Self.labelStep(forPointsPerSecond: pointsPerSecond)
            let minorStep = Self.minorStep(for: step)
            let startTime = max(0, Double(scrollX / pointsPerSecond))
            let endTime = min(duration, Double((scrollX + size.width) / pointsPerSecond))

            func x(for time: Double) -> CGFloat {
                CGFloat(time) * pointsPerSecond - scrollX
            }

            // Minor ticks first, so a major line covers the one it lands on.
            var minorIndex = max(0, Int(floor(startTime / minorStep)))
            while true {
                let time = Double(minorIndex) * minorStep
                minorIndex += 1
                guard time <= endTime else { break }
                context.fill(
                    Path(CGRect(
                        x: x(for: time) - 0.5,
                        y: size.height - 1 - Self.minorTickHeight,
                        width: 1,
                        height: Self.minorTickHeight
                    )),
                    with: .color(.primary.opacity(0.14))
                )
            }

            var index = max(0, Int(floor(startTime / step)))
            let lastIndex = Int(ceil(endTime / step))
            while index <= lastIndex {
                let time = Double(index) * step
                index += 1
                guard time <= duration else { break }
                let tickX = x(for: time)
                context.fill(
                    Path(CGRect(x: tickX - 0.5, y: 0, width: 1, height: size.height)),
                    with: .color(Palette.hairline)
                )

                let label = context.resolve(
                    Text(Self.label(for: time, step: step))
                        .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.tertiaryLabel)
                )
                let labelSize = label.measure(in: size)
                let labelX = tickX + Self.labelInset.x
                // A label that would run off the trailing edge is left out
                // rather than squeezed against the tick before it.
                guard labelX + labelSize.width <= size.width else { continue }
                context.draw(label, in: CGRect(
                    x: labelX,
                    y: Self.labelInset.y,
                    width: labelSize.width,
                    height: labelSize.height
                ))
            }
        }
    }

    /// Smallest "nice" interval whose labels stay comfortably apart at the
    /// current scale. Sub-second steps unlock once a zoomed lane spreads a
    /// single second across most of the viewport.
    private static func labelStep(forPointsPerSecond pointsPerSecond: CGFloat) -> Double {
        let candidates: [Double] = [
            0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800
        ]
        for candidate in candidates where CGFloat(candidate) * pointsPerSecond >= 72 {
            return candidate
        }
        return candidates.last ?? 60
    }

    /// Fifths of a step that divides into them evenly, quarters otherwise.
    private static func minorStep(for step: Double) -> Double {
        let isFifths = step >= 1 && step.truncatingRemainder(dividingBy: 5) == 0
        return step / (isFifths ? 5 : 4)
    }

    private static func label(for time: Double, step: Double) -> String {
        step < 1 ? studioPreciseTimecode(time) : studioTimecode(time)
    }
}

func studioTimecode(_ seconds: Double) -> String {
    let safe = max(0, seconds.isFinite ? seconds : 0)
    let total = Int(safe.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remainingSeconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        : String(format: "%02d:%02d", minutes, remainingSeconds)
}

func studioPreciseTimecode(_ seconds: Double) -> String {
    let safe = max(0, seconds.isFinite ? seconds : 0)
    let totalMinutes = Int(safe) / 60
    let remaining = safe.truncatingRemainder(dividingBy: 60)
    return String(format: "%02d:%04.1f", totalMinutes, remaining)
}

/// The flat, full-width ground a track sits on. It stays pinned to the
/// viewport while the track's blocks scroll over it, so the row reads as a
/// fixed track no matter how far the timeline is zoomed. An empty track
/// names what it is for at its leading edge.
private struct StudioTrackGround: View {
    let hint: String?
    /// Where dragged files would land, in viewport points; set only on the
    /// tracks they'll land on.
    var dropX: CGFloat? = nil

    var body: some View {
        Rectangle()
            .fill(dropX == nil ? Color.primary.opacity(0.04) : Palette.highlight.opacity(0.12))
            .overlay(alignment: .leading) {
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(dropX == nil ? Palette.tertiaryLabel : Palette.highlight)
                        .lineLimit(1)
                        .padding(.leading, 10)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if let dropX {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Palette.highlight)
                            .frame(width: 2, height: proxy.size.height)
                            .offset(x: min(max(dropX, 0), proxy.size.width) - 1)
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: hint)
            .animation(.easeOut(duration: 0.15), value: dropX == nil)
            .allowsHitTesting(false)
    }
}

/// Files dragged over the tracks: the tracks their kinds land on, and the
/// moment under the pointer.
private struct StudioMediaDrop: Equatable {
    var tracks: Set<StudioTrack>
    var time: TimeInterval
}

/// Takes files from Finder. Images and GIFs land on the overlay track and
/// audio on the audio track; when a drag doesn't say what it carries, both
/// light up.
private struct StudioMediaDropDelegate: DropDelegate {
    let canDrop: Bool
    let time: (CGPoint) -> TimeInterval
    let onPreview: (StudioMediaDrop?) -> Void
    let onDrop: ([URL], TimeInterval) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        canDrop && info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            onPreview(nil)
            return DropProposal(operation: .forbidden)
        }
        var tracks: Set<StudioTrack> = []
        if info.hasItemsConforming(to: [.image]) { tracks.insert(.overlay) }
        if info.hasItemsConforming(to: [.audio]) { tracks.insert(.audio) }
        if tracks.isEmpty { tracks = [.overlay, .audio] }
        onPreview(StudioMediaDrop(tracks: tracks, time: time(info.location)))
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        onPreview(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        onPreview(nil)
        guard canDrop else { return false }
        let at = time(info.location)
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        continuation.resume(returning: url)
                    }
                }
                if let url { urls.append(url) }
            }
            if !urls.isEmpty { onDrop(urls, at) }
        }
        return true
    }
}

/// Zoom cues. Dragging across empty track draws out a zoom in the gap it
/// started in; a click scrubs. Recorded clicks mark the track's floor.
private struct StudioZoomLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>

    var body: some View {
        StudioBlockLane(
            model: model,
            blocks: visibleBlocks,
            selectedID: model.selectedCueID,
            scale: scale,
            height: StudioTrack.zooms.height,
            keepsBlocksApart: true,
            empty: .create(tint: Palette.highlight, minimumLength: 0.001) { range in
                model.addZoomCue(fromEditorTime: range.lowerBound, toEditorTime: range.upperBound)
            },
            actions: StudioBlockLaneActions(
                select: { model.selectZoomCue(id: $0.id) },
                begin: { _ in model.beginZoomCueEdit() },
                edit: apply,
                end: { kind in model.endZoomCueEdit(actionName: kind == .move ? "Move Zoom" : "Resize Zoom") }
            ),
            decoration: { pressMarks },
            content: { block, state in content(for: block, state: state) },
            menu: { block in menu(for: block.item) },
            help: { block in
                block.item.isEnabled
                    ? "Drag to move, drag an end to resize, right-click for options"
                    : "Turned off. Right-click to turn it back on."
            }
        )
        .opacity(model.zoomEnabled ? 1 : 0.45)
        .contextMenu {
            Button("Add Zoom at Playhead", systemImage: "plus.magnifyingglass") {
                model.addZoomCue(at: model.currentTime)
            }
        }
    }

    /// Recorded clicks as small dots along the track's floor, so they mark
    /// where Auto Zoom would act without striping the blocks. Culled to the
    /// visible span: an hour-long take can hold thousands of clicks.
    private var pressMarks: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(visiblePressTimes.enumerated()), id: \.offset) { _, pressTime in
                Circle()
                    .fill(Color.primary.opacity(0.28))
                    .frame(width: 3, height: 3)
                    .offset(
                        x: scale.x(for: pressTime) - 1.5,
                        y: StudioTrack.zooms.height - StudioBlockMetrics.inset - 3
                    )
            }
        }
    }

    @ViewBuilder
    private func content(for block: StudioLaneBlock<ZoomCue>, state: StudioBlockState) -> some View {
        let cue = block.item
        StudioBlockLabel(
            systemImage: cue.anchorMode == .pinnedAnchor ? "scope" : "magnifyingglass",
            title: cue.isEnabled
                ? InspectorValueFormat.magnification(fractionDigits: 1).displayString(for: cue.zoom)
                : "Off",
            // Following the pointer is the default, so only a zoom that
            // does something else says so, ahead of its length.
            detail: (cue.isEnabled && cue.anchorMode != .pointerAnchor ? "\(cue.anchorMode.laneTitle) · " : "")
                + studioTimecode(block.editorLength),
            state: state,
            color: cue.isEnabled ? StudioBlockStyle.zoom.onTint : .secondary
        )
        .background {
            if cue.isEnabled {
                StudioBlockSurface(fill: StudioBlockStyle.zoom.fill(isHovering: state.isHovered))
            } else {
                // Hatched, so a turned-off zoom reads as "kept, not used".
                StudioBlockSurface(fill: Color.primary.opacity(0.08))
                    .overlay { StudioBlockHatch(color: .primary.opacity(0.10)) }
            }
        }
    }

    private func apply(_ edit: StudioBlockEdit<ZoomCue>) {
        let base = edit.base
        var cue = base.item
        switch edit.kind {
        case .move:
            let range = studioMovedSourceRange(
                model: model,
                editorStart: base.editorStart + edit.delta,
                editorLength: base.editorLength
            )
            cue.start = range.start
            cue.end = range.end
            model.moveZoomCue(cue)
        case .trimLeading:
            let source = model.sourceTime(atEditorTime: base.editorStart + edit.delta)
            cue.start = min(max(0, source), base.item.end - ZoomCue.minimumDuration)
            model.updateZoomCue(cue)
        case .trimTrailing:
            let source = model.sourceTime(atEditorTime: base.editorEnd + edit.delta)
            cue.end = max(base.item.start + ZoomCue.minimumDuration, min(model.sourceDuration, source))
            model.updateZoomCue(cue)
        }
    }

    @ViewBuilder
    private func menu(for cue: ZoomCue) -> some View {
        Menu("Zoom Level") {
            ForEach(Self.zoomPresets, id: \.self) { preset in
                Toggle(
                    String(format: "%g×", preset),
                    isOn: Binding(
                        get: { abs(cue.zoom - preset) < 0.01 },
                        set: { _ in edit(cue, action: "Change Zoom Level") { $0.zoom = preset } }
                    )
                )
            }
        }

        Menu("Camera Focus") {
            ForEach(ZoomAnchorMode.allCases, id: \.self) { mode in
                Toggle(
                    mode.laneTitle,
                    isOn: Binding(
                        get: { cue.anchorMode == mode },
                        set: { _ in
                            edit(cue, action: "Change Camera Focus") { updated in
                                updated.anchorMode = mode
                                if mode == .pinnedAnchor,
                                   let pointer = model.pointerLocation(at: model.currentTime) {
                                    updated.pinnedPoint = pointer
                                }
                            }
                        }
                    )
                )
            }
        }

        Divider()

        Button(cue.isEnabled ? "Turn Off This Zoom" : "Turn On This Zoom",
               systemImage: cue.isEnabled ? "eye.slash" : "eye") {
            edit(cue, action: cue.isEnabled ? "Turn Off Zoom" : "Turn On Zoom") {
                $0.isEnabled.toggle()
            }
        }

        Button("Remove Zoom", systemImage: "trash", role: .destructive) {
            model.removeZoomCue(id: cue.id)
        }
    }

    /// Magnifications offered from a block's context menu.
    private static let zoomPresets: [Double] = [1.25, 1.5, 2, 2.5, 3]

    /// One undoable change to a zoom from its context menu.
    private func edit(_ cue: ZoomCue, action: String, _ change: (inout ZoomCue) -> Void) {
        var updated = cue
        change(&updated)
        model.beginZoomCueEdit()
        model.updateZoomCue(updated)
        model.endZoomCueEdit(actionName: action)
    }

    private var visiblePressTimes: [TimeInterval] {
        model.visibleRecordedPressTimes.filter { visibleRange.contains($0) }
    }

    private var visibleBlocks: [StudioLaneBlock<ZoomCue>] {
        model.zoomTimelineBlocks
            .filter { $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound }
            .map { StudioLaneBlock(item: $0.cue, editorStart: $0.editorStart, editorEnd: $0.editorEnd) }
    }
}

private extension ZoomAnchorMode {
    var laneTitle: String {
        switch self {
        case .pointerAnchor: "Pointer"
        case .smartAnchor: "Smart"
        case .pinnedAnchor: "Fixed"
        }
    }
}

// MARK: - Layout lane

/// Camera layout cues. Dragging across empty track draws out a layout in
/// the gap it started in; a click scrubs, as on the zoom track.
private struct StudioLayoutLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>

    var body: some View {
        StudioBlockLane(
            model: model,
            blocks: visibleBlocks,
            selectedID: model.selectedLayoutCueID,
            scale: scale,
            height: StudioTrack.layouts.height,
            keepsBlocksApart: true,
            empty: .create(tint: Palette.layoutCue, minimumLength: 0.001) { range in
                model.addLayoutCue(fromEditorTime: range.lowerBound, toEditorTime: range.upperBound)
            },
            actions: StudioBlockLaneActions(
                select: { model.selectLayoutCue(id: $0.id) },
                begin: { _ in model.beginLayoutCueEdit() },
                edit: apply,
                end: { kind in model.endLayoutCueEdit(actionName: kind == .move ? "Move Layout" : "Resize Layout") }
            ),
            content: { block, state in content(for: block, state: state) },
            menu: { block in menu(for: block.item) },
            help: { block in
                "\(block.item.layout.detailedTitle). Drag to move, drag an end to resize, right-click to change."
            }
        )
        .opacity(model.showsCameraLayer ? 1 : 0.45)
        .contextMenu {
            Menu("Add Layout at Playhead") {
                ForEach(RecordingCameraLayout.presets, id: \.self) { preset in
                    Button(preset.detailedTitle, systemImage: preset.systemImage) {
                        model.addLayoutCue(
                            at: model.currentTime,
                            layout: model.style.camera.layout.adopting(preset)
                        )
                    }
                }
            }
        }
    }

    private func content(
        for block: StudioLaneBlock<RecordingCameraLayoutCue>,
        state: StudioBlockState
    ) -> some View {
        let rampWidth = min(
            state.width / 2,
            CGFloat(RecordingCameraLayoutTimeline.transitionDuration) * scale.pointsPerSecond
        )
        return StudioBlockLabel(
            systemImage: block.item.layout.systemImage,
            title: block.item.layout.title,
            detail: studioTimecode(block.editorLength),
            state: state,
            color: StudioBlockStyle.layout.onTint
        )
        .background {
            StudioBlockSurface(fill: StudioBlockStyle.layout.fill(isHovering: state.isHovered))
                .overlay(alignment: .leading) {
                    // Where the layout is still morphing in.
                    LinearGradient(
                        colors: [StudioBlockStyle.layout.onTint.opacity(0.2), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: rampWidth)
                    .studioBlockClip()
                }
        }
    }

    private func apply(_ edit: StudioBlockEdit<RecordingCameraLayoutCue>) {
        let base = edit.base
        var cue = base.item
        let minimum = RecordingCameraLayoutCue.minimumDuration
        switch edit.kind {
        case .move:
            let range = studioMovedSourceRange(
                model: model,
                editorStart: base.editorStart + edit.delta,
                editorLength: base.editorLength
            )
            cue.start = range.start
            cue.end = range.end
            model.moveLayoutCue(cue)
        case .trimLeading:
            let source = model.sourceTime(atEditorTime: base.editorStart + edit.delta)
            cue.start = min(max(0, source), base.item.end - minimum)
            model.resizeLayoutCue(cue)
        case .trimTrailing:
            let source = model.sourceTime(atEditorTime: base.editorEnd + edit.delta)
            cue.end = max(base.item.start + minimum, min(model.sourceDuration, source))
            model.resizeLayoutCue(cue)
        }
    }

    @ViewBuilder
    private func menu(for cue: RecordingCameraLayoutCue) -> some View {
        Menu("Layout") {
            ForEach(RecordingCameraLayout.presets, id: \.self) { preset in
                Toggle(
                    preset.detailedTitle,
                    isOn: Binding(
                        get: { cue.layout.matches(preset: preset) },
                        set: { _ in
                            var updated = cue
                            updated.layout = cue.layout.adopting(preset)
                            model.updateLayoutCue(updated, actionName: "Change Layout")
                        }
                    )
                )
            }
        }

        Divider()

        Button("Remove Layout", systemImage: "trash", role: .destructive) {
            model.removeLayoutCue(id: cue.id)
        }
    }

    private var visibleBlocks: [StudioLaneBlock<RecordingCameraLayoutCue>] {
        model.cameraLayoutTimelineBlocks
            .filter { $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound }
            .map { StudioLaneBlock(item: $0.cue, editorStart: $0.editorStart, editorEnd: $0.editorEnd) }
    }
}

// MARK: - Text and pixelate tracks

/// Text blocks. Dragging across empty track adds a text over the dragged
/// range; a click scrubs. Texts may overlap.
private struct StudioTextLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>
    let onScrubbing: (Bool) -> Void

    var body: some View {
        StudioBlockLane(
            model: model,
            blocks: visibleBlocks,
            selectedID: model.selectedTextID,
            scale: scale,
            height: StudioTrack.text.height,
            empty: .create(tint: Palette.textCue, minimumLength: 0.05) { range in
                model.addText(fromEditorTime: range.lowerBound, toEditorTime: range.upperBound)
            },
            onScrubbing: onScrubbing,
            actions: StudioBlockLaneActions(
                select: { model.selectText(id: $0.id) },
                begin: { _ in model.beginTextEdit() },
                edit: { edit in
                    var text = edit.base.item
                    let range = studioOverlaySourceRange(for: edit, model: model, start: text.start, end: text.end)
                    text.start = range.start
                    text.end = range.end
                    model.setText(text)
                },
                end: { kind in model.endTextEdit(actionName: kind == .move ? "Move Text" : "Resize Text") }
            ),
            content: { block, state in
                StudioOverlayBlockContent(
                    style: .text,
                    systemImage: "textformat",
                    title: title(for: block.item),
                    length: block.editorLength,
                    state: state
                )
            },
            menu: { block in
                Button("Delete Text", systemImage: "trash", role: .destructive) {
                    model.removeText(id: block.id)
                }
            },
            help: { block in "\(title(for: block.item)). Drag to move, drag an end to resize, right-click for options." }
        )
        .contextMenu {
            Button("Add Text at Playhead", systemImage: "textformat") {
                model.addText(atEditorTime: model.currentTime)
            }
        }
    }

    private func title(for text: RecordingTextOverlay) -> String {
        text.text.isEmpty ? "Text" : text.text.replacingOccurrences(of: "\n", with: " ")
    }

    private var visibleBlocks: [StudioLaneBlock<RecordingTextOverlay>] {
        model.textTimelineBlocks
            .filter { $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound }
            .map { StudioLaneBlock(item: $0.item, editorStart: $0.editorStart, editorEnd: $0.editorEnd) }
    }
}

/// What sits on the Images and Effects track. Images and pixelate or blur
/// regions share it, so they hit-test together.
private enum StudioEffectsItem: Identifiable {
    case image(RecordingImageOverlay)
    case redaction(RecordingRedaction)

    var id: UUID {
        switch self {
        case .image(let overlay): overlay.id
        case .redaction(let redaction): redaction.id
        }
    }

    var title: String {
        switch self {
        case .image(let overlay): overlay.isAnimated ? "\(overlay.displayName) · GIF" : overlay.displayName
        case .redaction(let redaction): redaction.style.title
        }
    }
}

/// Images, GIFs, and pixelate and blur blocks, on the Images and Effects
/// track. A drag across empty track scrubs.
private struct StudioRedactionLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>
    let onScrubbing: (Bool) -> Void

    var body: some View {
        StudioBlockLane(
            model: model,
            blocks: visibleBlocks,
            selectedID: model.selectedImageID ?? model.selectedRedactionID,
            scale: scale,
            height: StudioTrack.overlay.height,
            empty: .scrub,
            onScrubbing: onScrubbing,
            actions: StudioBlockLaneActions(
                select: { item in
                    switch item {
                    case .image(let overlay): model.selectImage(id: overlay.id)
                    case .redaction(let redaction): model.selectRedaction(id: redaction.id)
                    }
                },
                begin: { _ in
                    model.beginImageEdit()
                    model.beginRedactionEdit()
                },
                edit: apply,
                end: { kind in
                    let verb = kind == .move ? "Move" : "Resize"
                    model.endImageEdit(actionName: "\(verb) Image")
                    model.endRedactionEdit(actionName: "\(verb) Pixelate")
                }
            ),
            content: { block, state in
                switch block.item {
                case .image(let overlay):
                    StudioOverlayBlockContent(
                        style: .image,
                        systemImage: overlay.isAnimated ? "photo.stack" : "photo",
                        title: block.item.title,
                        length: block.editorLength,
                        state: state
                    )
                case .redaction(let redaction):
                    // Effects carry light stripes, so they read apart from
                    // images.
                    StudioOverlayBlockContent(
                        style: .effect,
                        systemImage: redaction.style.systemImage,
                        title: block.item.title,
                        length: block.editorLength,
                        state: state,
                        isHatched: true
                    )
                }
            },
            menu: { block in menu(for: block.item) },
            help: { block in "\(block.item.title). Drag to move, drag an end to resize, right-click for options." }
        )
        .contextMenu {
            Button("Pixelate at Playhead", systemImage: "squareshape.split.3x3") {
                model.addRedaction(atEditorTime: model.currentTime)
            }
            Button("Blur at Playhead", systemImage: "drop.halffull") {
                model.addRedaction(atEditorTime: model.currentTime, style: .blur)
            }
        }
    }

    private func apply(_ edit: StudioBlockEdit<StudioEffectsItem>) {
        switch edit.base.item {
        case .image(var overlay):
            let range = studioOverlaySourceRange(for: edit, model: model, start: overlay.start, end: overlay.end)
            overlay.start = range.start
            overlay.end = range.end
            model.setImage(overlay)
        case .redaction(var redaction):
            let range = studioOverlaySourceRange(for: edit, model: model, start: redaction.start, end: redaction.end)
            redaction.start = range.start
            redaction.end = range.end
            model.setRedaction(redaction)
        }
    }

    @ViewBuilder
    private func menu(for item: StudioEffectsItem) -> some View {
        switch item {
        case .image(let overlay):
            Button("Delete Image", systemImage: "trash", role: .destructive) {
                model.removeImage(id: overlay.id)
            }
        case .redaction(let redaction):
            Menu("Style") {
                ForEach(RecordingRedaction.Style.allCases) { style in
                    Toggle(style.title, isOn: Binding(
                        get: { redaction.style == style },
                        set: { _ in
                            var edited = redaction
                            edited.style = style
                            model.updateRedaction(edited, actionName: "Change Pixelate Style")
                        }
                    ))
                }
            }
            Divider()
            Button("Delete \(redaction.style.title)", systemImage: "trash", role: .destructive) {
                model.removeRedaction(id: redaction.id)
            }
        }
    }

    /// Images under effects, as they draw on the video.
    private var visibleBlocks: [StudioLaneBlock<StudioEffectsItem>] {
        let images = model.imageTimelineBlocks.map {
            StudioLaneBlock(item: StudioEffectsItem.image($0.item), editorStart: $0.editorStart, editorEnd: $0.editorEnd)
        }
        let redactions = model.redactionTimelineBlocks.map {
            StudioLaneBlock(item: StudioEffectsItem.redaction($0.item), editorStart: $0.editorStart, editorEnd: $0.editorEnd)
        }
        return (images + redactions).filter {
            $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound
        }
    }
}

/// Where a text, image or effect lands after a drag. A move keeps its
/// length on the timeline; a trim moves one end, never past the other.
private func studioOverlaySourceRange<Item>(
    for edit: StudioBlockEdit<Item>,
    model: RecordingStudioModel,
    start: TimeInterval,
    end: TimeInterval
) -> (start: TimeInterval, end: TimeInterval) {
    switch edit.kind {
    case .move:
        return studioMovedSourceRange(
            model: model,
            editorStart: edit.base.editorStart + edit.delta,
            editorLength: edit.base.editorLength
        )
    case .trimLeading:
        let source = model.sourceTime(atEditorTime: edit.base.editorStart + edit.delta)
        return (min(source, end - 0.1), end)
    case .trimTrailing:
        let source = model.sourceTime(atEditorTime: edit.base.editorEnd + edit.delta)
        return (start, max(source, start + 0.1))
    }
}

/// A text, image or effect block: its surface, stripes for effects, and
/// its label.
private struct StudioOverlayBlockContent: View {
    let style: StudioBlockStyle
    let systemImage: String
    let title: String
    let length: TimeInterval
    let state: StudioBlockState
    var isHatched = false

    var body: some View {
        StudioBlockLabel(
            systemImage: systemImage,
            title: title,
            detail: studioTimecode(length),
            state: state,
            color: style.onTint
        )
        .background {
            StudioBlockSurface(fill: style.fill(isHovering: state.isHovered))
                .overlay {
                    if isHatched {
                        StudioBlockHatch(color: style.onTint.opacity(0.1), spacing: 12, lineWidth: 6)
                    }
                }
        }
    }
}

// MARK: - Audio track

/// Music and sound under the video. Blocks sit on the edited video's clock:
/// the body moves a clip along the video, its ends trim the file. A drag
/// across empty track scrubs.
private struct StudioAudioLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>
    let onScrubbing: (Bool) -> Void

    var body: some View {
        StudioBlockLane(
            model: model,
            blocks: visibleBlocks,
            selectedID: model.selectedAudioClipID,
            scale: scale,
            height: StudioTrack.audio.height,
            empty: .scrub,
            onScrubbing: onScrubbing,
            actions: StudioBlockLaneActions(
                select: { model.selectAudioClip(id: $0.id) },
                begin: { _ in model.beginAudioClipEdit() },
                edit: apply,
                end: { kind in model.endAudioClipEdit(actionName: kind == .move ? "Move Audio" : "Trim Audio") }
            ),
            content: { block, state in content(for: block.item, state: state) },
            menu: { block in
                Button("Delete Audio", systemImage: "trash", role: .destructive) {
                    model.removeAudioClip(id: block.id)
                }
            },
            help: { block in "\(block.item.displayName). Drag to move, drag an end to trim, right-click for options." }
        )
    }

    /// Its name over a waveform of the stretch that plays.
    private func content(for clip: RecordingAudioClip, state: StudioBlockState) -> some View {
        let style = StudioBlockStyle.audio
        return ZStack(alignment: .topLeading) {
            StudioWaveform(
                peaks: model.audioPeaks[clip.fileName] ?? [],
                color: style.onTint.opacity(0.55),
                from: clip.trimStart,
                to: clip.trimStart + Double(state.width / max(scale.pointsPerSecond, 1))
            )
            .padding(.top, 13)
            .padding(.bottom, 3)
            .padding(.horizontal, 2)

            StudioBlockLabel(
                systemImage: "music.note",
                title: clip.displayName,
                detail: studioTimecode(clip.duration),
                state: state,
                color: style.onTint,
                verticalAlignment: .top
            )
            .padding(.top, 2)
        }
        .frame(width: state.width, height: state.height, alignment: .topLeading)
        .background { StudioBlockSurface(fill: style.fill(isHovering: state.isHovered)) }
        .studioBlockClip()
    }

    private func apply(_ edit: StudioBlockEdit<RecordingAudioClip>) {
        let base = edit.base.item
        let minimum = RecordingAudioClip.minimumDuration
        var edited = base
        switch edit.kind {
        case .move:
            edited.start = max(0, base.start + edit.delta)
        case .trimLeading:
            // The start can't run before the file's first sample or the
            // video's first frame.
            let shift = min(max(edit.delta, -base.trimStart, -base.start), base.duration - minimum)
            edited.start = base.start + shift
            edited.trimStart = base.trimStart + shift
        case .trimTrailing:
            edited.trimEnd = min(max(base.trimEnd + edit.delta, base.trimStart + minimum), base.fileDuration)
        }
        model.setAudioClip(edited)
    }

    private var visibleBlocks: [StudioLaneBlock<RecordingAudioClip>] {
        model.audioClips
            .filter { $0.end >= visibleRange.lowerBound && $0.start <= visibleRange.upperBound }
            .map { StudioLaneBlock(item: $0, editorStart: $0.start, editorEnd: $0.end) }
    }
}

/// Rounded bars of an audio file's loudness between two file times.
private struct StudioWaveform: View {
    let peaks: [Float]
    let color: Color
    let from: TimeInterval
    let to: TimeInterval

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty, to > from, size.width > 4 else { return }
            let perSecond = Double(RecordingAudioPeaks.peaksPerSecond)
            let bar: CGFloat = 2
            let gap: CGFloat = 2
            var path = Path()
            var x: CGFloat = gap
            while x < size.width - bar {
                let t0 = from + Double(x / size.width) * (to - from)
                let t1 = from + Double((x + bar) / size.width) * (to - from)
                let i0 = max(0, Int(t0 * perSecond))
                let i1 = min(peaks.count, max(i0 + 1, Int(t1 * perSecond)))
                var value: Float = 0
                if i0 < i1 {
                    for index in i0..<i1 { value = max(value, peaks[index]) }
                }
                let height = max(bar, CGFloat(value) * size.height)
                path.addRoundedRect(
                    in: CGRect(x: x, y: (size.height - height) / 2, width: bar, height: height),
                    cornerSize: CGSize(width: bar / 2, height: bar / 2)
                )
                x += bar + gap
            }
            context.fill(path, with: .color(color))
        }
        .allowsHitTesting(false)
    }
}
