//
//  AnnotationMockupEffectsRenderer.swift
//  Screendrop
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

enum AnnotationMockupEffectsError: Error {
    case progressiveBlurFailed
    case cameraProjectionFailed
}

enum AnnotationMockupEffectsRenderer {
    /// `CIContext` is immutable after creation and documented for reuse across
    /// render calls. Access is serialized for previews by the worker below;
    /// exports run on the editor's actor.
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    nonisolated static func progressiveBlur(
        _ image: CGImage,
        settings: AnnotationProgressiveBlurSettings,
        colorSpace: CGColorSpace
    ) throws -> CGImage {
        guard settings.isActive else { return image }

        let input = CIImage(cgImage: image)
        let extent = input.extent
        let output = try progressiveBlurCIImage(input, settings: settings)
        guard let renderedImage = context.createCGImage(
            output,
            from: extent,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            throw AnnotationMockupEffectsError.progressiveBlurFailed
        }
        return renderedImage
    }

    static func drawProjectedForeground(
        _ image: CGImage,
        projection: AnnotationCameraProjection,
        canvasSize: CGSize,
        colorSpace: CGColorSpace,
        into destinationContext: CGContext
    ) throws {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let output = try projectedForegroundCIImage(
            image,
            projection: projection,
            canvasSize: canvasSize
        )

        draw(
            output,
            in: canvasRect,
            colorSpace: colorSpace,
            into: destinationContext
        )
    }

    static func drawProgressivelyBlurredScene(
        _ image: CGImage,
        canvasSize: CGSize,
        colorSpace: CGColorSpace,
        progressiveBlurSettings: AnnotationProgressiveBlurSettings,
        into destinationContext: CGContext
    ) throws {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let output = try progressiveBlurCIImage(
            CIImage(cgImage: image),
            settings: progressiveBlurSettings
        )
        draw(
            output,
            in: canvasRect,
            colorSpace: colorSpace,
            into: destinationContext
        )
    }

    private static func draw(
        _ image: CIImage,
        in canvasRect: CGRect,
        colorSpace: CGColorSpace,
        into destinationContext: CGContext
    ) {
        // Render directly into the already-allocated final canvas. This avoids
        // materializing another full-canvas RGBA bitmap for large compositions.
        let destination = CIContext(
            cgContext: destinationContext,
            options: [
                .cacheIntermediates: false,
                .workingColorSpace: colorSpace,
                .outputColorSpace: colorSpace
            ]
        )
        destination.draw(image, in: canvasRect, from: canvasRect)
    }

    static func clearCaches() {
        context.clearCaches()
    }

    nonisolated private static func blurMask(
        for extent: CGRect,
        settings: AnnotationProgressiveBlurSettings
    ) -> CIImage? {
        let focus = CGPoint(
            x: extent.minX + min(max(settings.focusPosition.x, 0), 1) * extent.width,
            y: extent.minY + (1 - min(max(settings.focusPosition.y, 0), 1)) * extent.height
        )
        let shortestEdge = min(extent.width, extent.height)
        let falloff = min(max(settings.falloff, 0), 1)
        let focusSize = min(max(settings.focusSize, 0), 1)
        let transitionWidth = shortestEdge * (0.10 + falloff * 0.48)
        let baseMask: CIImage?

        switch settings.mode {
        case .radial:
            let minimumRadius = shortestEdge * 0.04
            let maximumRadius = radialMaximumDistance(from: focus, to: extent)
            let focusRadius = minimumRadius
                + focusSize * max(0, maximumRadius - minimumRadius)
            let gradient = CIFilter.radialGradient()
            gradient.center = focus
            gradient.radius0 = Float(focusRadius)
            gradient.radius1 = Float(focusRadius + transitionWidth)
            gradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            gradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            baseMask = gradient.outputImage

        case .directional:
            let angle = settings.directionDegrees * .pi / 180
            // The angle describes the sharp band, so gradients run along its normal.
            // The stored angle is clockwise in top-left UI coordinates. Core
            // Image uses a bottom-left origin, so its normal flips horizontally.
            let normal = CGVector(dx: sin(angle), dy: cos(angle))
            let minimumHalfWidth = shortestEdge * 0.025
            let maximumHalfWidth = directionalMaximumDistance(
                from: focus,
                along: normal,
                to: extent
            )
            let focusHalfWidth = minimumHalfWidth
                + focusSize * max(0, maximumHalfWidth - minimumHalfWidth)
            let positiveFocusEdge = CGPoint(
                x: focus.x + normal.dx * focusHalfWidth,
                y: focus.y + normal.dy * focusHalfWidth
            )
            let negativeFocusEdge = CGPoint(
                x: focus.x - normal.dx * focusHalfWidth,
                y: focus.y - normal.dy * focusHalfWidth
            )
            let positive = directionalGradient(
                from: positiveFocusEdge,
                to: CGPoint(
                    x: positiveFocusEdge.x + normal.dx * transitionWidth,
                    y: positiveFocusEdge.y + normal.dy * transitionWidth
                )
            )
            let negative = directionalGradient(
                from: negativeFocusEdge,
                to: CGPoint(
                    x: negativeFocusEdge.x - normal.dx * transitionWidth,
                    y: negativeFocusEdge.y - normal.dy * transitionWidth
                )
            )

            let maximum = CIFilter.maximumCompositing()
            maximum.inputImage = positive
            maximum.backgroundImage = negative
            baseMask = maximum.outputImage
        }

        return baseMask?.cropped(to: extent)
    }

    nonisolated private static func directionalGradient(from start: CGPoint, to end: CGPoint) -> CIImage? {
        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = start
        gradient.point1 = end
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        return gradient.outputImage
    }

    nonisolated private static func radialMaximumDistance(
        from focus: CGPoint,
        to extent: CGRect
    ) -> CGFloat {
        corners(of: extent).map { corner in
            hypot(corner.x - focus.x, corner.y - focus.y)
        }.max() ?? 0
    }

    nonisolated private static func directionalMaximumDistance(
        from focus: CGPoint,
        along normal: CGVector,
        to extent: CGRect
    ) -> CGFloat {
        corners(of: extent).map { corner in
            abs((corner.x - focus.x) * normal.dx + (corner.y - focus.y) * normal.dy)
        }.max() ?? 0
    }

    nonisolated private static func corners(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }

    private static func coreImagePoint(_ point: CGPoint, canvasHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: canvasHeight - point.y)
    }

    private static func projectedForegroundCIImage(
        _ image: CGImage,
        projection: AnnotationCameraProjection,
        canvasSize: CGSize
    ) throws -> CIImage {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            throw AnnotationMockupEffectsError.cameraProjectionFailed
        }

        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = CIImage(cgImage: image)
        filter.topLeft = coreImagePoint(projection.quad.topLeft, canvasHeight: canvasSize.height)
        filter.topRight = coreImagePoint(projection.quad.topRight, canvasHeight: canvasSize.height)
        filter.bottomRight = coreImagePoint(projection.quad.bottomRight, canvasHeight: canvasSize.height)
        filter.bottomLeft = coreImagePoint(projection.quad.bottomLeft, canvasHeight: canvasSize.height)

        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        guard let output = filter.outputImage?.cropped(to: canvasRect) else {
            throw AnnotationMockupEffectsError.cameraProjectionFailed
        }
        return output
    }

    nonisolated private static func progressiveBlurCIImage(
        _ input: CIImage,
        settings: AnnotationProgressiveBlurSettings
    ) throws -> CIImage {
        guard settings.isActive else { return input }

        let extent = input.extent
        guard extent.width > 0, extent.height > 0,
              let mask = blurMask(for: extent, settings: settings) else {
            throw AnnotationMockupEffectsError.progressiveBlurFailed
        }

        let shortestEdge = min(extent.width, extent.height)
        let radius = max(0.5, settings.strength * shortestEdge / 1000)
        let blur = CIFilter.maskedVariableBlur()
        blur.inputImage = input.clampedToExtent()
        blur.mask = mask
        blur.radius = Float(radius)
        guard let output = blur.outputImage?.cropped(to: extent) else {
            throw AnnotationMockupEffectsError.progressiveBlurFailed
        }
        return output
    }
}

actor AnnotationProgressiveBlurPreviewWorker {
    static let shared = AnnotationProgressiveBlurPreviewWorker()

    func render(
        source: CGImage,
        settings: AnnotationProgressiveBlurSettings,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return try? AnnotationMockupEffectsRenderer.progressiveBlur(
            source,
            settings: settings,
            colorSpace: colorSpace
        )
    }
}
