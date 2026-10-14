//
//  RecordingClipTimelineView.swift
//  Screendrop
//
//  Compact, segment-aware Studio video lane. The AppKit control gives mouse
//  tracking, contextual split locations, cursor control, and edge trimming
//  pixel-level precision while SwiftUI owns the surrounding editor chrome.
//

import AppKit
import SwiftUI

struct RecordingClipTimelineView: NSViewRepresentable {
    @Binding var selectedClipID: UUID?
    @Binding var playheadTime: TimeInterval

    let timeline: RecordingClipTimeline
    let sourceDuration: TimeInterval
    let thumbnails: RecordingTimelineThumbnailStore
    let onSelect: (UUID) -> Void
    let onSeek: (TimeInterval) -> Void
    let onHover: (TimeInterval?) -> Void
    let onSplit: (TimeInterval) -> Void
    let onDelete: () -> Void
    let onTrim: (RecordingClipSegment) -> Void
    /// Pinch or ⌘-scroll over the lane: `(factor, anchor editor time)`. The
    /// anchor is the time under the pointer, which the caller keeps pinned to
    /// its current screen position while the scale changes.
    let onZoom: (Double, TimeInterval) -> Void
    /// Arrow-key nudge of the playhead by a signed number of seconds.
    let onStep: (TimeInterval) -> Void
    /// A speed picked from a clip's context menu: `(clip, rate)`.
    let onSetSpeed: (UUID, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedClipID: $selectedClipID,
            playheadTime: $playheadTime,
            onSelect: onSelect,
            onSeek: onSeek,
            onHover: onHover,
            onSplit: onSplit,
            onDelete: onDelete,
            onTrim: onTrim,
            onZoom: onZoom,
            onStep: onStep,
            onSetSpeed: onSetSpeed
        )
    }

    func makeNSView(context: Context) -> RecordingClipTimelineControl {
        let view = RecordingClipTimelineControl()
        context.coordinator.connect(to: view)
        return view
    }

    func updateNSView(_ nsView: RecordingClipTimelineControl, context: Context) {
        context.coordinator.updateCallbacks(
            onSelect: onSelect,
            onSeek: onSeek,
            onHover: onHover,
            onSplit: onSplit,
            onDelete: onDelete,
            onTrim: onTrim,
            onZoom: onZoom,
            onStep: onStep,
            onSetSpeed: onSetSpeed
        )
        nsView.update(
            timeline: timeline,
            sourceDuration: sourceDuration,
            thumbnails: thumbnails,
            selectedClipID: selectedClipID,
            playheadTime: playheadTime
        )
    }

    final class Coordinator {
        @Binding private var selectedClipID: UUID?
        @Binding private var playheadTime: TimeInterval

        private var onSelect: (UUID) -> Void
        private var onSeek: (TimeInterval) -> Void
        private var onHover: (TimeInterval?) -> Void
        private var onSplit: (TimeInterval) -> Void
        private var onDelete: () -> Void
        private var onTrim: (RecordingClipSegment) -> Void
        private var onZoom: (Double, TimeInterval) -> Void
        private var onStep: (TimeInterval) -> Void
        private var onSetSpeed: (UUID, Double) -> Void

        init(
            selectedClipID: Binding<UUID?>,
            playheadTime: Binding<TimeInterval>,
            onSelect: @escaping (UUID) -> Void,
            onSeek: @escaping (TimeInterval) -> Void,
            onHover: @escaping (TimeInterval?) -> Void,
            onSplit: @escaping (TimeInterval) -> Void,
            onDelete: @escaping () -> Void,
            onTrim: @escaping (RecordingClipSegment) -> Void,
            onZoom: @escaping (Double, TimeInterval) -> Void,
            onStep: @escaping (TimeInterval) -> Void,
            onSetSpeed: @escaping (UUID, Double) -> Void
        ) {
            _selectedClipID = selectedClipID
            _playheadTime = playheadTime
            self.onSelect = onSelect
            self.onSeek = onSeek
            self.onHover = onHover
            self.onSplit = onSplit
            self.onDelete = onDelete
            self.onTrim = onTrim
            self.onZoom = onZoom
            self.onStep = onStep
            self.onSetSpeed = onSetSpeed
        }

        func updateCallbacks(
            onSelect: @escaping (UUID) -> Void,
            onSeek: @escaping (TimeInterval) -> Void,
            onHover: @escaping (TimeInterval?) -> Void,
            onSplit: @escaping (TimeInterval) -> Void,
            onDelete: @escaping () -> Void,
            onTrim: @escaping (RecordingClipSegment) -> Void,
            onZoom: @escaping (Double, TimeInterval) -> Void,
            onStep: @escaping (TimeInterval) -> Void,
            onSetSpeed: @escaping (UUID, Double) -> Void
        ) {
            self.onSelect = onSelect
            self.onSeek = onSeek
            self.onHover = onHover
            self.onSplit = onSplit
            self.onDelete = onDelete
            self.onTrim = onTrim
            self.onZoom = onZoom
            self.onStep = onStep
            self.onSetSpeed = onSetSpeed
        }

        func connect(to view: RecordingClipTimelineControl) {
            view.selectionDidChange = { [weak self] id in
                self?.selectedClipID = id
                self?.onSelect(id)
            }
            view.playheadDidChange = { [weak self] time in
                self?.playheadTime = time
                self?.onSeek(time)
            }
            view.hoverTimeDidChange = { [weak self] time in
                self?.onHover(time)
            }
            view.splitRequested = { [weak self] time in
                self?.onSplit(time)
            }
            view.deleteRequested = { [weak self] in
                self?.onDelete()
            }
            view.trimDidCommit = { [weak self] clip in
                self?.onTrim(clip)
            }
            view.zoomRequested = { [weak self] factor, anchorTime in
                self?.onZoom(factor, anchorTime)
            }
            view.stepRequested = { [weak self] seconds in
                self?.onStep(seconds)
            }
            view.speedRequested = { [weak self] clipID, speed in
                self?.onSetSpeed(clipID, speed)
            }
        }
    }
}

final class RecordingClipTimelineControl: NSView {
    var selectionDidChange: ((UUID) -> Void)?
    var playheadDidChange: ((TimeInterval) -> Void)?
    var hoverTimeDidChange: ((TimeInterval?) -> Void)?
    var splitRequested: ((TimeInterval) -> Void)?
    var deleteRequested: (() -> Void)?
    var trimDidCommit: ((RecordingClipSegment) -> Void)?
    var zoomRequested: ((Double, TimeInterval) -> Void)?
    var stepRequested: ((TimeInterval) -> Void)?
    var speedRequested: ((UUID, Double) -> Void)?

    private enum Edge: Equatable {
        case leading
        case trailing
    }

    private enum DragTarget {
        case scrub
        case trim(clipID: UUID, edge: Edge)
    }

    private enum Metrics {
        static let trackRadius: CGFloat = 10
        static let trackInset: CGFloat = 2
        static let clipRadius = trackRadius - trackInset
        static let selectionPadding: CGFloat = 3
        static let splitGap: CGFloat = trackInset * 2
        static let handleHitWidth: CGFloat = 10
        static let selectionHandleInset: CGFloat = 5
        static let selectionHandleGrooveWidth: CGFloat = 3
        static let selectionHandleGrooveHeight: CGFloat = 18
        static let thumbnailWidth: CGFloat = 58
        /// Scroll distance that equals one doubling of the timeline scale
        /// under ⌘-scroll.
        static let zoomScrollPointsPerDoubling: CGFloat = 220
        /// Arrow-key steps: one frame at 30 fps, or a second with Shift.
        static let frameStep: TimeInterval = 1.0 / 30.0
        static let coarseStep: TimeInterval = 1
    }

    private var timeline = RecordingClipTimeline(segments: [])
    private var sourceDuration: TimeInterval = 0
    private var thumbnails: RecordingTimelineThumbnailStore?
    private var selectedClipID: UUID?
    private var playheadTime: TimeInterval = 0

    private var trackingArea: NSTrackingArea?
    private var hoverTime: TimeInterval?
    private var hoveredClipID: UUID?
    private var hoveredEdge: (clipID: UUID, edge: Edge)?
    private var dragTarget: DragTarget?
    private var dragStartPoint: CGPoint?
    private var dragStartTimeline: RecordingClipTimeline?
    private var dragStartClip: RecordingClipSegment?
    private var contextTime: TimeInterval?
    private var contextClipID: UUID?
    private var lastHoverCallbackTimestamp: TimeInterval = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func update(
        timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval,
        thumbnails: RecordingTimelineThumbnailStore,
        selectedClipID: UUID?,
        playheadTime: TimeInterval
    ) {
        if dragTarget == nil {
            self.timeline = timeline
        }
        self.sourceDuration = sourceDuration
        if self.thumbnails !== thumbnails {
            self.thumbnails = thumbnails
            // Newly sampled tiles arrive outside SwiftUI's update cycle, so
            // the lane refreshes itself rather than invalidating the editor.
            thumbnails.onChange = { [weak self] in
                self?.needsDisplay = true
            }
        }
        self.selectedClipID = selectedClipID
        self.playheadTime = min(max(playheadTime, 0), max(timeline.duration, 0))
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .activeInKeyWindow,
                .mouseMoved,
                .mouseEnteredAndExited,
                .inVisibleRect,
                .cursorUpdate
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard timelineRect.width > 2, timelineRect.height > 2 else { return }

        drawTrack()
        drawSelectionChrome()
        drawClips(in: dirtyRect)
        drawSelectionGrooves()
        drawBadges(in: dirtyRect)
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeFirstResponder(self)
        updateHover(with: event, forceCallback: true)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event, forceCallback: false)
    }

    override func mouseExited(with event: NSEvent) {
        guard dragTarget == nil else { return }
        clearHover()
    }

    override func cursorUpdate(with event: NSEvent) {
        if hoveredEdge != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard timeline.duration > 0 else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard timelineRect.contains(point) else { return }
        let time = editorTime(forX: point.x)
        guard let location = timeline.location(at: time) else { return }
        let edgeHit = edgeHit(at: point)
        let targetClipID = edgeHit?.clipID ?? location.segmentID

        if selectedClipID != targetClipID {
            selectedClipID = targetClipID
            selectionDidChange?(targetClipID)
        }

        dragStartPoint = point
        dragStartTimeline = timeline
        if let hit = edgeHit,
           let clip = timeline.segments.first(where: { $0.id == hit.clipID }) {
            dragTarget = .trim(clipID: hit.clipID, edge: hit.edge)
            dragStartClip = clip
        } else {
            dragTarget = .scrub
            playheadTime = time
            playheadDidChange?(time)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragTarget else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch dragTarget {
        case .scrub:
            let time = editorTime(forX: point.x)
            playheadTime = time
            playheadDidChange?(time)
        case .trim(let clipID, let edge):
            updateTrim(clipID: clipID, edge: edge, point: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .trim(let clipID, _) = dragTarget,
           let original = dragStartClip,
           let replacement = timeline.segments.first(where: { $0.id == clipID }),
           replacement != original {
            trimDidCommit?(replacement)
        }

        dragTarget = nil
        dragStartPoint = nil
        dragStartTimeline = nil
        dragStartClip = nil
        updateHover(with: event, forceCallback: true)
        needsDisplay = true
    }

    /// ⌘-scroll zooms around the pointer; a plain scroll is left to the
    /// enclosing scroll view so two-finger swipes still pan the timeline.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), zoomRequested != nil else {
            super.scrollWheel(with: event)
            return
        }
        let rawDelta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 16
        guard abs(rawDelta) > 0.001 else { return }
        let factor = pow(2, Double(rawDelta / Metrics.zoomScrollPointsPerDoubling))
        zoomRequested?(factor, anchorTime(for: event))
    }

    override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else { return }
        zoomRequested?(1 + Double(event.magnification), anchorTime(for: event))
    }

    private func anchorTime(for event: NSEvent) -> TimeInterval {
        editorTime(forX: convert(event.locationInWindow, from: nil).x)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased()

        if modifiers.isEmpty, characters == "c", let hoverTime, hoveredClipID != nil {
            splitRequested?(hoverTime)
            return
        }
        if modifiers.isEmpty, characters == "s" {
            splitRequested?(playheadTime)
            return
        }
        if modifiers.subtracting([.shift, .numericPad, .function]).isEmpty,
           event.keyCode == 123 || event.keyCode == 124 {
            let magnitude = modifiers.contains(.shift) ? Metrics.coarseStep : Metrics.frameStep
            stepRequested?(event.keyCode == 123 ? -magnitude : magnitude)
            return
        }
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            deleteRequested?()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard timelineRect.contains(point), timeline.duration > 0 else { return nil }
        let time = editorTime(forX: point.x)
        guard let location = timeline.location(at: time) else { return nil }

        contextTime = time
        contextClipID = location.segmentID
        selectedClipID = location.segmentID
        selectionDidChange?(location.segmentID)

        let menu = NSMenu()
        let split = NSMenuItem(
            title: "Split Clip Here",
            action: #selector(splitFromContextMenu),
            keyEquivalent: ""
        )
        split.target = self
        split.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
        menu.addItem(split)

        menu.addItem(.separator())

        let currentSpeed = timeline.segments.first { $0.id == location.segmentID }?.speed ?? 1
        let speedMenu = NSMenu()
        for preset in RecordingClipSegment.speedPresets {
            let item = NSMenuItem(
                title: preset == 1 ? "Normal (1×)" : RecordingClipSegment.speedTitle(preset),
                action: #selector(speedFromContextMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset
            item.state = abs(preset - currentSpeed) < 0.001 ? .on : .off
            speedMenu.addItem(item)
            if preset == 1 {
                speedMenu.addItem(.separator())
            }
        }
        let speed = NSMenuItem(
            title: currentSpeed == 1 ? "Speed" : "Speed (\(RecordingClipSegment.speedTitle(currentSpeed)))",
            action: nil,
            keyEquivalent: ""
        )
        speed.image = NSImage(systemSymbolName: "hare", accessibilityDescription: nil)
        speed.submenu = speedMenu
        menu.addItem(speed)

        menu.addItem(.separator())

        let delete = NSMenuItem(
            title: "Delete Clip",
            action: #selector(deleteFromContextMenu),
            keyEquivalent: ""
        )
        delete.target = self
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        delete.isEnabled = timeline.segments.count > 1
        menu.addItem(delete)
        return menu
    }

    @objc private func speedFromContextMenu(_ sender: NSMenuItem) {
        guard let contextClipID, let speed = sender.representedObject as? Double else { return }
        speedRequested?(contextClipID, speed)
    }

    @objc private func splitFromContextMenu() {
        guard let contextTime else { return }
        splitRequested?(contextTime)
    }

    @objc private func deleteFromContextMenu() {
        guard let contextClipID else { return }
        if selectedClipID != contextClipID {
            selectedClipID = contextClipID
            selectionDidChange?(contextClipID)
        }
        deleteRequested?()
    }

    private var timelineRect: CGRect {
        bounds.insetBy(dx: 0.5, dy: 0.5)
    }

    private func updateHover(with event: NSEvent, forceCallback: Bool) {
        guard dragTarget == nil, timeline.duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard timelineRect.contains(point) else {
            clearHover()
            return
        }

        let time = editorTime(forX: point.x)
        hoverTime = time
        hoveredClipID = timeline.location(at: time)?.segmentID
        hoveredEdge = edgeHit(at: point)

        if forceCallback || event.timestamp - lastHoverCallbackTimestamp >= 1.0 / 60.0 {
            lastHoverCallbackTimestamp = event.timestamp
            hoverTimeDidChange?(time)
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func clearHover() {
        guard hoverTime != nil || hoveredClipID != nil || hoveredEdge != nil else { return }
        hoverTime = nil
        hoveredClipID = nil
        hoveredEdge = nil
        hoverTimeDidChange?(nil)
        needsDisplay = true
    }

    private func updateTrim(clipID: UUID, edge: Edge, point: CGPoint) {
        guard let dragStartPoint,
              let startTimeline = dragStartTimeline,
              let original = dragStartClip,
              let index = startTimeline.segments.firstIndex(where: { $0.id == clipID }) else {
            return
        }

        // The drag distance is measured against the timeline's editor-space
        // width, but sourceStart/sourceEnd are source-space - a clip playing
        // at 2x covers twice as many source seconds per dragged editor
        // second, so the delta must be rescaled by the clip's own speed.
        let editorDelta = Double((point.x - dragStartPoint.x) / max(timelineRect.width, 1))
            * startTimeline.duration
        let delta = editorDelta * original.speed
        let previousEnd = index > 0 ? startTimeline.segments[index - 1].sourceEnd : 0
        let nextStart = index + 1 < startTimeline.segments.count
            ? startTimeline.segments[index + 1].sourceStart
            : sourceDuration
        var replacement = original

        switch edge {
        case .leading:
            replacement.sourceStart = min(
                max(original.sourceStart + delta, previousEnd),
                original.sourceEnd - RecordingClipSegment.minimumDuration
            )
        case .trailing:
            replacement.sourceEnd = max(
                original.sourceStart + RecordingClipSegment.minimumDuration,
                min(original.sourceEnd + delta, nextStart)
            )
        }
        timeline = startTimeline.replacing(replacement)
    }

    private func edgeHit(at point: CGPoint) -> (clipID: UUID, edge: Edge)? {
        let candidates = timeline.segments.flatMap { clip -> [(UUID, Edge, CGFloat)] in
            guard let rect = clipRect(for: clip.id) else { return [] }
            return [
                (clip.id, .leading, abs(point.x - rect.minX)),
                (clip.id, .trailing, abs(point.x - rect.maxX))
            ]
        }
        .filter { $0.2 <= Metrics.handleHitWidth }
        .sorted { lhs, rhs in
            let lhsIsSelected = lhs.0 == selectedClipID
            let rhsIsSelected = rhs.0 == selectedClipID
            if lhsIsSelected != rhsIsSelected {
                return lhsIsSelected
            }
            return lhs.2 < rhs.2
        }

        guard let closest = candidates.first else { return nil }
        return (closest.0, closest.1)
    }

    private func clipRect(for clipID: UUID) -> CGRect? {
        guard let index = timeline.segments.firstIndex(where: { $0.id == clipID }),
              let range = timeline.editorRange(for: clipID),
              timeline.duration > 0 else { return nil }
        let rawMinX = xPosition(for: range.lowerBound)
        let rawMaxX = xPosition(for: range.upperBound)
        let leadingInset = index == 0
            ? Metrics.trackInset
            : Metrics.splitGap / 2
        let trailingInset = index == timeline.segments.count - 1
            ? Metrics.trackInset
            : Metrics.splitGap / 2
        let minX = rawMinX + leadingInset
        let maxX = rawMaxX - trailingInset
        let height = timelineRect.height - Metrics.trackInset * 2
        guard minX.isFinite, maxX.isFinite, height > 0 else { return nil }
        return CGRect(
            x: minX,
            y: timelineRect.minY + Metrics.trackInset,
            width: max(1, maxX - minX),
            height: height
        )
    }

    private func xPosition(for editorTime: TimeInterval) -> CGFloat {
        guard timeline.duration > 0 else { return timelineRect.minX }
        let fraction = min(max(editorTime / timeline.duration, 0), 1)
        return timelineRect.minX + CGFloat(fraction) * timelineRect.width
    }

    private func editorTime(forX x: CGFloat) -> TimeInterval {
        guard timeline.duration > 0, timelineRect.width > 0 else { return 0 }
        let fraction = min(max((x - timelineRect.minX) / timelineRect.width, 0), 1)
        return Double(fraction) * timeline.duration
    }

    private func drawTrack() {
        NSColor.labelColor.withAlphaComponent(0.055).setFill()
        Self.roundedPath(
            roundedRect: timelineRect,
            xRadius: Metrics.trackRadius,
            yRadius: Metrics.trackRadius
        ).fill()
    }

    private func drawClips(in dirtyRect: CGRect) {
        for clip in timeline.segments {
            guard let rect = clipRect(for: clip.id), rect.intersects(dirtyRect) else { continue }
            NSGraphicsContext.saveGraphicsState()
            Self.roundedPath(
                roundedRect: rect,
                xRadius: clipRadius(for: rect),
                yRadius: clipRadius(for: rect)
            ).addClip()
            drawThumbnails(in: rect, clip: clip, dirtyRect: dirtyRect)
            // Unselected clips sit a little back from the selected one;
            // the clip under the pointer lifts toward it.
            let isSelected = clip.id == selectedClipID
            let isHovered = clip.id == hoveredClipID && dragTarget == nil
            NSColor.black.withAlphaComponent(isSelected ? 0 : isHovered ? 0.06 : 0.16).setFill()
            rect.intersection(dirtyRect).fill()
            NSGraphicsContext.restoreGraphicsState()

            // A hairline inner edge so neighbouring clips and the track read
            // apart even where the thumbnails are dark.
            NSColor.white.withAlphaComponent(isSelected ? 0.0 : 0.10).setStroke()
            let edge = Self.roundedPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: max(0, clipRadius(for: rect) - 0.5),
                yRadius: max(0, clipRadius(for: rect) - 0.5)
            )
            edge.lineWidth = 1
            edge.stroke()
        }
    }

    private func drawThumbnails(in rect: CGRect, clip: RecordingClipSegment, dirtyRect: CGRect) {
        // The striped placeholder stays underneath, so tiles still being
        // sampled read as "loading" rather than as holes in the strip.
        drawPlaceholder(in: rect, dirtyRect: dirtyRect)
        guard let thumbnails, clip.duration > 0, rect.width > 0 else { return }

        // Tiles live on the store's source-time grid rather than on a pixel
        // grid of this rect: that keeps a tile anchored to the same moment
        // while the lane is zoomed or the clip is trimmed, instead of the whole
        // strip re-flowing on every scale change.
        let pointsPerSourceSecond = rect.width / CGFloat(clip.duration)
        guard pointsPerSourceSecond > 0 else { return }
        let grid = thumbnails.grid(
            forTargetSpan: Double(Metrics.thumbnailWidth / pointsPerSourceSecond)
        )
        guard grid.spacing > 0 else { return }

        let visible = rect.intersection(dirtyRect)
        guard !visible.isEmpty else { return }
        let startTime = clip.sourceStart
            + Double((visible.minX - rect.minX) / pointsPerSourceSecond)
        let endTime = clip.sourceStart
            + Double((visible.maxX - rect.minX) / pointsPerSourceSecond)
        let firstIndex = max(0, Int(floor(startTime / grid.spacing)))
        let lastIndex = max(firstIndex, Int(floor(min(endTime, clip.sourceEnd) / grid.spacing)))

        for index in firstIndex...lastIndex {
            let tileStart = max(Double(index) * grid.spacing, clip.sourceStart)
            let tileEnd = min(Double(index + 1) * grid.spacing, clip.sourceEnd)
            guard tileEnd > tileStart,
                  let image = thumbnails.image(in: grid, tileIndex: index) else { continue }
            let minX = rect.minX
                + CGFloat(tileStart - clip.sourceStart) * pointsPerSourceSecond
            let maxX = rect.minX
                + CGFloat(tileEnd - clip.sourceStart) * pointsPerSourceSecond
            draw(image: image, filling: CGRect(
                x: minX,
                y: rect.minY,
                width: ceil(maxX - minX),
                height: rect.height
            ))
        }
    }

    /// Only the tiles the current redraw actually touches. A zoomed lane can
    /// be tens of thousands of points wide, so drawing every tile on every
    /// scroll step would be wasted work.
    private func tileIndices(
        in rect: CGRect,
        tileWidth: CGFloat,
        dirtyRect: CGRect
    ) -> Range<Int> {
        guard tileWidth > 0 else { return 0..<0 }
        let count = max(1, Int((rect.width / tileWidth).rounded()))
        let first = max(0, Int(floor((dirtyRect.minX - rect.minX) / tileWidth)))
        let last = min(count, Int(ceil((dirtyRect.maxX - rect.minX) / tileWidth)) + 1)
        guard first < last else { return 0..<0 }
        return first..<last
    }

    private func drawPlaceholder(in rect: CGRect, dirtyRect: CGRect) {
        let count = max(3, Int(rect.width / 42))
        let width = rect.width / CGFloat(count)
        for index in tileIndices(in: rect, tileWidth: width, dirtyRect: dirtyRect) {
            NSColor.labelColor.withAlphaComponent(0.07 + CGFloat(index % 3) * 0.025).setFill()
            CGRect(
                x: rect.minX + CGFloat(index) * width,
                y: rect.minY,
                width: ceil(width),
                height: rect.height
            ).fill()
        }
    }

    private func draw(image: NSImage, filling rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let imageAspect = image.size.width / image.size.height
        let rectAspect = rect.width / rect.height
        let sourceRect: CGRect
        if imageAspect > rectAspect {
            let width = image.size.height * rectAspect
            sourceRect = CGRect(
                x: (image.size.width - width) / 2,
                y: 0,
                width: width,
                height: image.size.height
            )
        } else {
            let height = image.size.width / rectAspect
            sourceRect = CGRect(
                x: 0,
                y: (image.size.height - height) / 2,
                width: image.size.width,
                height: height
            )
        }
        image.draw(
            in: rect,
            from: sourceRect,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    /// A speed badge on every clip that plays faster than recorded, and the
    /// selected clip's edited length - each only where the clip is wide
    /// enough to carry it without covering the picture.
    private func drawBadges(in dirtyRect: CGRect) {
        for clip in timeline.segments {
            guard let rect = clipRect(for: clip.id), rect.intersects(dirtyRect) else { continue }
            let content = rect.insetBy(dx: Metrics.selectionHandleInset * 2 + 2, dy: 5)
            var leadingX = content.minX

            if abs(clip.speed - 1) > 0.001 {
                let badge = badgeRect(
                    text: RecordingClipSegment.speedTitle(clip.speed),
                    symbol: "hare.fill",
                    origin: CGPoint(x: leadingX, y: content.minY),
                    maxX: content.maxX
                )
                if let badge {
                    drawBadge(badge)
                    leadingX = badge.frame.maxX + 4
                }
            }

            if clip.id == selectedClipID {
                let length = Self.durationText(clip.editorDuration)
                let size = Self.badgeSize(text: length, hasSymbol: false)
                let origin = CGPoint(x: content.maxX - size.width, y: content.maxY - size.height)
                if origin.x >= leadingX {
                    drawBadge(BadgeLayout(
                        frame: CGRect(origin: origin, size: size),
                        text: length,
                        symbol: nil
                    ))
                }
            }
        }
    }

    private struct BadgeLayout {
        let frame: CGRect
        let text: String
        let symbol: String?
    }

    private static let badgeFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let badgeHeight: CGFloat = 16
    private static let badgePadding: CGFloat = 6
    private static let badgeSymbolWidth: CGFloat = 11

    private static func badgeSize(text: String, hasSymbol: Bool) -> CGSize {
        let textWidth = (text as NSString).size(withAttributes: [.font: badgeFont]).width
        let symbolWidth = hasSymbol ? badgeSymbolWidth + 3 : 0
        return CGSize(width: ceil(textWidth + symbolWidth + badgePadding * 2), height: badgeHeight)
    }

    private func badgeRect(text: String, symbol: String?, origin: CGPoint, maxX: CGFloat) -> BadgeLayout? {
        let size = Self.badgeSize(text: text, hasSymbol: symbol != nil)
        guard origin.x + size.width <= maxX else { return nil }
        return BadgeLayout(frame: CGRect(origin: origin, size: size), text: text, symbol: symbol)
    }

    private func drawBadge(_ badge: BadgeLayout) {
        let frame = badge.frame
        NSColor.black.withAlphaComponent(0.62).setFill()
        Self.roundedPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()

        var x = frame.minX + Self.badgePadding
        if let symbol = badge.symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            ) {
            let imageSize = image.size
            let scale = min(Self.badgeSymbolWidth / max(imageSize.width, 1), 10 / max(imageSize.height, 1))
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            image.draw(
                in: CGRect(
                    x: x,
                    y: frame.midY - drawSize.height / 2,
                    width: drawSize.width,
                    height: drawSize.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            x += Self.badgeSymbolWidth + 3
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.badgeFont,
            .foregroundColor: NSColor.white
        ]
        let textSize = (badge.text as NSString).size(withAttributes: attributes)
        (badge.text as NSString).draw(
            at: CGPoint(x: x, y: frame.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let safe = max(0, seconds)
        if safe < 60 {
            return String(format: "%.1fs", safe)
        }
        let total = Int(safe.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Matches the zoom blocks and playhead so the timeline has a single
    /// selection color.
    private var selectionColor: NSColor {
        .controlAccentColor
    }

    /// AppKit raises (and crashes the app) when a rounded rect is built from
    /// non-finite geometry, so degenerate rects draw nothing and radii are
    /// clamped to what the rect can actually hold.
    private static func roundedPath(
        roundedRect rect: CGRect,
        xRadius: CGFloat,
        yRadius: CGFloat
    ) -> NSBezierPath {
        let rect = rect.standardized
        guard !rect.isNull, !rect.isInfinite,
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return NSBezierPath() }
        let limit = min(rect.width, rect.height) / 2
        let clamp = { (radius: CGFloat) in radius.isFinite ? min(max(radius, 0), limit) : 0 }
        return NSBezierPath(roundedRect: rect, xRadius: clamp(xRadius), yRadius: clamp(yRadius))
    }

    private func clipRadius(for rect: CGRect) -> CGFloat {
        min(Metrics.clipRadius, rect.width / 2, rect.height / 2)
    }

    private func selectionGeometry() -> (video: CGRect, outer: CGRect, radius: CGFloat)? {
        guard let selectedClipID,
              let baseRect = clipRect(for: selectedClipID),
              baseRect.width > 1 else { return nil }
        // Kept inside the lane: the first and last clips sit against the
        // enclosing scroll view's clip, which would cut an outset edge off.
        let outerRect = baseRect.insetBy(
            dx: -Metrics.selectionPadding,
            dy: -Metrics.selectionPadding
        ).intersection(bounds)
        return (
            video: baseRect,
            outer: outerRect,
            radius: min(
                clipRadius(for: baseRect) + Metrics.selectionPadding,
                outerRect.width / 2,
                outerRect.height / 2
            )
        )
    }

    private func drawSelectionChrome() {
        guard let geometry = selectionGeometry() else { return }

        selectionColor.setFill()
        Self.roundedPath(
            roundedRect: geometry.outer,
            xRadius: geometry.radius,
            yRadius: geometry.radius
        ).fill()
    }

    private func drawSelectionGrooves() {
        guard let geometry = selectionGeometry() else { return }
        guard geometry.video.width > Metrics.selectionHandleInset * 4 else { return }

        let grooveY = geometry.video.midY - Metrics.selectionHandleGrooveHeight / 2
        let grooveCenters = [
            geometry.video.minX + Metrics.selectionHandleInset,
            geometry.video.maxX - Metrics.selectionHandleInset
        ]

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor.white.withAlphaComponent(0.92).setFill()
        for centerX in grooveCenters {
            let grooveRect = CGRect(
                x: centerX - Metrics.selectionHandleGrooveWidth / 2,
                y: grooveY,
                width: Metrics.selectionHandleGrooveWidth,
                height: Metrics.selectionHandleGrooveHeight
            )
            Self.roundedPath(
                roundedRect: grooveRect,
                xRadius: Metrics.selectionHandleGrooveWidth / 2,
                yRadius: Metrics.selectionHandleGrooveWidth / 2
            ).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
