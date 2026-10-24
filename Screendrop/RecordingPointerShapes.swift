//
//  RecordingPointerShapes.swift
//  Screendrop
//
//  Screendrop's own vector pointers. The Studio cursor style swaps the
//  recorded macOS arrow for one of them, and the pointing hand always becomes
//  the vector hand: macOS ships that cursor at 64 px at most, which turns soft
//  once an export scales it up. A circle style stands in for every cursor.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// The arrow drawn for a synthesized pointer. `.system` keeps the arrow macOS
/// handed over during the recording.
nonisolated enum RecordingCursorStyle: String, Codable, CaseIterable, Sendable {
    case system
    case pointer
    case rounded
    case sharp
    case triangle
    case transparent
    case frosted

    /// Projects saved with a style this build no longer has open on the
    /// macOS arrow instead of failing to load.
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = RecordingCursorStyle(rawValue: rawValue) ?? .system
    }

    var title: String {
        switch self {
        case .system: "macOS"
        case .pointer: "Pointer"
        case .rounded: "Rounded"
        case .sharp: "Sharp"
        case .triangle: "Triangle"
        case .transparent: "Transparent"
        case .frosted: "Frosted"
        }
    }

    var shape: PointerShape? {
        switch self {
        case .system: nil
        case .pointer: .pointer
        case .rounded: .rounded
        case .sharp: .sharp
        case .triangle: .triangle
        case .transparent: .transparent
        case .frosted: .frosted
        }
    }
}

/// What a circle pointer does to the video beneath it. The artwork carries
/// only its tint and rim; the renderer draws this inside the circle first.
nonisolated enum PointerMaterial: Sendable {
    /// The blurred, lightened backdrop of macOS window chrome.
    case frosted
}

nonisolated enum PointerShape: String, CaseIterable, Sendable {
    case pointer
    case rounded
    case sharp
    case triangle
    case hand
    case transparent
    case frosted

    init?(artworkID: String) {
        guard artworkID.hasPrefix("shape-") else { return nil }
        var name = artworkID.dropFirst("shape-".count)
        if name.hasSuffix(Self.invertedSuffix) {
            name = name.dropLast(Self.invertedSuffix.count)
        }
        self.init(rawValue: String(name))
    }

    private static let invertedSuffix = "-inverted"

    var isCircle: Bool {
        switch self {
        case .transparent, .frosted: true
        default: false
        }
    }

    var material: PointerMaterial? {
        switch self {
        case .frosted: .frosted
        default: nil
        }
    }

    /// The circle's radius as a fraction of the artwork's side.
    static let circleRadiusRatio = circleRadius / canvas
    private static let circleRadius: CGFloat = 100

    /// Rendered once per shape, large enough to only ever be scaled down.
    var artwork: PointerArtwork? { Self.artworks[self] }

    /// Black inside a white outline. Circles have no inverted form.
    func artwork(inverted: Bool) -> PointerArtwork? {
        inverted && !isCircle ? Self.invertedArtworks[self] : artwork
    }

    private static let artworks: [PointerShape: PointerArtwork] = Dictionary(
        uniqueKeysWithValues: allCases.compactMap { shape in
            shape.render(inverted: false).map { (shape, $0) }
        }
    )

    private static let invertedArtworks: [PointerShape: PointerArtwork] = Dictionary(
        uniqueKeysWithValues: allCases.filter { !$0.isCircle }.compactMap { shape in
            shape.render(inverted: true).map { (shape, $0) }
        }
    )

    /// Every drawing sits on a 256-unit square, as exported from Figma.
    private static let canvas: CGFloat = 256
    private static let pixelSize = 512

    /// The artwork's side in the points macOS uses for cursor images, so a
    /// vector pointer draws at the size of the system cursor it replaces.
    private var pointSize: CGFloat {
        if isCircle { return 26 }
        return self == .hand ? 24 : 22
    }

    /// The tip, in canvas units with a top-left origin.
    private var hotSpot: CGPoint {
        switch self {
        case .pointer: CGPoint(x: 31, y: 31)
        case .rounded: CGPoint(x: 27, y: 27)
        case .sharp: CGPoint(x: 29, y: 29)
        case .triangle: CGPoint(x: 39, y: 39)
        case .hand: CGPoint(x: 78, y: 30)
        case .transparent, .frosted: CGPoint(x: Self.canvas / 2, y: Self.canvas / 2)
        }
    }

    private var outlines: [Outline] {
        switch self {
        case .pointer:
            [Outline(fills: true, lineWidth: 15, isRound: false, path: """
            M28.4293 42.1989L71.8128 192.919C73.8686 202.22 82.0364 209.765 92.1599 211.166L94.0491 211.343C98.3822 211.603 102.706 210.705 106.577 208.74C110.448 206.775 113.726 203.815 116.074 200.164L116.574 199.297L132.132 176.272L177.138 221.278C179.271 223.412 181.804 225.105 184.591 226.261C187.379 227.416 190.367 228.01 193.384 228.01C196.402 228.01 199.39 227.416 202.177 226.261C204.965 225.105 207.498 223.412 209.631 221.278L221.266 209.643C225.577 205.332 228 199.497 228 193.408L227.911 191.385C227.435 186.011 225.083 180.975 221.266 177.161L176.293 132.177L199.663 116.486C207.731 112.208 212.776 102.285 211.364 92.1611C210.679 87.2242 208.502 82.6147 205.123 78.9503C201.745 75.2859 197.327 72.7416 192.462 71.6584L42.1756 28.4305C40.2659 27.8829 38.2444 27.8573 36.3215 28.3562C34.3986 28.8552 32.6446 29.8605 31.2421 31.2675C29.8396 32.6745 28.84 34.4317 28.3473 36.3563C27.8545 38.2808 27.8867 40.3022 28.4404 42.2101L28.4293 42.1989Z
            """)]
        case .rounded:
            [Outline(fills: true, lineWidth: 15, isRound: false, path: """
            M20.6987 56.5037C12.718 34.2359 34.2358 12.718 56.5036 20.6986L219.43 79.0907C242.88 87.4951 244.504 120.039 222.006 130.736L181.017 150.225C167.518 156.644 156.644 167.518 150.226 181.016L130.736 222.007C120.039 244.504 87.4952 242.88 79.0908 219.43L20.6987 56.5037Z
            """)]
        case .sharp:
            [Outline(fills: true, lineWidth: 15, isRound: false, path: """
            M28.2912 38.9156L28.2335 37.8722L28.3138 36.5928L28.4723 35.7071L28.8183 34.4969L29.2724 33.4443L29.8346 32.4608L30.4951 31.5758L31.2343 30.7696L31.8156 30.2585L32.9584 29.4528L33.9039 28.9421C34.8887 28.4807 35.9324 28.1868 37.0152 28.0601L38.0586 28.0122C38.7967 28.0131 39.525 28.0927 40.2236 28.2511L41.4338 28.5971L219.278 93.1068C221.93 94.3288 224.175 96.2861 225.747 98.7462C227.32 101.206 228.153 104.066 228.149 106.986C228.154 109.615 227.478 112.202 226.187 114.492C224.895 116.783 223.033 118.7 220.78 120.057L219.53 120.696L159.488 150.633C155.617 152.563 152.476 155.697 150.536 159.563L120.609 219.216C119.495 221.644 117.764 223.737 115.587 225.285C113.41 226.833 110.866 227.783 108.207 228.039L106.74 228.097C101.228 228.09 96.1926 225.121 93.266 219.803L92.5787 218.424L28.7611 41.0126L28.4671 39.9689L28.2912 38.9156Z
            """)]
        case .triangle:
            [Outline(fills: true, lineWidth: 15, isRound: false, path: """
            M34.9984 51.7987C31.5201 39.7099 42.7099 28.5201 54.7987 31.9984L221.466 79.953C234.78 83.7836 237.294 101.669 225.836 109.457C176.203 143.195 145.372 173.444 112.534 222.153C104.736 233.719 86.6395 231.279 82.7824 217.873L34.9984 51.7987Z
            """)]
        case .hand:
            [
                Outline(fills: true, lineWidth: 12.5, isRound: true, path: """
                M66.0227 186.018C62.0664 180.743 58.1102 171.512 50.1977 159.643C46.2414 153.05 34.3727 139.862 30.4164 134.587C27.7789 129.312 27.7789 126.675 29.0977 121.4C30.4164 113.487 38.3289 106.893 47.5602 106.893C54.1539 106.893 60.7477 112.168 66.0227 116.125C68.6602 118.762 72.6164 124.037 75.2539 126.675C77.8914 129.312 77.8914 130.631 80.5289 133.268C83.1664 137.225 84.4852 139.862 83.1664 134.587C81.8477 127.993 80.5289 117.443 77.8914 106.893C76.5727 98.9808 75.2539 97.662 73.9352 92.387C72.6164 85.7933 71.2977 81.837 69.9789 75.2433C68.6602 71.287 67.3414 60.737 66.0227 55.462C64.7039 48.8683 64.7039 36.9995 69.9789 31.7245C73.9352 27.7683 81.8477 26.4495 87.1227 29.087C93.7164 33.0433 97.6727 42.2745 98.9914 46.2308C101.629 52.8245 104.266 62.0558 105.585 72.6058C108.223 85.7933 112.179 105.575 112.179 109.531C112.179 104.256 110.86 95.0245 112.179 89.7495C113.498 85.7933 116.135 80.5183 121.41 79.1995C125.366 77.8808 129.323 77.8808 133.279 77.8808C137.235 79.1995 141.191 81.837 143.829 84.4745C149.104 92.387 149.104 109.531 149.104 108.212C150.423 102.937 150.423 92.387 153.06 87.112C154.379 84.4745 159.654 81.837 162.291 80.5183C166.248 79.1995 171.523 79.1995 175.479 80.5183C178.116 80.5183 183.391 84.4745 184.71 87.112C187.348 91.0683 188.666 104.256 189.985 109.531C189.985 110.85 191.304 104.256 193.941 100.3C199.216 92.387 217.679 89.7495 218.998 108.212C218.998 117.443 218.998 116.125 218.998 122.718C218.998 129.312 218.998 133.268 218.998 138.543C218.998 143.818 217.679 155.687 216.36 160.962C215.041 164.918 211.085 174.15 207.129 179.425C207.129 179.425 192.623 195.25 191.304 203.162C189.985 211.075 189.985 211.075 189.985 216.35C189.985 221.625 191.304 228.218 191.304 228.218C191.304 228.218 180.754 229.537 175.479 228.218C170.204 226.9 163.61 217.668 162.291 213.712C159.654 209.756 155.698 209.756 153.06 213.712C150.423 218.987 143.829 228.218 138.554 228.218C129.323 229.537 110.86 228.218 97.6727 228.218C97.6727 228.218 100.31 215.031 95.0352 209.756C91.0789 205.8 84.4852 199.206 80.5289 195.25L66.0227 186.018Z
                """),
                Outline(fills: false, lineWidth: 12.5, isRound: true, path: "M175.47 189.979V145.142"),
                Outline(fills: false, lineWidth: 12.5, isRound: true, path: "M149.1 189.979L147.781 145.142"),
                Outline(fills: false, lineWidth: 12.5, isRound: true, path: "M122.72 145.142V189.979")
            ]
        case .transparent, .frosted:
            []
        }
    }

    /// White fill and black outline, or the reverse, under the 15% drop
    /// shadow from the Figma export, encoded the way captured cursors are.
    private func render(inverted: Bool) -> PointerArtwork? {
        let pixelSize = Self.pixelSize
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelSize,
                height: pixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        let scale = CGFloat(pixelSize) / Self.canvas
        context.translateBy(x: 0, y: CGFloat(pixelSize))
        context.scaleBy(x: scale, y: -scale)
        if isCircle {
            drawCircle(in: context, scale: scale)
        } else {
            drawOutlines(in: context, scale: scale, inverted: inverted)
        }

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let points = pointSize / Self.canvas
        return PointerArtwork(
            artworkID: "shape-\(rawValue)" + (inverted ? Self.invertedSuffix : ""),
            imageData: data as Data,
            anchorPoint: PointerArtwork.Point(
                x: Double(hotSpot.x * points),
                y: Double(hotSpot.y * points)
            ),
            referenceSize: PointerArtwork.Size(
                width: Double(pointSize),
                height: Double(pointSize)
            )
        )
    }
}

nonisolated extension PointerShape {
    private func drawOutlines(in context: CGContext, scale: CGFloat, inverted: Bool) {
        // The shadow ignores the transform, so it is set in pixels.
        context.setShadow(
            offset: .zero,
            blur: 4 * scale,
            color: CGColor(gray: 0, alpha: 0.15)
        )
        context.setMiterLimit(4)
        context.setFillColor(CGColor(gray: inverted ? 0 : 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: inverted ? 1 : 0, alpha: 1))

        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for outline in outlines {
            let path = SVGPathData.path(outline.path)
            if outline.fills {
                context.addPath(path)
                context.fillPath()
            }
            context.setLineWidth(outline.lineWidth)
            context.setLineCap(outline.isRound ? .round : .butt)
            context.setLineJoin(outline.isRound ? .round : .miter)
            context.addPath(path)
            context.strokePath()
        }
        context.endTransparencyLayer()
    }

    /// A shadow that stays outside the disc, so a see-through fill doesn't
    /// darken, then the fill and rim for each look.
    private func drawCircle(in context: CGContext, scale: CGFloat) {
        let radius = Self.circleRadius
        let center = Self.canvas / 2
        let disc = CGRect(x: center - radius, y: center - radius, width: radius * 2, height: radius * 2)

        // Cast from a copy off the canvas, then clear what falls inside.
        let shift = Self.canvas * 2
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: shift * scale, height: 0),
            blur: (self == .transparent ? 6 : 12) * scale,
            color: CGColor(gray: 0, alpha: self == .transparent ? 0.2 : 0.28)
        )
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillEllipse(in: disc.offsetBy(dx: -shift, dy: 0))
        context.restoreGState()
        context.saveGState()
        context.setBlendMode(.clear)
        context.fillEllipse(in: disc)
        context.restoreGState()

        switch self {
        case .transparent:
            // A soft white ball, lit a little from the top left and greying
            // toward its edge, with the video faintly showing through.
            context.saveGState()
            context.addEllipse(in: disc)
            context.clip()
            let colors = [
                CGColor(gray: 1, alpha: 0.88),
                CGColor(gray: 0.95, alpha: 0.82),
                CGColor(gray: 0.8, alpha: 0.78)
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 0.55, 1]) {
                context.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: center - radius * 0.2, y: center - radius * 0.25),
                    startRadius: 0,
                    endCenter: CGPoint(x: center, y: center),
                    endRadius: radius,
                    options: []
                )
            }
            context.restoreGState()
        case .frosted:
            context.setFillColor(CGColor(gray: 1, alpha: 0.22))
            context.fillEllipse(in: disc)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.6))
            context.setLineWidth(3)
            context.strokeEllipse(in: disc.insetBy(dx: 1.5, dy: 1.5))
        default:
            break
        }
    }
}

/// Draws a circle pointer's material for export, from the frame pixels
/// already in the context. The preview uses the system's own materials.
nonisolated final class PointerMaterialRenderer {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// `center` and `radius` are in the context's pixels, bottom-up, with an
    /// identity transform.
    func draw(_ material: PointerMaterial, center: CGPoint, radius: CGFloat, in context: CGContext) {
        guard radius >= 1,
              let backdrop = Backdrop(around: center, reach: radius * 1.6, in: context),
              let source = backdrop.image() else {
            return
        }
        let blurred: CIImage
        switch material {
        case .frosted:
            blurred = CIImage(cgImage: source).clampedToExtent()
                .applyingGaussianBlur(sigma: radius * 0.45)
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1.6,
                    kCIInputBrightnessKey: 0.06
                ])
        }
        let extent = CGRect(origin: .zero, size: backdrop.rect.size)
        guard let image = ciContext.createCGImage(
            blurred.cropped(to: extent),
            from: extent,
            format: .BGRA8,
            colorSpace: context.colorSpace
        ) else {
            return
        }

        context.saveGState()
        context.addEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.clip()
        context.draw(image, in: backdrop.rect)
        context.restoreGState()
    }
}

/// A copy of the frame's pixels around a point; only the small square is
/// read, never the whole frame. Rows run top-down, as in memory.
nonisolated private struct Backdrop {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    /// Where the copy sits in the context, bottom-up.
    let rect: CGRect
    private let colorSpace: CGColorSpace
    private let bitmapInfo: CGBitmapInfo

    init?(around center: CGPoint, reach: CGFloat, in context: CGContext) {
        guard context.bitsPerPixel == 32,
              let colorSpace = context.colorSpace,
              let base = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        let bounds = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        let rect = CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2)
            .integral
            .intersection(bounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }

        width = Int(rect.width)
        height = Int(rect.height)
        self.rect = rect
        self.colorSpace = colorSpace
        bitmapInfo = context.bitmapInfo

        let rowBytes = width * 4
        let sourceRowBytes = context.bytesPerRow
        // The rect's top edge is its maxY.
        let firstRow = context.height - Int(rect.maxY)
        let minX = Int(rect.minX)
        let rows = height
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let destination = buffer.baseAddress else { return }
            for row in 0..<rows {
                let source = base + (firstRow + row) * sourceRowBytes + minX * 4
                (destination + row * rowBytes).copyMemory(from: source, byteCount: rowBytes)
            }
        }
        self.pixels = pixels
    }

    func image() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

nonisolated private struct Outline {
    var fills: Bool
    var lineWidth: CGFloat
    /// Round caps and joins, as the hand is drawn; the arrows keep sharp miters.
    var isRound: Bool
    var path: String
}

/// Reads the absolute M, L, H, V, C and Z commands Figma writes into path data.
nonisolated private enum SVGPathData {
    static func path(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Tokens(data)
        var command: Character = "M"
        var current = CGPoint.zero

        while let token = scanner.next() {
            switch token {
            case .command(let letter):
                command = letter
                if letter == "Z" {
                    path.closeSubpath()
                }
                continue
            case .number(let first):
                switch command {
                case "M":
                    current = CGPoint(x: first, y: scanner.number())
                    path.move(to: current)
                    // Further pairs after a move are lines.
                    command = "L"
                case "L":
                    current = CGPoint(x: first, y: scanner.number())
                    path.addLine(to: current)
                case "H":
                    current.x = first
                    path.addLine(to: current)
                case "V":
                    current.y = first
                    path.addLine(to: current)
                case "C":
                    let control1 = CGPoint(x: first, y: scanner.number())
                    let control2 = CGPoint(x: scanner.number(), y: scanner.number())
                    current = CGPoint(x: scanner.number(), y: scanner.number())
                    path.addCurve(to: current, control1: control1, control2: control2)
                default:
                    assertionFailure("Unsupported SVG path command \(command)")
                    return path
                }
            }
        }
        return path
    }

    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    private struct Tokens {
        private let characters: [Character]
        private var index = 0

        init(_ data: String) {
            characters = Array(data)
        }

        mutating func number() -> CGFloat {
            if case .number(let value) = next() { return value }
            return 0
        }

        mutating func next() -> Token? {
            while index < characters.count,
                  characters[index] == " " || characters[index] == "," || characters[index].isNewline {
                index += 1
            }
            guard index < characters.count else { return nil }

            let character = characters[index]
            if character.isLetter {
                index += 1
                return .command(character)
            }

            let start = index
            index += 1
            while index < characters.count,
                  characters[index].isNumber || characters[index] == "." {
                index += 1
            }
            return .number(CGFloat(Double(String(characters[start..<index])) ?? 0))
        }
    }
}
