//
//  AnnotationScreenshotFrameGeometry.swift
//  Screendrop
//

import CoreGraphics
import SwiftUI

/// Shared preview/export geometry for the rounded screenshot and its optional
/// outer border. Keeping both paths together prevents the border from drifting
/// away from the screenshot's per-corner alignment treatment.
nonisolated struct AnnotationScreenshotFrameGeometry {
    let imageRect: CGRect
    let cardRect: CGRect
    let imageCornerRadii: PerCornerRadii
    let cardCornerRadii: PerCornerRadii
    let borderWidth: CGFloat

    init(
        imageRect: CGRect,
        cardRect: CGRect,
        settings: AnnotationBackgroundSettings
    ) {
        self.imageRect = imageRect
        self.cardRect = cardRect

        let horizontalInset = max(0, (cardRect.width - imageRect.width) / 2)
        let verticalInset = max(0, (cardRect.height - imageRect.height) / 2)
        borderWidth = settings.border.isActive
            ? min(horizontalInset, verticalInset)
            : 0

        let baseImageRadius = settings.requiresCanvasLayout
            ? max(0, settings.cornerRadius) * min(imageRect.width, imageRect.height)
            : 0
        let multipliers = settings.effectiveCanvasAlignment.cornerRadiusMultipliers
        imageCornerRadii = PerCornerRadii(
            topLeft: baseImageRadius * multipliers.topLeft,
            topRight: baseImageRadius * multipliers.topRight,
            bottomLeft: baseImageRadius * multipliers.bottomLeft,
            bottomRight: baseImageRadius * multipliers.bottomRight
        )

        // A rounded outer border stays concentric with the clipped screenshot:
        // add the ring width to rounded corners, while intentionally square
        // corners (including stuck canvas edges) remain square.
        let baseCardRadius = baseImageRadius > 0 ? baseImageRadius + borderWidth : 0
        cardCornerRadii = PerCornerRadii(
            topLeft: baseCardRadius * multipliers.topLeft,
            topRight: baseCardRadius * multipliers.topRight,
            bottomLeft: baseCardRadius * multipliers.bottomLeft,
            bottomRight: baseCardRadius * multipliers.bottomRight
        )
    }

    var imagePath: CGPath {
        PerCornerRadii.path(in: imageRect, radii: imageCornerRadii)
    }

    var cardPath: CGPath {
        PerCornerRadii.path(in: cardRect, radii: cardCornerRadii)
    }
}

/// SwiftUI's coordinate system points down, while the shared Core Graphics
/// path builder points up. Flipping that exact path lets live preview use the
/// same circular corner geometry as the exported image.
struct AnnotationPerCornerRoundedRectangle: Shape {
    let radii: PerCornerRadii

    func path(in rect: CGRect) -> Path {
        Path(Self.cgPath(in: rect, radii: radii))
    }

    static func cgPath(in rect: CGRect, radii: PerCornerRadii) -> CGPath {
        let source = PerCornerRadii.path(in: rect, radii: radii)
        var flip = CGAffineTransform(
            a: 1,
            b: 0,
            c: 0,
            d: -1,
            tx: 0,
            ty: rect.minY + rect.maxY
        )
        return source.copy(using: &flip) ?? source
    }
}

/// A true even-odd ring. The screenshot's interior is deliberately absent,
/// rather than merely being covered by another layer, so transparent source
/// pixels cannot reveal the border material.
struct AnnotationScreenshotBorderRingShape: Shape {
    let outerRadii: PerCornerRadii
    let innerRadii: PerCornerRadii
    let thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let innerRect = rect.insetBy(dx: thickness, dy: thickness)
        let outerPath = AnnotationPerCornerRoundedRectangle.cgPath(
            in: rect,
            radii: outerRadii
        )
        guard innerRect.width > 0, innerRect.height > 0 else {
            return Path(outerPath)
        }

        let innerPath = AnnotationPerCornerRoundedRectangle.cgPath(
            in: innerRect,
            radii: innerRadii
        )
        return Path(outerPath.subtracting(innerPath))
    }
}
