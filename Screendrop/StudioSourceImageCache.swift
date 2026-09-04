//
//  StudioSourceImageCache.swift
//  Screendrop
//
//  Turns a screen-capture pixel buffer into the CGImage the studio
//  compositor draws. The export renders on a fixed output clock while a
//  screen capture only emits frames where pixels changed, so consecutive
//  output frames routinely share one source buffer.
//

import CoreGraphics
import CoreVideo

/// Not thread-safe by design: it holds one slot, so each compositing worker
/// owns its own instance rather than sharing one behind a lock.
nonisolated final class StudioSourceImageCache {
    private let colorSpace: CGColorSpace
    private var cachedBuffer: CVPixelBuffer?
    private var cachedImage: CGImage?

    init(colorSpace: CGColorSpace) {
        self.colorSpace = colorSpace
    }

    func image(for buffer: CVPixelBuffer) -> CGImage? {
        if let cachedBuffer, cachedBuffer === buffer, let cachedImage {
            return cachedImage
        }
        let image = Self.makeImage(from: buffer, colorSpace: colorSpace)
        cachedBuffer = buffer
        cachedImage = image
        return image
    }

    private static func makeImage(
        from pixelBuffer: CVPixelBuffer,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }
        return context.makeImage()
    }
}
