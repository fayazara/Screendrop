//
//  RecordingStudioExporter.swift
//  Screendrop
//
//  Offline compositor for studio exports: decodes the screen (and camera)
//  recordings frame by frame, draws each frame through the same
//  RecordingStudioLayout / ***REMOVED*** math the live preview
//  uses, and writes a new HEVC movie. Audio tracks (system + microphone)
//  are mixed and passed through on the unchanged timeline.
//
//  Everything static — the background fill and the card shadow — is
//  rendered once into a backdrop image; per frame the work is one backdrop
//  blit plus the clipped video draws.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

nonisolated final class RecordingStudioExporter: @unchecked Sendable {
    struct Configuration: Sendable {
        let screenURL: URL
        let cameraURL: URL?
        let cameraOffset: TimeInterval
        let style: RecordingStudioStyle
        let zoomPath: ***REMOVED***
        /// Non-nil when the capture hid the OS cursor and the export must
        /// draw the synthetic one along this smoothed path.
        let cursorPath: ***REMOVED***?
        let canvasSize: CGSize
        let trimSelection: VideoTrimSelection?
        let exportSettings: VideoCompressionSettings
    }

    enum ExportError: LocalizedError {
        case noVideoTrack
        case writerFailed(Error?)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                "The recording has no video track."
            case .writerFailed(let error):
                error?.localizedDescription ?? "Writing the exported video failed."
            case .cancelled:
                "Export cancelled."
            }
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.withLock { cancelled = true }
        }

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }
    }

    func export(
        _ configuration: Configuration,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let cancelFlag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await run(configuration, cancelFlag: cancelFlag, progress: progress)
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    private func run(
        _ configuration: Configuration,
        cancelFlag: CancelFlag,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let screenAsset = AVURLAsset(url: configuration.screenURL)
        guard let videoTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let audioTracks = try await screenAsset.loadTracks(withMediaType: .audio)
        let sourceDuration = try await screenAsset.load(.duration).seconds
        let trimSelection = (configuration.trimSelection
            ?? VideoTrimSelection(start: 0, end: sourceDuration))
            .clamped(to: sourceDuration)
        guard trimSelection.duration >= VideoTrimSelection.minimumDuration else {
            throw VideoTrimExportError.invalidRange
        }
        let exportStartTime = CMTime(
            seconds: trimSelection.start,
            preferredTimescale: 600
        )
        let exportTimeRange = CMTimeRange(
            start: exportStartTime,
            duration: CMTime(seconds: trimSelection.duration, preferredTimescale: 600)
        )

        let outputSize = Self.outputSize(
            source: configuration.canvasSize,
            resolution: configuration.exportSettings.resolution
        )
        let canvasWidth = max(2, Int(outputSize.width.rounded()) & ~1)
        let canvasHeight = max(2, Int(outputSize.height.rounded()) & ~1)
        let canvasSize = CGSize(width: canvasWidth, height: canvasHeight)

        // Readers
        let screenReader = try AVAssetReader(asset: screenAsset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.alwaysCopiesSampleData = false
        screenReader.add(videoOutput)
        screenReader.timeRange = exportTimeRange

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !configuration.exportSettings.removeAudio, !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
            output.alwaysCopiesSampleData = false
            screenReader.add(output)
            audioOutput = output
        }

        let cameraFeed = try await CameraFrameFeed(
            url: configuration.cameraURL,
            offset: configuration.cameraOffset
        )

        // Writer
        let outputURL = Self.temporaryOutputURL()
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let codec: AVVideoCodecType = configuration.exportSettings.codec == .hevc ? .hevc : .h264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: canvasWidth,
            AVVideoHeightKey: canvasHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.averageBitRate(
                    width: canvasWidth,
                    height: canvasHeight,
                    quality: configuration.exportSettings.quality
                ),
                AVVideoExpectedSourceFrameRateKey: 60
            ] as [String: Any]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: canvasWidth,
                kCVPixelBufferHeightKey as String: canvasHeight
            ]
        )

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard screenReader.startReading() else {
            throw screenReader.error ?? ExportError.writerFailed(nil)
        }
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error)
        }
        // Keep source timestamps for camera/zoom lookup while defining the
        // selected source time as output time zero.
        writer.startSession(atSourceTime: exportStartTime)

        let compositor = StudioFrameCompositor(
            canvasSize: canvasSize,
            style: configuration.style,
            zoomPath: configuration.zoomPath,
            cursorPath: configuration.cursorPath,
            includeBubble: cameraFeed != nil
        )

        let screenAudioOutput = audioOutput
        let writerAudioInput = audioInput

        do {
            async let videoDone: Void = pumpVideo(
                output: videoOutput,
                input: videoInput,
                adaptor: adaptor,
                compositor: compositor,
                cameraFeed: cameraFeed,
                exportStart: trimSelection.start,
                duration: trimSelection.duration,
                cancelFlag: cancelFlag,
                progress: progress
            )
            async let audioDone: Void = pumpAudio(
                output: screenAudioOutput,
                input: writerAudioInput,
                cancelFlag: cancelFlag
            )
            _ = try await (videoDone, audioDone)
        } catch {
            screenReader.cancelReading()
            cameraFeed?.cancel()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        cameraFeed?.cancel()

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.writerFailed(writer.error)
        }
        progress(1)
        return outputURL
    }

    private func pumpVideo(
        output: AVAssetReaderTrackOutput,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        compositor: StudioFrameCompositor,
        cameraFeed: CameraFrameFeed?,
        exportStart: TimeInterval,
        duration: TimeInterval,
        cancelFlag: CancelFlag,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Render on a fixed output clock, not per source frame. Screen
        // captures only contain frames where pixels changed, so a static
        // screen has second-long gaps — but the virtual camera animates
        // through them (most zoom-outs happen exactly there, seconds after
        // the last click). Each tick re-renders the newest source frame at
        // or before it; only writing on source arrivals would hold the last
        // zoomed frame through the move and then visibly jump.
        let frameRate: Double = 60
        let frameCount = max(1, Int((duration * frameRate).rounded()))

        func nextSourceFrame() -> (buffer: CVPixelBuffer, time: TimeInterval)? {
            while let sampleBuffer = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                return (buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
            }
            return nil
        }

        var currentBuffer: CVPixelBuffer?
        var pending = nextSourceFrame()

        for frame in 0..<frameCount {
            if cancelFlag.isCancelled { throw ExportError.cancelled }
            let time = exportStart + Double(frame) / frameRate

            while let sample = pending, sample.time <= time {
                currentBuffer = sample.buffer
                pending = nextSourceFrame()
            }
            // Ticks before the first source frame show it early rather than
            // emitting black; a capture with no frames at all has nothing to
            // render.
            guard let sourceBuffer = currentBuffer ?? pending?.buffer else { break }

            while !input.isReadyForMoreMediaData {
                if cancelFlag.isCancelled { throw ExportError.cancelled }
                try await Task.sleep(nanoseconds: 2_000_000)
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw ExportError.writerFailed(nil)
            }
            var destinationBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationBuffer)
            guard let destinationBuffer else {
                throw ExportError.writerFailed(nil)
            }

            let cameraBuffer = cameraFeed?.latestFrame(at: time)
            try compositor.render(
                screenFrame: sourceBuffer,
                cameraFrame: cameraBuffer,
                time: time,
                into: destinationBuffer
            )

            let pts = CMTime(seconds: time, preferredTimescale: 600)
            if !adaptor.append(destinationBuffer, withPresentationTime: pts) {
                throw ExportError.writerFailed(nil)
            }

            if frame % 10 == 0 {
                progress(min(0.98, Double(frame) / Double(frameCount)))
            }
        }
        input.markAsFinished()
    }

    private func pumpAudio(
        output: AVAssetReaderAudioMixOutput?,
        input: AVAssetWriterInput?,
        cancelFlag: CancelFlag
    ) async throws {
        guard let output, let input else { return }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if cancelFlag.isCancelled { throw ExportError.cancelled }
            while !input.isReadyForMoreMediaData {
                if cancelFlag.isCancelled { throw ExportError.cancelled }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if !input.append(sampleBuffer) {
                throw ExportError.writerFailed(nil)
            }
        }
        input.markAsFinished()
    }

    private static func temporaryOutputURL() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Screendrop", isDirectory: true)
            .appendingPathComponent("StudioExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString).mov")
    }

    private static func outputSize(
        source: CGSize,
        resolution: VideoCompressionResolution
    ) -> CGSize {
        guard source.width > 0, source.height > 0 else {
            return CGSize(width: 1920, height: 1080)
        }
        let requestedHeight: CGFloat?
        switch resolution {
        case .original: requestedHeight = nil
        case .p1080: requestedHeight = 1080
        case .p720: requestedHeight = 720
        case .p480: requestedHeight = 480
        }
        guard let requestedHeight, source.height > requestedHeight else { return source }
        return CGSize(
            width: source.width * requestedHeight / source.height,
            height: requestedHeight
        )
    }

    private static func averageBitRate(
        width: Int,
        height: Int,
        quality: VideoCompressionQuality
    ) -> Int {
        let factor: Double
        switch quality {
        case .high: factor = 3.2
        case .medium: factor = 2.1
        case .low: factor = 1.25
        }
        return max(2_500_000, Int(Double(width * height) * factor))
    }
}

// MARK: - Camera frame feed

/// Sequential decoder for the camera movie that answers "latest camera frame
/// at screen-time t". Screen frames arrive in order, so a one-frame
/// look-ahead over the camera reader is all that's needed.
nonisolated private final class CameraFrameFeed: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let offset: TimeInterval
    private var currentFrame: CVPixelBuffer?
    private var pendingFrame: (buffer: CVPixelBuffer, time: TimeInterval)?
    private var isFinished = false

    init?(url: URL?, offset: TimeInterval) async throws {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? RecordingStudioExporter.ExportError.noVideoTrack
        }

        self.reader = reader
        self.output = output
        self.offset = offset
    }

    func latestFrame(at screenTime: TimeInterval) -> CVPixelBuffer? {
        while !isFinished {
            if let pending = pendingFrame {
                // Promote the very first frame unconditionally: the camera
                // starts a beat after the screen (capture warmup), and holding
                // its first frame from t=0 beats the bubble popping in late.
                guard pending.time <= screenTime || currentFrame == nil else { break }
                currentFrame = pending.buffer
                pendingFrame = nil
            }
            guard let sample = output.copyNextSampleBuffer() else {
                isFinished = true
                break
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds + offset
            pendingFrame = (buffer: buffer, time: time)
        }
        return currentFrame
    }

    func cancel() {
        reader.cancelReading()
    }
}

// MARK: - Frame compositor

/// Draws one output frame: cached backdrop, then the zoom-transformed screen
/// frame clipped to the rounded card, then the camera bubble.
nonisolated private final class StudioFrameCompositor: @unchecked Sendable {
    private let canvasSize: CGSize
    private let layout: RecordingStudioLayout
    private let zoomPath: ***REMOVED***
    private let cursorPath: ***REMOVED***?
    private let cursorImage: CGImage?
    private let cursorScale: CGFloat
    private let colorSpace: CGColorSpace
    private let backdrop: CGImage?
    private var previousFrameTime: TimeInterval?

    init(
        canvasSize: CGSize,
        style: RecordingStudioStyle,
        zoomPath: ***REMOVED***,
        cursorPath: ***REMOVED***?,
        includeBubble: Bool
    ) {
        self.canvasSize = canvasSize
        self.layout = RecordingStudioLayout.make(
            canvasSize: canvasSize,
            style: style,
            includeBubble: includeBubble
        )
        self.zoomPath = zoomPath
        self.cursorPath = cursorPath
        self.cursorImage = cursorPath != nil ? Self.loadCursorImage() : nil
        self.cursorScale = style.cursorScale
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.backdrop = Self.renderBackdrop(
            canvasSize: canvasSize,
            layout: layout,
            style: style,
            colorSpace: colorSpace
        )
    }

    private static func loadCursorImage() -> CGImage? {
        guard let url = Bundle.main.url(forResource: ***REMOVED***.imageName, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func render(
        screenFrame: CVPixelBuffer,
        cameraFrame: CVPixelBuffer?,
        time: TimeInterval,
        into destination: CVPixelBuffer
    ) throws {
        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        guard let base = CVPixelBufferGetBaseAddress(destination),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(destination),
                height: CVPixelBufferGetHeight(destination),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            throw RecordingStudioExporter.ExportError.writerFailed(nil)
        }
        context.interpolationQuality = .high

        if let backdrop {
            context.draw(backdrop, in: CGRect(origin: .zero, size: canvasSize))
        } else {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(origin: .zero, size: canvasSize))
        }

        if let screenImage = Self.makeImage(from: screenFrame, colorSpace: colorSpace) {
            // Motion blur by temporal supersampling: while the virtual camera
            // is moving, average several sub-frame camera states across the
            // frame's shutter interval. Pans smear linearly, zooms radially,
            // and settled frames pay for a single draw.
            let shutter = min(max(time - (previousFrameTime ?? time - 1.0 / 60), 1.0 / 120), 1.0 / 24)
            previousFrameTime = time
            let sampleCount = blurSampleCount(at: time, shutter: shutter)

            context.saveGState()
            context.addPath(roundedPath(for: layout.cardRect, radius: layout.cardCornerRadius))
            context.clip()
            for sample in 0..<sampleCount {
                let sampleTime = time - shutter / 2
                    + shutter * (Double(sample) + 0.5) / Double(sampleCount)
                let drawRect = layout.videoDrawRect(for: zoomPath.state(at: sampleTime))
                // Drawing sample i at alpha 1/(i+1) keeps the buffer equal to
                // the running average of all samples so far.
                context.setAlpha(1 / CGFloat(sample + 1))
                context.draw(screenImage, in: flipped(drawRect))

                // The synthetic cursor is part of the video content: same
                // clip, same camera transform, same shutter samples.
                if let cursorImage, let cursorPath,
                   let position = cursorPath.position(at: sampleTime) {
                    let height = drawRect.height * ***REMOVED***.heightFraction * cursorScale
                    let size = CGSize(width: height * ***REMOVED***.aspectRatio, height: height)
                    let tip = CGPoint(
                        x: drawRect.minX + position.x * drawRect.width,
                        y: drawRect.minY + position.y * drawRect.height
                    )
                    let cursorRect = CGRect(
                        x: tip.x - ***REMOVED***.hotspot.x * size.width,
                        y: tip.y - ***REMOVED***.hotspot.y * size.height,
                        width: size.width,
                        height: size.height
                    )
                    context.draw(cursorImage, in: flipped(cursorRect))
                }
            }
            context.restoreGState()
        }

        if let cameraFrame,
           layout.bubbleRect.width > 0,
           let cameraImage = Self.makeImage(from: cameraFrame, colorSpace: colorSpace) {
            let bubble = layout.bubbleRect
            let imageSize = CGSize(width: cameraImage.width, height: cameraImage.height)
            let scale = max(bubble.width / imageSize.width, bubble.height / imageSize.height)
            let fillSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let fillRect = CGRect(
                x: bubble.midX - fillSize.width / 2,
                y: bubble.midY - fillSize.height / 2,
                width: fillSize.width,
                height: fillSize.height
            )

            // Shadow + hairline border match the live preview's bubble
            // styling; the bubble sits over moving video, so both must be
            // drawn per frame rather than baked into the backdrop.
            let minDimension = min(canvasSize.width, canvasSize.height)
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -minDimension * 0.009),
                blur: minDimension * 0.022,
                color: CGColor(gray: 0, alpha: 0.35)
            )
            context.addPath(roundedPath(for: bubble, radius: layout.bubbleCornerRadius))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()

            context.saveGState()
            context.addPath(roundedPath(for: bubble, radius: layout.bubbleCornerRadius))
            context.clip()
            context.draw(cameraImage, in: flipped(fillRect))
            context.restoreGState()

            context.saveGState()
            context.addPath(roundedPath(for: bubble.insetBy(dx: 0.5, dy: 0.5), radius: layout.bubbleCornerRadius))
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
            context.setLineWidth(max(1, minDimension * 0.0018))
            context.strokePath()
            context.restoreGState()
        }
    }

    /// How many shutter sub-samples this frame needs: one when the camera is
    /// still, up to twelve when it sweeps, spaced so consecutive samples land
    /// roughly two output pixels apart.
    private func blurSampleCount(at time: TimeInterval, shutter: TimeInterval) -> Int {
        let a = layout.videoDrawRect(for: zoomPath.state(at: time - shutter / 2))
        let b = layout.videoDrawRect(for: zoomPath.state(at: time + shutter / 2))
        let displacement = max(
            max(abs(a.minX - b.minX), abs(a.minY - b.minY)),
            max(abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
        )
        guard displacement > 1.5 else { return 1 }
        return min(12, max(2, Int((displacement / 2).rounded(.up))))
    }

    /// Layout rects use a top-left origin; CoreGraphics draws bottom-up.
    private func flipped(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: canvasSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func roundedPath(for rect: CGRect, radius: CGFloat) -> CGPath {
        let flippedRect = flipped(rect)
        let boundedRadius = min(radius, min(flippedRect.width, flippedRect.height) / 2)
        guard boundedRadius > 0.5 else { return CGPath(rect: flippedRect, transform: nil) }
        return CGPath(
            roundedRect: flippedRect,
            cornerWidth: boundedRadius,
            cornerHeight: boundedRadius,
            transform: nil
        )
    }

    private static func makeImage(from pixelBuffer: CVPixelBuffer, colorSpace: CGColorSpace) -> CGImage? {
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
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }
        return context.makeImage()
    }

    private static func renderBackdrop(
        canvasSize: CGSize,
        layout: RecordingStudioLayout,
        style: RecordingStudioStyle,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        let canvasRect = CGRect(origin: .zero, size: canvasSize)

        switch style.background {
        case .none:
            context.setFillColor(CGColor(gray: 0.04, alpha: 1))
            context.fill(canvasRect)
        case .solid(let color):
            context.setFillColor(CGColor(
                colorSpace: colorSpace,
                components: [color.red, color.green, color.blue, color.alpha]
            ) ?? CGColor(gray: 0, alpha: 1))
            context.fill(canvasRect)
        case .gradient(let gradient):
            let cgColors = gradient.colors.map { color in
                CGColor(
                    colorSpace: colorSpace,
                    components: [color.red, color.green, color.blue, color.alpha]
                ) ?? CGColor(gray: 0, alpha: 1)
            }
            if let cgGradient = CGGradient(
                colorsSpace: colorSpace,
                colors: cgColors as CFArray,
                locations: nil
            ) {
                // UnitPoint has a top-left origin; the context is bottom-up.
                let start = CGPoint(
                    x: gradient.startPoint.x * canvasSize.width,
                    y: canvasSize.height - gradient.startPoint.y * canvasSize.height
                )
                let end = CGPoint(
                    x: gradient.endPoint.x * canvasSize.width,
                    y: canvasSize.height - gradient.endPoint.y * canvasSize.height
                )
                context.drawLinearGradient(cgGradient, start: start, end: end, options: [
                    .drawsBeforeStartLocation,
                    .drawsAfterEndLocation
                ])
            }
        case .customWallpaper(let wallpaper):
            if let source = CGImageSourceCreateWithURL(wallpaper.url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, [
                   kCGImageSourceShouldCache: false
               ] as CFDictionary) {
                let imageSize = CGSize(width: image.width, height: image.height)
                let scale = max(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
                let fillSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                let fillRect = CGRect(
                    x: (canvasSize.width - fillSize.width) / 2,
                    y: (canvasSize.height - fillSize.height) / 2,
                    width: fillSize.width,
                    height: fillSize.height
                )
                context.draw(image, in: fillRect)
            } else {
                context.setFillColor(CGColor(gray: 0.04, alpha: 1))
                context.fill(canvasRect)
            }
        }

        // Card shadow: static, so it lives in the backdrop. The filled shape
        // is fully covered by video pixels every frame.
        if style.shadow > 0.01, style.background != .none {
            let minDimension = min(canvasSize.width, canvasSize.height)
            let blur = minDimension * 0.045 * style.shadow
            let cardRect = CGRect(
                x: layout.cardRect.minX,
                y: canvasSize.height - layout.cardRect.maxY,
                width: layout.cardRect.width,
                height: layout.cardRect.height
            )
            let radius = min(layout.cardCornerRadius, min(cardRect.width, cardRect.height) / 2)
            let path = radius > 0.5
                ? CGPath(roundedRect: cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                : CGPath(rect: cardRect, transform: nil)

            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -blur * 0.35),
                blur: blur,
                color: CGColor(gray: 0, alpha: 0.55 * style.shadow)
            )
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }

        return context.makeImage()
    }
}
