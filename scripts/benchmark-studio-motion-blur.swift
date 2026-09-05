import AVFoundation
// Compile this harness with StudioMetalScreenRenderer.swift; see docs/export-performance.md.
import AppKit
import CoreText
import CoreVideo
import ImageIO
import Metal
import UniformTypeIdentifiers

@main
struct MotionBlurBenchmark {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func buffer(_ width: Int, _ height: Int) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        precondition(
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &result) == kCVReturnSuccess)
        return result!
    }

    static func context(_ buffer: CVPixelBuffer) -> CGContext {
        CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space, bitmapInfo: info)!
    }

    static func fixture(_ width: Int, _ height: Int) -> CVPixelBuffer {
        let image = buffer(width, height)
        CVPixelBufferLockBaseAddress(image, [])
        let c = context(image)
        c.setFillColor(CGColor(srgbRed: 0.94, green: 0.95, blue: 0.98, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for y in stride(from: 0, to: height, by: 40) {
            for x in stride(from: 0, to: width, by: 80) {
                c.setFillColor(
                    CGColor(srgbRed: CGFloat((x / 80) % 5) / 5, green: CGFloat((y / 40) % 7) / 7, blue: 0.3, alpha: 1))
                c.fill(CGRect(x: x, y: y, width: 60, height: 28))
            }
        }
        // One-pixel features expose aliasing, edge filtering, and flips.
        c.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 20, to: width / 2, by: 5) {
            c.fill(CGRect(x: x, y: height / 2, width: 1, height: height / 4))
        }
        c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 70, height: 90))
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        c.fill(CGRect(x: width - 100, y: height - 120, width: 100, height: 120))
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        c.fill(CGRect(x: width / 5, y: height / 2 + height / 4 + 10, width: width / 2, height: 115))
        let font = CTFontCreateWithName("SFMono-Regular" as CFString, 18, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: CGColor(gray: 0.12, alpha: 1),
        ]
        for (i, text) in [
            "Screendrop • Screenshot and recording exports", "let shutter = 1.0 / 60.0",
            "Motion blur keeps all 24 temporal samples.",
        ].enumerated() {
            c.textPosition = CGPoint(x: width / 5 + 14, y: height / 2 + height / 4 + 95 - i * 30)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), c)
        }
        c.flush()
        CVPixelBufferUnlockBaseAddress(image, [])
        return image
    }

    static func reference(source: CGImage, backdrop: CGImage, rects: [CGRect], path: CGPath, into buffer: CVPixelBuffer)
    {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let c = context(buffer)
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        c.interpolationQuality = .high
        c.draw(backdrop, in: CGRect(origin: .zero, size: size))
        c.addPath(path)
        c.clip()
        for (i, rect) in rects.enumerated() {
            c.setAlpha(1 / CGFloat(i + 1))
            c.draw(source, in: CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height))
        }
    }

    static func metrics(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (mae: Double, psnr: Double, max: Int) {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let ap = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let bp = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        var square = 0.0
        var maximum = 0
        for y in 0..<CVPixelBufferGetHeight(a) {
            for x in 0..<(CVPixelBufferGetWidth(a) * 4) where x % 4 != 3 {
                let d = abs(
                    Int(ap[y * CVPixelBufferGetBytesPerRow(a) + x]) - Int(bp[y * CVPixelBufferGetBytesPerRow(b) + x]))
                sum += Double(d)
                square += Double(d * d)
                maximum = max(maximum, d)
            }
        }
        let n = Double(CVPixelBufferGetWidth(a) * CVPixelBufferGetHeight(a) * 3)
        return (sum / n, square == 0 ? .infinity : 10 * log10(255 * 255 / (square / n)), maximum)
    }

    static func save(_ buffer: CVPixelBuffer, to url: URL) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let image = context(buffer).makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
    }

    static func main() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
        let library = try await device.makeLibrary(
            source: String(contentsOfFile: "Screendrop/StudioMotionBlur.metal", encoding: .utf8), options: nil)
        let output = URL(fileURLWithPath: "/tmp/screendrop-motion-blur-benchmark", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("Device: \(device.name)")
        let cases =
            CommandLine.arguments.contains("--encode-only")
            ? [] : [(1920, 1080, 1), (1920, 1080, 2), (1920, 1080, 4), (3840, 2160, 1)]
        for (width, height, inputScale) in cases {
            let size = CGSize(width: width, height: height)
            let sourceBuffer = fixture(width * inputScale, height * inputScale)
            CVPixelBufferLockBaseAddress(sourceBuffer, .readOnly)
            let source = context(sourceBuffer).makeImage()!
            CVPixelBufferUnlockBaseAddress(sourceBuffer, .readOnly)
            let background = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: info)!
            background.setFillColor(CGColor(srgbRed: 0.12, green: 0.15, blue: 0.25, alpha: 1))
            background.fill(CGRect(origin: .zero, size: size))
            let backdrop = background.makeImage()!
            let card = CGRect(
                x: Double(width) * 0.04, y: Double(height) * 0.06, width: Double(width) * 0.92,
                height: Double(height) * 0.88)
            let path = CGPath(
                roundedRect: CGRect(x: card.minX, y: size.height - card.maxY, width: card.width, height: card.height),
                cornerWidth: 22, cornerHeight: 22, transform: nil)
            guard
                let gpu = StudioMetalScreenRenderer(
                    canvasSize: size, backdrop: backdrop, cardPath: path, colorSpace: space, library: library)
            else { fatalError("Metal setup failed") }
            let cpuBuffer = buffer(width, height)
            let gpuBuffer = buffer(width, height)
            for samples in [2, 8, 24] {
                let rects: [CGRect] = (0..<samples).map { index in
                    let i = CGFloat(index)
                    return CGRect(
                        x: -i * 2 + card.minX, y: -i * 1.1 + card.minY, width: card.width * 1.3 + i * 3,
                        height: card.height * 1.3 + i * 2)
                }
                reference(source: source, backdrop: backdrop, rects: rects, path: path, into: cpuBuffer)
                // The app retains Core Graphics for light blur when reducing
                // footage. Do not quietly include those cases in GPU claims.
                guard StudioMetalScreenRenderer.shouldAccelerate(screenFrame: sourceBuffer, sampleRects: rects) else {
                    print("\(width)x\(height) input=\(inputScale)x samples=\(samples): Core Graphics quality fallback")
                    continue
                }
                precondition(
                    gpu.render(screenFrame: sourceBuffer, sampleRects: rects, into: gpuBuffer), "Metal render failed")
                let result = metrics(cpuBuffer, gpuBuffer)
                print(
                    "Quality: \(width)x\(height) input=\(inputScale)x samples=\(samples) MAE=\(result.mae) PSNR=\(result.psnr)"
                )
                fflush(nil)
                precondition(
                    result.mae < 4 && result.psnr > 31,
                    "Pixel comparison failed: MAE=\(result.mae), PSNR=\(result.psnr)")
                let iterations = 4
                var start = CFAbsoluteTimeGetCurrent()
                for _ in 0..<iterations {
                    autoreleasepool {
                        reference(source: source, backdrop: backdrop, rects: rects, path: path, into: cpuBuffer)
                    }
                }
                let cpu = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(iterations)
                start = CFAbsoluteTimeGetCurrent()
                for _ in 0..<iterations {
                    autoreleasepool {
                        precondition(gpu.render(screenFrame: sourceBuffer, sampleRects: rects, into: gpuBuffer))
                    }
                }
                let metal = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(iterations)
                print("Input scale: \(inputScale)")
                print(
                    String(
                        format: "%dx%d samples=%d CPU=%.2fms Metal=%.2fms speedup=%.2fx MAE=%.3f PSNR=%.2fdB max=%d",
                        width, height, samples, cpu, metal, cpu / metal, result.mae, result.psnr, result.max))
                if width == 1920 {
                    save(cpuBuffer, to: output.appendingPathComponent("cpu-\(inputScale)x-\(samples).png"))
                    save(gpuBuffer, to: output.appendingPathComponent("metal-\(inputScale)x-\(samples).png"))
                }
            }
        }
        for codec in [AVVideoCodecType.h264, .hevc] {
            try await encodingSmokeTest(library: library, output: output, codec: codec)
        }
    }

    /// Exercise the exact Core Video attributes used by the app: writer pool
    /// -> Metal -> CPU overlay -> encoder -> reader -> Metal again.
    static func encodingSmokeTest(library: MTLLibrary, output: URL, codec: AVVideoCodecType) async throws {
        let url = output.appendingPathComponent("metal-encoder-smoke-\(codec.rawValue).mov")
        try? FileManager.default.removeItem(at: url)
        let width = 320
        let height = 180
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let source = fixture(width, height)
        let gpu = StudioMetalScreenRenderer(
            canvasSize: bounds.size, backdrop: nil,
            cardPath: CGPath(rect: bounds, transform: nil), colorSpace: space, library: library)!
        for i in 0..<6 {
            let waitStarted = ContinuousClock.now
            while !input.isReadyForMoreMediaData {
                precondition(
                    writer.status == .writing && waitStarted.duration(to: .now) < .seconds(10),
                    "Encoder failed or stalled: \(String(describing: writer.error))")
                try await Task.sleep(for: .milliseconds(2))
            }
            var frame: CVPixelBuffer?
            precondition(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &frame) == kCVReturnSuccess)
            precondition(
                gpu.render(screenFrame: source, sampleRects: [bounds, bounds.offsetBy(dx: -2, dy: 0)], into: frame!))
            CVPixelBufferLockBaseAddress(frame!, [])
            let overlay = context(frame!)
            overlay.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))
            overlay.fill(CGRect(x: 10, y: 10, width: 30, height: 30))
            overlay.flush()
            CVPixelBufferUnlockBaseAddress(frame!, [])
            precondition(adaptor.append(frame!, withPresentationTime: CMTime(value: Int64(i), timescale: 60)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed)
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ])
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)
        precondition(reader.startReading())
        let destination = buffer(width, height)
        var frames = 0
        while let sample = trackOutput.copyNextSampleBuffer() {
            let decoded = CMSampleBufferGetImageBuffer(sample)!
            precondition(gpu.render(screenFrame: decoded, sampleRects: [bounds, bounds], into: destination))
            CVPixelBufferLockBaseAddress(destination, .readOnly)
            let pixels = CVPixelBufferGetBaseAddress(destination)!.assumingMemoryBound(to: UInt8.self)
            let index = (height - 20) * CVPixelBufferGetBytesPerRow(destination) + 20 * 4
            precondition(
                pixels[index] < 60 && pixels[index + 1] > 200 && pixels[index + 2] > 200,
                "CPU overlay was lost or flipped across encoding")
            CVPixelBufferUnlockBaseAddress(destination, .readOnly)
            frames += 1
        }
        precondition(frames == 6 && reader.status == .completed)
        precondition(!gpu.render(screenFrame: source, sampleRects: [], into: destination))
        precondition(!gpu.render(screenFrame: source, sampleRects: [.zero], into: destination))
        print(
            "PASS: encoder pool, Metal/CPU synchronization, \(codec.rawValue) write, and Metal-compatible decoding (6 frames)."
        )
    }
}
