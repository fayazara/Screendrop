//
//  RecordingAreaGeometry.swift
//  Screendrop
//
//  The math behind the area recording selection: drawing it, resizing it by
//  a handle, reshaping it to a ratio, and keeping it on its screen. Pure
//  functions over global AppKit rects (bottom-left origin, y up), so "top"
//  is maxY.
//

import CoreGraphics

/// The eight grips around a selection. Corners resize both sides; edges
/// resize one, or both about the edge's centre line while a ratio is locked.
nonisolated enum RecordingAreaHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    /// Which way the handle pushes along each axis: -1 toward minX/minY,
    /// 1 toward maxX/maxY, 0 for an axis it doesn't move.
    var direction: (x: CGFloat, y: CGFloat) {
        switch self {
        case .topLeft: (-1, 1)
        case .top: (0, 1)
        case .topRight: (1, 1)
        case .left: (-1, 0)
        case .right: (1, 0)
        case .bottomLeft: (-1, -1)
        case .bottom: (0, -1)
        case .bottomRight: (1, -1)
        }
    }

    var isCorner: Bool { direction.x != 0 && direction.y != 0 }

    func point(in rect: CGRect) -> CGPoint {
        let (dx, dy) = direction
        return CGPoint(
            x: dx < 0 ? rect.minX : dx > 0 ? rect.maxX : rect.midX,
            y: dy < 0 ? rect.minY : dy > 0 ? rect.maxY : rect.midY
        )
    }
}

nonisolated enum RecordingAreaGeometry {
    /// Smaller than this and there's nothing worth recording - it's a stray
    /// click, not a selection.
    static let minimumSide: CGFloat = 16

    /// A selection dragged out from `anchor` to `point`. With a ratio, the
    /// axis the pointer has travelled further along leads, so the rectangle
    /// always reaches the pointer. From the centre (Option), `anchor` is the
    /// middle rather than a corner.
    static func drawn(
        from anchor: CGPoint,
        to point: CGPoint,
        ratio: CGFloat?,
        fromCenter: Bool,
        in bounds: CGRect
    ) -> CGRect {
        let point = clamped(point, to: bounds)
        let reach = fromCenter ? 2 : 1
        var size = CGSize(
            width: abs(point.x - anchor.x) * CGFloat(reach),
            height: abs(point.y - anchor.y) * CGFloat(reach)
        )
        if let ratio {
            size = leading(size, ratio: ratio)
        }

        let rect: CGRect
        if fromCenter {
            rect = CGRect(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2,
                          width: size.width, height: size.height)
        } else {
            rect = CGRect(
                x: point.x >= anchor.x ? anchor.x : anchor.x - size.width,
                y: point.y >= anchor.y ? anchor.y : anchor.y - size.height,
                width: size.width,
                height: size.height
            )
        }
        return fit(rect, scalingAbout: anchor, in: bounds)
    }

    /// `rect` with `handle` dragged to `point`. The side opposite the handle
    /// stays put; it never folds over, stopping at the minimum size instead.
    static func resized(
        _ rect: CGRect,
        handle: RecordingAreaHandle,
        to point: CGPoint,
        ratio: CGFloat?,
        in bounds: CGRect
    ) -> CGRect {
        let point = clamped(point, to: bounds)
        let (dx, dy) = handle.direction
        let anchor = CGPoint(
            x: dx > 0 ? rect.minX : dx < 0 ? rect.maxX : rect.midX,
            y: dy > 0 ? rect.minY : dy < 0 ? rect.maxY : rect.midY
        )

        var size = CGSize(
            width: dx != 0 ? max(minimumSide, (point.x - anchor.x) * dx) : rect.width,
            height: dy != 0 ? max(minimumSide, (point.y - anchor.y) * dy) : rect.height
        )
        if let ratio {
            if handle.isCorner {
                size = leading(size, ratio: ratio)
            } else if dx != 0 {
                size.height = size.width / ratio
            } else {
                size.width = size.height * ratio
            }
            size = atLeastMinimum(size, ratio: ratio)
        }

        let resized = CGRect(
            x: dx > 0 ? anchor.x : dx < 0 ? anchor.x - size.width : anchor.x - size.width / 2,
            y: dy > 0 ? anchor.y : dy < 0 ? anchor.y - size.height : anchor.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        // Free resizing can't leave the screen - the pointer was clamped -
        // but a locked edge grows the other axis too, which can.
        return ratio == nil ? resized.intersection(bounds) : fit(resized, scalingAbout: anchor, in: bounds)
    }

    /// The selection re-cut to `ratio` around its own centre, keeping its
    /// area, so picking a ratio changes the shape and not how much of the
    /// screen is taken.
    static func reshaped(_ rect: CGRect, to ratio: CGFloat, in bounds: CGRect) -> CGRect {
        let area = rect.width * rect.height
        let size = atLeastMinimum(CGSize(width: (area * ratio).squareRoot(), height: (area / ratio).squareRoot()), ratio: ratio)
        return placed(size, around: CGPoint(x: rect.midX, y: rect.midY), in: bounds)
    }

    /// A rectangle of `size` centred on `center`, shrunk (keeping its shape)
    /// if the screen can't hold it and slid back onto the screen if it hangs
    /// off an edge.
    static func placed(_ size: CGSize, around center: CGPoint, in bounds: CGRect) -> CGRect {
        let scale = min(1, bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return moved(
            CGRect(x: center.x - fitted.width / 2, y: center.y - fitted.height / 2,
                   width: fitted.width, height: fitted.height),
            by: .zero,
            in: bounds
        )
    }

    /// `rect` slid by `delta`, stopping at the screen's edges without
    /// changing size.
    static func moved(_ rect: CGRect, by delta: CGSize, in bounds: CGRect) -> CGRect {
        var moved = rect.offsetBy(dx: delta.width, dy: delta.height)
        moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
        moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
        return moved
    }

    /// Aligned to the display's pixel grid, so the size shown is exactly the
    /// size recorded. With a ratio, the height is derived from the snapped
    /// width rather than snapped on its own, which keeps the two in ratio.
    static func snapped(_ rect: CGRect, scale: CGFloat, ratio: CGFloat?, in bounds: CGRect) -> CGRect {
        let scale = max(scale, 1)
        let pixelWidth = max(1, (rect.width * scale).rounded())
        let pixelHeight = ratio.map { max(1, (pixelWidth / $0).rounded()) } ?? max(1, (rect.height * scale).rounded())
        let snapped = CGRect(
            x: (rect.minX * scale).rounded() / scale,
            y: (rect.minY * scale).rounded() / scale,
            width: min(pixelWidth / scale, bounds.width),
            height: min(pixelHeight / scale, bounds.height)
        )
        return moved(snapped, by: .zero, in: bounds)
    }

    static func isLargeEnough(_ rect: CGRect) -> Bool {
        rect.width >= minimumSide && rect.height >= minimumSide
    }

    /// Whether `rect` is already `ratio` to within a pixel, so a restored
    /// selection is only reshaped when it's actually off.
    static func matches(_ rect: CGRect, ratio: CGFloat, scale: CGFloat) -> Bool {
        let height = rect.width / ratio
        return abs(height - rect.height) * max(scale, 1) <= 1
    }

    // MARK: Helpers

    /// The smallest `ratio`-shaped size that still covers `size`, so a
    /// constrained drag keeps the pointer on the selection's edge.
    private static func leading(_ size: CGSize, ratio: CGFloat) -> CGSize {
        let width = max(size.width, size.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    private static func atLeastMinimum(_ size: CGSize, ratio: CGFloat) -> CGSize {
        var size = size
        if size.height < minimumSide {
            size = CGSize(width: minimumSide * ratio, height: minimumSide)
        }
        if size.width < minimumSide {
            size = CGSize(width: minimumSide, height: minimumSide / ratio)
        }
        return size
    }

    /// Scales `rect` toward `anchor` just enough to fit inside `bounds`, so
    /// a ratio-locked selection stops at the screen's edge instead of being
    /// squashed by it.
    private static func fit(_ rect: CGRect, scalingAbout anchor: CGPoint, in bounds: CGRect) -> CGRect {
        let anchor = clamped(anchor, to: bounds)
        var scale: CGFloat = 1
        if rect.minX < bounds.minX, anchor.x - rect.minX > 0 {
            scale = min(scale, (anchor.x - bounds.minX) / (anchor.x - rect.minX))
        }
        if rect.maxX > bounds.maxX, rect.maxX - anchor.x > 0 {
            scale = min(scale, (bounds.maxX - anchor.x) / (rect.maxX - anchor.x))
        }
        if rect.minY < bounds.minY, anchor.y - rect.minY > 0 {
            scale = min(scale, (anchor.y - bounds.minY) / (anchor.y - rect.minY))
        }
        if rect.maxY > bounds.maxY, rect.maxY - anchor.y > 0 {
            scale = min(scale, (bounds.maxY - anchor.y) / (rect.maxY - anchor.y))
        }
        guard scale < 1 else { return rect }
        return CGRect(
            x: anchor.x + (rect.minX - anchor.x) * scale,
            y: anchor.y + (rect.minY - anchor.y) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    private static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}
