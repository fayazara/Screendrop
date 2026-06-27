//
//  AnnotationRenderer.swift
//  Screendrop
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

enum AnnotationRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func renderToTemporaryFile(
        sourceURL: URL,
        items: [AnnotationItem],
        backgroundSettings: AnnotationBackgroundSettings = AnnotationBackgroundSettings()
    ) throws -> URL {
        let destinationURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Screendrop_Annotated_\(UUID().uuidString.prefix(6)).png")
        try render(
            sourceURL: sourceURL,
            items: items,
            backgroundSettings: backgroundSettings,
            destinationURL: destinationURL,
            contentType: .png
        )
        return destinationURL
    }

    static func render(
        sourceURL: URL,
        items: [AnnotationItem],
        backgroundSettings: AnnotationBackgroundSettings = AnnotationBackgroundSettings(),
        destinationURL: URL,
        contentType: UTType
    ) throws {
        defer {
            ciContext.clearCaches()
        }

        try autoreleasepool {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let renderedImage: CGImage
            if backgroundSettings.hasRenderableContent {
                let sourceImage = try loadSourceImage(sourceURL: sourceURL)
                renderedImage = try AnnotationBackgroundRenderer.compose(
                    contentImage: sourceImage,
                    settings: backgroundSettings,
                    colorSpace: colorSpace
                ) { context, layout, imageRect in
                    drawAnnotations(
                        items,
                        in: imageRect,
                        canvasSize: layout.canvasSize,
                        context: context,
                        colorSpace: colorSpace
                    )
                    AnnotationBackgroundRenderer.drawWatermark(
                        backgroundSettings.watermark,
                        in: CGRect(origin: .zero, size: layout.canvasSize),
                        context: context
                    )
                }
            } else {
                renderedImage = try renderAnnotatedImage(sourceURL: sourceURL, items: items, colorSpace: colorSpace)
            }

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            guard let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL,
                contentType.identifier as CFString,
                1,
                nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }

            var options: CFDictionary?
            if contentType != .png {
                options = [
                    kCGImageDestinationLossyCompressionQuality: ScreendropPreferences.compressionQuality
                ] as CFDictionary
            }

            CGImageDestinationAddImage(destination, renderedImage, options)

            guard CGImageDestinationFinalize(destination) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

    }

    private static func loadSourceImage(sourceURL: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(
            sourceURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
              let cgImage = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return cgImage
    }

    private static func renderAnnotatedImage(
        sourceURL: URL,
        items: [AnnotationItem],
        colorSpace: CGColorSpace
    ) throws -> CGImage {
        let cgImage = try loadSourceImage(sourceURL: sourceURL)

        let width = cgImage.width
        let height = cgImage.height

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
        context.draw(cgImage, in: fullRect)
        drawAnnotations(
            items,
            in: fullRect,
            canvasSize: fullRect.size,
            context: context,
            colorSpace: colorSpace
        )

        guard let renderedImage = context.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }

        return renderedImage
    }

    private static func drawAnnotations(
        _ items: [AnnotationItem],
        in imageRect: CGRect,
        canvasSize: CGSize,
        context: CGContext,
        colorSpace: CGColorSpace
    ) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for item in items {
            autoreleasepool {
                context.setStrokeColor(item.swatch.nsColor.cgColor)
                context.setFillColor(item.swatch.nsColor.cgColor)

                let lineWidth = renderedLineWidth(for: item, imageSize: imageRect.size)
                context.setLineWidth(lineWidth)

                switch item.tool {
                case .select:
                    return

                case .rectangle:
                    context.stroke(renderedRect(item.bounds, in: imageRect))

                case .filledRectangle:
                    let rect = renderedRect(item.bounds, in: imageRect)
                    context.addPath(CGPath(
                        roundedRect: rect,
                        cornerWidth: AnnotationFilledRectangleMetrics.cornerRadius(for: rect),
                        cornerHeight: AnnotationFilledRectangleMetrics.cornerRadius(for: rect),
                        transform: nil
                    ))
                    context.fillPath()

                case .ellipse:
                    context.strokeEllipse(in: renderedRect(item.bounds, in: imageRect))

                case .numberedCircle:
                    drawNumberedCircle(
                        item,
                        in: renderedRect(item.bounds, in: imageRect),
                        context: context
                    )

                case .pixelate:
                    applyPixelation(
                        in: renderedRect(item.bounds, in: imageRect),
                        context: context,
                        canvasSize: canvasSize,
                        colorSpace: colorSpace,
                        density: item.redactionDensity
                    )

                case .blur:
                    applyBlur(
                        in: renderedRect(item.bounds, in: imageRect),
                        context: context,
                        canvasSize: canvasSize,
                        density: item.redactionDensity
                    )

                case .text:
                    drawText(
                        item,
                        in: renderedRect(item.bounds, in: imageRect),
                        imageHeight: imageRect.height,
                        context: context
                    )

                case .line:
                    guard let first = item.points.first,
                          let last = item.points.last else {
                        return
                    }

                    let start = renderedPoint(first, in: imageRect)
                    let end = renderedPoint(last, in: imageRect)
                    context.beginPath()
                    context.move(to: start)
                    context.addLine(to: end)
                    context.strokePath()

                case .freehand:
                    drawFreehand(
                        points: item.points,
                        imageRect: imageRect,
                        context: context
                    )

                case .arrow:
                    guard let first = item.points.first,
                          let control = item.controlPoint,
                          let last = item.points.last,
                          let geometry = AnnotationArrowGeometry(
                            start: renderedPoint(first, in: imageRect),
                            control: renderedPoint(control, in: imageRect),
                            end: renderedPoint(last, in: imageRect),
                            lineWidth: lineWidth
                          ) else {
                        return
                    }

                    context.beginPath()
                    context.move(to: renderedPoint(first, in: imageRect))
                    context.addQuadCurve(to: geometry.tip, control: geometry.shaftControl)
                    context.strokePath()
                    drawArrowHead(geometry, context: context)
                }
            }
        }
    }

    private static func renderedRect(_ rect: CGRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + rect.minX * imageRect.width,
            y: imageRect.minY + (1 - rect.maxY) * imageRect.height,
            width: rect.width * imageRect.width,
            height: rect.height * imageRect.height
        )
    }

    private static func renderedPoint(_ point: CGPoint, in imageRect: CGRect) -> CGPoint {
        CGPoint(
            x: imageRect.minX + point.x * imageRect.width,
            y: imageRect.minY + (1 - point.y) * imageRect.height
        )
    }

    private static func drawArrowHead(_ geometry: AnnotationArrowGeometry, context: CGContext) {
        context.beginPath()
        context.move(to: geometry.firstWing)
        context.addLine(to: geometry.tip)
        context.addLine(to: geometry.secondWing)
        context.strokePath()
    }

    private static func drawNumberedCircle(_ item: AnnotationItem, in rect: CGRect, context: CGContext) {
        let diameter = min(rect.width, rect.height)
        guard diameter > 1 else { return }

        let outlineWidth = AnnotationNumberedCircleMetrics.outlineWidth(for: diameter)
        context.saveGState()
        context.setFillColor(item.swatch.nsColor.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(item.swatch.numberedCircleOutlineNSColor.cgColor)
        context.setLineWidth(outlineWidth)
        context.strokeEllipse(in: rect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2))
        context.restoreGState()

        let fontSize = AnnotationNumberedCircleMetrics.fontSize(for: diameter, text: item.text)
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: item.swatch.numberedCircleTextNSColor,
            .paragraphStyle: paragraphStyle
        ]
        let attributedText = NSAttributedString(string: item.text, attributes: attributes)
        let measuredRect = attributedText.boundingRect(
            with: CGSize(width: rect.width, height: rect.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textRect = CGRect(
            x: rect.minX,
            y: rect.midY - measuredRect.height / 2 - fontSize * 0.04,
            width: rect.width,
            height: measuredRect.height + 2
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributedText.draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawFreehand(points: [CGPoint], imageRect: CGRect, context: CGContext) {
        let renderedPoints = points.map { renderedPoint($0, in: imageRect) }
        guard let first = renderedPoints.first else { return }

        context.beginPath()
        context.move(to: first)
        guard renderedPoints.count > 1 else { return }

        if renderedPoints.count == 2 {
            context.addLine(to: renderedPoints[1])
            context.strokePath()
            return
        }

        for index in 1..<renderedPoints.count {
            let previous = renderedPoints[index - 1]
            let current = renderedPoints[index]
            context.addQuadCurve(to: midpoint(previous, current), control: previous)
        }

        context.addLine(to: renderedPoints[renderedPoints.count - 1])
        context.strokePath()
    }

    private static func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }

    private static func drawText(
        _ item: AnnotationItem,
        in rect: CGRect,
        imageHeight: CGFloat,
        context: CGContext
    ) {
        let text = item.text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty,
              rect.width > 1,
              rect.height > 1 else {
            return
        }

        let fontSize = AnnotationTextMetrics.renderedFontSize(
            lineHeight: item.textLineHeight,
            imagePixelHeight: imageHeight
        )
        let font = item.resolvedFont(size: fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = item.textAlignment
        paragraphStyle.lineBreakMode = .byClipping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: item.swatch.nsColor,
            .paragraphStyle: paragraphStyle,
            .shadow: AnnotationTextMetrics.textShadow
        ]
        if item.isUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        let attributedText = NSAttributedString(string: text, attributes: attributes)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributedText.draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func applyPixelation(
        in rect: CGRect,
        context: CGContext,
        canvasSize: CGSize,
        colorSpace: CGColorSpace,
        density: CGFloat
    ) {
        let targetRect = rect.integral.intersection(CGRect(origin: .zero, size: canvasSize))
        guard targetRect.width >= 1,
              targetRect.height >= 1,
              let currentImage = context.makeImage(),
              let croppedImage = currentImage.cropping(to: imageCropRect(for: targetRect, imageHeight: CGFloat(currentImage.height))) else {
            return
        }

        let pixelSize = RedactionImageProcessor.pixelBlockSize(for: density)
        let lowWidth = max(1, Int(targetRect.width / pixelSize))
        let lowHeight = max(1, Int(targetRect.height / pixelSize))

        guard let lowContext = CGContext(
            data: nil,
            width: lowWidth,
            height: lowHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return
        }

        lowContext.interpolationQuality = .medium
        lowContext.draw(croppedImage, in: CGRect(x: 0, y: 0, width: lowWidth, height: lowHeight))

        guard let pixelatedImage = lowContext.makeImage() else { return }

        context.saveGState()
        context.clip(to: targetRect)
        context.interpolationQuality = .none
        context.draw(pixelatedImage, in: targetRect)
        context.restoreGState()
    }

    private static func applyBlur(
        in rect: CGRect,
        context: CGContext,
        canvasSize: CGSize,
        density: CGFloat
    ) {
        let targetRect = rect.integral.intersection(CGRect(origin: .zero, size: canvasSize))
        guard targetRect.width >= 1,
              targetRect.height >= 1,
              let currentImage = context.makeImage(),
              let croppedImage = currentImage.cropping(to: imageCropRect(for: targetRect, imageHeight: CGFloat(currentImage.height))) else {
            return
        }

        let inputImage = CIImage(cgImage: croppedImage)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = inputImage.clampedToExtent()
        filter.radius = Float(RedactionImageProcessor.blurRadius(for: density))

        guard let outputImage = filter.outputImage,
              let blurredImage = ciContext.createCGImage(outputImage, from: inputImage.extent) else {
            return
        }

        context.saveGState()
        context.clip(to: targetRect)
        context.draw(blurredImage, in: targetRect)
        context.restoreGState()
    }

    private static func renderedLineWidth(for item: AnnotationItem, imageSize: CGSize) -> CGFloat {
        max(1.5, item.strokeWidth * max(imageSize.width, imageSize.height) / 900)
    }

    private static func imageCropRect(for contextRect: CGRect, imageHeight: CGFloat) -> CGRect {
        CGRect(
            x: contextRect.minX,
            y: imageHeight - contextRect.maxY,
            width: contextRect.width,
            height: contextRect.height
        ).integral
    }
}
