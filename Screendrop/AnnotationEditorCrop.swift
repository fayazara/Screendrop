//
//  AnnotationEditorCrop.swift
//  Screendrop
//
//  Crop mode's state and interaction. The model owns hit testing as well as
//  the geometry, so the pointer, a press and the drawn handles all agree on
//  what sits where; the overlay only draws. Pointer positions arrive in
//  viewport points and are mapped to image pixels through the live camera,
//  so zooming or auto-scrolling mid-drag keeps the edge under the pointer.
//

import AppKit

extension AnnotationEditorModel {
    /// Smallest selection edge, in image pixels.
    static let minimumCropPixels: CGFloat = 24

    /// How far a corner's hit zone reaches outside and inside the selection,
    /// in viewport points. It reaches further in than out: the outside can be
    /// cut off by the viewport edge, the inside never is.
    static let cropCornerReachOutside: CGFloat = 10
    static let cropCornerReachInside: CGFloat = 22
    /// The same for an edge's hit zone, which runs the edge's whole length.
    static let cropEdgeReachOutside: CGFloat = 8
    static let cropEdgeReachInside: CGFloat = 10

    /// Auto-scroll starts this close to a viewport edge (points) and reaches
    /// `cropAutoscrollSpeed` points per second at the edge itself.
    private static let cropAutoscrollZone: CGFloat = 36
    private static let cropAutoscrollSpeed: CGFloat = 900

    /// The image in its own pixel space: everything a selection may cover.
    var cropBounds: CGRect { CGRect(origin: .zero, size: imageSize) }

    /// Pixel dimensions of the current crop selection.
    var cropPixelSize: CGSize { cropPixelRect.size }

    var isCropDragging: Bool { cropDrag != nil }

    private var minimumCropSize: CGSize {
        CGSize(
            width: min(Self.minimumCropPixels, imageSize.width),
            height: min(Self.minimumCropPixels, imageSize.height)
        )
    }

    // MARK: Mode

    func beginCropping() {
        guard imageSize != .zero, !isCropping else { return }

        commitTextEditing()
        engine.selectedIds.removeAll()
        cropAspect = .freeform
        cropDrag = nil
        cropPixelRect = cropBounds
        fitCanvas()
        isCropping = true
    }

    func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
        cropDrag = nil
        // The fading box settles on the whole image it leaves showing.
        cropPixelRect = cropBounds
        cropAspect = .freeform
    }

    func toggleCropping() {
        isCropping ? cancelCrop() : beginCropping()
    }

    func resetCrop() {
        guard isCropping else { return }
        if let ratio = cropAspect.pixelRatio(imageSize: imageSize) {
            cropPixelRect = CropGeometry.snapped(CropGeometry.largest(aspect: ratio, in: cropBounds), in: cropBounds)
        } else {
            cropPixelRect = cropBounds
        }
    }

    func setCropAspect(_ aspect: CropAspectRatio) {
        cropAspect = aspect
        guard isCropping, let ratio = aspect.pixelRatio(imageSize: imageSize) else { return }
        cropPixelRect = CropGeometry.snapped(
            CropGeometry.reshaped(cropPixelRect, aspect: ratio, in: cropBounds),
            in: cropBounds
        )
    }

    /// Arrow keys: moves the selection by whole pixels.
    func nudgeCrop(by delta: CGSize) {
        guard isCropping, cropDrag == nil else { return }
        cropPixelRect = CropGeometry.snapped(
            CropGeometry.move(cropPixelRect, by: delta, in: cropBounds),
            in: cropBounds
        )
    }

    // MARK: Geometry on screen

    /// The selection in viewport points, for an image drawn at `imageFrame`.
    func cropViewRect(in imageFrame: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scaleX = imageFrame.width / imageSize.width
        let scaleY = imageFrame.height / imageSize.height
        return CGRect(
            x: imageFrame.minX + cropPixelRect.minX * scaleX,
            y: imageFrame.minY + cropPixelRect.minY * scaleY,
            width: cropPixelRect.width * scaleX,
            height: cropPixelRect.height * scaleY
        )
    }

    /// What a press at `point` (viewport points) grabs: a corner, then an
    /// edge, then the inside of the box; anywhere else starts a new selection.
    func cropTarget(at point: CGPoint) -> CropDragTarget {
        guard let imageFrame = displayedImageFrame else { return .newSelection }
        let box = cropViewRect(in: imageFrame)

        for handle in CropHandle.allCases where handle.isCorner {
            let zone = Self.cropHitZone(
                for: handle, of: box,
                outside: Self.cropCornerReachOutside,
                inside: Self.cropCornerReachInside
            )
            if zone.contains(point) { return .handle(handle) }
        }
        for handle in CropHandle.allCases where !handle.isCorner {
            let zone = Self.cropHitZone(
                for: handle, of: box,
                outside: Self.cropEdgeReachOutside,
                inside: Self.cropEdgeReachInside
            )
            if zone.contains(point) { return .handle(handle) }
        }
        return box.contains(point) ? .move : .newSelection
    }

    /// A handle's hit zone around `box`. Along an axis the handle sits on, it
    /// straddles that edge; along the other, it spans the box. The inside
    /// reach shrinks on a small box so its middle stays free for moving.
    private static func cropHitZone(for handle: CropHandle, of box: CGRect, outside: CGFloat, inside: CGFloat) -> CGRect {
        func span(_ direction: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> ClosedRange<CGFloat> {
            let inward = min(inside, (upper - lower) / 3)
            if direction < 0 { return (lower - outside)...(lower + inward) }
            if direction > 0 { return (upper - inward)...(upper + outside) }
            return lower...upper
        }
        let x = span(handle.xDirection, box.minX, box.maxX)
        let y = span(handle.yDirection, box.minY, box.maxY)
        return CGRect(x: x.lowerBound, y: y.lowerBound, width: x.upperBound - x.lowerBound, height: y.upperBound - y.lowerBound)
    }

    // MARK: Dragging

    func beginCropDrag(at pointer: CGPoint) {
        guard isCropping, let point = cropImagePoint(at: pointer) else { return }
        let target = cropTarget(at: pointer)
        cropDrag = CropDrag(
            target: target,
            startRect: cropPixelRect,
            startPoint: point,
            startPointer: pointer,
            pointer: pointer,
            hasTravelled: target != .newSelection
        )
    }

    func updateCropDrag(to pointer: CGPoint) {
        guard var drag = cropDrag else { return }
        drag.pointer = pointer
        if !drag.hasTravelled {
            drag.hasTravelled = hypot(pointer.x - drag.startPointer.x, pointer.y - drag.startPointer.y) >= 3
        }
        cropDrag = drag
        applyCropDrag()
    }

    func endCropDrag() {
        cropDrag = nil
    }

    /// Scrolls the canvas while a drag holds the pointer near a viewport edge,
    /// then re-applies the drag so the selection keeps following the pointer.
    /// An edge the drag began near only scrolls once the pointer moves further
    /// in, so grabbing a handle at the viewport edge doesn't set it sliding.
    func autoscrollCropDrag(elapsed: TimeInterval) {
        guard let drag = cropDrag, drag.hasTravelled, let layout = canvasViewport.layout else { return }
        let zone = Self.cropAutoscrollZone
        let visible = CGRect(x: 0, y: 0, width: layout.viewportSize.width, height: layout.fitHeight)

        func push(_ depth: CGFloat, startDepth: CGFloat) -> CGFloat {
            let gained = depth - max(startDepth, 0)
            guard depth > 0, gained > 0 else { return 0 }
            let reach = min(gained / zone, 1.5)
            return Self.cropAutoscrollSpeed * reach * reach
        }
        let now = drag.pointer
        let start = drag.startPointer
        let velocity = CGSize(
            width: push(zone - now.x, startDepth: zone - start.x)
                - push(now.x - (visible.maxX - zone), startDepth: start.x - (visible.maxX - zone)),
            height: push(zone - now.y, startDepth: zone - start.y)
                - push(now.y - (visible.maxY - zone), startDepth: start.y - (visible.maxY - zone))
        )
        guard velocity != .zero else { return }

        let before = canvasViewport.frame.origin
        canvasViewport.pan(by: CGSize(width: velocity.width * elapsed, height: velocity.height * elapsed))
        guard canvasViewport.frame.origin != before else { return }
        applyCropDrag()
    }

    private func applyCropDrag() {
        guard let drag = cropDrag, drag.hasTravelled, let point = cropImagePoint(at: drag.pointer) else { return }

        let flags = NSEvent.modifierFlags
        let fromCenter = flags.contains(.option)
        // Shift holds the ratio the drag started with (a square for a new
        // selection) when no preset already locks one.
        let aspect = cropAspect.pixelRatio(imageSize: imageSize) ?? {
            guard flags.contains(.shift) else { return nil }
            if drag.target == .newSelection { return 1 }
            return drag.startRect.height > 0 ? drag.startRect.width / drag.startRect.height : nil
        }()
        let translation = CGSize(width: point.x - drag.startPoint.x, height: point.y - drag.startPoint.y)

        let next: CGRect
        switch drag.target {
        case .handle(let handle):
            next = CropGeometry.resize(
                drag.startRect, handle: handle, by: translation, in: cropBounds,
                aspect: aspect, minimumSize: minimumCropSize, fromCenter: fromCenter
            )
        case .move:
            next = CropGeometry.move(drag.startRect, by: translation, in: cropBounds)
        case .newSelection:
            next = CropGeometry.span(
                from: drag.startPoint, to: point, in: cropBounds,
                aspect: aspect, minimumSize: minimumCropSize, fromCenter: fromCenter
            )
        }
        cropPixelRect = CropGeometry.snapped(next, in: cropBounds)
    }

    /// A viewport point in image pixels, through the camera as it is now.
    private func cropImagePoint(at pointer: CGPoint) -> CGPoint? {
        guard let frame = displayedImageFrame, frame.width > 0, frame.height > 0 else { return nil }
        return CGPoint(
            x: (pointer.x - frame.minX) * imageSize.width / frame.width,
            y: (pointer.y - frame.minY) * imageSize.height / frame.height
        )
    }
}
