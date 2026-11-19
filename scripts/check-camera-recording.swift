import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// xcrun swiftc Screendrop/CameraMovieWriter.swift scripts/check-camera-recording.swift \
//   -o /tmp/screendrop-camera-check && /tmp/screendrop-camera-check
// Uses real AVFoundation writers and generated frames; no camera permission is needed.
@main
struct CameraRecordingChecks {
    final class WriterReference: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AVAssetWriter?
        func make(_ url: URL) throws -> AVAssetWriter {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            lock.withLock { value = writer }
            return writer
        }
        func injectTimingFailure(_ sample: CMSampleBuffer) {
            lock.withLock { _ = value?.inputs.first?.append(sample) }
        }
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "CameraRecordingChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func sample(at time: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        try expect(CVPixelBufferCreate(kCFAllocatorDefault, 160, 96, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel) == noErr, "Create pixel buffer")
        let image = pixel!
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 0, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        try expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &format) == noErr, "Create video format")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        try expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescription: format!, sampleTiming: &timing,
            sampleBufferOut: &buffer) == noErr, "Create sample buffer")
        return buffer!
    }

    static func verifyMovie(_ url: URL, minimumFrames: Int) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        try expect(tracks.count == 1, "Expected one camera video track")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        try expect(reader.startReading(), "Start decoding camera movie")
        var previous: CMTime?
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            try expect(time.isNumeric && time >= .zero, "Invalid encoded camera timestamp")
            if let previous { try expect(time > previous, "Duplicate or backward encoded timestamp") }
            previous = time
            count += 1
        }
        try expect(reader.status == .completed, "Camera movie must decode through its final frame")
        try expect(count >= minimumFrames, "Too many camera frames lost: \(count)")
    }

    static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    static func run() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("screendrop-camera-check-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        for mode in ["normal", "early-pause", "pause", "repeated-pause", "backward", "interrupted"] {
            let url = root.appendingPathComponent("\(mode).mov")
            let reference = WriterReference()
            let writer = CameraMovieWriter(makeAssetWriter: { try reference.make($0) })
            try writer.setup(outputURL: url, width: 160, height: 96)
            if mode == "early-pause" {
                writer.pause()
                writer.writeVideoSample(try sample(at: CMTime(value: 2999, timescale: 30)))
                writer.resume()
            }
            var hostGap: Int64 = 0
            for frame in 0..<240 {
                if (mode == "pause" && frame == 120) || (mode == "repeated-pause" && [60, 120, 180].contains(frame)) {
                    writer.pause()
                    writer.writeVideoSample(try sample(at: CMTime(value: 3000 + Int64(frame) + hostGap, timescale: 30)))
                    writer.resume()
                    hostGap += 900
                }
                var ticks = 3000 + Int64(frame) + hostGap
                if mode == "backward" && frame >= 120 { ticks -= 15 }
                writer.writeVideoSample(try sample(at: CMTime(value: ticks, timescale: 30)))
                try await Task.sleep(for: .milliseconds(4))
            }
            // Inject a late encoder-side timing fault into the real AVAssetWriter,
            // bypassing the production PTS guard only for this failure-path check.
            if mode == "interrupted" {
                reference.injectTimingFailure(try sample(at: CMTime(value: 1, timescale: 1)))
            }
            guard let result = await writer.finish() else { throw CocoaError(.fileWriteUnknown) }
            try expect(result.url.map { manager.fileExists(atPath: $0.path) } == true, "Camera bytes must survive finish: \(mode)")
            if mode == "interrupted" {
                try expect(result.error != nil && result.warningMessage != nil, "Interrupted writer must surface a warning")
                if result.fileIsUsable { try await verifyMovie(url, minimumFrames: 60) }
                print("INFO: failed writer footage retained; playable=\(result.fileIsUsable)")
            } else {
                try expect(result.error == nil && result.fileIsUsable, "Camera failed after \(mode): \(String(describing: result.error))")
                try expect(result.warningMessage == nil, "Successful camera should not warn")
                try await verifyMovie(url, minimumFrames: 200)
            }
            try expect(await writer.finish() == nil, "Repeated finish must be harmless")
            print("PASS: \(mode) retains footage and reports the correct result")
        }

        let emptyURL = root.appendingPathComponent("empty.mov")
        let empty = CameraMovieWriter()
        try empty.setup(outputURL: emptyURL, width: 160, height: 96)
        let emptyResult = await empty.finish()
        try expect(emptyResult?.fileIsUsable == false && emptyResult?.warningMessage != nil,
            "No-frame camera must warn instead of pretending to succeed")
        try expect(!manager.fileExists(atPath: emptyURL.path), "Unreadable partial camera must not break Studio screen export")
        print("PASS: empty camera warns and is excluded from Studio")

        for suffix in ["mov", "partial.mov"] {
            let final = root.appendingPathComponent("existing-\(suffix).mov")
            let existing = suffix == "mov" ? final : final.deletingPathExtension().appendingPathExtension("partial.mov")
            let original = Data("existing camera footage".utf8)
            try original.write(to: existing)
            do {
                try CameraMovieWriter().setup(outputURL: final, width: 160, height: 96)
                throw NSError(domain: "CameraRecordingChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Setup overwrote existing footage"])
            } catch let error as CocoaError { try expect(error.code == .fileWriteFileExists, "Unexpected setup error") }
            try expect(try Data(contentsOf: existing) == original, "Existing camera bytes changed")
        }
        print("PASS: setup refuses to overwrite completed or partial footage")

        let cancelURL = root.appendingPathComponent("discard.mov")
        let discard = CameraMovieWriter()
        try discard.setup(outputURL: cancelURL, width: 160, height: 96)
        discard.writeVideoSample(try sample(at: CMTime(value: 100, timescale: 1)))
        await discard.cancel()
        try expect(!manager.fileExists(atPath: cancelURL.path)
            && !manager.fileExists(atPath: cancelURL.deletingPathExtension().appendingPathExtension("partial.mov").path),
            "Explicit discard must still remove only its own partial footage")
        print("PASS: explicit discard cleans up its own recording")
    }
}
