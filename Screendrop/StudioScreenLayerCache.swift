import CoreGraphics
import CoreVideo
import Foundation

/// One exact copy of the screen + backdrop before any animated overlays.
/// Retaining the decoded source prevents pixel-buffer pool address reuse
/// from turning a different frame into a false cache hit. Used serially.
nonisolated final class StudioScreenLayerCache {
    private let byteLimit = 64 * 1024 * 1024
    private var source: CVPixelBuffer?
    private var rect: CGRect?
    private var pixels: Data?
    private var width = 0
    private var height = 0

    func invalidate() {
        source = nil
        rect = nil
        pixels = nil
    }

    /// Completes the copy before the compositor locks the buffer for overlays.
    func restore(source: CVPixelBuffer, rect: CGRect, into destination: CVPixelBuffer) -> Bool {
        guard self.source === source, self.rect == rect, let pixels,
              width == CVPixelBufferGetWidth(destination), height == CVPixelBufferGetHeight(destination),
              CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let base = CVPixelBufferGetBaseAddress(destination) else { return false }
        let stride = CVPixelBufferGetBytesPerRow(destination)
        pixels.withUnsafeBytes { bytes in
            for row in 0..<height {
                memcpy(base.advanced(by: row * stride), bytes.baseAddress!.advanced(by: row * width * 4), width * 4)
            }
        }
        return true
    }

    /// The caller holds the rendered buffer's CPU lock. Copy its bytes now:
    /// storing that buffer itself would also cache later cursor/camera draws.
    func capture(source: CVPixelBuffer, rect: CGRect, fromLocked rendered: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(rendered)
        let height = CVPixelBufferGetHeight(rendered)
        let cost = width * height * 4
        guard cost <= byteLimit,
              CVPixelBufferGetPixelFormatType(rendered) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(rendered) else {
            invalidate()
            return
        }
        var snapshot = Data(count: cost)
        let stride = CVPixelBufferGetBytesPerRow(rendered)
        snapshot.withUnsafeMutableBytes { bytes in
            for row in 0..<height {
                memcpy(bytes.baseAddress!.advanced(by: row * width * 4), base.advanced(by: row * stride), width * 4)
            }
        }
        self.source = source
        self.rect = rect
        self.width = width
        self.height = height
        pixels = snapshot
    }
}
