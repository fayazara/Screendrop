import CoreGraphics

// Compile the actual camera used by the editor, without launching the app:
// xcrun swiftc -module-cache-path /tmp/screendrop-viewport-module-cache \
//   Screendrop/AnnotationCanvasViewport.swift scripts/check-editor-viewport.swift \
//   -o /tmp/screendrop-viewport-check && /tmp/screendrop-viewport-check
@main
struct EditorViewportChecks {
    static var checks = 0

    static func near(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        checks += 1
        precondition(actual.isFinite && abs(actual - expected) < 0.00001,
                     "\(message): expected \(expected), got \(actual)")
    }

    static func sameFrame(_ actual: CGRect, _ expected: CGRect, _ message: String) {
        near(actual.minX, expected.minX, message)
        near(actual.minY, expected.minY, message)
        near(actual.width, expected.width, message)
        near(actual.height, expected.height, message)
    }

    static func assertAnchor(_ camera: AnnotationCanvasViewport, point: CGPoint, anchor: CGPoint) {
        near(camera.origin.x + point.x * camera.scale, anchor.x, "Pointer anchor X")
        near(camera.origin.y + point.y * camera.scale, anchor.y, "Pointer anchor Y")
    }

    static func assertEdges(_ camera: AnnotationCanvasViewport) {
        let viewport = camera.layout!.viewportSize
        let frame = camera.frame
        if frame.width <= viewport.width {
            near(frame.midX, viewport.width / 2, "Fitting width stays centered")
        } else {
            precondition(frame.minX <= 0.00001 && frame.maxX >= viewport.width - 0.00001,
                         "Horizontal panning exposed workspace past an image edge")
            checks += 1
        }
        if frame.height <= viewport.height {
            near(frame.midY, viewport.height / 2, "Fitting height stays centered")
        } else {
            precondition(frame.minY <= 0.00001 && frame.maxY >= viewport.height - 0.00001,
                         "Vertical panning exposed workspace past an image edge")
            checks += 1
        }
    }

    static func main() {
        let layout = AnnotationCanvasViewport.Layout(
            canvasSize: CGSize(width: 2000, height: 1000),
            viewportSize: CGSize(width: 1068, height: 656),
            displayScale: 2, fitInsets: CGSize(width: 34, height: 28)
        )
        var camera = AnnotationCanvasViewport()
        camera.configure(layout)
        near(camera.scale, 0.5, "Fit scale")
        sameFrame(camera.frame, CGRect(x: 34, y: 78, width: 1000, height: 500), "Fit margins")

        // Real recognizer semantics: factors are cumulative, not event deltas.
        // Every began/identity/redraw/end transition must preserve the visible camera.
        let anchor = CGPoint(x: 230, y: 150)
        let sourcePoint = camera.canvasPoint(at: anchor)
        let initialFrame = camera.frame
        camera.beginPinch(at: anchor)
        sameFrame(camera.frame, initialFrame, "Gesture begin must not shrink")
        camera.magnify(to: 1)
        sameFrame(camera.frame, initialFrame, "Identity event must not shrink")
        camera.configure(layout)
        precondition(camera.isPinching, "A redraw must not reset recognition")
        for factor: CGFloat in [1.001, 1.01, 1.05, 1.2, 1.5, 2, 3, 4] {
            let oldScale = camera.scale
            camera.magnify(to: factor)
            precondition(camera.scale >= oldScale, "An outward pinch shrank the image")
            assertEdges(camera)
            // A SwiftUI rendering pass runs layout configuration on a copy.
            var rendered = camera
            rendered.configure(layout)
            sameFrame(rendered.frame, camera.frame, "Rendering must not recenter or clamp")
        }
        assertAnchor(camera, point: sourcePoint, anchor: anchor)
        let endedFrame = camera.frame
        camera.endPinch()
        sameFrame(camera.frame, endedFrame, "Gesture end must not snap")
        camera.beginPinch(at: anchor)
        camera.magnify(to: 1)
        sameFrame(camera.frame, endedFrame, "Second pinch must start at current zoom")
        camera.magnify(to: 0.9)
        near(camera.scale, 1.8, "Pinch out from prior zoom")
        assertAnchor(camera, point: sourcePoint, anchor: anchor)
        camera.endPinch()

        // Event count and timing do not affect the final transform.
        var oneEvent = AnnotationCanvasViewport()
        oneEvent.configure(layout)
        oneEvent.beginPinch(at: anchor)
        oneEvent.magnify(to: 3)
        var manyEvents = AnnotationCanvasViewport()
        manyEvents.configure(layout)
        manyEvents.beginPinch(at: anchor)
        for index in 1...200 { manyEvents.magnify(to: 1 + CGFloat(index) / 100) }
        sameFrame(manyEvents.frame, oneEvent.frame, "Cumulative event cadence")

        // Fit can lie outside the manual zoom range. Gesture start, a zero
        // sample, and an outward sample must never normalize it down first.
        for pixels in [CGSize(width: 100, height: 80), CGSize(width: 80000, height: 60000)] {
            for backing: CGFloat in [1, 2] {
                var unusual = layout
                unusual.canvasSize = pixels
                unusual.displayScale = backing
                var subject = AnnotationCanvasViewport()
                subject.configure(unusual)
                let fittedScale = subject.scale
                let fittedFrame = subject.frame
                subject.beginPinch(at: unusual.center)
                subject.magnify(to: 1)
                sameFrame(subject.frame, fittedFrame, "Out-of-range Fit begin")
                subject.magnify(to: 1.02)
                precondition(subject.scale >= fittedScale, "Out-of-range Fit shrank on pinch in")
                subject.endPinch()
            }
        }

        // Fit thresholds constrain fitting axes; reversal still returns to the
        // same view without accumulating intermediate edge-clamping offsets.
        var small = AnnotationCanvasViewport()
        small.configure(layout)
        small.zoom(to: 0.25)
        let smallAnchor = CGPoint(x: small.frame.minX + 50, y: small.frame.minY + 30)
        let smallFrame = small.frame
        small.beginPinch(at: smallAnchor)
        for factor: CGFloat in [1, 1.1, 1.5, 2, 3, 4, 3, 2, 1.5, 1.1, 1] {
            small.magnify(to: factor)
            assertEdges(small)
        }
        sameFrame(small.frame, smallFrame, "Pinch round trip")
        small.endPinch()

        // The gesture alone owns zoom; interleaved scroll cannot pan it.
        small.beginPinch(at: smallAnchor)
        let beforeScroll = small.frame
        small.pan(by: CGSize(width: 150, height: -90))
        sameFrame(small.frame, beforeScroll, "Ignore scroll during pinch")
        small.magnify(to: .nan)
        small.magnify(to: 0)
        sameFrame(small.frame, beforeScroll, "Reject invalid magnification")
        small.endPinch()
        small.pan(by: CGSize(width: 8, height: 6))
        sameFrame(small.frame, beforeScroll, "Fitting image cannot pan into workspace")
        small.pan(by: CGSize(width: 100000, height: -100000))
        assertEdges(small)

        // A clamp has no hidden overshoot to unwind when fingers reverse.
        camera.fit()
        camera.beginPinch(at: anchor)
        camera.magnify(to: 20)
        near(camera.scale, 5, "1000% upper zoom limit at 2x display scale")
        precondition(camera.zoomPercent == 1000 && !camera.canZoomIn)
        camera.magnify(to: 18)
        near(camera.scale, 4.5, "Immediate reversal at upper limit")
        camera.endPinch()

        // All four edges, both fitting axes, and one-axis overflow. Bounds
        // must hold after pan, pinch, zoom-out and viewport resize.
        for size in [CGSize(width: 2000, height: 1000), CGSize(width: 400, height: 4000),
                     CGSize(width: 4000, height: 400), CGSize(width: 100, height: 80)] {
            for backing: CGFloat in [1, 2] {
                var edgeLayout = layout
                edgeLayout.canvasSize = size
                edgeLayout.displayScale = backing
                var subject = AnnotationCanvasViewport()
                subject.configure(edgeLayout)
                precondition(subject.zoomPercent <= 1000, "Fit exceeds maximum zoom")
                subject.zoom(to: 1000 / (100 * backing))
                precondition(subject.zoomPercent == 1000, "1000% cannot be reached")
                subject.zoom(by: 1.25)
                precondition(subject.zoomPercent == 1000, "Menu zoom exceeds maximum")
                for delta in [CGSize(width: 100000, height: 100000),
                              CGSize(width: -100000, height: -100000),
                              CGSize(width: 100000, height: -100000),
                              CGSize(width: -100000, height: 100000)] {
                    subject.pan(by: delta)
                    assertEdges(subject)
                }
                subject.beginPinch(at: edgeLayout.center)
                for factor: CGFloat in [1, 0.8, 0.2, 0.05, 0.2, 0.8, 1] {
                    subject.magnify(to: factor)
                    assertEdges(subject)
                }
                subject.endPinch()
                subject.zoom(to: 0.25 / backing)
                assertEdges(subject)
                edgeLayout.viewportSize = CGSize(width: 1500, height: 1000)
                subject.configure(edgeLayout)
                assertEdges(subject)
            }
        }

        // Resize preserves the central document point; Fit recomputes its margins.
        let centerBeforeResize = camera.canvasPoint(at: layout.center)
        var resized = layout
        resized.viewportSize = CGSize(width: 800, height: 700)
        camera.configure(resized)
        let centerAfterResize = camera.canvasPoint(at: resized.center)
        near(centerBeforeResize.x, centerAfterResize.x, "Resize center X")
        near(centerBeforeResize.y, centerAfterResize.y, "Resize center Y")
        camera.fit()
        resized.fitInsets = CGSize(width: 60, height: 54)
        camera.configure(resized)
        precondition(camera.frame.minX >= 60 && camera.frame.minY >= 54, "Crop handle clearance")
        camera.beginPinch(at: resized.center)
        camera.fit()
        precondition(!camera.isPinching && camera.isFitting, "Fit must end gesture ownership")

        print("Editor camera checks passed (\(checks) assertions): gesture start/end, cumulative input, repeat pinch, fit limits, stable anchor, reversal, scroll arbitration, resize, crop.")
    }
}
