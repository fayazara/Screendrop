import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

// Compile with VideoCompressionModels.swift and RecordingExportTiming.swift.
// Exercises production timing/settings without launching Screendrop.
@main
struct RecordingExportOptionChecks {
    static func checkSettingsAndSampling() throws {
        let legacyJSON = Data(#"{"quality":"High","speed":"Slow","codec":"HEVC","resolution":"720p","removeAudio":true}"#.utf8)
        let legacy = try JSONDecoder().decode(VideoCompressionSettings.self, from: legacyJSON)
        precondition(legacy.effectiveFrameRate == .fps60 && legacy.effectiveMotionBlurEnabled)
        precondition(legacy.quality == .high && legacy.codec == .hevc && legacy.resolution == .p720 && legacy.removeAudio)
        var explicitDefault = legacy
        explicitDefault.frameRate = .fps60
        explicitDefault.motionBlurEnabled = true
        precondition(explicitDefault == legacy, "Explicit defaults must match older cached render settings")

        var variants: [VideoCompressionSettings] = []
        let still = CGRect(x: 10, y: 20, width: 500, height: 300)
        for fps in VideoExportFrameRate.allCases {
            for blur in [false, true] {
                var settings = legacy
                settings.frameRate = fps
                settings.motionBlurEnabled = blur
                let decoded = try JSONDecoder().decode(VideoCompressionSettings.self, from: JSONEncoder().encode(settings))
                precondition(decoded == settings)
                precondition(!variants.contains(decoded), "Different fps/blur choices must invalidate render equality")
                variants.append(decoded)

                let timing = RecordingExportTiming(settings: decoded)
                let count = timing.frameCount(for: 1)
                precondition(count == (fps == .fps30 ? 30 : 60))
                precondition(timing.time(forFrame: count) == 1)
                precondition(timing.screenSampleRects(at: 0.5) { _ in still } == [still])

                let moving: (TimeInterval) -> CGRect = { t in still.offsetBy(dx: 120 * t, dy: 0) }
                let samples = timing.screenSampleRects(at: 0.5, frameRect: moving)
                if blur {
                    // A 120 px/s pan spans two pixels at 60 fps and four at
                    // 30 fps. The original policy gives two midpoint samples.
                    precondition(samples.count == 2)
                    let halfSpacing: CGFloat = fps == .fps30 ? 1 : 0.5
                    precondition(abs(samples[0].minX - (70 - halfSpacing)) < 1e-10)
                    precondition(abs(samples[1].minX - (70 + halfSpacing)) < 1e-10)
                    let fast = timing.screenSampleRects(at: 0.5) { t in still.offsetBy(dx: t * 6000, dy: 0) }
                    precondition(fast.count == 24, "Fast motion must retain the 24-sample cap")
                } else {
                    precondition(samples == [moving(0.5)], "Blur-off must draw the current camera position once")
                }
            }
        }
        print("PASS: legacy settings, four settings round trips, render identity, 30/60 frame clocks, blur on/off sampling")
    }

    static func checkEncodedCadence(fps: VideoExportFrameRate, blur: Bool, codec: AVVideoCodecType) async throws {
        var settings = VideoCompressionSettings()
        settings.frameRate = fps
        settings.motionBlurEnabled = blur
        let timing = RecordingExportTiming(settings: settings)
        let directory = URL(fileURLWithPath: "/tmp/screendrop-export-options", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(Int(timing.framesPerSecond))-\(blur)-\(codec.rawValue).mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = 320, height = 180
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: timing.framesPerSecond]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let count = timing.frameCount(for: 1)
        for frame in 0..<count {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !input.isReadyForMoreMediaData {
                precondition(writer.status == .writing && ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess)
            let output = buffer!
            CVPixelBufferLockBaseAddress(output, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(output), width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(output),
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let time = timing.time(forFrame: frame)
            let rects = timing.screenSampleRects(at: time) { t in CGRect(x: 600 * t, y: 40, width: 100, height: 100) }
            for (index, rect) in rects.enumerated() {
                context.setFillColor(CGColor(gray: 0, alpha: 1 / CGFloat(index + 1)))
                context.fill(rect)
            }
            context.flush()
            CVPixelBufferUnlockBaseAddress(output, [])
            precondition(adaptor.append(output, withPresentationTime: timing.presentationTime(forFrame: frame)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed)
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let nominalRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        precondition(abs(Double(nominalRate) - timing.framesPerSecond) < 0.01)
        precondition(abs(duration - 1) < 0.002, "Changing cadence must preserve playback duration")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        precondition(reader.startReading())
        var decodedCount = 0
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            precondition(abs(time - timing.time(forFrame: decodedCount)) < 1e-6,
                         "Frame \(decodedCount): decoded PTS \(time), expected \(timing.time(forFrame: decodedCount))")
            decodedCount += 1
        }
        precondition(decodedCount == count && reader.status == .completed)
        print("PASS: \(codec.rawValue), \(fps.rawValue), blur=\(blur), \(decodedCount) decoded frames, 1-second duration")
    }

    static func main() async throws {
        try checkSettingsAndSampling()
        for codec: AVVideoCodecType in [.h264, .hevc] {
            for fps in VideoExportFrameRate.allCases {
                for blur in [false, true] {
                    try await checkEncodedCadence(fps: fps, blur: blur, codec: codec)
                }
            }
        }
    }
}
