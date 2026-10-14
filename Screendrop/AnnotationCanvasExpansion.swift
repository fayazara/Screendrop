//
//  AnnotationCanvasExpansion.swift
//  Screendrop
//

import CoreGraphics
import Foundation
import ImageIO

/// Grows the canvas when annotations run past the screenshot's edge, as
/// Shottr does, instead of cutting them off. The canvas then reaches a margin
/// past the outermost annotation, the same margin goes on every side, and the
/// new area takes the screenshot's own edge color, so the result reads as one
/// image rather than a screenshot on a backdrop.
nonisolated struct AnnotationCanvasExpansion: Equatable, Sendable {
    /// Added on each side, in image pixels.
    var left = 0
    var top = 0
    var right = 0
    var bottom = 0

    /// Shottr's margin.
    static let marginPoints: CGFloat = 20

    var isEmpty: Bool {
        left == 0 && top == 0 && right == 0 && bottom == 0
    }

    init() {}

    /// The growth the shapes need on an image of `imageSize` pixels.
    init(shapes: [AnnoShape], imageSize: CGSize, pixelsPerPoint: CGFloat) {
        let document = AnnoDocument()
        document.restore(AnnoDocument.Snapshot(shapes: shapes, bindings: []))
        self.init(
            annotationBounds: document.renderedPageBounds(),
            imageSize: imageSize,
            pixelsPerPoint: pixelsPerPoint
        )
    }

    /// No growth while everything drawn stays on the screenshot.
    init(annotationBounds: CGRect?, imageSize: CGSize, pixelsPerPoint: CGFloat) {
        guard let bounds = annotationBounds,
              bounds.minX < 0 || bounds.minY < 0
                || bounds.maxX > imageSize.width || bounds.maxY > imageSize.height else {
            return
        }
        let margin = Self.marginPoints * pixelsPerPoint
        left = Int((max(0, -bounds.minX) + margin).rounded(.up))
        top = Int((max(0, -bounds.minY) + margin).rounded(.up))
        right = Int((max(0, bounds.maxX - imageSize.width) + margin).rounded(.up))
        bottom = Int((max(0, bounds.maxY - imageSize.height) + margin).rounded(.up))
    }

    /// Pixels per point from the DPI the image was saved with (144 for a
    /// Retina capture), or 1 when it records none.
    static func pixelsPerPoint(of source: CGImageSource) -> CGFloat {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return max(1, CGFloat(dpi) / 72)
    }

    func grownSize(_ imageSize: CGSize) -> CGSize {
        CGSize(width: imageSize.width + CGFloat(left + right), height: imageSize.height + CGFloat(top + bottom))
    }

    /// Where the screenshot sits when the grown canvas is drawn in `frame`.
    func imageFrame(in frame: CGRect, imageSize: CGSize) -> CGRect {
        guard !isEmpty, imageSize.width > 0 else { return frame }
        let scale = frame.width / grownSize(imageSize).width
        return CGRect(
            x: frame.minX + CGFloat(left) * scale,
            y: frame.minY + CGFloat(top) * scale,
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }

    /// The screenshot on the grown canvas, the new area filled with `fill`,
    /// the screenshot's edge color.
    func apply(to image: CGImage, fill: CGColor, colorSpace: CGColorSpace) -> CGImage? {
        let width = image.width + left + right
        let height = image.height + top + bottom
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(fill)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Quartz is y-up: the image's bottom edge sits `bottom` pixels up.
        context.draw(image, in: CGRect(x: left, y: bottom, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// A composed result on `fill`, so a border's rounded corners, which
    /// leave transparency, can't make a grown canvas see-through.
    static func flatten(_ image: CGImage, onto fill: CGColor, colorSpace: CGColorSpace) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(fill)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }

    /// Shapes moved into the grown canvas's coordinates. Only for drawing:
    /// what's saved stays in the screenshot's own coordinates, and the growth
    /// is worked out again from the shapes next time.
    func shifted(_ shapes: [AnnoShape]) -> [AnnoShape] {
        shapes.map { shape in
            var shape = shape
            shape.x += Double(left)
            shape.y += Double(top)
            return shape
        }
    }

    /// The color most of the screenshot's outermost pixels share - typically
    /// a window's background - so the added area continues the image. Ties go
    /// to the color met first, going clockwise from the top-left corner, so
    /// the same image always gets the same fill.
    static func edgeColor(of image: CGImage, colorSpace: CGColorSpace) -> CGColor {
        let width = image.width
        let height = image.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw, width > 0, height > 0 else { return CGColor(gray: 1, alpha: 1) }

        // Clockwise around the border, each pixel once. The strides stay
        // empty, rather than trapping, for an image one pixel thin.
        var border = Array(0..<width)
        border += (1..<height).map { $0 * width + width - 1 }
        if height > 1 {
            border += stride(from: width - 2, through: 0, by: -1).map { (height - 1) * width + $0 }
        }
        if width > 1 {
            border += stride(from: height - 2, through: 1, by: -1).map { $0 * width }
        }
        var counts: [UInt32: (count: Int, firstSeen: Int)] = [:]
        for (order, index) in border.enumerated() {
            counts[pixels[index], default: (0, order)].count += 1
        }
        let winner = counts.max { a, b in
            a.value.count != b.value.count ? a.value.count < b.value.count : a.value.firstSeen > b.value.firstSeen
        }!.key

        // Each word reads as premultiplied RGBA, red in the top byte; undo
        // the premultiplication.
        let red = CGFloat((winner >> 24) & 0xFF)
        let green = CGFloat((winner >> 16) & 0xFF)
        let blue = CGFloat((winner >> 8) & 0xFF)
        let alpha = CGFloat(winner & 0xFF)
        guard alpha > 0 else { return CGColor(gray: 1, alpha: 1) }
        return CGColor(
            colorSpace: colorSpace,
            components: [red / alpha, green / alpha, blue / alpha, 1]
        ) ?? CGColor(gray: 1, alpha: 1)
    }
}
