import CoreGraphics
import CoreVideo
import XCTest

/// The studio exporter renders on a fixed 60 fps output clock, but a screen
/// capture only produces frames where pixels changed. Many consecutive output
/// frames therefore share one source buffer, and rebuilding a full-size
/// `CGImage` for each of them is pure waste.
final class StudioSourceImageCacheTests: XCTestCase {
    private func makePixelBuffer(width: Int = 8, height: Int = 4) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return buffer!
    }

    func testReusesOneImageWhileTheSourceBufferIsUnchanged() {
        let cache = StudioSourceImageCache(colorSpace: CGColorSpaceCreateDeviceRGB())
        let buffer = makePixelBuffer()

        guard let first = cache.image(for: buffer),
              let second = cache.image(for: buffer) else {
            return XCTFail("The cache produced no image for a valid pixel buffer.")
        }

        XCTAssertTrue(
            first === second,
            "Consecutive output frames sharing one source buffer must reuse one CGImage."
        )
    }

    func testRebuildsTheImageWhenTheSourceBufferChanges() {
        let cache = StudioSourceImageCache(colorSpace: CGColorSpaceCreateDeviceRGB())
        let first = makePixelBuffer()
        let second = makePixelBuffer()

        guard let firstImage = cache.image(for: first),
              let secondImage = cache.image(for: second) else {
            return XCTFail("The cache produced no image for a valid pixel buffer.")
        }

        XCTAssertFalse(
            firstImage === secondImage,
            "A new source buffer must produce a new image, not the previous frame."
        )
    }
}
