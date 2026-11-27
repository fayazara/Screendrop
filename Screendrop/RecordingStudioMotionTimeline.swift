//
//  RecordingStudioMotionTimeline.swift
//  Screendrop
//
//  One edited-time motion track for the screen rectangle, its clipping card,
//  and the camera. Resolve destination geometry first, then integrate it;
//  preview, export, and the cursor all use that same sampled transform.
//

import CoreGraphics
import Foundation

nonisolated struct RecordingStudioMotionTimeline: Sendable {
    private struct Sample: Sendable {
        let frame: RecordingCameraLayoutFrame
        let drawRect: CGRect
        let isLayoutSettled: Bool
        let isZoomed: Bool
    }

    private let base: RecordingStudioLayout?
    private let samples: [Sample]
    private let duration: TimeInterval

    static let none = RecordingStudioMotionTimeline(base: nil, samples: [], duration: 0)

    static func build(
        canvasSize: CGSize,
        style: RecordingStudioStyle,
        usesUniformPadding: Bool,
        contentAspect: CGFloat?,
        contentMode: RecordingStudioLayout.ContentMode,
        contentCropRect: CGRect,
        showsCamera: Bool,
        cameraAspect: CGFloat = RecordingCameraLayoutResolver.defaultCameraAspect,
        layoutTimeline: RecordingCameraLayoutTimeline,
        cues: [ZoomCue],
        capture: PointerCaptureFile,
        clipTimeline: RecordingClipTimeline
    ) -> RecordingStudioMotionTimeline {
        let duration = clipTimeline.duration
        guard duration.isFinite, duration > 0, canvasSize.width > 0, canvasSize.height > 0 else { return .none }
        let base = RecordingStudioLayout.make(
            canvasSize: canvasSize,
            style: style,
            usesUniformPadding: usesUniformPadding,
            contentAspect: contentAspect,
            contentMode: contentMode,
            contentCropRect: contentCropRect
        )
        let crop = base.contentCropRect
        let resolver = RecordingCameraLayoutResolver(
            base: base, style: style, showsCamera: showsCamera, cameraAspect: cameraAspect
        )
        // Retain original subject points. Bounds apply to the destination
        // rectangle after camera clearance, never to the subject beforehand.
        let targets = ViewportTimeline.build(
            cues: cues,
            capture: capture,
            clipTimeline: clipTimeline,
            sourceBounds: crop,
            smoothsMotion: false
        ) { time, magnification in
            let layout = base.applying(resolver.frame(
                for: layoutTimeline.layout(at: time),
                zoomProgress: magnification > 1 ? 1 : 0
            ))
            return CGSize(
                width: layout.cardRect.width / layout.contentFillSize.width,
                height: layout.cardRect.height / layout.contentFillSize.height
            )
        }
        let initialFrame = resolver.frame(for: layoutTimeline.initial)
        var layoutSpring = StudioLayoutSpring(initialFrame)
        var drawSpring = StudioRectSpring(cropRect(base.applying(initialFrame).frameRect(for: ViewportFrame(
            magnification: 1,
            anchor: CGPoint(x: crop.midX, y: crop.midY)
        )), crop: crop))
        let dt = 1 / ViewportTimeline.stepRate
        let count = max(2, Int((duration * ViewportTimeline.stepRate).rounded(.up)) + 1)
        var samples: [Sample] = []
        samples.reserveCapacity(count)

        for index in 0..<count {
            let time = min(Double(index) * dt, duration)
            let target = targets.target(at: time) ?? ViewportTarget(
                magnification: 1, point: CGPoint(x: crop.midX, y: crop.midY), boundsBias: 0
            )
            let zoomed = target.magnification > 1.0001
            let cameraLayout = layoutTimeline.layout(at: time)
            let destination = resolver.frame(for: cameraLayout, zoomProgress: zoomed ? 1 : 0)
            let layout = base.applying(destination)
            var draw = layout.frameRect(for: ViewportFrame(
                magnification: target.magnification, anchor: target.point
            ))
            if zoomed {
                // Place the subject in the clearest part of the screen,
                // rather than under the camera that has become an overlay.
                let focus = focusCenter(in: destination)
                let original = CGPoint(
                    x: layout.cardRect.minX + (target.point.x - crop.minX) / crop.width * layout.cardRect.width,
                    y: layout.cardRect.minY + (target.point.y - crop.minY) / crop.height * layout.cardRect.height
                )
                var focused = draw
                focused.origin.x += focus.x - layout.cardRect.midX
                focused.origin.y += focus.y - layout.cardRect.midY
                let bounded = contained(focused, in: layout.cardRect, crop: crop)
                let bias = CGFloat(target.boundsBias)
                draw.origin.x += focus.x + (original.x - focus.x) * bias - layout.cardRect.midX
                draw.origin.y += focus.y + (original.y - focus.y) * bias - layout.cardRect.midY
                // The Edge preference can move an interior subject, but
                // must not undo the reference geometry's source-edge clamp.
                let boundedCrop = cropRect(bounded, crop: crop)
                if abs(boundedCrop.minX - layout.cardRect.minX) < 0.0001
                    || abs(boundedCrop.maxX - layout.cardRect.maxX) < 0.0001 {
                    draw.origin.x = bounded.minX
                }
                if abs(boundedCrop.minY - layout.cardRect.minY) < 0.0001
                    || abs(boundedCrop.maxY - layout.cardRect.maxY) < 0.0001 {
                    draw.origin.y = bounded.minY
                }
            } else if showsCamera, cameraLayout.kind == .split, cameraLayout.screenFit == .fill {
                draw = restingSplitRect(draw, layout: layout, cameraLayout: cameraLayout, anchor: target.point)
            }
            draw = contained(draw, in: destination.screenRect, crop: crop)
            // Spring the selected region's edges. With a manual crop, its
            // origin is fullOrigin + cropOrigin * fullSize; independent
            // clamped springs on those terms do not preserve that relation.
            let drawnCrop = cropRect(draw, crop: crop)
            if targets.snaps(at: time) {
                layoutSpring = StudioLayoutSpring(destination)
                drawSpring = StudioRectSpring(drawnCrop)
            } else if index > 0 {
                layoutSpring.step(toward: destination, dt: dt)
                drawSpring.step(toward: drawnCrop, dt: dt)
            }
            let frame = layoutSpring.frame
            samples.append(Sample(
                frame: frame,
                drawRect: contained(sourceRect(drawSpring.rect, crop: crop), in: frame.screenRect, crop: crop),
                isLayoutSettled: layoutSpring.isSettled(on: destination),
                isZoomed: zoomed
            ))
        }
        return RecordingStudioMotionTimeline(base: base, samples: samples, duration: duration)
    }

    func layoutFrame(at time: TimeInterval, canvasSize: CGSize) -> RecordingCameraLayoutFrame? {
        guard let base, let sample = sample(at: time) else { return nil }
        let sx = canvasSize.width / base.canvasSize.width
        let sy = canvasSize.height / base.canvasSize.height
        func scaled(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
        }
        var frame = sample.frame
        frame.screenRect = scaled(frame.screenRect)
        frame.cameraRect = scaled(frame.cameraRect)
        frame.cameraCornerRadius *= min(sx, sy)
        return frame
    }

    func viewport(at time: TimeInterval) -> ViewportFrame? {
        guard let base, let sample = sample(at: time) else { return nil }
        let layout = base.applying(sample.frame)
        // Derive the viewport from the interpolated draw rectangle, so cursor
        // coordinates also follow the pan during a changing card aspect.
        return ViewportFrame(
            magnification: sample.drawRect.width / layout.contentFillSize.width,
            anchor: CGPoint(
                x: (sample.frame.screenRect.midX - sample.drawRect.minX) / sample.drawRect.width,
                y: (sample.frame.screenRect.midY - sample.drawRect.minY) / sample.drawRect.height
            )
        )
    }

    func isLayoutSettled(at time: TimeInterval) -> Bool { sample(at: time)?.isLayoutSettled ?? false }
    func isZoomed(at time: TimeInterval) -> Bool { sample(at: time)?.isZoomed ?? false }

    private func sample(at time: TimeInterval) -> Sample? {
        guard !samples.isEmpty else { return nil }
        let position = min(max(time, 0), duration) * ViewportTimeline.stepRate
        let index = min(Int(position), samples.count - 1)
        guard index < samples.count - 1 else { return samples[index] }
        let t = CGFloat(position - Double(index))
        let a = samples[index], b = samples[index + 1]
        return Sample(
            frame: RecordingCameraLayoutFrame(
                screenRect: a.frame.screenRect.motionLerp(b.frame.screenRect, t),
                screenOpacity: a.frame.screenOpacity + (b.frame.screenOpacity - a.frame.screenOpacity) * t,
                cameraRect: a.frame.cameraRect.motionLerp(b.frame.cameraRect, t),
                cameraCornerRadius: a.frame.cameraCornerRadius + (b.frame.cameraCornerRadius - a.frame.cameraCornerRadius) * t,
                cameraOpacity: a.frame.cameraOpacity + (b.frame.cameraOpacity - a.frame.cameraOpacity) * t,
                cameraCutout: a.frame.cameraCutout + (b.frame.cameraCutout - a.frame.cameraCutout) * t,
                cameraFloats: a.frame.cameraFloats + (b.frame.cameraFloats - a.frame.cameraFloats) * t
            ),
            drawRect: a.drawRect.motionLerp(b.drawRect, t),
            isLayoutSettled: a.isLayoutSettled && b.isLayoutSettled,
            isZoomed: a.isZoomed
        )
    }

    /// Clamp the selected source region over the card, with a uniform scale.
    /// Bounding the resolved rectangle also handles interpolated card sizes.
    private static func contained(_ requested: CGRect, in card: CGRect, crop: CGRect) -> CGRect {
        let scale = max(1, card.width / (requested.width * crop.width), card.height / (requested.height * crop.height))
        let width = requested.width * scale, height = requested.height * scale
        return CGRect(
            x: min(max(requested.minX, card.maxX - crop.maxX * width), card.minX - crop.minX * width),
            y: min(max(requested.minY, card.maxY - crop.maxY * height), card.minY - crop.minY * height),
            width: width, height: height
        )
    }

    private static func cropRect(_ source: CGRect, crop: CGRect) -> CGRect {
        CGRect(x: source.minX + crop.minX * source.width, y: source.minY + crop.minY * source.height,
               width: crop.width * source.width, height: crop.height * source.height)
    }

    private static func sourceRect(_ drawnCrop: CGRect, crop: CGRect) -> CGRect {
        let width = drawnCrop.width / crop.width, height = drawnCrop.height / crop.height
        return CGRect(x: drawnCrop.minX - crop.minX * width, y: drawnCrop.minY - crop.minY * height,
                      width: width, height: height)
    }

    /// Resting split crops align to the screen's side, flipping when the
    /// action needs the other edge. Very narrow crops can frame the middle.
    private static func restingSplitRect(
        _ draw: CGRect, layout: RecordingStudioLayout,
        cameraLayout: RecordingCameraLayout, anchor: CGPoint
    ) -> CGRect {
        let horizontal = layout.canvasSize.width >= layout.canvasSize.height
        let crop = layout.contentCropRect
        let fraction = horizontal ? layout.cardRect.width / draw.width : layout.cardRect.height / draw.height
        let lower = horizontal ? crop.minX : crop.minY
        let upper = horizontal ? crop.maxX : crop.maxY
        let point = horizontal ? anchor.x : anchor.y
        let preferred = cameraLayout.side == .trailing ? lower + fraction / 2 : upper - fraction / 2
        let opposite = cameraLayout.side == .trailing ? upper - fraction / 2 : lower + fraction / 2
        let safe = fraction * 0.375
        let center = abs(point - preferred) <= safe ? preferred
            : (abs(point - opposite) <= safe ? opposite : point)
        var result = draw
        if horizontal { result.origin.x = layout.cardRect.midX - center * draw.width }
        else { result.origin.y = layout.cardRect.midY - center * draw.height }
        return result
    }

    private static func focusCenter(in frame: RecordingCameraLayoutFrame) -> CGPoint {
        let card = frame.screenRect
        let center = CGPoint(x: card.midX, y: card.midY)
        guard frame.cameraOpacity > 0.001 else { return center }
        // A cutout's frame is mostly empty background either side of the
        // person, who stands in its middle.
        let occupied = frame.cameraRect.insetBy(dx: frame.cameraRect.width * 0.2 * frame.cameraCutout, dy: 0)
        let camera = card.intersection(occupied)
        guard !camera.isNull, camera.width > 0, camera.height > 0 else { return center }
        let regions = [
            CGRect(x: card.minX, y: card.minY, width: camera.minX - card.minX, height: card.height),
            CGRect(x: camera.maxX, y: card.minY, width: card.maxX - camera.maxX, height: card.height),
            CGRect(x: card.minX, y: card.minY, width: card.width, height: camera.minY - card.minY),
            CGRect(x: card.minX, y: camera.maxY, width: card.width, height: card.maxY - camera.maxY)
        ]
        let candidates = ([center] + regions.filter { $0.width > 0 && $0.height > 0 }.map {
            CGPoint(x: $0.midX, y: $0.midY)
        }).filter {
            !($0.x >= camera.minX && $0.x <= camera.maxX && $0.y >= camera.minY && $0.y <= camera.maxY)
        }
        func clearance(_ point: CGPoint) -> CGFloat {
            var left = point.x - card.minX, right = card.maxX - point.x
            var top = point.y - card.minY, bottom = card.maxY - point.y
            if point.y > camera.minY, point.y < camera.maxY {
                if point.x < camera.minX { right = min(right, camera.minX - point.x) }
                if point.x > camera.maxX { left = min(left, point.x - camera.maxX) }
            }
            if point.x > camera.minX, point.x < camera.maxX {
                if point.y < camera.minY { bottom = min(bottom, camera.minY - point.y) }
                if point.y > camera.maxY { top = min(top, point.y - camera.maxY) }
            }
            return min(left, right, top, bottom)
        }
        return candidates.max { a, b in
            let delta = clearance(a) - clearance(b)
            if abs(delta) > 0.000000001 { return delta < 0 }
            return hypot(a.x - center.x, a.y - center.y) > hypot(b.x - center.x, b.y - center.y)
        } ?? center
    }
}

nonisolated private struct StudioRectSpring {
    private var x: DampedSpring
    private var y: DampedSpring
    private var width: DampedSpring
    private var height: DampedSpring

    init(_ rect: CGRect) {
        x = DampedSpring(position: rect.minX)
        y = DampedSpring(position: rect.minY)
        width = DampedSpring(position: rect.width)
        height = DampedSpring(position: rect.height)
    }

    var rect: CGRect { CGRect(x: x.position, y: y.position, width: width.position, height: height.position) }

    mutating func step(toward rect: CGRect, dt: Double) {
        x.motionStep(toward: rect.minX, dt: dt)
        y.motionStep(toward: rect.minY, dt: dt)
        width.motionStep(toward: rect.width, dt: dt)
        height.motionStep(toward: rect.height, dt: dt)
    }

    func isSettled(on rect: CGRect) -> Bool {
        x.isSettled(on: rect.minX) && y.isSettled(on: rect.minY)
            && width.isSettled(on: rect.width) && height.isSettled(on: rect.height)
    }
}

nonisolated private struct StudioLayoutSpring {
    private var screen: StudioRectSpring
    private var camera: StudioRectSpring
    private var radius: DampedSpring
    private var screenOpacity: DampedSpring
    private var cameraOpacity: DampedSpring
    private var cameraCutout: DampedSpring
    private var cameraFloats: DampedSpring

    init(_ frame: RecordingCameraLayoutFrame) {
        screen = StudioRectSpring(frame.screenRect)
        camera = StudioRectSpring(frame.cameraRect)
        radius = DampedSpring(position: frame.cameraCornerRadius)
        screenOpacity = DampedSpring(position: frame.screenOpacity)
        cameraOpacity = DampedSpring(position: frame.cameraOpacity)
        cameraCutout = DampedSpring(position: frame.cameraCutout)
        cameraFloats = DampedSpring(position: frame.cameraFloats)
    }

    var frame: RecordingCameraLayoutFrame {
        RecordingCameraLayoutFrame(
            screenRect: screen.rect, screenOpacity: screenOpacity.position,
            cameraRect: camera.rect, cameraCornerRadius: radius.position, cameraOpacity: cameraOpacity.position,
            cameraCutout: min(max(cameraCutout.position, 0), 1),
            cameraFloats: min(max(cameraFloats.position, 0), 1)
        )
    }

    mutating func step(toward frame: RecordingCameraLayoutFrame, dt: Double) {
        screen.step(toward: frame.screenRect, dt: dt)
        camera.step(toward: frame.cameraRect, dt: dt)
        radius.motionStep(toward: frame.cameraCornerRadius, dt: dt)
        screenOpacity.motionStep(toward: frame.screenOpacity, dt: dt)
        cameraOpacity.motionStep(toward: frame.cameraOpacity, dt: dt)
        cameraCutout.motionStep(toward: frame.cameraCutout, dt: dt)
        cameraFloats.motionStep(toward: frame.cameraFloats, dt: dt)
    }

    func isSettled(on frame: RecordingCameraLayoutFrame) -> Bool {
        screen.isSettled(on: frame.screenRect) && camera.isSettled(on: frame.cameraRect)
            && radius.isSettled(on: frame.cameraCornerRadius)
            && screenOpacity.isSettled(on: frame.screenOpacity) && cameraOpacity.isSettled(on: frame.cameraOpacity)
            && cameraCutout.isSettled(on: frame.cameraCutout)
            && cameraFloats.isSettled(on: frame.cameraFloats)
    }
}

private extension DampedSpring {
    mutating func motionStep(toward target: Double, dt: Double) {
        step(toward: target, using: ViewportTimeline.motionProfile, dt: dt)
        if isSettled(on: target) { snap(to: target) }
    }

    func isSettled(on target: Double) -> Bool {
        abs(position - target) < 0.0001 && abs(velocity) < 0.0001
    }
}

private extension CGRect {
    nonisolated func motionLerp(_ other: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: minX + (other.minX - minX) * t, y: minY + (other.minY - minY) * t,
               width: width + (other.width - width) * t, height: height + (other.height - height) * t)
    }
}
