//
//  AnnotationBackgroundLayout.swift
//  Screendrop
//

import CoreGraphics

struct AnnotationBackgroundLayout {
    let canvasSize: CGSize
    let imageRect: CGRect
    let padding: CGFloat

    static func make(contentSize: CGSize, settings: AnnotationBackgroundSettings) -> AnnotationBackgroundLayout {
        guard contentSize.width > 0, contentSize.height > 0 else {
            return AnnotationBackgroundLayout(canvasSize: .zero, imageRect: .zero, padding: 0)
        }

        guard settings.isEnabled else {
            return AnnotationBackgroundLayout(
                canvasSize: contentSize,
                imageRect: CGRect(origin: .zero, size: contentSize),
                padding: 0
            )
        }

        let alignment = settings.alignment
        let shortestEdge = min(contentSize.width, contentSize.height)
        let padding = max(0, shortestEdge * settings.padding)

        // Per-edge padding: stuck edges get zero padding
        let paddingTop: CGFloat = alignment.sticksToTop ? 0 : padding
        let paddingBottom: CGFloat = alignment.sticksToBottom ? 0 : padding
        let paddingLeading: CGFloat = alignment.sticksToLeading ? 0 : padding
        let paddingTrailing: CGFloat = alignment.sticksToTrailing ? 0 : padding

        let minimumSize = CGSize(
            width: contentSize.width + paddingLeading + paddingTrailing,
            height: contentSize.height + paddingTop + paddingBottom
        )
        let canvasSize = expandedSize(minimumSize, aspectRatio: settings.aspectRatio.value)

        // Available rect accounts for per-edge padding
        let availableRect = CGRect(
            x: paddingLeading,
            y: paddingTop,
            width: canvasSize.width - paddingLeading - paddingTrailing,
            height: canvasSize.height - paddingTop - paddingBottom
        )
        let origin = CGPoint(
            x: availableRect.minX + max(0, availableRect.width - contentSize.width) * alignment.xFactor,
            y: availableRect.minY + max(0, availableRect.height - contentSize.height) * alignment.yFactor
        )

        return AnnotationBackgroundLayout(
            canvasSize: canvasSize,
            imageRect: CGRect(origin: origin, size: contentSize),
            padding: padding
        )
    }

    func scaled(to frame: CGRect) -> AnnotationBackgroundDisplayLayout {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return AnnotationBackgroundDisplayLayout(canvasFrame: frame, imageFrame: .zero, scale: 1)
        }

        let scale = frame.width / canvasSize.width
        let imageFrame = CGRect(
            x: frame.minX + imageRect.minX * scale,
            y: frame.minY + imageRect.minY * scale,
            width: imageRect.width * scale,
            height: imageRect.height * scale
        )
        return AnnotationBackgroundDisplayLayout(
            canvasFrame: frame,
            imageFrame: imageFrame,
            scale: scale
        )
    }

    private static func expandedSize(_ size: CGSize, aspectRatio: CGFloat?) -> CGSize {
        guard let aspectRatio, aspectRatio > 0, size.width > 0, size.height > 0 else {
            return size
        }

        let currentRatio = size.width / size.height
        if currentRatio < aspectRatio {
            return CGSize(width: size.height * aspectRatio, height: size.height)
        }

        return CGSize(width: size.width, height: size.width / aspectRatio)
    }
}

struct AnnotationBackgroundDisplayLayout {
    let canvasFrame: CGRect
    let imageFrame: CGRect
    let scale: CGFloat
}
