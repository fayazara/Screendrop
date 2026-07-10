//
//  AnnotationProgressiveBlurPreview.swift
//  Screendrop
//

import AppKit
import CoreGraphics
import SwiftUI

struct AnnotationProgressiveBlurBlendMask: View {
    let settings: AnnotationProgressiveBlurSettings
    let level: Int
    let levelCount: Int

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let geometry = AnnotationProgressiveBlurGeometry(
                extent: CGRect(origin: .zero, size: size),
                settings: settings,
                coordinateOrigin: .topLeft
            )

            switch settings.mode {
            case .radial:
                radialMask(geometry: geometry, size: size)
            case .directional:
                directionalMask(geometry: geometry, size: size)
            }
        }
    }

    private func radialMask(
        geometry: AnnotationProgressiveBlurGeometry,
        size: CGSize
    ) -> some View {
        let transitionStart = geometry.radialFocusRadius
            + geometry.transitionWidth * levelStart
        let transitionEnd = geometry.radialFocusRadius
            + geometry.transitionWidth * levelEnd

        return RadialGradient(
            colors: [.clear, .white],
            center: UnitPoint(
                x: geometry.focus.x / max(size.width, 1),
                y: geometry.focus.y / max(size.height, 1)
            ),
            startRadius: transitionStart,
            endRadius: transitionEnd
        )
    }

    private func directionalMask(
        geometry: AnnotationProgressiveBlurGeometry,
        size: CGSize
    ) -> some View {
        let minimumDistance = geometry.directionalDistances.min() ?? -1
        let maximumDistance = geometry.directionalDistances.max() ?? 1
        let distanceRange = max(maximumDistance - minimumDistance, 1)
        let transitionStart = geometry.transitionWidth * levelStart
        let transitionEnd = geometry.transitionWidth * levelEnd

        func location(for distance: CGFloat) -> CGFloat {
            min(max((distance - minimumDistance) / distanceRange, 0), 1)
        }

        let start = CGPoint(
            x: geometry.focus.x + geometry.directionNormal.dx * minimumDistance,
            y: geometry.focus.y + geometry.directionNormal.dy * minimumDistance
        )
        let end = CGPoint(
            x: geometry.focus.x + geometry.directionNormal.dx * maximumDistance,
            y: geometry.focus.y + geometry.directionNormal.dy * maximumDistance
        )
        let stops = [
            Gradient.Stop(color: .white, location: 0),
            Gradient.Stop(
                color: .white,
                location: location(
                    for: -geometry.directionalFocusHalfWidth - transitionEnd
                )
            ),
            Gradient.Stop(
                color: .clear,
                location: location(
                    for: -geometry.directionalFocusHalfWidth - transitionStart
                )
            ),
            Gradient.Stop(
                color: .clear,
                location: location(
                    for: geometry.directionalFocusHalfWidth + transitionStart
                )
            ),
            Gradient.Stop(
                color: .white,
                location: location(
                    for: geometry.directionalFocusHalfWidth + transitionEnd
                )
            ),
            Gradient.Stop(color: .white, location: 1)
        ]

        return LinearGradient(
            gradient: Gradient(stops: stops),
            startPoint: UnitPoint(
                x: start.x / max(size.width, 1),
                y: start.y / max(size.height, 1)
            ),
            endPoint: UnitPoint(
                x: end.x / max(size.width, 1),
                y: end.y / max(size.height, 1)
            )
        )
    }

    private var levelStart: CGFloat {
        CGFloat(min(max(level, 0), max(levelCount - 1, 0))) / CGFloat(max(levelCount, 1))
    }

    private var levelEnd: CGFloat {
        CGFloat(min(max(level + 1, 1), max(levelCount, 1))) / CGFloat(max(levelCount, 1))
    }

}

struct AnnotationProgressiveBlurPreviewKey: Hashable {
    let sourceID: ObjectIdentifier
    let isEnabled: Bool
    let edgeMode: AnnotationProgressiveBlurEdgeMode
    let mode: AnnotationProgressiveBlurMode
    let strength: CGFloat
    let falloff: CGFloat
    let focusSize: CGFloat
    let focusX: CGFloat
    let focusY: CGFloat
    let directionDegrees: CGFloat

    init(image: NSImage, settings: AnnotationProgressiveBlurSettings) {
        sourceID = ObjectIdentifier(image)
        isEnabled = settings.isEnabled
        edgeMode = settings.edgeMode
        mode = settings.mode
        strength = settings.strength
        falloff = settings.falloff
        focusSize = settings.focusSize
        focusX = settings.focusPosition.x
        focusY = settings.focusPosition.y
        directionDegrees = settings.directionDegrees
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
