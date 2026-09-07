import CoreGraphics

/// Editor-only camera. Every layer consumes the same scale and top-left origin;
/// neither rendering nor gesture start resolves a second fit/manual transform.
nonisolated struct AnnotationCanvasViewport {
    struct Layout: Equatable {
        var canvasSize: CGSize
        var viewportSize: CGSize
        var displayScale: CGFloat
        var fitInsets: CGSize

        var isValid: Bool {
            [canvasSize.width, canvasSize.height, viewportSize.width, viewportSize.height,
             displayScale].allSatisfy { $0.isFinite && $0 > 0 }
        }

        var fitScale: CGFloat {
            min(max(1, viewportSize.width - fitInsets.width * 2) / canvasSize.width,
                max(1, viewportSize.height - fitInsets.height * 2) / canvasSize.height,
                scaleLimits.upperBound)
        }

        var scaleLimits: ClosedRange<CGFloat> { (0.1 / displayScale)...(10 / displayScale) }
        var center: CGPoint { CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2) }
    }

    private struct Pinch {
        let anchor: CGPoint
        let canvasPoint: CGPoint
        let limits: ClosedRange<CGFloat>
        var previousFactor: CGFloat = 1
    }

    private(set) var layout: Layout?
    private(set) var scale: CGFloat = 1
    private(set) var origin: CGPoint = .zero
    private(set) var isFitting = true
    private var pinch: Pinch?

    var isPinching: Bool { pinch != nil }
    var frame: CGRect {
        guard let layout else { return .zero }
        return CGRect(origin: origin, size: CGSize(
            width: layout.canvasSize.width * scale,
            height: layout.canvasSize.height * scale
        ))
    }

    var zoomPercent: Int {
        guard let layout else { return 100 }
        return Int((scale * layout.displayScale * 100).rounded())
    }

    var canZoomIn: Bool { layout.map { scale < $0.scaleLimits.upperBound } ?? false }
    var canZoomOut: Bool { layout.map { scale > $0.scaleLimits.lowerBound } ?? false }

    /// Idempotent: a redraw during a gesture cannot alter its starting scale.
    /// Manual views preserve the canvas point at the viewport center on resize.
    mutating func configure(_ newLayout: Layout) {
        guard newLayout.isValid, newLayout != layout else { return }
        let oldLayout = layout
        let oldCenterPoint = oldLayout.map { canvasPoint(at: $0.center) }
        layout = newLayout
        pinch = nil
        if isFitting || oldLayout == nil {
            fit()
        } else if let oldLayout, let oldCenterPoint {
            scale = min(scale, newLayout.scaleLimits.upperBound)
            let relativeCenter = CGPoint(x: oldCenterPoint.x / oldLayout.canvasSize.width,
                                         y: oldCenterPoint.y / oldLayout.canvasSize.height)
            origin = CGPoint(
                x: newLayout.center.x - relativeCenter.x * newLayout.canvasSize.width * scale,
                y: newLayout.center.y - relativeCenter.y * newLayout.canvasSize.height * scale
            )
            constrainToCanvasEdges()
        }
    }

    mutating func fit() {
        pinch = nil
        isFitting = true
        guard let layout else { return }
        scale = layout.fitScale
        origin = CGPoint(x: (layout.viewportSize.width - layout.canvasSize.width * scale) / 2,
                         y: (layout.viewportSize.height - layout.canvasSize.height * scale) / 2)
    }

    mutating func zoom(to requestedScale: CGFloat, anchor requestedAnchor: CGPoint? = nil) {
        guard let layout, requestedScale.isFinite, requestedScale > 0 else { return }
        pinch = nil
        let nextScale = directionalClamp(requestedScale, limits: layout.scaleLimits)
        guard nextScale != scale else { return }
        let anchor = visibleAnchor(requestedAnchor ?? layout.center)
        let point = canvasPoint(at: anchor)
        apply(scale: nextScale, keeping: point, at: anchor)
    }

    mutating func zoom(by factor: CGFloat, anchor: CGPoint? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        zoom(to: scale * factor, anchor: anchor)
    }

    /// Begin captures only an anchor. It never changes the displayed transform.
    mutating func beginPinch(at requestedAnchor: CGPoint) {
        guard let layout else { return }
        let anchor = visibleAnchor(requestedAnchor)
        pinch = Pinch(
            anchor: anchor,
            canvasPoint: canvasPoint(at: anchor),
            limits: min(scale, layout.scaleLimits.lowerBound)...max(scale, layout.scaleLimits.upperBound)
        )
    }

    /// NSMagnificationGestureRecognizer provides a cumulative factor (1 + value).
    /// Ratios let reversing at a zoom limit respond immediately. The target
    /// stays fixed for the whole gesture; canvas edges may constrain the view.
    mutating func magnify(to factor: CGFloat) {
        guard var gesture = pinch, factor.isFinite, factor > 0 else { return }
        let ratio = factor / gesture.previousFactor
        gesture.previousFactor = factor
        pinch = gesture
        guard ratio.isFinite, ratio > 0, ratio != 1 else { return }
        let nextScale = min(max(scale * ratio, gesture.limits.lowerBound), gesture.limits.upperBound)
        guard nextScale != scale else { return }
        apply(scale: nextScale, keeping: gesture.canvasPoint, at: gesture.anchor)
    }

    mutating func endPinch() { pinch = nil }

    mutating func pan(by delta: CGSize) {
        guard layout != nil, pinch == nil, delta.width.isFinite, delta.height.isFinite,
              delta != .zero else { return }
        origin.x += delta.width
        origin.y += delta.height
        constrainToCanvasEdges()
        isFitting = false
    }

    func canvasPoint(at point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }

    private mutating func apply(scale newScale: CGFloat, keeping point: CGPoint, at anchor: CGPoint) {
        scale = newScale
        origin = CGPoint(x: anchor.x - point.x * scale, y: anchor.y - point.y * scale)
        isFitting = false
        // Keep the gesture's original target even if this frame hits an edge.
        // Later frames can return to it without accumulating clamping drift.
        constrainToCanvasEdges()
    }

    private func directionalClamp(_ proposed: CGFloat, limits: ClosedRange<CGFloat>) -> CGFloat {
        if proposed > scale { return max(scale, min(proposed, limits.upperBound)) }
        return min(scale, max(proposed, limits.lowerBound))
    }

    private func visibleAnchor(_ requested: CGPoint) -> CGPoint {
        guard let layout else { return .zero }
        let visible = frame.intersection(CGRect(origin: .zero, size: layout.viewportSize))
        guard !visible.isNull, !visible.isEmpty else { return layout.center }
        let point = requested.x.isFinite && requested.y.isFinite ? requested : layout.center
        return CGPoint(x: min(max(point.x, visible.minX), visible.maxX),
                       y: min(max(point.y, visible.minY), visible.maxY))
    }

    /// An overflowing axis stops flush at either canvas edge. A fitting axis
    /// stays centered and cannot be scrolled into empty workspace.
    private mutating func constrainToCanvasEdges() {
        guard let layout else { return }
        let size = frame.size
        origin.x = size.width <= layout.viewportSize.width
            ? (layout.viewportSize.width - size.width) / 2
            : min(max(origin.x, layout.viewportSize.width - size.width), 0)
        origin.y = size.height <= layout.viewportSize.height
            ? (layout.viewportSize.height - size.height) / 2
            : min(max(origin.y, layout.viewportSize.height - size.height), 0)
    }
}
