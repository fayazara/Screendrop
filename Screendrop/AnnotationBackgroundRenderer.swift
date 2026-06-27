//
//  AnnotationBackgroundRenderer.swift
//  Screendrop
//

import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

enum AnnotationBackgroundRenderer {
    typealias CanvasOverlay = (_ context: CGContext, _ layout: AnnotationBackgroundLayout, _ imageRect: CGRect) -> Void

    static func compose(
        annotatedImage: CGImage,
        settings: AnnotationBackgroundSettings,
        colorSpace: CGColorSpace
    ) throws -> CGImage {
        try compose(
            contentImage: annotatedImage,
            settings: settings,
            colorSpace: colorSpace
        )
    }

    static func compose(
        contentImage: CGImage,
        settings: AnnotationBackgroundSettings,
        colorSpace: CGColorSpace,
        canvasOverlay: CanvasOverlay? = nil
    ) throws -> CGImage {
        guard settings.isEnabled else {
            guard let canvasOverlay else { return contentImage }

            let width = contentImage.width
            let height = contentImage.height
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }

            let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
            context.interpolationQuality = .none
            context.draw(contentImage, in: fullRect)
            canvasOverlay(
                context,
                AnnotationBackgroundLayout(canvasSize: fullRect.size, imageRect: fullRect, padding: 0),
                fullRect
            )

            guard let renderedImage = context.makeImage() else {
                throw CocoaError(.fileWriteUnknown)
            }
            return renderedImage
        }

        let contentSize = CGSize(width: contentImage.width, height: contentImage.height)
        let layout = AnnotationBackgroundLayout.make(contentSize: contentSize, settings: settings)
        let width = max(1, Int(ceil(layout.canvasSize.width)))
        let height = max(1, Int(ceil(layout.canvasSize.height)))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        drawBackground(settings.style, in: canvasRect, context: context)

        let imageRect = pixelAlignedImageRect(
            flipped(layout.imageRect, canvasHeight: CGFloat(height)),
            contentSize: contentSize,
            canvasSize: canvasRect.size
        )
        let baseCornerRadius = settings.cornerRadius * min(imageRect.width, imageRect.height)
        let m = settings.alignment.cornerRadiusMultipliers
        let cornerRadii = PerCornerRadii(
            topLeft: baseCornerRadius * m.topLeft,
            topRight: baseCornerRadius * m.topRight,
            bottomLeft: baseCornerRadius * m.bottomLeft,
            bottomRight: baseCornerRadius * m.bottomRight
        )
        let clipPath = PerCornerRadii.path(in: imageRect, radii: cornerRadii)
        drawShadow(path: clipPath, strength: settings.shadow, context: context)

        context.saveGState()
        context.interpolationQuality = .none
        context.addPath(clipPath)
        context.clip()
        context.draw(contentImage, in: imageRect)
        context.restoreGState()
        canvasOverlay?(context, layout, imageRect)

        guard let renderedImage = context.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return renderedImage
    }

    static func drawWatermark(
        _ settings: AnnotationWatermarkSettings,
        in rect: CGRect,
        context: CGContext
    ) {
        let text = settings.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.isVisible,
              !text.isEmpty,
              rect.width > 1,
              rect.height > 1 else {
            return
        }

        let rows = max(2, Int(round(settings.density)))
        let spacingY = rect.height / CGFloat(rows)
        let spacingX = max(1, spacingY * 2.2)
        let diagonal = hypot(rect.width, rect.height)
        let columnCount = max(2, Int(ceil(diagonal / spacingX)))
        let rowCount = max(2, Int(ceil(diagonal / spacingY)))
        let originX = rect.midX - CGFloat(columnCount) * spacingX / 2
        let originY = rect.midY - CGFloat(rowCount) * spacingY / 2

        let font = AnnotationWatermarkTypography.nsFont(size: settings.fontSize)
        let color = settings.color.nsColor.withAlphaComponent(min(0.75, max(0, settings.opacity)))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let measuredSize = attributedText.size()
        guard measuredSize.width > 0, measuredSize.height > 0 else { return }

        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: -settings.rotationDegrees * .pi / 180)
        context.translateBy(x: -rect.midX, y: -rect.midY)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for row in 0...rowCount {
            for column in 0...columnCount {
                let center = CGPoint(
                    x: originX + CGFloat(column) * spacingX,
                    y: originY + CGFloat(row) * spacingY
                )
                attributedText.draw(
                    with: CGRect(
                        x: center.x - measuredSize.width / 2,
                        y: center.y - measuredSize.height / 2,
                        width: measuredSize.width,
                        height: measuredSize.height
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private static func drawBackground(
        _ style: AnnotationBackgroundStyle,
        in rect: CGRect,
        context: CGContext
    ) {
        switch style {
        case .none:
            NSColor.clear.setFill()
            context.fill(rect)

        case .solid(let color):
            context.setFillColor(color.nsColor.cgColor)
            context.fill(rect)

        case .gradient(let gradient):
            let nsColors = gradient.colors.map(\.nsColor)
            let cgColors = nsColors.map(\.cgColor) as CFArray
            guard let cgGradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: cgColors,
                locations: nil
            ) else {
                context.setFillColor(nsColors.first?.cgColor ?? NSColor.black.cgColor)
                context.fill(rect)
                return
            }

            context.drawLinearGradient(
                cgGradient,
                start: cgPoint(for: gradient.startPoint, in: rect),
                end: cgPoint(for: gradient.endPoint, in: rect),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )

        case .customWallpaper(let wallpaper):
            drawCustomWallpaper(
                wallpaper,
                in: rect,
                context: context
            )
        }
    }

    private static func drawCustomWallpaper(
        _ wallpaper: AnnotationCustomWallpaper,
        in rect: CGRect,
        context: CGContext
    ) {
        guard let image = loadCGImageForAspectFill(at: wallpaper.url, fillSize: rect.size) else {
            drawMissingWallpaperFallback(in: rect, context: context)
            return
        }

        context.interpolationQuality = .high
        context.draw(image, in: aspectFillRect(
            imageSize: CGSize(width: image.width, height: image.height),
            fillRect: rect
        ))
    }

    private static func loadCGImageForAspectFill(at url: URL, fillSize: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }

        guard let sourceSize = imageSize(from: source),
              sourceSize.width > 0,
              sourceSize.height > 0,
              fillSize.width > 0,
              fillSize.height > 0 else {
            return CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary)
        }

        let drawScale = max(fillSize.width / sourceSize.width, fillSize.height / sourceSize.height)
        let requiredMaxPixelSize = max(sourceSize.width, sourceSize.height) * drawScale

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(requiredMaxPixelSize.rounded(.up)))
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func imageSize(from source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }

        return CGSize(width: width, height: height)
    }

    private static func aspectFillRect(imageSize: CGSize, fillRect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, fillRect.width > 0, fillRect.height > 0 else {
            return fillRect
        }

        let scale = max(fillRect.width / imageSize.width, fillRect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: fillRect.midX - size.width / 2,
            y: fillRect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func drawMissingWallpaperFallback(in rect: CGRect, context: CGContext) {
        context.setFillColor(NSColor.black.cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        context.setLineWidth(2)
        context.stroke(rect.insetBy(dx: 8, dy: 8))
    }

    private static func drawShadow(
        path: CGPath,
        strength: CGFloat,
        context: CGContext
    ) {
        guard strength > 0 else { return }

        let rect = path.boundingBoxOfPath
        let shortestEdge = min(rect.width, rect.height)
        let radius = max(2, shortestEdge * (0.035 + strength * 0.035))
        let offset = CGSize(width: 0, height: -shortestEdge * (0.012 + strength * 0.018))
        let alpha = min(max(strength, 0), 1) * 0.36

        context.saveGState()
        context.setShadow(offset: offset, blur: radius, color: NSColor.black.withAlphaComponent(alpha).cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    private static func flipped(_ rect: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: canvasHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func pixelAlignedImageRect(
        _ rect: CGRect,
        contentSize: CGSize,
        canvasSize: CGSize
    ) -> CGRect {
        let width = min(contentSize.width, canvasSize.width)
        let height = min(contentSize.height, canvasSize.height)
        let maxX = max(0, canvasSize.width - width)
        let maxY = max(0, canvasSize.height - height)
        let x = min(max(0, rect.minX.rounded()), maxX)
        let y = min(max(0, rect.minY.rounded()), maxY)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func cgPoint(for unitPoint: UnitPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + unitPoint.x * rect.width,
            y: rect.minY + (1 - unitPoint.y) * rect.height
        )
    }
}
