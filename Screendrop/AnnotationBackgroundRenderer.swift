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
        drawBackground(settings.style, in: canvasRect, context: context)

        let imageRect = flipped(layout.imageRect, canvasHeight: CGFloat(height)).integral
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
        guard let image = loadCGImage(at: wallpaper.url, maxPixelSize: max(rect.width, rect.height)) else {
            drawMissingWallpaperFallback(in: rect, context: context)
            return
        }

        context.draw(image, in: aspectFillRect(
            imageSize: CGSize(width: image.width, height: image.height),
            fillRect: rect
        ))
    }

    private static func loadCGImage(at url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up)))
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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

    private static func cgPoint(for unitPoint: UnitPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + unitPoint.x * rect.width,
            y: rect.minY + (1 - unitPoint.y) * rect.height
        )
    }
}
