//
//  VideoTrimTimelineView.swift
//  OpenShot
//

import AppKit
import SwiftUI

struct VideoTrimTimelineView: NSViewRepresentable {
    @Binding var selection: VideoTrimSelection
    @Binding var playheadTime: Double
    let duration: Double
    let frames: [NSImage]
    let onSeek: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, playheadTime: $playheadTime, onSeek: onSeek)
    }

    func makeNSView(context: Context) -> VideoTrimTimelineControl {
        let view = VideoTrimTimelineControl()
        view.selectionDidChange = context.coordinator.selectionDidChange
        view.playheadDidChange = context.coordinator.playheadDidChange
        return view
    }

    func updateNSView(_ nsView: VideoTrimTimelineControl, context: Context) {
        nsView.duration = duration
        nsView.frames = frames
        nsView.selection = selection.clamped(to: duration)
        nsView.playheadTime = min(max(playheadTime, nsView.selection.start), nsView.selection.end)
        nsView.needsDisplay = true
    }

    final class Coordinator {
        @Binding private var selection: VideoTrimSelection
        @Binding private var playheadTime: Double
        private let onSeek: (Double) -> Void

        init(
            selection: Binding<VideoTrimSelection>,
            playheadTime: Binding<Double>,
            onSeek: @escaping (Double) -> Void
        ) {
            _selection = selection
            _playheadTime = playheadTime
            self.onSeek = onSeek
        }

        func selectionDidChange(_ newSelection: VideoTrimSelection, previewTime: Double) {
            selection = newSelection
            playheadTime = previewTime
            onSeek(previewTime)
        }

        func playheadDidChange(_ seconds: Double) {
            playheadTime = seconds
            onSeek(seconds)
        }
    }
}

final class VideoTrimTimelineControl: NSView {
    var duration: Double = 0
    var selection = VideoTrimSelection(start: 0, end: 0)
    var playheadTime: Double = 0
    var frames: [NSImage] = []
    var selectionDidChange: ((VideoTrimSelection, Double) -> Void)?
    var playheadDidChange: ((Double) -> Void)?

    private enum DragTarget {
        case startHandle
        case endHandle
        case playhead
    }

    private let handleWidth: CGFloat = 12
    private let handleHitSlop: CGFloat = 14
    private let borderWidth: CGFloat = 4
    private let cornerRadius: CGFloat = 9
    private let minRangeDuration = VideoTrimSelection.minimumDuration
    private let dragActivationDistance: CGFloat = 3
    private var dragTarget: DragTarget?
    private var dragStartPoint: CGPoint?
    private var dragOffsetX: CGFloat = 0
    private var dragDidActivate = false

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        drawBackground(in: rect)
        drawFrames(in: rect)
        drawOutsideDim(in: rect)
        drawPlayhead(in: rect)
        drawSelectionFrame(in: rect)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        dragTarget = hitTarget(at: point)
        dragStartPoint = point
        dragDidActivate = false
        dragOffsetX = 0

        if dragTarget == nil, timelineRect.contains(point) {
            dragTarget = .playhead
        }

        switch dragTarget {
        case .startHandle:
            dragOffsetX = point.x - selectedStartX
            previewHandleFrame(at: selection.start)
        case .endHandle:
            dragOffsetX = point.x - selectedEndX
            previewHandleFrame(at: selection.end)
        case .playhead:
            dragDidActivate = true
            updateDrag(at: point)
        case nil:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if !dragDidActivate {
            guard let dragStartPoint else { return }
            let distance = hypot(point.x - dragStartPoint.x, point.y - dragStartPoint.y)
            guard distance >= dragActivationDistance else { return }
            dragDidActivate = true
        }

        updateDrag(at: point)
    }

    override func mouseUp(with event: NSEvent) {
        dragTarget = nil
        dragStartPoint = nil
        dragOffsetX = 0
        dragDidActivate = false
        needsDisplay = true
    }

    private var timelineRect: CGRect {
        bounds.insetBy(dx: 0.5, dy: 0.5)
    }

    private var frameStripRect: CGRect {
        timelineRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
    }

    private var selectedStartX: CGFloat {
        xPosition(for: selection.start)
    }

    private var selectedEndX: CGFloat {
        xPosition(for: selection.end)
    }

    private var clampedPlayheadX: CGFloat {
        let left = min(selectedStartX + handleWidth + borderWidth, timelineRect.maxX)
        let right = max(selectedEndX - handleWidth - borderWidth, left)
        return min(max(xPosition(for: playheadTime), left), right)
    }

    private func drawBackground(in rect: CGRect) {
        NSColor.black.withAlphaComponent(0.42).setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    private func drawFrames(in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frameStripRect, xRadius: 6, yRadius: 6).addClip()

        if frames.isEmpty {
            drawPlaceholderFrames(in: frameStripRect)
        } else {
            let frameWidth = frameStripRect.width / CGFloat(frames.count)
            for (index, frame) in frames.enumerated() {
                let target = CGRect(
                    x: frameStripRect.minX + CGFloat(index) * frameWidth,
                    y: frameStripRect.minY,
                    width: ceil(frameWidth),
                    height: frameStripRect.height
                )
                draw(image: frame, filling: target)
            }
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawPlaceholderFrames(in rect: CGRect) {
        let count = 18
        let gap: CGFloat = 2
        let itemWidth = (rect.width - CGFloat(count - 1) * gap) / CGFloat(count)

        for index in 0..<count {
            NSColor.white.withAlphaComponent(0.18 + CGFloat(index % 5) * 0.04).setFill()
            NSBezierPath(
                roundedRect: CGRect(
                    x: rect.minX + CGFloat(index) * (itemWidth + gap),
                    y: rect.minY,
                    width: itemWidth,
                    height: rect.height
                ),
                xRadius: 3,
                yRadius: 3
            ).fill()
        }
    }

    private func drawOutsideDim(in rect: CGRect) {
        let left = selectedStartX
        let right = selectedEndX
        NSColor.black.withAlphaComponent(0.34).setFill()
        CGRect(x: rect.minX, y: rect.minY, width: max(left - rect.minX, 0), height: rect.height).fill()
        CGRect(x: right, y: rect.minY, width: max(rect.maxX - right, 0), height: rect.height).fill()
    }

    private func drawPlayhead(in rect: CGRect) {
        guard selection.end > selection.start else { return }
        guard dragTarget != .startHandle, dragTarget != .endHandle else {
            return
        }

        guard playheadTime > selection.start + 0.001, playheadTime < selection.end - 0.001 else {
            return
        }

        let x = clampedPlayheadX
        guard abs(x - selectedStartX) > 1, abs(x - selectedEndX) > 1 else {
            return
        }

        NSColor.systemRed.setFill()
        CGRect(
            x: x - 0.5,
            y: rect.minY + borderWidth,
            width: 1,
            height: rect.height - borderWidth * 2
        ).fill()
    }

    private func drawSelectionFrame(in rect: CGRect) {
        let left = selectedStartX
        let right = selectedEndX
        let selectionRect = CGRect(x: left, y: rect.minY, width: max(right - left, handleWidth * 2), height: rect.height)

        NSColor.systemYellow.setStroke()
        let framePath = NSBezierPath(roundedRect: selectionRect, xRadius: cornerRadius, yRadius: cornerRadius)
        framePath.lineWidth = borderWidth
        framePath.stroke()

        drawHandle(
            rect: CGRect(x: selectionRect.minX, y: selectionRect.minY, width: handleWidth, height: selectionRect.height),
            roundedLeft: true
        )
        drawHandle(
            rect: CGRect(x: selectionRect.maxX - handleWidth, y: selectionRect.minY, width: handleWidth, height: selectionRect.height),
            roundedLeft: false
        )
    }

    private func drawHandle(rect: CGRect, roundedLeft: Bool) {
        NSColor.systemYellow.setFill()
        handlePath(rect: rect, roundedLeft: roundedLeft).fill()

        NSColor.black.withAlphaComponent(0.72).setFill()
        let gripHeight: CGFloat = 18
        let gripY = rect.midY - gripHeight / 2
        let gripCenterX = rect.midX + (roundedLeft ? -1.0 : 1.0)
        for offset in [-2.0, 2.0] {
            NSBezierPath(
                roundedRect: CGRect(x: gripCenterX + offset - 0.65, y: gripY, width: 1.3, height: gripHeight),
                xRadius: 1,
                yRadius: 1
            ).fill()
        }
    }

    private func handlePath(rect: CGRect, roundedLeft: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)

        if roundedLeft {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.line(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.curve(
                to: CGPoint(x: rect.minX, y: rect.minY + radius),
                controlPoint1: CGPoint(x: rect.minX + radius * 0.45, y: rect.minY),
                controlPoint2: CGPoint(x: rect.minX, y: rect.minY + radius * 0.45)
            )
            path.line(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            path.curve(
                to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                controlPoint1: CGPoint(x: rect.minX, y: rect.maxY - radius * 0.45),
                controlPoint2: CGPoint(x: rect.minX + radius * 0.45, y: rect.maxY)
            )
            path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.line(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.curve(
                to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                controlPoint1: CGPoint(x: rect.maxX - radius * 0.45, y: rect.minY),
                controlPoint2: CGPoint(x: rect.maxX, y: rect.minY + radius * 0.45)
            )
            path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.curve(
                to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                controlPoint1: CGPoint(x: rect.maxX, y: rect.maxY - radius * 0.45),
                controlPoint2: CGPoint(x: rect.maxX - radius * 0.45, y: rect.maxY)
            )
            path.line(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        path.close()
        return path
    }

    private func draw(image: NSImage, filling rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else {
            return
        }

        let imageAspect = image.size.width / image.size.height
        let rectAspect = rect.width / rect.height
        let sourceRect: CGRect

        if imageAspect > rectAspect {
            let sourceWidth = image.size.height * rectAspect
            sourceRect = CGRect(
                x: (image.size.width - sourceWidth) / 2,
                y: 0,
                width: sourceWidth,
                height: image.size.height
            )
        } else {
            let sourceHeight = image.size.width / rectAspect
            sourceRect = CGRect(
                x: 0,
                y: (image.size.height - sourceHeight) / 2,
                width: image.size.width,
                height: sourceHeight
            )
        }

        image.draw(
            in: rect,
            from: sourceRect,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func hitTarget(at point: CGPoint) -> DragTarget? {
        guard timelineRect.contains(point), duration > 0 else {
            return nil
        }

        let left = selectedStartX
        let right = selectedEndX
        let playhead = clampedPlayheadX

        if abs(point.x - left) <= handleWidth + handleHitSlop {
            return .startHandle
        }

        if abs(point.x - right) <= handleWidth + handleHitSlop {
            return .endHandle
        }

        if abs(point.x - playhead) <= 10 {
            return .playhead
        }

        return nil
    }

    private func updateDrag(at point: CGPoint) {
        guard let dragTarget, duration > 0 else {
            return
        }

        switch dragTarget {
        case .startHandle:
            let seconds = time(for: point.x - dragOffsetX)
            selection.start = min(max(seconds, 0), selection.end - minRangeDuration)
            playheadTime = selection.start
            selectionDidChange?(selection, selection.start)
        case .endHandle:
            let seconds = time(for: point.x - dragOffsetX)
            selection.end = max(min(seconds, duration), selection.start + minRangeDuration)
            playheadTime = selection.end
            selectionDidChange?(selection, selection.end)
        case .playhead:
            let seconds = time(for: point.x)
            let clamped = min(max(seconds, selection.start), selection.end)
            playheadTime = clamped
            playheadDidChange?(clamped)
        }

        needsDisplay = true
    }

    private func previewHandleFrame(at seconds: Double) {
        playheadTime = seconds
        selectionDidChange?(selection, seconds)
        needsDisplay = true
    }

    private func xPosition(for seconds: Double) -> CGFloat {
        guard duration > 0 else {
            return timelineRect.minX
        }

        let fraction = min(max(seconds / duration, 0), 1)
        return timelineRect.minX + timelineRect.width * CGFloat(fraction)
    }

    private func time(for x: CGFloat) -> Double {
        guard duration > 0 else {
            return 0
        }

        let fraction = min(max((x - timelineRect.minX) / timelineRect.width, 0), 1)
        return Double(fraction) * duration
    }
}
