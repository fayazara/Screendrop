//
//  AnnotationItem.swift
//  Screendrop
//

import AppKit

struct AnnotationItem: Identifiable, Equatable {
    let id: UUID
    var tool: AnnotationTool
    var rect: CGRect
    var points: [CGPoint]
    var swatch: AnnotationSwatch
    var strokeWidth: CGFloat
    var redactionDensity: CGFloat
    var text: String
    var textLineHeight: CGFloat
    var fontName: String
    var isBold: Bool
    var isItalic: Bool
    var isUnderline: Bool
    var textAlignment: NSTextAlignment

    init(
        id: UUID = UUID(),
        tool: AnnotationTool,
        rect: CGRect,
        points: [CGPoint] = [],
        swatch: AnnotationSwatch,
        strokeWidth: CGFloat,
        redactionDensity: CGFloat = 0.55,
        text: String = "",
        textLineHeight: CGFloat = AnnotationTextMetrics.defaultNormalizedLineHeight,
        fontName: String = AnnotationTextMetrics.defaultFontName,
        isBold: Bool = true,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        textAlignment: NSTextAlignment = .left
    ) {
        self.id = id
        self.tool = tool
        self.rect = rect
        self.points = points
        self.swatch = swatch
        self.strokeWidth = strokeWidth
        self.redactionDensity = redactionDensity
        self.text = text
        self.textLineHeight = textLineHeight
        self.fontName = fontName
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.textAlignment = textAlignment
    }

    /// Build the NSFont for this text annotation at the given point size.
    func resolvedFont(size: CGFloat) -> NSFont {
        AnnotationTextMetrics.resolvedFont(
            name: fontName, size: size, bold: isBold, italic: isItalic
        )
    }

    var bounds: CGRect {
        switch tool {
        case .select:
            return rect.standardized

        case .line, .arrow, .freehand:
            let boundsPoints = tool == .arrow ? arrowPoints : points
            guard let first = boundsPoints.first else { return rect.standardized }
            let bounds = boundsPoints.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
                rect.union(CGRect(origin: point, size: .zero))
            }
            return bounds.standardized
        case .rectangle, .filledRectangle, .ellipse, .numberedCircle, .pixelate, .blur, .text:
            return rect.standardized
        }
    }

    var controlPoint: CGPoint? {
        guard tool == .arrow,
              let start = points.first,
              let end = points.last else {
            return nil
        }

        if points.count >= 3 {
            return points[1]
        }

        return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }

    /// The point on the rendered curve that the curve handle is displayed at:
    /// the apex of the quadratic Bezier (the value at t = 0.5). A quadratic
    /// curve only travels halfway towards its control point, so dragging the
    /// raw control point feels half as responsive as the visible bend. By
    /// exposing the apex as the draggable handle, dragging maps 1:1 to the
    /// curve and the handle stays on the line, matching CleanShot.
    var arrowCurveHandle: CGPoint? {
        guard tool == .arrow,
              let start = points.first,
              let end = points.last,
              let control = controlPoint else {
            return nil
        }

        return CGPoint(
            x: 0.25 * start.x + 0.5 * control.x + 0.25 * end.x,
            y: 0.25 * start.y + 0.5 * control.y + 0.25 * end.y
        )
    }

    /// Convert an apex position (where the curve handle is dragged) into the
    /// Bezier control point that produces that apex: control = 2 * apex - mid.
    static func arrowControlPoint(forApex apex: CGPoint, start: CGPoint, end: CGPoint) -> CGPoint {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        return CGPoint(x: 2 * apex.x - mid.x, y: 2 * apex.y - mid.y)
    }

    func isRenderable(minimumSize: CGFloat, allowEmptyText: Bool = false) -> Bool {
        switch tool {
        case .select:
            return false

        case .line:
            guard points.count == 2 else { return false }
            return hypot(points[0].x - points[1].x, points[0].y - points[1].y) >= minimumSize
        case .arrow:
            guard let start = points.first,
                  let end = points.last else {
                return false
            }

            return hypot(start.x - end.x, start.y - end.y) >= minimumSize
        case .freehand:
            guard points.count >= 2 else { return false }
            return pathLength(points) >= minimumSize
        case .rectangle, .filledRectangle, .ellipse, .numberedCircle, .pixelate, .blur:
            return bounds.width >= minimumSize && bounds.height >= minimumSize
        case .text:
            return bounds.width >= minimumSize
                && bounds.height >= minimumSize
                && (allowEmptyText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch tool {
        case .select:
            return false

        case .line:
            guard let start = points.first,
                  let end = points.last else {
                return false
            }

            return distance(from: point, toSegmentFrom: start, to: end) <= tolerance

        case .freehand:
            guard points.count >= 2 else { return false }
            for index in 1..<points.count {
                if distance(from: point, toSegmentFrom: points[index - 1], to: points[index]) <= tolerance {
                    return true
                }
            }
            return false

        case .arrow:
            guard let start = points.first,
                  let controlPoint,
                  let end = points.last else {
                return false
            }

            return distance(from: point, toQuadraticFrom: start, control: controlPoint, to: end) <= tolerance

        case .rectangle, .filledRectangle, .pixelate, .blur, .text:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)

        case .ellipse, .numberedCircle:
            let expandedBounds = bounds.insetBy(dx: -tolerance, dy: -tolerance)
            guard expandedBounds.width > 0, expandedBounds.height > 0 else { return false }

            let center = CGPoint(x: expandedBounds.midX, y: expandedBounds.midY)
            let normalizedX = (point.x - center.x) / (expandedBounds.width / 2)
            let normalizedY = (point.y - center.y) / (expandedBounds.height / 2)
            return normalizedX * normalizedX + normalizedY * normalizedY <= 1
        }
    }

    func offsetBy(_ delta: CGPoint) -> AnnotationItem {
        var item = self
        item.rect = rect.offsetBy(dx: delta.x, dy: delta.y)
        item.points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return item
    }

    func withEndpoint(_ handle: AnnotationResizeHandle, movedTo point: CGPoint) -> AnnotationItem {
        guard tool.usesEndpoints else { return self }

        var item = self
        if item.points.count < 2 {
            let fallback = item.points.first ?? point
            item.points = [fallback, fallback]
        }

        switch handle {
        case .start:
            item.ensureArrowPointStorage()
            item.points[0] = point
        case .control:
            guard item.tool == .arrow else { return self }
            item.ensureArrowPointStorage()
            item.points[1] = point
        case .end:
            item.ensureArrowPointStorage()
            item.points[item.points.count - 1] = point
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return self
        }

        item.rect = item.bounds
        return item
    }

    func resized(to newBounds: CGRect) -> AnnotationItem {
        let oldBounds = bounds.standardized
        guard oldBounds.width > 0, oldBounds.height > 0 else {
            var item = self
            item.rect = newBounds
            return item
        }

        var item = self
        item.rect = newBounds
        item.points = points.map { point in
            CGPoint(
                x: newBounds.minX + ((point.x - oldBounds.minX) / oldBounds.width) * newBounds.width,
                y: newBounds.minY + ((point.y - oldBounds.minY) / oldBounds.height) * newBounds.height
            )
        }
        return item
    }

    /// Remap this annotation from the original image's normalized space into the
    /// space of a cropped image. `crop` is the normalized crop rect relative to
    /// the original image. Stroke width and text size are rescaled so they keep
    /// the same rendered pixel size after the image dimensions change. Returns
    /// `nil` when the annotation falls entirely outside the crop.
    func remappedForCrop(crop: CGRect, oldImageSize: CGSize, newImageSize: CGSize) -> AnnotationItem? {
        guard crop.width > 0, crop.height > 0 else { return nil }

        func remap(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: (point.x - crop.minX) / crop.width,
                y: (point.y - crop.minY) / crop.height
            )
        }

        let standardizedRect = rect.standardized
        var item = self
        item.rect = CGRect(
            x: (standardizedRect.minX - crop.minX) / crop.width,
            y: (standardizedRect.minY - crop.minY) / crop.height,
            width: standardizedRect.width / crop.width,
            height: standardizedRect.height / crop.height
        )
        item.points = points.map(remap)

        let oldMaxEdge = max(oldImageSize.width, oldImageSize.height)
        let newMaxEdge = max(newImageSize.width, newImageSize.height)
        if newMaxEdge > 0 {
            item.strokeWidth = strokeWidth * oldMaxEdge / newMaxEdge
        }
        // textLineHeight is normalized to the image height; the new height is
        // `oldHeight * crop.height`, so divide to preserve the rendered size.
        item.textLineHeight = textLineHeight / crop.height

        guard item.bounds.intersects(CropRectEditor.unit) else { return nil }
        return item
    }

    private var arrowPoints: [CGPoint] {
        guard tool == .arrow,
              let start = points.first,
              let controlPoint,
              let end = points.last else {
            return points
        }

        return [start, controlPoint, end]
    }

    private mutating func ensureArrowPointStorage() {
        guard tool == .arrow,
              points.count == 2,
              let start = points.first,
              let end = points.last else {
            return
        }

        points = [start, CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), end]
    }

    private func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }

        var length: CGFloat = 0
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            length += hypot(current.x - previous.x, current.y - previous.y)
        }
        return length
    }

    private func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let clampedProjection = min(max(projection, 0), 1)
        let closest = CGPoint(
            x: start.x + clampedProjection * dx,
            y: start.y + clampedProjection * dy
        )

        return hypot(point.x - closest.x, point.y - closest.y)
    }

    private func distance(from point: CGPoint, toQuadraticFrom start: CGPoint, control: CGPoint, to end: CGPoint) -> CGFloat {
        var shortestDistance = CGFloat.greatestFiniteMagnitude
        var previous = start

        for step in 1...32 {
            let t = CGFloat(step) / 32
            let current = quadraticPoint(start: start, control: control, end: end, t: t)
            shortestDistance = min(shortestDistance, distance(from: point, toSegmentFrom: previous, to: current))
            previous = current
        }

        return shortestDistance
    }

    private func quadraticPoint(start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
        let first = CGPoint(
            x: start.x + (control.x - start.x) * t,
            y: start.y + (control.y - start.y) * t
        )
        let second = CGPoint(
            x: control.x + (end.x - control.x) * t,
            y: control.y + (end.y - control.y) * t
        )

        return CGPoint(
            x: first.x + (second.x - first.x) * t,
            y: first.y + (second.y - first.y) * t
        )
    }
}
