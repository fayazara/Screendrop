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
private struct StudioTimelineScale: Equatable {
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

private struct StudioZoomLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>

    /// Below this many dragged points, a gesture on blank lane space is
    /// still treated as a click-to-seek rather than a zoom-creating drag.
    private static let dragCreateThreshold: CGFloat = 4

    /// Held as a time rather than a position so a zoom change mid-drag can't
    /// reinterpret where the drag began.
    @State private var dragStartTime: TimeInterval?
    @State private var pendingZoomRange: ClosedRange<TimeInterval>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Contentless hit surface: the lane can be tens of thousands of
            // points wide, and the visible frame is drawn by the chrome behind
            // the scroll view.
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard scale.pointsPerSecond > 0 else { return }
                            let time = scale.time(forX: value.location.x)

                            if dragStartTime == nil {
                                model.pause()
                                dragStartTime = time
                                // A click on empty lane lets go of whatever
                                // was selected, like clicking empty canvas.
                                model.clearTimelineSelection()
                            }
                            guard let startTime = dragStartTime else { return }

                            if pendingZoomRange == nil,
                               abs(value.location.x - scale.x(for: startTime))
                                   < Self.dragCreateThreshold {
                                // Still within click tolerance: scrub the
                                // playhead, same as a plain click always has.
                                model.seek(to: time)
                                return
                            }

                            pendingZoomRange = pendingRange(from: startTime, to: time)
                        }
                        .onEnded { _ in
                            // A range clamped to nothing means the drag ran
                            // entirely into a neighboring block; there is no
                            // gap here to put a zoom in.
                            if let range = pendingZoomRange,
                               range.upperBound - range.lowerBound > 0.001 {
                                model.addZoomCue(
                                    fromEditorTime: range.lowerBound,
                                    toEditorTime: range.upperBound
                                )
                            }
                            dragStartTime = nil
                            pendingZoomRange = nil
                        }
                )

            // Recorded clicks as small dots along the lane's floor, so they
            // mark where Auto Zoom would act without striping the blocks.
            // Culled to the visible span: an hour-long take can hold
            // thousands of clicks, and only a screenful can ever be seen.
            ForEach(Array(visiblePressTimes.enumerated()), id: \.offset) { _, pressTime in
                Circle()
                    .fill(Color.primary.opacity(0.28))
                    .frame(width: 3, height: 3)
                    .offset(
                        x: scale.x(for: pressTime) - 1.5,
                        y: StudioZoomLaneMetrics.laneHeight - StudioZoomLaneMetrics.blockInset - 3
                    )
                    .allowsHitTesting(false)
            }

            if let pendingZoomRange {
                let lowX = scale.x(for: pendingZoomRange.lowerBound)
                let highX = scale.x(for: pendingZoomRange.upperBound)
                RoundedRectangle(
                    cornerRadius: StudioZoomLaneMetrics.blockCornerRadius,
                    style: .continuous
                )
                    .fill(Palette.highlight.opacity(0.22))
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: StudioZoomLaneMetrics.blockCornerRadius,
                            style: .continuous
                        )
                        .strokeBorder(
                            Palette.highlight.opacity(0.8),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                    }
                    .frame(width: max(2, highX - lowX), height: StudioZoomLaneMetrics.blockHeight)
                    .offset(x: lowX, y: StudioZoomLaneMetrics.blockInset)
                    .allowsHitTesting(false)
            }

            ForEach(visibleBlocks) { block in
                StudioZoomCueBlock(model: model, block: block, scale: scale)
            }
        }
        .opacity(model.zoomEnabled ? 1 : 0.45)
        .contextMenu {
            Button("Add Zoom at Playhead", systemImage: "plus.magnifyingglass") {
                model.addZoomCue(at: model.currentTime)
            }
        }
    }

    /// The range a drag-created zoom would cover, stopped at the blocks on
    /// either side of where the drag began so the preview matches the cue the
    /// model will actually allow.
    private func pendingRange(
        from startTime: TimeInterval,
        to currentTime: TimeInterval
    ) -> ClosedRange<TimeInterval> {
        let blocks = model.zoomTimelineBlocks
        let lowerLimit = blocks
            .filter { $0.editorEnd <= startTime }
            .map(\.editorEnd)
            .max() ?? 0
        let upperLimit = blocks
            .filter { $0.editorStart >= startTime }
            .map(\.editorStart)
            .min() ?? model.duration
        let low = max(min(startTime, currentTime), lowerLimit)
        let high = min(max(startTime, currentTime), upperLimit)
        return low...max(low, high)
    }

    private var visiblePressTimes: [TimeInterval] {
        model.visibleRecordedPressTimes.filter { visibleRange.contains($0) }
    }

    private var visibleBlocks: [RecordingZoomTimelineBlock] {
        model.zoomTimelineBlocks.filter {
            $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound
        }
    }
}

/// How a block on a track is painted: an opaque body in its colour with
/// light marks on it, as in Final Cut and iMovie. Selection doesn't change
/// the body; `StudioTrimFrame` goes around it.
private struct StudioBlockStyle {
    let tint: NSColor
    /// Marks on the body.
    var onTint: Color = .white

    static let zoom = StudioBlockStyle(tint: .controlAccentColor)
    static let layout = StudioBlockStyle(tint: .systemGreen)
    static let text = StudioBlockStyle(tint: .systemPurple)
    static let image = StudioBlockStyle(tint: .systemTeal)
    static let effect = StudioBlockStyle(tint: .systemGray)
    static let audio = StudioBlockStyle(tint: .systemIndigo)

    /// The tint settled a little toward black, more so in dark mode, so a
    /// row of blocks stays calm and white marks read on any of them. The
    /// pointer lifts it slightly.
    func fill(isHovering: Bool) -> Color {
        let tint = tint
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = tint
            appearance.performAsCurrentDrawingAppearance {
                resolved = tint.usingColorSpace(.sRGB) ?? tint
            }
            let body = resolved.blended(
                withFraction: appearance.isDarkAppearance ? 0.3 : 0.12,
                of: .black
            ) ?? resolved
            return isHovering ? body.blended(withFraction: 0.1, of: .white) ?? body : body
        })
    }
}

/// A block's body: its fill, a faint light along the top and a hairline
/// rim, so neighbouring blocks and the track behind them stay apart.
private struct StudioBlockSurface<Fill: ShapeStyle>: View {
    let fill: Fill

    var body: some View {
        let shape = StudioZoomLaneMetrics.blockShape
        shape.fill(fill)
            .overlay {
                shape.fill(LinearGradient(
                    colors: [.white.opacity(0.14), .white.opacity(0)],
                    startPoint: .top,
                    endPoint: .center
                ))
            }
            .overlay {
                shape.strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
    }
}

/// The one label every block uses: a glyph, then a title, then a quieter
/// detail. As the block narrows the detail goes first, then the title
/// (a long one is truncated while a few letters still show), then the
/// glyph, so nothing is ever cut to a stub like "C…".
private struct StudioBlockLabel: View {
    let systemImage: String
    let title: String
    var detail: String?
    let width: CGFloat
    let color: Color

    var body: some View {
        if width >= 28 {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                ViewThatFits(in: .horizontal) {
                    if let detail {
                        HStack(spacing: 5) {
                            titleText
                            Text(detail)
                                .font(.system(size: 11))
                                .opacity(0.72)
                        }
                        .fixedSize()
                    }
                    titleText
                        .fixedSize()
                    // A long title is cut only where a few letters still
                    // show; below that the glyph stands alone.
                    if width >= 88 {
                        titleText
                            .truncationMode(.tail)
                    } else {
                        Color.clear.frame(width: 0)
                    }
                }
            }
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, StudioZoomLaneMetrics.handleWidth)
            .frame(width: width, alignment: .leading)
            .allowsHitTesting(false)
        }
    }

    /// Digits keep their width, so "1.5×" doesn't shuffle as it changes.
    private var titleText: Text {
        Text(title)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
    }
}

/// Selection, drawn the way Apple's trimmers draw it: a yellow frame whose
/// ends thicken into grips. The block's own edge handles sit over the ends.
private struct StudioTrimFrame: View {
    var body: some View {
        StudioTrimFrameShape(
            edgeWidth: StudioZoomLaneMetrics.trimEdgeWidth,
            borderWidth: StudioZoomLaneMetrics.trimBorderWidth,
            cornerRadius: StudioZoomLaneMetrics.blockCornerRadius
        )
        .fill(Color(nsColor: .systemYellow), style: FillStyle(eoFill: true))
        .overlay(alignment: .leading) { grip }
        .overlay(alignment: .trailing) { grip }
        .allowsHitTesting(false)
    }

    private var grip: some View {
        Capsule()
            .fill(Color.black.opacity(0.5))
            .frame(width: 1.5, height: 9)
            .frame(width: StudioZoomLaneMetrics.trimEdgeWidth)
    }
}

/// A rounded frame: thin along the top and bottom, wide at either end.
private struct StudioTrimFrameShape: Shape {
    let edgeWidth: CGFloat
    let borderWidth: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        let inner = rect.insetBy(dx: edgeWidth, dy: borderWidth)
        if inner.width > 0, inner.height > 0 {
            path.addPath(Path(
                roundedRect: inner,
                cornerRadius: max(0, cornerRadius - borderWidth),
                style: .continuous
            ))
        }
        return path
    }
}

/// The mark on a block's edge under the pointer, saying it can be dragged.
/// A selected block shows the trim frame's grips instead.
private struct StudioBlockGrip: View {
    var color: Color = .white

    var body: some View {
        Capsule()
            .fill(color.opacity(0.85))
            .frame(width: 2, height: 10)
    }
}

private enum StudioZoomLaneMetrics {
    static let laneHeight = StudioTrack.zooms.height
    static let blockCornerRadius: CGFloat = 4
    static var blockShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: blockCornerRadius, style: .continuous)
    }
    /// The selection frame's grips at either end, and its rim between them.
    static let trimEdgeWidth: CGFloat = 6
    static let trimBorderWidth: CGFloat = 2
    static let blockInset: CGFloat = 4
    static let blockHeight = laneHeight - blockInset * 2
    static let handleWidth: CGFloat = 10
    /// Magnifications offered from a block's context menu.
    static let zoomPresets: [Double] = [1.25, 1.5, 2, 2.5, 3]
}

/// One zoom on the timeline: an accent capsule whose label names the
/// magnification (and, when there is room, where the camera looks). Resize
/// handles show on hover and selection; a turned-off zoom keeps its place as
/// a muted, hatched block.
private struct StudioZoomCueBlock: View {
    @Bindable var model: RecordingStudioModel
    let block: RecordingZoomTimelineBlock
    let scale: StudioTimelineScale

    /// Frozen at drag start. The live block re-derives on every model update,
    /// so measuring the drag against it would compound the translation each
    /// event and send the block flying.
    private struct DragBase {
        let cue: ZoomCue
        let editorStart: TimeInterval
        let editorEnd: TimeInterval
    }

    @State private var dragBase: DragBase?
    @State private var isHovering = false

    private var isSelected: Bool {
        model.selectedCueID == block.cue.id
    }

    private var showsHandles: Bool {
        isSelected || isHovering || dragBase != nil
    }

    var body: some View {
        if scale.pointsPerSecond > 0 {
            content
        }
    }

    private var content: some View {
        let cue = block.cue
        let blockDuration = block.editorEnd - block.editorStart
        // Short cues keep a grabbable minimum width even when the timeline is
        // fitted; zooming in is what makes them accurate to work with.
        let width = min(
            scale.contentWidth,
            max(24, CGFloat(blockDuration) * scale.pointsPerSecond)
        )
        let x = min(
            max(scale.x(for: block.editorStart), 0),
            max(0, scale.contentWidth - width)
        )

        return label(for: cue, width: width)
            .frame(width: width, height: StudioZoomLaneMetrics.blockHeight, alignment: .leading)
            .background { blockFill(cue: cue) }
            .overlay { if isSelected { StudioTrimFrame() } }
            .overlay(alignment: .leading) {
                if showsHandles { resizeHandle(edge: .leading) }
            }
            .overlay(alignment: .trailing) {
                if showsHandles { resizeHandle(edge: .trailing) }
            }
            .contentShape(StudioZoomLaneMetrics.blockShape)
            .onHover { isHovering = $0 }
            .offset(x: x, y: StudioZoomLaneMetrics.blockInset)
            .gesture(moveGesture(cue: cue))
            .onTapGesture {
                model.selectZoomCue(id: cue.id)
            }
            .contextMenu { menu(for: cue) }
            .help(helpText(for: cue))
    }

    private func label(for cue: ZoomCue, width: CGFloat) -> some View {
        StudioBlockLabel(
            systemImage: cue.anchorMode == .pinnedAnchor ? "scope" : "magnifyingglass",
            title: cue.isEnabled
                ? InspectorValueFormat.magnification(fractionDigits: 1).displayString(for: cue.zoom)
                : "Off",
            // Following the pointer is the default, so only a zoom that
            // does something else says so.
            detail: cue.isEnabled && cue.anchorMode != .pointerAnchor ? cue.anchorMode.laneTitle : nil,
            width: width,
            color: cue.isEnabled ? StudioBlockStyle.zoom.onTint : .secondary
        )
    }

    @ViewBuilder
    private func blockFill(cue: ZoomCue) -> some View {
        if cue.isEnabled {
            StudioBlockSurface(fill: StudioBlockStyle.zoom.fill(isHovering: isHovering))
        } else {
            StudioBlockSurface(fill: Color.primary.opacity(0.08))
                .overlay {
                    // Hatched, so a turned-off zoom reads as "kept, not used".
                    Canvas { context, size in
                        var path = Path()
                        var x: CGFloat = -size.height
                        while x < size.width {
                            path.move(to: CGPoint(x: x, y: size.height))
                            path.addLine(to: CGPoint(x: x + size.height, y: 0))
                            x += 6
                        }
                        context.stroke(path, with: .color(.primary.opacity(0.10)), lineWidth: 1)
                    }
                    .clipShape(StudioZoomLaneMetrics.blockShape)
                    .allowsHitTesting(false)
                }
        }
    }

    @ViewBuilder
    private func menu(for cue: ZoomCue) -> some View {
        Menu("Zoom Level") {
            ForEach(StudioZoomLaneMetrics.zoomPresets, id: \.self) { preset in
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

    /// One undoable change to this zoom from its context menu.
    private func edit(_ cue: ZoomCue, action: String, _ change: (inout ZoomCue) -> Void) {
        var updated = cue
        change(&updated)
        model.beginZoomCueEdit()
        model.updateZoomCue(updated)
        model.endZoomCueEdit(actionName: action)
    }

    private func helpText(for cue: ZoomCue) -> String {
        guard cue.isEnabled else { return "Turned off. Right-click to turn it back on." }
        return "Drag to move, drag an edge to resize, right-click for options"
    }

    private func moveGesture(cue: ZoomCue) -> some Gesture {
        // Global coordinates: the block moves under the pointer while
        // dragging, so a local-space translation would chase its own
        // updates and jitter.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if dragBase == nil {
                    dragBase = DragBase(
                        cue: cue,
                        editorStart: block.editorStart,
                        editorEnd: block.editorEnd
                    )
                    model.beginZoomCueEdit()
                    model.selectZoomCue(id: cue.id)
                }
                guard let dragBase else { return }
                let delta = Double(value.translation.width) * scale.secondsPerPoint
                var moved = dragBase.cue
                let length = dragBase.cue.duration
                let baseBlockDuration = dragBase.editorEnd - dragBase.editorStart
                let editorStart = min(
                    max(0, dragBase.editorStart + delta),
                    max(0, model.duration - baseBlockDuration)
                )
                moved.start = min(
                    max(0, model.sourceTime(atEditorTime: editorStart)),
                    max(0, model.sourceDuration - length)
                )
                moved.end = min(model.sourceDuration, moved.start + length)
                model.moveZoomCue(moved)
            }
            .onEnded { _ in
                dragBase = nil
                model.endZoomCueEdit(actionName: "Move Zoom")
            }
    }

    private func resizeHandle(edge: HorizontalEdge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: StudioZoomLaneMetrics.handleWidth, height: StudioZoomLaneMetrics.blockHeight)
            .overlay {
                if !isSelected {
                    StudioBlockGrip(color: block.cue.isEnabled ? StudioBlockStyle.zoom.onTint : .secondary)
                }
            }
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: edge == .leading ? .leading : .trailing))
            .gesture(
                // Global coordinates - the handle itself moves while resizing,
                // so local-space translations feed back into the drag and jitter.
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = DragBase(
                                cue: block.cue,
                                editorStart: block.editorStart,
                                editorEnd: block.editorEnd
                            )
                            model.beginZoomCueEdit()
                            model.selectZoomCue(id: block.cue.id)
                        }
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * scale.secondsPerPoint
                        var resized = dragBase.cue
                        switch edge {
                        case .leading:
                            let editorTime = dragBase.editorStart + delta
                            let sourceTime = model.sourceTime(atEditorTime: editorTime)
                            resized.start = min(
                                max(0, sourceTime),
                                dragBase.cue.end - ZoomCue.minimumDuration
                            )
                        case .trailing:
                            let editorTime = dragBase.editorEnd + delta
                            let sourceTime = model.sourceTime(atEditorTime: editorTime)
                            resized.end = max(
                                dragBase.cue.start + ZoomCue.minimumDuration,
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

/// Camera layout cues. Dragging across empty lane creates one over the
/// dragged range; a click scrubs, as on the zoom lane.
private struct StudioLayoutLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>

    private static let dragCreateThreshold: CGFloat = 4

    @State private var dragStartTime: TimeInterval?
    @State private var pendingRange: ClosedRange<TimeInterval>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard scale.pointsPerSecond > 0 else { return }
                            let time = scale.time(forX: value.location.x)
                            if dragStartTime == nil {
                                model.pause()
                                dragStartTime = time
                                model.clearTimelineSelection()
                            }
                            guard let startTime = dragStartTime else { return }
                            if pendingRange == nil,
                               abs(value.location.x - scale.x(for: startTime)) < Self.dragCreateThreshold {
                                model.seek(to: time)
                                return
                            }
                            pendingRange = clampedRange(from: startTime, to: time)
                        }
                        .onEnded { _ in
                            if let range = pendingRange, range.upperBound - range.lowerBound > 0.001 {
                                model.addLayoutCue(fromEditorTime: range.lowerBound, toEditorTime: range.upperBound)
                            }
                            dragStartTime = nil
                            pendingRange = nil
                        }
                )

            if let pendingRange {
                let lowX = scale.x(for: pendingRange.lowerBound)
                let highX = scale.x(for: pendingRange.upperBound)
                RoundedRectangle(cornerRadius: StudioZoomLaneMetrics.blockCornerRadius, style: .continuous)
                    .fill(Palette.layoutCue.opacity(0.22))
                    .overlay {
                        RoundedRectangle(cornerRadius: StudioZoomLaneMetrics.blockCornerRadius, style: .continuous)
                            .strokeBorder(Palette.layoutCue.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                    .frame(width: max(2, highX - lowX), height: StudioZoomLaneMetrics.blockHeight)
                    .offset(x: lowX, y: StudioZoomLaneMetrics.blockInset)
                    .allowsHitTesting(false)
            }

            ForEach(visibleBlocks) { block in
                StudioLayoutCueBlock(model: model, block: block, scale: scale)
            }
        }
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

    private func clampedRange(from startTime: TimeInterval, to currentTime: TimeInterval) -> ClosedRange<TimeInterval> {
        let blocks = model.cameraLayoutTimelineBlocks
        let lowerLimit = blocks.filter { $0.editorEnd <= startTime }.map(\.editorEnd).max() ?? 0
        let upperLimit = blocks.filter { $0.editorStart >= startTime }.map(\.editorStart).min() ?? model.duration
        let low = max(min(startTime, currentTime), lowerLimit)
        let high = min(max(startTime, currentTime), upperLimit)
        return low...max(low, high)
    }

    private var visibleBlocks: [RecordingCameraLayoutTimelineBlock] {
        model.cameraLayoutTimelineBlocks.filter {
            $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound
        }
    }
}

/// One layout cue: a capsule naming its layout, with the morph-in drawn as
/// a soft ramp at its leading edge. Moves and resizes like a zoom block.
private struct StudioLayoutCueBlock: View {
    @Bindable var model: RecordingStudioModel
    let block: RecordingCameraLayoutTimelineBlock
    let scale: StudioTimelineScale

    private struct DragBase {
        let cue: RecordingCameraLayoutCue
        let editorStart: TimeInterval
        let editorEnd: TimeInterval
    }

    @State private var dragBase: DragBase?
    @State private var isHovering = false

    private var isSelected: Bool {
        model.selectedLayoutCueID == block.cue.id
    }

    private var showsHandles: Bool {
        isSelected || isHovering || dragBase != nil
    }

    var body: some View {
        if scale.pointsPerSecond > 0 {
            content
        }
    }

    private var content: some View {
        let cue = block.cue
        let width = min(
            scale.contentWidth,
            max(24, CGFloat(block.editorEnd - block.editorStart) * scale.pointsPerSecond)
        )
        let x = min(max(scale.x(for: block.editorStart), 0), max(0, scale.contentWidth - width))
        let rampWidth = min(width / 2, CGFloat(RecordingCameraLayoutTimeline.transitionDuration) * scale.pointsPerSecond)

        return StudioBlockLabel(
            systemImage: cue.layout.systemImage,
            title: cue.layout.title,
            width: width,
            color: StudioBlockStyle.layout.onTint
        )
            .frame(width: width, height: StudioZoomLaneMetrics.blockHeight, alignment: .leading)
            .background {
                StudioBlockSurface(fill: StudioBlockStyle.layout.fill(isHovering: isHovering))
                    .overlay(alignment: .leading) {
                        // Where the layout is still morphing in.
                        LinearGradient(
                            colors: [StudioBlockStyle.layout.onTint.opacity(0.2), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: rampWidth)
                        .clipShape(StudioZoomLaneMetrics.blockShape)
                        .allowsHitTesting(false)
                    }
            }
            .overlay { if isSelected { StudioTrimFrame() } }
            .overlay(alignment: .leading) {
                if showsHandles { resizeHandle(edge: .leading) }
            }
            .overlay(alignment: .trailing) {
                if showsHandles { resizeHandle(edge: .trailing) }
            }
            .contentShape(StudioZoomLaneMetrics.blockShape)
            .onHover { isHovering = $0 }
            .offset(x: x, y: StudioZoomLaneMetrics.blockInset)
            .gesture(moveGesture(cue: cue))
            .onTapGesture {
                model.selectLayoutCue(id: cue.id)
            }
            .contextMenu { menu(for: cue) }
            .help("\(cue.layout.detailedTitle). Drag to move, drag an edge to resize, right-click to change.")
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

    private func beginDrag() {
        guard dragBase == nil else { return }
        dragBase = DragBase(cue: block.cue, editorStart: block.editorStart, editorEnd: block.editorEnd)
        model.beginLayoutCueEdit()
        model.selectLayoutCue(id: block.cue.id)
    }

    private func moveGesture(cue: RecordingCameraLayoutCue) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                beginDrag()
                guard let dragBase else { return }
                let delta = Double(value.translation.width) * scale.secondsPerPoint
                let length = dragBase.cue.duration
                let blockDuration = dragBase.editorEnd - dragBase.editorStart
                let editorStart = min(max(0, dragBase.editorStart + delta), max(0, model.duration - blockDuration))
                var moved = dragBase.cue
                moved.start = min(
                    max(0, model.sourceTime(atEditorTime: editorStart)),
                    max(0, model.sourceDuration - length)
                )
                moved.end = min(model.sourceDuration, moved.start + length)
                model.moveLayoutCue(moved)
            }
            .onEnded { _ in
                dragBase = nil
                model.endLayoutCueEdit(actionName: "Move Layout")
            }
    }

    private func resizeHandle(edge: HorizontalEdge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: StudioZoomLaneMetrics.handleWidth, height: StudioZoomLaneMetrics.blockHeight)
            .overlay {
                if !isSelected { StudioBlockGrip(color: StudioBlockStyle.layout.onTint) }
            }
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: edge == .leading ? .leading : .trailing))
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        beginDrag()
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * scale.secondsPerPoint
                        var resized = dragBase.cue
                        let minimum = RecordingCameraLayoutCue.minimumDuration
                        switch edge {
                        case .leading:
                            let source = model.sourceTime(atEditorTime: dragBase.editorStart + delta)
                            resized.start = min(max(0, source), dragBase.cue.end - minimum)
                        case .trailing:
                            let source = model.sourceTime(atEditorTime: dragBase.editorEnd + delta)
                            resized.end = max(dragBase.cue.start + minimum, min(model.sourceDuration, source))
                        }
                        model.resizeLayoutCue(resized)
                    }
                    .onEnded { _ in
                        dragBase = nil
                        model.endLayoutCueEdit(actionName: "Resize Layout")
                    }
            )
    }
}

// MARK: - Text and pixelate tracks

/// Text blocks. Dragging across empty track adds a text over the dragged
/// range; a click scrubs, as on the zoom lane.
private struct StudioTextLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>
    let onScrubbing: (Bool) -> Void

    private static let dragCreateThreshold: CGFloat = 4

    @State private var dragStartTime: TimeInterval?
    @State private var pendingRange: ClosedRange<TimeInterval>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard scale.pointsPerSecond > 0 else { return }
                            let time = scale.time(forX: value.location.x)
                            if dragStartTime == nil {
                                model.pause()
                                dragStartTime = time
                                model.clearTimelineSelection()
                            }
                            guard let startTime = dragStartTime else { return }
                            if pendingRange == nil,
                               abs(value.location.x - scale.x(for: startTime)) < Self.dragCreateThreshold {
                                onScrubbing(true)
                                model.seek(to: time)
                                return
                            }
                            onScrubbing(false)
                            pendingRange = min(startTime, time)...max(startTime, time)
                        }
                        .onEnded { _ in
                            onScrubbing(false)
                            if let range = pendingRange, range.upperBound - range.lowerBound > 0.05 {
                                model.addText(fromEditorTime: range.lowerBound, toEditorTime: range.upperBound)
                            }
                            dragStartTime = nil
                            pendingRange = nil
                        }
                )

            if let pendingRange {
                StudioPendingBlock(range: pendingRange, scale: scale, tint: Palette.textCue)
            }

            ForEach(visibleBlocks) { block in
                StudioOverlayBlock(
                    block: block,
                    scale: scale,
                    isSelected: model.selectedTextID == block.item.id,
                    style: .text,
                    systemImage: "textformat",
                    title: block.item.text.isEmpty ? "Text" : block.item.text
                        .replacingOccurrences(of: "\n", with: " "),
                    isHatched: false,
                    onSelect: { model.selectText(id: block.item.id) },
                    onBegin: {
                        model.selectText(id: block.item.id)
                        model.beginTextEdit()
                    },
                    onEdit: { base, start, end in
                        var edited = base
                        edited.start = start
                        edited.end = end
                        model.setText(edited)
                    },
                    onEnd: { kind in
                        model.endTextEdit(actionName: kind == .move ? "Move Text" : "Resize Text")
                    },
                    sourceRange: { ($0.start, $0.end) },
                    model: model
                ) {
                    Button("Delete Text", systemImage: "trash", role: .destructive) {
                        model.removeText(id: block.item.id)
                    }
                }
            }
        }
        .contextMenu {
            Button("Add Text at Playhead", systemImage: "textformat") {
                model.addText(atEditorTime: model.currentTime)
            }
        }
    }

    private var visibleBlocks: [RecordingOverlayTimelineBlock<RecordingTextOverlay>] {
        model.textTimelineBlocks.filter {
            $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound
        }
    }
}

/// Images, GIFs, and pixelate and blur blocks, on the Images and Effects
/// track. A click on empty track scrubs.
private struct StudioRedactionLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>
    let onScrubbing: (Bool) -> Void

    @State private var isScrubbing = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isScrubbing {
                                isScrubbing = true
                                onScrubbing(true)
                                model.pause()
                                model.clearTimelineSelection()
                            }
                            model.seek(to: scale.time(forX: value.location.x))
                        }
                        .onEnded { _ in
                            isScrubbing = false
                            onScrubbing(false)
                        }
                )

            ForEach(visibleImageBlocks) { block in
                let overlay = block.item
                StudioOverlayBlock(
                    block: block,
                    scale: scale,
                    isSelected: model.selectedImageID == overlay.id,
                    style: .image,
                    systemImage: overlay.isAnimated ? "photo.stack" : "photo",
                    title: overlay.isAnimated ? "\(overlay.displayName) · GIF" : overlay.displayName,
                    isHatched: false,
                    onSelect: { model.selectImage(id: overlay.id) },
                    onBegin: {
                        model.selectImage(id: overlay.id)
                        model.beginImageEdit()
                    },
                    onEdit: { base, start, end in
                        var edited = base
                        edited.start = start
                        edited.end = end
                        model.setImage(edited)
                    },
                    onEnd: { kind in
                        model.endImageEdit(actionName: kind == .move ? "Move Image" : "Resize Image")
                    },
                    sourceRange: { ($0.start, $0.end) },
                    model: model
                ) {
                    Button("Delete Image", systemImage: "trash", role: .destructive) {
                        model.removeImage(id: overlay.id)
                    }
                }
            }

            ForEach(visibleBlocks) { block in
                let redaction = block.item
                StudioOverlayBlock(
                    block: block,
                    scale: scale,
                    isSelected: model.selectedRedactionID == redaction.id,
                    style: .effect,
                    systemImage: redaction.style.systemImage,
                    title: redaction.style.title,
                    isHatched: true,
                    onSelect: { model.selectRedaction(id: redaction.id) },
                    onBegin: {
                        model.selectRedaction(id: redaction.id)
                        model.beginRedactionEdit()
                    },
                    onEdit: { base, start, end in
                        var edited = base
                        edited.start = start
                        edited.end = end
                        model.setRedaction(edited)
                    },
                    onEnd: { kind in
                        model.endRedactionEdit(actionName: kind == .move ? "Move Pixelate" : "Resize Pixelate")
                    },
                    sourceRange: { ($0.start, $0.end) },
                    model: model
                ) {
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
        }
        .contextMenu {
            Button("Pixelate at Playhead", systemImage: "squareshape.split.3x3") {
                model.addRedaction(atEditorTime: model.currentTime)
            }
            Button("Blur at Playhead", systemImage: "drop.halffull") {
                model.addRedaction(atEditorTime: model.currentTime, style: .blur)
            }
        }
    }

    private var visibleImageBlocks: [RecordingOverlayTimelineBlock<RecordingImageOverlay>] {
        model.imageTimelineBlocks.filter {
            $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound
        }
    }

    private var visibleBlocks: [RecordingOverlayTimelineBlock<RecordingRedaction>] {
        model.redactionTimelineBlocks.filter {
            $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound
        }
    }
}

/// The dashed block a drag across an empty track would create.
private struct StudioPendingBlock: View {
    let range: ClosedRange<TimeInterval>
    let scale: StudioTimelineScale
    let tint: Color

    var body: some View {
        let lowX = scale.x(for: range.lowerBound)
        let highX = scale.x(for: range.upperBound)
        let shape = RoundedRectangle(cornerRadius: StudioZoomLaneMetrics.blockCornerRadius, style: .continuous)
        shape
            .fill(tint.opacity(0.22))
            .overlay {
                shape.strokeBorder(tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            .frame(width: max(2, highX - lowX), height: StudioZoomLaneMetrics.blockHeight)
            .offset(x: lowX, y: StudioZoomLaneMetrics.blockInset)
            .allowsHitTesting(false)
    }
}

/// One text or effect on its track: a tinted block naming what it is, moved
/// by dragging its body and resized by its edges. Unlike zooms and
/// layouts, these may overlap, so a block never parks against another.
private struct StudioOverlayBlock<Item: Identifiable & Sendable, MenuContent: View>: View {
    enum EditKind { case move, leading, trailing }

    let block: RecordingOverlayTimelineBlock<Item>
    let scale: StudioTimelineScale
    let isSelected: Bool
    let style: StudioBlockStyle
    let systemImage: String
    let title: String
    /// Effects carry light stripes, so they read apart from images.
    let isHatched: Bool
    let onSelect: () -> Void
    let onBegin: () -> Void
    /// The item as the drag found it, and its new source range.
    let onEdit: (Item, TimeInterval, TimeInterval) -> Void
    let onEnd: (EditKind) -> Void
    let sourceRange: (Item) -> (start: TimeInterval, end: TimeInterval)
    let model: RecordingStudioModel
    @ViewBuilder let menu: () -> MenuContent

    /// Frozen at drag start; the live block re-derives on every update.
    private struct DragBase {
        let item: Item
        let editorStart: TimeInterval
        let editorEnd: TimeInterval
    }

    @State private var dragBase: DragBase?
    @State private var isHovering = false

    private var showsHandles: Bool {
        isSelected || isHovering || dragBase != nil
    }

    var body: some View {
        if scale.pointsPerSecond > 0 {
            content
        }
    }

    private var content: some View {
        let width = min(
            scale.contentWidth,
            max(16, CGFloat(block.editorEnd - block.editorStart) * scale.pointsPerSecond)
        )
        let x = min(max(scale.x(for: block.editorStart), 0), max(0, scale.contentWidth - width))
        let shape = StudioZoomLaneMetrics.blockShape

        return StudioBlockLabel(systemImage: systemImage, title: title, width: width, color: style.onTint)
            .frame(width: width, height: StudioZoomLaneMetrics.blockHeight, alignment: .leading)
            .background {
                StudioBlockSurface(fill: style.fill(isHovering: isHovering))
                    .overlay {
                        if isHatched {
                            let stripe = style.onTint.opacity(0.1)
                            Canvas { context, size in
                                var path = Path()
                                var stripeX: CGFloat = -size.height
                                while stripeX < size.width {
                                    path.move(to: CGPoint(x: stripeX, y: size.height))
                                    path.addLine(to: CGPoint(x: stripeX + size.height, y: 0))
                                    stripeX += 12
                                }
                                context.stroke(path, with: .color(stripe), lineWidth: 6)
                            }
                            .clipShape(shape)
                            .allowsHitTesting(false)
                        }
                    }
            }
            .overlay { if isSelected { StudioTrimFrame() } }
            .overlay(alignment: .leading) {
                if showsHandles { resizeHandle(.leading) }
            }
            .overlay(alignment: .trailing) {
                if showsHandles { resizeHandle(.trailing) }
            }
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .offset(x: x, y: StudioZoomLaneMetrics.blockInset)
            .gesture(dragGesture(.move))
            .onTapGesture(perform: onSelect)
            .contextMenu { menu() }
            .help("\(title). Drag to move, drag an edge to resize, right-click for options.")
    }

    private func dragGesture(_ kind: EditKind) -> some Gesture {
        // Global coordinates: the block moves under the pointer, so local
        // translations would chase their own updates and jitter.
        DragGesture(minimumDistance: kind == .move ? 2 : 0, coordinateSpace: .global)
            .onChanged { value in
                if dragBase == nil {
                    dragBase = DragBase(item: block.item, editorStart: block.editorStart, editorEnd: block.editorEnd)
                    model.pause()
                    onBegin()
                }
                guard let dragBase else { return }
                let delta = Double(value.translation.width) * scale.secondsPerPoint
                let base = sourceRange(dragBase.item)
                switch kind {
                case .move:
                    let length = base.end - base.start
                    let blockLength = dragBase.editorEnd - dragBase.editorStart
                    let editorStart = min(max(0, dragBase.editorStart + delta), max(0, model.duration - blockLength))
                    let start = min(max(0, model.sourceTime(atEditorTime: editorStart)), max(0, model.sourceDuration - length))
                    onEdit(dragBase.item, start, start + length)
                case .leading:
                    let start = model.sourceTime(atEditorTime: dragBase.editorStart + delta)
                    onEdit(dragBase.item, min(start, base.end - 0.1), base.end)
                case .trailing:
                    let end = model.sourceTime(atEditorTime: dragBase.editorEnd + delta)
                    onEdit(dragBase.item, base.start, max(end, base.start + 0.1))
                }
            }
            .onEnded { _ in
                dragBase = nil
                onEnd(kind)
            }
    }

    private func resizeHandle(_ edge: HorizontalEdge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: StudioZoomLaneMetrics.handleWidth, height: StudioZoomLaneMetrics.blockHeight)
            .overlay {
                if !isSelected { StudioBlockGrip(color: style.onTint) }
            }
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: edge == .leading ? .leading : .trailing))
            .gesture(dragGesture(edge == .leading ? .leading : .trailing))
    }
}

// MARK: - Audio track

/// Music and sound under the video. Blocks sit on the edited video's clock;
/// a click on empty track scrubs.
private struct StudioAudioLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>
    let onScrubbing: (Bool) -> Void

    @State private var isScrubbing = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isScrubbing {
                                isScrubbing = true
                                onScrubbing(true)
                                model.pause()
                                model.clearTimelineSelection()
                            }
                            model.seek(to: scale.time(forX: value.location.x))
                        }
                        .onEnded { _ in
                            isScrubbing = false
                            onScrubbing(false)
                        }
                )

            ForEach(visibleClips) { clip in
                StudioAudioClipBlock(model: model, clip: clip, scale: scale)
            }
        }
    }

    private var visibleClips: [RecordingAudioClip] {
        model.audioClips.filter { $0.end >= visibleRange.lowerBound && $0.start <= visibleRange.upperBound }
    }
}

/// One audio clip: its name over a waveform of the stretch that plays.
/// The body moves it along the video; the edges trim the file.
private struct StudioAudioClipBlock: View {
    @Bindable var model: RecordingStudioModel
    let clip: RecordingAudioClip
    let scale: StudioTimelineScale

    private enum EditKind { case move, leading, trailing }

    @State private var dragBase: RecordingAudioClip?
    @State private var isHovering = false

    private static let height = StudioTrack.audio.height - StudioZoomLaneMetrics.blockInset * 2

    private var isSelected: Bool { model.selectedAudioClipID == clip.id }
    private var showsHandles: Bool { isSelected || isHovering || dragBase != nil }

    var body: some View {
        if scale.pointsPerSecond > 0 {
            content
        }
    }

    private var content: some View {
        let x = scale.x(for: clip.start)
        // A clip may run past the video's end; only what fits is drawn.
        let width = max(16, min(CGFloat(clip.duration) * scale.pointsPerSecond, scale.contentWidth - x))
        let shape = StudioZoomLaneMetrics.blockShape
        let peaks = model.audioPeaks[clip.fileName] ?? []

        return ZStack(alignment: .topLeading) {
            StudioWaveform(
                peaks: peaks,
                color: StudioBlockStyle.audio.onTint.opacity(0.55),
                from: clip.trimStart,
                to: clip.trimStart + Double(width / scale.pointsPerSecond)
            )
            .padding(.top, 13)
            .padding(.bottom, 3)
            .padding(.horizontal, 2)

            StudioBlockLabel(
                systemImage: "music.note",
                title: clip.displayName,
                width: width,
                color: StudioBlockStyle.audio.onTint
            )
            .padding(.top, 2)
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
        .background { StudioBlockSurface(fill: StudioBlockStyle.audio.fill(isHovering: isHovering)) }
        .clipShape(shape)
        .overlay { if isSelected { StudioTrimFrame() } }
        .overlay(alignment: .leading) {
            if showsHandles { resizeHandle(.leading) }
        }
        .overlay(alignment: .trailing) {
            if showsHandles { resizeHandle(.trailing) }
        }
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .offset(x: x, y: StudioZoomLaneMetrics.blockInset)
        .gesture(dragGesture(.move))
        .onTapGesture { model.selectAudioClip(id: clip.id) }
        .contextMenu {
            Button("Delete Audio", systemImage: "trash", role: .destructive) {
                model.removeAudioClip(id: clip.id)
            }
        }
        .help("\(clip.displayName). Drag to move, drag an edge to trim, right-click for options.")
    }

    private func dragGesture(_ kind: EditKind) -> some Gesture {
        DragGesture(minimumDistance: kind == .move ? 2 : 0, coordinateSpace: .global)
            .onChanged { value in
                if dragBase == nil {
                    dragBase = clip
                    model.pause()
                    model.selectAudioClip(id: clip.id)
                    model.beginAudioClipEdit()
                }
                guard let base = dragBase else { return }
                let delta = Double(value.translation.width) * scale.secondsPerPoint
                let minimum = RecordingAudioClip.minimumDuration
                var edited = base
                switch kind {
                case .move:
                    edited.start = max(0, base.start + delta)
                case .leading:
                    let shift = min(max(delta, -base.trimStart, -base.start), base.duration - minimum)
                    edited.start = base.start + shift
                    edited.trimStart = base.trimStart + shift
                case .trailing:
                    edited.trimEnd = min(max(base.trimEnd + delta, base.trimStart + minimum), base.fileDuration)
                }
                model.setAudioClip(edited)
            }
            .onEnded { _ in
                dragBase = nil
                model.endAudioClipEdit(actionName: kind == .move ? "Move Audio" : "Trim Audio")
            }
    }

    private func resizeHandle(_ edge: HorizontalEdge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: StudioZoomLaneMetrics.handleWidth, height: Self.height)
            .overlay {
                if !isSelected { StudioBlockGrip(color: StudioBlockStyle.audio.onTint) }
            }
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: edge == .leading ? .leading : .trailing))
            .gesture(dragGesture(edge == .leading ? .leading : .trailing))
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
