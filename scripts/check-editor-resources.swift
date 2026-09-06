import AppKit
import CoreVideo

// Compiles the production caches directly; see docs/editor-performance.md.
@main
struct EditorResourceChecks {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func image(_ size: Int = 16) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: size * 4, space: space, bitmapInfo: bitmapInfo)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    static func checkImageBudget() {
        let sample = image()
        let cost = sample.bytesPerRow * sample.height
        let cache = BoundedCGImageCache(byteLimit: cost * 2, countLimit: 3)
        var first: BoundedCGImageCache.Lease? = cache.beginUse()
        var second: BoundedCGImageCache.Lease? = cache.beginUse()
        let generation = cache.generation
        cache.insert(sample, for: "a", generation: generation)
        cache.insert(sample, for: "b", generation: generation)
        precondition(cache.image(for: "a") === sample)
        cache.insert(sample, for: "c", generation: generation)
        precondition(cache.image(for: "b") == nil, "Least recently used image must be evicted")
        precondition(cache.retainedBytes == cost * 2)
        cache.insert(image(64), for: "oversize", generation: generation)
        precondition(cache.image(for: "oversize") == nil && cache.retainedBytes == cost * 2)
        withExtendedLifetime(first) {}
        first = nil
        precondition(cache.image(for: "a") != nil, "Closing one consumer must preserve another's cache")
        withExtendedLifetime(second) {}
        second = nil
        precondition(cache.retainedBytes == 0, "Last consumer must release decoded images")
        let reopened = cache.beginUse()
        cache.insert(sample, for: "late", generation: generation)
        precondition(cache.image(for: "late") == nil, "Old decode must not repopulate a reopened cache")
        cache.insert(sample, for: "fresh", generation: cache.generation)
        precondition(cache.image(for: "fresh") != nil)
        withExtendedLifetime(reopened) {}

        let countCache = BoundedCGImageCache(byteLimit: cost * 10, countLimit: 1)
        let lease = countCache.beginUse()
        countCache.insert(sample, for: "one", generation: countCache.generation)
        countCache.insert(sample, for: "two", generation: countCache.generation)
        precondition(countCache.image(for: "one") == nil && countCache.retainedBytes == cost)
        withExtendedLifetime(lease) {}
        print("PASS: hard byte/count limits, LRU, multiple consumers, last-close release, stale decode rejection")
    }

    static func checkRedactions() {
        let cache = AnnoRedactionPreviewCache()
        let source = image(64)
        let processed = image()
        let frame = CGRect(x: 5, y: 8, width: 200, height: 200)
        let bounds = CGRect(x: 10, y: 10, width: 30, height: 30)
        cache.configure(source: source, imageFrame: frame)
        var renders = 0
        func draw(kind: String = "blur", density: Double = 0.5, rect: CGRect? = nil) -> CGImage? {
            cache.image(kind: kind, density: density, bounds: rect ?? bounds) {
                renders += 1
                return processed
            }
        }
        precondition(draw() === processed)
        for _ in 0..<100 { precondition(draw() === processed) }
        precondition(renders == 1, "Selection-only redraws must reuse exact processed pixels")
        _ = draw(density: 0.6)
        _ = draw(kind: "pixelate")
        _ = draw(rect: bounds.offsetBy(dx: 1, dy: 0))
        precondition(renders == 4)
        cache.configure(source: source, imageFrame: frame.offsetBy(dx: 1, dy: 0))
        _ = draw()
        cache.configure(source: image(64), imageFrame: frame)
        _ = draw()
        precondition(renders == 6, "Source and sampling geometry changes must invalidate results")
        cache.releaseResources()
        cache.configure(source: source, imageFrame: frame)
        _ = draw()
        precondition(renders == 7)
        print("PASS: redaction reuse and invalidation for density, kind, bounds, source, resize, and close")
    }

    static func buffer(width: Int = 17, height: Int = 11, alignment: Int = 64) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                       [kCVPixelBufferBytesPerRowAlignmentKey: alignment] as CFDictionary,
                                       &buffer) == kCVReturnSuccess)
        return buffer!
    }

    static func paint(_ buffer: CVPixelBuffer, overlayX: Int? = nil) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                let i = y * stride + x * 4
                if let overlayX {
                    if x == overlayX { base[i] = 255; base[i + 1] = 255; base[i + 2] = 0 }
                } else {
                    base[i] = UInt8((x * 7) % 200)
                    base[i + 1] = UInt8((y * 11) % 200)
                    base[i + 2] = 71
                    base[i + 3] = 255
                }
            }
        }
    }

    static func bytes(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var result = Data()
        let base = CVPixelBufferGetBaseAddress(buffer)!
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            result.append(base.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self),
                          count: CVPixelBufferGetWidth(buffer) * 4)
        }
        return result
    }

    static func checkScreenLayer() {
        let cache = StudioScreenLayerCache()
        let source = buffer()
        let rendered = buffer()
        let output = buffer(alignment: 256)
        let reference = buffer()
        let rect = CGRect(x: 1, y: 2, width: 14, height: 8)
        paint(rendered)
        let clean = bytes(rendered)
        CVPixelBufferLockBaseAddress(rendered, .readOnly)
        cache.capture(source: source, rect: rect, fromLocked: rendered)
        CVPixelBufferUnlockBaseAddress(rendered, .readOnly)
        paint(rendered, overlayX: 3)
        precondition(bytes(rendered) != clean)
        for frame in 0..<60 {
            precondition(cache.restore(source: source, rect: rect, into: output))
            precondition(bytes(output) == clean, "Previous overlays must not enter the screen cache")
            paint(output, overlayX: frame % 17)
            paint(reference)
            paint(reference, overlayX: frame % 17)
            precondition(bytes(output) == bytes(reference), "Reuse plus moving overlay must match full redraw byte for byte")
        }
        precondition(!cache.restore(source: buffer(), rect: rect, into: output), "New decoded frame must miss")
        precondition(!cache.restore(source: source, rect: rect.offsetBy(dx: 0.001, dy: 0), into: output))
        precondition(!cache.restore(source: source, rect: rect, into: buffer(width: 18)))
        cache.invalidate()
        precondition(!cache.restore(source: source, rect: rect, into: output))
        let oversized = buffer(width: 4097, height: 4096)
        CVPixelBufferLockBaseAddress(oversized, .readOnly)
        cache.capture(source: source, rect: rect, fromLocked: oversized)
        CVPixelBufferUnlockBaseAddress(oversized, .readOnly)
        precondition(!cache.restore(source: source, rect: rect, into: oversized), "Layer over 64 MiB must not be cached")
        print("PASS: byte-identical screen reuse, independent row strides, moving overlay isolation, misses, 64 MiB cap")
    }

    static func main() {
        checkImageBudget()
        checkRedactions()
        checkScreenLayer()
    }
}
