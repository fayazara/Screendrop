//
//  AnnotationBackground.swift
//  OpenShot
//
//  Created by Codex on 28/04/26.
//

import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

struct AnnotationBackgroundSettings: Equatable {
    var style: AnnotationBackgroundStyle = .none
    var padding: CGFloat = 0.16
    var cornerRadius: CGFloat = 0.035
    var shadow: CGFloat = 0.36
    var aspectRatio: AnnotationBackgroundAspectRatio = .auto
    var alignment: AnnotationBackgroundAlignment = .center
    var customWallpaper: AnnotationCustomWallpaper?

    var isEnabled: Bool {
        style != .none
    }
}

enum AnnotationBackgroundStyle: Equatable {
    case none
    case solid(AnnotationBackgroundColor)
    case gradient(AnnotationBackgroundGradient)
    case customWallpaper(AnnotationCustomWallpaper)
}

struct AnnotationBackgroundColor: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(_ id: String, title: String, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.id = id
        self.title = title
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    static let black = AnnotationBackgroundColor("black", title: "Black", red: 0.02, green: 0.02, blue: 0.024)
    static let white = AnnotationBackgroundColor("white", title: "White", red: 0.96, green: 0.96, blue: 0.94)
    static let graphite = AnnotationBackgroundColor("graphite", title: "Graphite", red: 0.17, green: 0.18, blue: 0.21)
    static let red = AnnotationBackgroundColor("red", title: "Red", red: 0.94, green: 0.23, blue: 0.28)
    static let orange = AnnotationBackgroundColor("orange", title: "Orange", red: 0.97, green: 0.52, blue: 0.16)
    static let yellow = AnnotationBackgroundColor("yellow", title: "Yellow", red: 0.96, green: 0.73, blue: 0.23)
    static let green = AnnotationBackgroundColor("green", title: "Green", red: 0.23, green: 0.61, blue: 0.36)
    static let blue = AnnotationBackgroundColor("blue", title: "Blue", red: 0.16, green: 0.50, blue: 0.88)
    static let purple = AnnotationBackgroundColor("purple", title: "Purple", red: 0.48, green: 0.26, blue: 0.91)
    static let blush = AnnotationBackgroundColor("blush", title: "Blush", red: 0.93, green: 0.66, blue: 0.62)
    static let mint = AnnotationBackgroundColor("mint", title: "Mint", red: 0.66, green: 0.90, blue: 0.73)
    static let sky = AnnotationBackgroundColor("sky", title: "Sky", red: 0.63, green: 0.79, blue: 0.94)

    static let plainPresets: [AnnotationBackgroundColor] = [
        .black, .white, .graphite, .red, .orange, .yellow,
        .green, .blue, .purple, .blush, .mint, .sky
    ]
}

struct AnnotationBackgroundGradient: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let colors: [AnnotationBackgroundColor]
    let startPoint: UnitPoint
    let endPoint: UnitPoint

    static let presets: [AnnotationBackgroundGradient] = [
        AnnotationBackgroundGradient(
            id: "aurora",
            title: "Aurora",
            colors: [
                AnnotationBackgroundColor("aurora-a", title: "Aurora A", red: 0.98, green: 0.31, blue: 0.58),
                AnnotationBackgroundColor("aurora-b", title: "Aurora B", red: 0.40, green: 0.32, blue: 0.95),
                AnnotationBackgroundColor("aurora-c", title: "Aurora C", red: 0.29, green: 0.84, blue: 0.80)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ),
        AnnotationBackgroundGradient(
            id: "cobalt",
            title: "Cobalt",
            colors: [
                AnnotationBackgroundColor("cobalt-a", title: "Cobalt A", red: 0.04, green: 0.05, blue: 0.50),
                AnnotationBackgroundColor("cobalt-b", title: "Cobalt B", red: 0.26, green: 0.19, blue: 0.93),
                AnnotationBackgroundColor("cobalt-c", title: "Cobalt C", red: 0.42, green: 0.67, blue: 0.98)
            ],
            startPoint: .top,
            endPoint: .bottomTrailing
        ),
        AnnotationBackgroundGradient(
            id: "peach",
            title: "Peach",
            colors: [
                AnnotationBackgroundColor("peach-a", title: "Peach A", red: 0.98, green: 0.38, blue: 0.36),
                AnnotationBackgroundColor("peach-b", title: "Peach B", red: 0.99, green: 0.71, blue: 0.36),
                AnnotationBackgroundColor("peach-c", title: "Peach C", red: 0.90, green: 0.33, blue: 0.65)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ),
        AnnotationBackgroundGradient(
            id: "glass",
            title: "Glass",
            colors: [
                AnnotationBackgroundColor("glass-a", title: "Glass A", red: 0.87, green: 0.95, blue: 0.94),
                AnnotationBackgroundColor("glass-b", title: "Glass B", red: 0.46, green: 0.77, blue: 0.86),
                AnnotationBackgroundColor("glass-c", title: "Glass C", red: 0.25, green: 0.53, blue: 0.93)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ),
        AnnotationBackgroundGradient(
            id: "plasma",
            title: "Plasma",
            colors: [
                AnnotationBackgroundColor("plasma-a", title: "Plasma A", red: 0.08, green: 0.02, blue: 0.22),
                AnnotationBackgroundColor("plasma-b", title: "Plasma B", red: 0.35, green: 0.12, blue: 0.84),
                AnnotationBackgroundColor("plasma-c", title: "Plasma C", red: 0.95, green: 0.26, blue: 0.42)
            ],
            startPoint: .topTrailing,
            endPoint: .bottomLeading
        ),
        AnnotationBackgroundGradient(
            id: "mango",
            title: "Mango",
            colors: [
                AnnotationBackgroundColor("mango-a", title: "Mango A", red: 0.99, green: 0.75, blue: 0.20),
                AnnotationBackgroundColor("mango-b", title: "Mango B", red: 0.96, green: 0.33, blue: 0.21),
                AnnotationBackgroundColor("mango-c", title: "Mango C", red: 0.67, green: 0.19, blue: 0.89)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ),
        AnnotationBackgroundGradient(
            id: "mist",
            title: "Mist",
            colors: [
                AnnotationBackgroundColor("mist-a", title: "Mist A", red: 0.94, green: 0.94, blue: 0.92),
                AnnotationBackgroundColor("mist-b", title: "Mist B", red: 0.80, green: 0.88, blue: 0.94),
                AnnotationBackgroundColor("mist-c", title: "Mist C", red: 0.95, green: 0.76, blue: 0.70)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ),
        AnnotationBackgroundGradient(
            id: "lagoon",
            title: "Lagoon",
            colors: [
                AnnotationBackgroundColor("lagoon-a", title: "Lagoon A", red: 0.08, green: 0.30, blue: 0.54),
                AnnotationBackgroundColor("lagoon-b", title: "Lagoon B", red: 0.25, green: 0.64, blue: 0.72),
                AnnotationBackgroundColor("lagoon-c", title: "Lagoon C", red: 0.70, green: 0.92, blue: 0.78)
            ],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    ]
}

struct AnnotationCustomWallpaper: Identifiable, Equatable, Hashable {
    let url: URL

    var id: String {
        url.path
    }

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }
}

enum AnnotationBackgroundAspectRatio: String, CaseIterable, Identifiable {
    case auto
    case square
    case fourThree
    case threeTwo
    case sixteenNine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .threeTwo: "3:2"
        case .sixteenNine: "16:9"
        }
    }

    var value: CGFloat? {
        switch self {
        case .auto: nil
        case .square: 1
        case .fourThree: 4 / 3
        case .threeTwo: 3 / 2
        case .sixteenNine: 16 / 9
        }
    }
}

enum AnnotationBackgroundAlignment: String, CaseIterable, Identifiable {
    case topLeading
    case top
    case topTrailing
    case leading
    case center
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeading: "Top left"
        case .top: "Top"
        case .topTrailing: "Top right"
        case .leading: "Left"
        case .center: "Center"
        case .trailing: "Right"
        case .bottomLeading: "Bottom left"
        case .bottom: "Bottom"
        case .bottomTrailing: "Bottom right"
        }
    }

    var xFactor: CGFloat {
        switch self {
        case .topLeading, .leading, .bottomLeading:
            0
        case .top, .center, .bottom:
            0.5
        case .topTrailing, .trailing, .bottomTrailing:
            1
        }
    }

    var yFactor: CGFloat {
        switch self {
        case .topLeading, .top, .topTrailing:
            0
        case .leading, .center, .trailing:
            0.5
        case .bottomLeading, .bottom, .bottomTrailing:
            1
        }
    }

    /// Whether the image sticks to the top edge (zero top padding).
    var sticksToTop: Bool {
        switch self {
        case .topLeading, .top, .topTrailing: true
        default: false
        }
    }

    /// Whether the image sticks to the bottom edge (zero bottom padding).
    var sticksToBottom: Bool {
        switch self {
        case .bottomLeading, .bottom, .bottomTrailing: true
        default: false
        }
    }

    /// Whether the image sticks to the leading (left) edge (zero left padding).
    var sticksToLeading: Bool {
        switch self {
        case .topLeading, .leading, .bottomLeading: true
        default: false
        }
    }

    /// Whether the image sticks to the trailing (right) edge (zero right padding).
    var sticksToTrailing: Bool {
        switch self {
        case .topTrailing, .trailing, .bottomTrailing: true
        default: false
        }
    }

    /// Per-corner radius multipliers. A corner that touches a stuck edge gets 0.
    /// Returns (topLeft, topRight, bottomLeft, bottomRight) multipliers (0 or 1).
    var cornerRadiusMultipliers: (topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
        switch self {
        case .center:
            (1, 1, 1, 1)
        case .top:
            (0, 0, 1, 1)
        case .bottom:
            (1, 1, 0, 0)
        case .leading:
            (0, 1, 0, 1)
        case .trailing:
            (1, 0, 1, 0)
        case .topLeading:
            (0, 0, 0, 1)
        case .topTrailing:
            (0, 0, 1, 0)
        case .bottomLeading:
            (0, 1, 0, 0)
        case .bottomTrailing:
            (1, 0, 0, 0)
        }
    }
}

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

enum AnnotationBackgroundRenderer {
    static func compose(
        annotatedImage: CGImage,
        settings: AnnotationBackgroundSettings,
        colorSpace: CGColorSpace
    ) throws -> CGImage {
        guard settings.isEnabled else { return annotatedImage }

        let contentSize = CGSize(width: annotatedImage.width, height: annotatedImage.height)
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
        // Note: CGContext uses flipped coordinates, so top/bottom are swapped
        let cornerRadii = PerCornerRadii(
            topLeft: baseCornerRadius * m.bottomLeft,
            topRight: baseCornerRadius * m.bottomRight,
            bottomLeft: baseCornerRadius * m.topLeft,
            bottomRight: baseCornerRadius * m.topRight
        )
        let clipPath = PerCornerRadii.path(in: imageRect, radii: cornerRadii)
        drawShadow(path: clipPath, strength: settings.shadow, context: context)

        context.saveGState()
        context.addPath(clipPath)
        context.clip()
        context.draw(annotatedImage, in: imageRect)
        context.restoreGState()

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

// MARK: - Per-Corner Radius Helpers

/// Holds per-corner radius values for a rounded rectangle.
struct PerCornerRadii: Equatable {
    let topLeft: CGFloat
    let topRight: CGFloat
    let bottomLeft: CGFloat
    let bottomRight: CGFloat

    var isUniform: Bool {
        topLeft == topRight && topRight == bottomLeft && bottomLeft == bottomRight
    }

    /// Creates a `CGPath` rounded rectangle with individual corner radii.
    static func path(in rect: CGRect, radii: PerCornerRadii) -> CGPath {
        let tl = min(radii.topLeft, min(rect.width, rect.height) / 2)
        let tr = min(radii.topRight, min(rect.width, rect.height) / 2)
        let bl = min(radii.bottomLeft, min(rect.width, rect.height) / 2)
        let br = min(radii.bottomRight, min(rect.width, rect.height) / 2)

        let path = CGMutablePath()

        // Start at top-left, after the top-left corner arc
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.maxY))

        // Top edge -> top-right corner
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.maxY))
        if tr > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - tr, y: rect.maxY - tr),
                radius: tr,
                startAngle: .pi / 2,
                endAngle: 0,
                clockwise: true
            )
        }

        // Right edge -> bottom-right corner
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + br))
        if br > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - br, y: rect.minY + br),
                radius: br,
                startAngle: 0,
                endAngle: -.pi / 2,
                clockwise: true
            )
        }

        // Bottom edge -> bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.minY))
        if bl > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + bl, y: rect.minY + bl),
                radius: bl,
                startAngle: -.pi / 2,
                endAngle: .pi,
                clockwise: true
            )
        }

        // Left edge -> top-left corner
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - tl))
        if tl > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + tl, y: rect.maxY - tl),
                radius: tl,
                startAngle: .pi,
                endAngle: .pi / 2,
                clockwise: true
            )
        }

        path.closeSubpath()
        return path
    }
}
