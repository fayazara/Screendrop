//
//  StudioCameraBeauty.swift
//  Screendrop
//
//  Touch-ups for the talking head: a soft light on the face and smoother
//  skin. Vision finds each face's landmarks; masks drawn from them steer
//  a lift of the face's shadows and midtones, and an edge-preserving blur
//  over the skin - one `studioFaceTouchUp` kernel - with the eyes, brows
//  and lips cut out. The camera movie is never changed: the preview runs
//  the touch-up as the camera player's video composition, the export on
//  each decoded camera frame, through the same renderer.
//

import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal
import Vision

/// How much the camera is touched up. Both default to off.
nonisolated struct StudioCameraBeauty: Equatable, Sendable {
    /// 0...1: how much the face's shadows and midtones are lifted.
    var faceLight: CGFloat = 0
    /// 0...1: how much of the edge-preserving blur shows on the skin.
    var skinSmoothing: CGFloat = 0

    var isActive: Bool {
        faceLight > 0.005 || skinSmoothing > 0.005
    }
}

// MARK: - Face tracking

/// One face, in normalized image coordinates with the origin at the
/// bottom left - Vision's and Core Image's shared convention.
nonisolated struct StudioFaceShape {
    var box: CGRect
    /// The face's roll, from the line between the eyes, in radians.
    var angle: CGFloat
    /// The regions cut out of the skin mask, in `Region` order.
    var regions: [[CGPoint]]

    enum Region: Int, CaseIterable {
        case leftEye, rightEye, leftEyebrow, rightEyebrow, outerLips
    }

    /// The middle of an eye, or nil when Vision didn't find it.
    func center(of region: Region) -> CGPoint? {
        let points = points(region)
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    func points(_ region: Region) -> [CGPoint] {
        region.rawValue < regions.count ? regions[region.rawValue] : []
    }

    /// `self` moved `amount` of the way to `other`.
    func blended(toward other: StudioFaceShape, amount t: CGFloat) -> StudioFaceShape {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: mix(a.x, b.x), y: mix(a.y, b.y)) }
        let regions = zip(regions, other.regions).map { pair in
            pair.0.count == pair.1.count ? zip(pair.0, pair.1).map { mix($0, $1) } : pair.1
        }
        return StudioFaceShape(
            box: CGRect(
                x: mix(box.minX, other.box.minX), y: mix(box.minY, other.box.minY),
                width: mix(box.width, other.box.width), height: mix(box.height, other.box.height)
            ),
            angle: mix(angle, other.angle),
            regions: regions.count == other.regions.count ? regions : other.regions
        )
    }
}

/// Finds faces frame after frame, steadying them across frames so the
/// masks drawn from them don't shimmer. A jump in time starts afresh.
nonisolated final class StudioFaceTracker: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var faces: [StudioFaceShape] = []
    private var lastTime: TimeInterval?
    private var lastDetection: TimeInterval?

    /// Faces are found on a copy this many rows tall.
    private static let analysisHeight: CGFloat = 360
    /// The share of each new detection taken per frame.
    private static let steadying: CGFloat = 0.6
    /// A face Vision misses for a moment - a blink, a turn - is held this long.
    private static let holdDuration: TimeInterval = 0.4
    /// At most this many faces are touched up, largest first.
    private static let maximumFaces = 3

    /// `image` has its origin at zero.
    func faces(in image: CIImage, time: TimeInterval) -> [StudioFaceShape] {
        let isContinuous = lastTime.map { time >= $0 - 0.001 && time - $0 <= 0.25 } ?? false
        lastTime = time
        if !isContinuous {
            faces = []
            lastDetection = nil
        }

        let detected = detect(in: image)
        if detected.isEmpty {
            if let lastDetection, time - lastDetection <= Self.holdDuration { return faces }
            faces = []
            return []
        }
        lastDetection = time
        faces = detected.map { face in
            let center = CGPoint(x: face.box.midX, y: face.box.midY)
            let previous = faces.min { a, b in
                hypot(a.box.midX - center.x, a.box.midY - center.y)
                    < hypot(b.box.midX - center.x, b.box.midY - center.y)
            }
            guard let previous,
                  hypot(previous.box.midX - center.x, previous.box.midY - center.y) < face.box.width * 0.5
            else { return face }
            return previous.blended(toward: face, amount: Self.steadying)
        }
        return faces
    }

    private func detect(in image: CIImage) -> [StudioFaceShape] {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return [] }
        let scale = min(1, Self.analysisHeight / extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(ciImage: small, options: [.ciContext: context])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let aspect = extent.width / extent.height
        return (request.results ?? [])
            .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
            .prefix(Self.maximumFaces)
            .compactMap { observation in
                guard let landmarks = observation.landmarks else { return nil }
                let unit = CGSize(width: 1, height: 1)
                let regions: [[CGPoint]] = [
                    landmarks.leftEye, landmarks.rightEye,
                    landmarks.leftEyebrow, landmarks.rightEyebrow, landmarks.outerLips
                ].map { $0?.pointsInImage(imageSize: unit) ?? [] }
                var angle: CGFloat = 0
                let left = regions[StudioFaceShape.Region.leftEye.rawValue]
                let right = regions[StudioFaceShape.Region.rightEye.rawValue]
                if !left.isEmpty, !right.isEmpty {
                    let a = Self.centroid(left), b = Self.centroid(right)
                    // Measured in pixels, not the normalized square.
                    angle = atan2((b.y - a.y), (b.x - a.x) * aspect)
                    if abs(angle) > .pi / 2 { angle += angle > 0 ? -.pi : .pi }
                }
                return StudioFaceShape(box: observation.boundingBox, angle: angle, regions: regions)
            }
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}

// MARK: - Rendering

/// Touches up camera frames in order. Holds a face tracker, so one renderer
/// serves one sequence of frames; calls are serialized.
nonisolated final class StudioCameraBeautyRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private let tracker = StudioFaceTracker()

    /// Masks are drawn this many rows tall and scaled up; they're soft.
    private static let maskHeight: CGFloat = 360
    /// The face's grey in the light mask. The hollows under the eyes are
    /// drawn white, a third brighter, the way a soft key light reaches
    /// into them, which is most of what reads as "tired".
    private static let faceLightLevel: CGFloat = 0.75

    /// `image` touched up, over the same extent. `time` is the frame's own
    /// time, which tells the tracker when frames run on and when they jump.
    func apply(_ beauty: StudioCameraBeauty, to image: CIImage, time: TimeInterval) -> CIImage {
        guard beauty.isActive else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return image }
        let origin = extent.origin
        // Work in a zero-origin frame, where face coordinates are simple.
        let normalized = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        let size = extent.size
        let faces = lock.withLock { tracker.faces(in: normalized, time: time) }
        guard !faces.isEmpty, let masks = Self.masks(for: faces, imageSize: size) else { return image }

        let frame = CGRect(origin: .zero, size: size)
        let faceWidth = (faces.map(\.box.width).max() ?? 0) * size.width
        // A blemish is a few hundredths of a face across.
        let step = max(1, faceWidth * 0.008)
        let smoothing = min(max(beauty.skinSmoothing, 0), 1)
        // Eased, so the middle of the slider already does most of the work.
        let blend = 1 - (1 - smoothing) * (1 - smoothing)
        guard let result = try? StudioFaceTouchUpKernel.apply(
            withExtent: frame,
            inputs: [normalized.clampedToExtent(), masks.skin.clampedToExtent(), masks.light.clampedToExtent()],
            arguments: [
                "step": Float(step),
                "rangeSigma": Float(0.04 + 0.08 * smoothing),
                // Never all the way, and some fine texture always comes back,
                // so the skin doesn't read as plastic.
                "smoothing": Float(0.95 * blend),
                "grain": Float(0.6 - 0.3 * smoothing),
                // The light mask's face sits at `faceLightLevel`, so the
                // shadows under the eyes can take a little more; this puts
                // the face itself back at full strength.
                "light": Float(min(max(beauty.faceLight, 0), 1) / Self.faceLightLevel),
                "pad": smoothing > 0.005 ? ceil(step * 3) + 1 : 0
            ]
        ) else { return image }
        return result
            .cropped(to: frame)
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    /// The skin mask - the face with its eyes, brows and lips cut out - and
    /// the light mask - the face, fading down the neck so the two don't
    /// part at the jaw - both at `imageSize`.
    private static func masks(for faces: [StudioFaceShape], imageSize: CGSize) -> (skin: CIImage, light: CIImage)? {
        let scale = min(1, maskHeight / imageSize.height)
        let width = max(1, Int((imageSize.width * scale).rounded()))
        let height = max(1, Int((imageSize.height * scale).rounded()))
        let size = CGSize(width: width, height: height)
        let faceWidth = (faces.map(\.box.width).max() ?? 0) * size.width
        guard faceWidth > 1 else { return nil }

        guard let skin = drawMask(width: width, height: height, draw: { context in
            // Up to the hairline and out to the ears: the kernel itself
            // leaves hair and stubble alone, so the mask needn't stop short.
            for face in faces {
                fillEllipse(face, in: context, size: size, centerOffset: 0.12, radii: CGSize(width: 0.5, height: 0.7))
            }
            context.setFillColor(gray: 0, alpha: 1)
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            for face in faces {
                let width = face.box.width * size.width
                // Tight around the eyes, so the skin under them - where
                // smoothing is wanted most - is still smoothed.
                for region in [StudioFaceShape.Region.leftEye, .rightEye] {
                    trace(face.points(region), in: context, size: size, closed: true, lineWidth: width * 0.03)
                }
                for region in [StudioFaceShape.Region.leftEyebrow, .rightEyebrow] {
                    trace(face.points(region), in: context, size: size, closed: false, lineWidth: width * 0.06)
                }
                trace(face.points(.outerLips), in: context, size: size, closed: true, lineWidth: width * 0.04)
            }
        }), let light = drawMask(width: width, height: height, draw: { context in
            // Kept to the face, so the wall and shirt around it stay as lit
            // as they were.
            context.setFillColor(gray: faceLightLevel, alpha: 1)
            for face in faces {
                fillEllipse(face, in: context, size: size, centerOffset: 0.04, radii: CGSize(width: 0.47, height: 0.64))
            }
            context.setFillColor(gray: faceLightLevel * 0.6, alpha: 1)
            for face in faces {
                fillEllipse(face, in: context, size: size, centerOffset: -0.72, radii: CGSize(width: 0.3, height: 0.32))
            }
            context.setFillColor(gray: 1, alpha: 1)
            for face in faces {
                for eye in [StudioFaceShape.Region.leftEye, .rightEye] {
                    guard let center = face.center(of: eye) else { continue }
                    fillUnderEye(face, below: center, in: context, size: size)
                }
            }
        }) else { return nil }

        let upscale = CGAffineTransform(scaleX: imageSize.width / size.width, y: imageSize.height / size.height)
        let maskFrame = CGRect(origin: .zero, size: size)
        func soften(_ image: CGImage, sigma: CGFloat) -> CIImage {
            CIImage(cgImage: image, options: [.colorSpace: NSNull()])
                .clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: maskFrame)
                .transformed(by: upscale)
                .cropped(to: CGRect(origin: .zero, size: imageSize))
        }
        return (soften(skin, sigma: faceWidth * 0.02), soften(light, sigma: faceWidth * 0.06))
    }

    private static func drawMask(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        draw(context)
        return context.makeImage()
    }

    /// An ellipse turned with the face. `centerOffset` moves it up the face
    /// by a share of the face's height; `radii` are shares of its size.
    private static func fillEllipse(
        _ face: StudioFaceShape, in context: CGContext, size: CGSize, centerOffset: CGFloat, radii: CGSize
    ) {
        let width = face.box.width * size.width, height = face.box.height * size.height
        context.saveGState()
        context.translateBy(x: face.box.midX * size.width, y: face.box.midY * size.height)
        context.rotate(by: face.angle)
        let rx = width * radii.width, ry = height * radii.height
        context.fillEllipse(in: CGRect(x: -rx, y: height * centerOffset - ry, width: rx * 2, height: ry * 2))
        context.restoreGState()
    }

    /// The hollow under an eye: a flat ellipse just below its middle,
    /// turned with the face. The mask's blur feathers it into the cheek.
    private static func fillUnderEye(_ face: StudioFaceShape, below eye: CGPoint, in context: CGContext, size: CGSize) {
        let width = face.box.width * size.width, height = face.box.height * size.height
        context.saveGState()
        context.translateBy(x: eye.x * size.width, y: eye.y * size.height)
        context.rotate(by: face.angle)
        let rx = width * 0.13, ry = height * 0.05
        context.fillEllipse(in: CGRect(x: -rx, y: -height * 0.075 - ry, width: rx * 2, height: ry * 2))
        context.restoreGState()
    }

    private static func trace(_ points: [CGPoint], in context: CGContext, size: CGSize, closed: Bool, lineWidth: CGFloat) {
        guard points.count > 1 else { return }
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
        if closed {
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
        }
        context.addPath(path)
        context.setLineWidth(lineWidth)
        context.strokePath()
    }
}

/// The touch-up kernel run inside Core Image, so the touch-up stays one
/// Core Image graph for both the player and the export.
nonisolated final class StudioFaceTouchUpKernel: CIImageProcessorKernel {
    private struct Parameters {
        var offset: SIMD2<Int32>
        var step: Float
        var rangeSigma: Float
        var smoothing: Float
        var grain: Float
        var light: Float
    }

    enum KernelError: Error {
        case unavailable
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pipelines: [UInt64: MTLComputePipelineState] = [:]

    override class var outputFormat: CIFormat { .RGBAh }

    override class func formatForInput(at input: Int32) -> CIFormat {
        input == 0 ? .RGBAh : .R8
    }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        guard input == 0 else { return outputRect }
        let pad = arguments?["pad"] as? CGFloat ?? 0
        return outputRect.insetBy(dx: -pad, dy: -pad)
    }

    override class func process(
        with inputs: [any CIImageProcessorInput]?,
        arguments: [String: Any]?,
        output: any CIImageProcessorOutput
    ) throws {
        guard let inputs, inputs.count == 3,
              let source = inputs[0].metalTexture,
              let skin = inputs[1].metalTexture,
              let light = inputs[2].metalTexture,
              let destination = output.metalTexture,
              let commandBuffer = output.metalCommandBuffer,
              let pipeline = pipeline(for: commandBuffer.device),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { throw KernelError.unavailable }

        // The inputs are clamped, so the source arrives as exactly the
        // padded region asked for: the same margin on every side, whichever
        // way up the texture's rows run.
        var parameters = Parameters(
            offset: SIMD2(
                Int32((output.region.minX - inputs[0].region.minX).rounded()),
                Int32((inputs[0].region.maxY - output.region.maxY).rounded())
            ),
            step: arguments?["step"] as? Float ?? 1,
            rangeSigma: arguments?["rangeSigma"] as? Float ?? 0.05,
            smoothing: arguments?["smoothing"] as? Float ?? 0,
            grain: arguments?["grain"] as? Float ?? 0,
            light: arguments?["light"] as? Float ?? 0
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(skin, index: 1)
        encoder.setTexture(light, index: 2)
        encoder.setTexture(destination, index: 3)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / threadWidth))
        encoder.dispatchThreads(
            MTLSize(width: destination.width, height: destination.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
    }

    private static func pipeline(for device: MTLDevice) -> MTLComputePipelineState? {
        lock.withLock {
            if let pipeline = pipelines[device.registryID] { return pipeline }
            guard let function = device.makeDefaultLibrary()?.makeFunction(name: "studioFaceTouchUp"),
                  let pipeline = try? device.makeComputePipelineState(function: function)
            else { return nil }
            pipelines[device.registryID] = pipeline
            return pipeline
        }
    }
}

// MARK: - Preview

/// The touch-up the Studio's camera player shows, read from the player's
/// rendering thread.
nonisolated final class StudioCameraBeautyPreviewSource: @unchecked Sendable {
    private let lock = NSLock()
    private var beauty = StudioCameraBeauty()
    private let renderer = StudioCameraBeautyRenderer()

    func update(_ beauty: StudioCameraBeauty) {
        lock.withLock { self.beauty = beauty }
    }

    /// A composition that touches up every frame the camera player shows,
    /// on the camera movie's own clock.
    func makeVideoComposition(for asset: AVAsset) -> AVVideoComposition {
        let composition = AVMutableVideoComposition(asset: asset) { [self] request in
            let beauty = lock.withLock { self.beauty }
            let image = renderer.apply(beauty, to: request.sourceImage, time: request.compositionTime.seconds)
            request.finish(with: image, context: nil)
        }
        // Rendered frames are RGB. Left to itself the composition tags them
        // with the camera's video 709 curve, which AVPlayerLayer draws
        // darker and warmer than the same picture as untouched YUV video:
        // turning on any touch-up tinted the whole camera, wall and all.
        // sRGB is read the same way everywhere, so only the face changes.
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_IEC_sRGB
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return composition
    }
}

// MARK: - Export

/// Touches up the exporter's decoded camera frames, in order.
nonisolated final class StudioCameraBeautyFrameFilter: @unchecked Sendable {
    private let beauty: StudioCameraBeauty
    private let renderer = StudioCameraBeautyRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int)?

    init?(beauty: StudioCameraBeauty) {
        guard beauty.isActive else { return nil }
        self.beauty = beauty
    }

    /// `buffer` touched up, or `buffer` itself when that fails.
    func apply(to buffer: CVPixelBuffer, time: TimeInterval) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let output = makeBuffer(width: width, height: height) else { return buffer }
        let image = renderer.apply(beauty, to: CIImage(cvPixelBuffer: buffer), time: time)
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue()
            ?? CGColorSpace(name: CGColorSpace.sRGB)
        do {
            // Metal reads this buffer next, so the render must be complete.
            try context.startTask(toRender: image, to: destination).waitUntilCompleted()
        } catch {
            return buffer
        }
        CVBufferPropagateAttachments(buffer, output)
        return output
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if poolSize?.width != width || poolSize?.height != height {
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ] as CFDictionary, &created)
            pool = created
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }
}
