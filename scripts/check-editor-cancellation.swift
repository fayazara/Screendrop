import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Standalone Vision + thumbnail lifecycle checks; see docs/editor-performance.md.
@main
struct EditorCancellationChecks {
    static func textFixture() -> URL {
        let width = 1800, height = 1200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica" as CFString, 32, nil),
            .foregroundColor: CGColor(gray: 0, alpha: 1)
        ]
        for y in stride(from: 60, to: height - 30, by: 55) {
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
                string: "Contact: hello@example.com — Screendrop cancellation fixture", attributes: attributes)), context)
        }
        let url = URL(fileURLWithPath: "/tmp/screendrop-editor-cancellation.png")
        let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(writer))
        return url
    }

    static func main() async throws {
        let url = textFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let recognized = await SmartRedactionRecognizer.sensitiveRegions(at: url)
        precondition(recognized.contains { $0.text.contains("hello@example.com") }, "Uncancelled OCR must still find sensitive text")
        let preCancelled = Task { await SmartRedactionRecognizer.sensitiveRegions(at: url) }
        preCancelled.cancel()
        let early = await preCancelled.value
        precondition(early.isEmpty)
        let inFlight = Task { await SmartRedactionRecognizer.sensitiveRegions(at: url) }
        try await Task.sleep(for: .milliseconds(10))
        inFlight.cancel()
        let late = await inFlight.value
        precondition(late.isEmpty, "Cancelled recognition must not publish regions")
        print("PASS: uncancelled OCR, cancellation before dispatch, cancellation during asynchronous recognition")

        let movie = URL(fileURLWithPath: "/tmp/screendrop-motion-blur-benchmark/metal-encoder-smoke-avc1.mov")
        precondition(FileManager.default.fileExists(atPath: movie.path), "Run the motion-blur harness with --encode-only first")
        let store = RecordingTimelineThumbnailStore()
        store.prepare(url: movie, duration: 0.1)
        let grid = store.grid(forTargetSpan: 0.1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.image(in: grid, tileIndex: 0) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(store.image(in: grid, tileIndex: 0) != nil, "Thumbnail fixture must load")
        store.releaseResources()
        precondition(store.image(in: grid, tileIndex: 0) == nil)
        for _ in 0..<10 {
            store.prepare(url: movie, duration: 0.1)
            // Allow background work to start, then close the consumer.
            try await Task.sleep(for: .milliseconds(1))
            store.releaseResources()
        }
        try await Task.sleep(for: .milliseconds(200))
        precondition(store.image(in: grid, tileIndex: 0) == nil && store.onChange == nil,
                     "Late thumbnail completions must not repopulate a closed store")
        print("PASS: loaded thumbnail release and repeated close during generation")
    }
}
