import CoreGraphics

extension AnnotationEditorModel {
    var canvasPixelSize: CGSize {
        AnnotationBackgroundLayout.make(contentSize: imageSize, settings: backgroundSettings).canvasSize
    }

    var zoomPercent: Int { canvasViewport.zoomPercent }
    var canZoomIn: Bool { canvasViewport.canZoomIn }
    var canZoomOut: Bool { canvasViewport.canZoomOut }

    func resetZoom() { canvasViewport = AnnotationCanvasViewport() }
    func fitCanvas() { canvasViewport.fit() }
    func zoomIn() { canvasViewport.zoom(by: 1.25) }
    func zoomOut() { canvasViewport.zoom(by: 0.8) }

    func setZoomPercent(_ percent: Int) {
        guard let layout = canvasViewport.layout else { return }
        canvasViewport.zoom(to: CGFloat(percent) / (100 * layout.displayScale))
    }

    func zoomBy(_ factor: CGFloat, anchor: CGPoint) {
        canvasViewport.zoom(by: factor, anchor: anchor)
    }

    func panBy(dx: CGFloat, dy: CGFloat) {
        canvasViewport.pan(by: CGSize(width: dx, height: dy))
    }

    func beginCanvasPinch(at anchor: CGPoint, visibleViewport: AnnotationCanvasViewport) {
        // Use precisely the transform supplied to the image and annotation
        // renderer, including a layout update that has not yet been observed.
        var next = visibleViewport
        next.beginPinch(at: anchor)
        canvasViewport = next
    }

    func updateCanvasPinch(factor: CGFloat) { canvasViewport.magnify(to: factor) }
    func endCanvasPinch() {
        guard canvasViewport.isPinching else { return }
        canvasViewport.endPinch()
    }
}
