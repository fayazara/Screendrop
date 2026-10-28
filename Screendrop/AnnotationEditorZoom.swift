import CoreGraphics

extension AnnotationEditorModel {
    var canvasPixelSize: CGSize {
        AnnotationBackgroundLayout.make(contentSize: imageSize, settings: backgroundSettings).canvasSize
    }

    var zoomPercent: Int { canvasViewport.zoomPercent }
    var canZoomIn: Bool { canvasViewport.canZoomIn }
    var canZoomOut: Bool { canvasViewport.canZoomOut }

    func resetZoom() { canvasViewport = AnnotationCanvasViewport() }

    /// Where the image sits in the viewport right now, in viewport points.
    var displayedImageFrame: CGRect? {
        guard canvasViewport.layout != nil else { return nil }
        return AnnotationBackgroundLayout.make(contentSize: imageSize, settings: backgroundSettings)
            .scaled(to: canvasViewport.frame)
            .imageFrame
    }

    /// Leaving crop mode: shows the current image at `imageRect` under the
    /// layout without the crop handle margin, then asks the canvas to animate
    /// to the fit. A crop thereby grows out of the box it was cut from.
    func revealCanvasLeavingCrop(imageAt imageRect: CGRect?) {
        let background = AnnotationBackgroundLayout.make(contentSize: imageSize, settings: backgroundSettings)
        guard let imageRect, var layout = canvasViewport.layout,
              background.imageRect.width > 0 else {
            resetZoom()
            return
        }
        layout.canvasSize = background.canvasSize
        layout.fitInsets = CGSize(width: layout.fitInsets.width - Self.cropHandleMargin,
                                  height: layout.fitInsets.height - Self.cropHandleMargin)
        layout.overscroll = 0
        let scale = imageRect.width / background.imageRect.width
        canvasViewport.show(CGRect(
            x: imageRect.minX - background.imageRect.minX * scale,
            y: imageRect.minY - background.imageRect.minY * scale,
            width: background.canvasSize.width * scale,
            height: background.canvasSize.height * scale
        ), in: layout)
        canvasRevealID &+= 1
    }
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
