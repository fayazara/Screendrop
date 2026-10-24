//
//  RecordingStudioExporter.swift
//  Screendrop
//
//  Offline compositor for studio exports: decodes the screen (and camera)
//  recordings frame by frame, draws each frame through the same
//  RecordingStudioLayout / ViewportTimeline math the live preview
//  uses, and writes a new HEVC movie. Audio tracks (system + microphone)
//  are mixed and passed through on the unchanged timeline, unless the
//  project imported a soundtrack to replace them.
//
//  Everything static - the background fill and the card shadow - is
//  rendered once into a backdrop image. A Metal compute pass draws the
//  screen layer for every frame, blurred or settled; Core Graphics handles
//  rare fallback frames and the per-frame pointer, camera, and caption
//  overlays.
//

import AppKit
import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import OSLog
import SwiftUI
import VideoToolbox

nonisolated final class RecordingStudioExporter: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.fayazahmed.Screendrop", category: "StudioExport")

    struct Configuration: Sendable {
        let screenURL: URL
        let cameraURL: URL?
        let cameraOffset: TimeInterval
        /// The camera picture's width over its height, which a cutout's
        /// frame takes; nil assumes 16:9.
        let cameraAspect: CGFloat?
        let style: RecordingStudioStyle
        /// Where the screen and camera sit over time.
        let cameraLayoutTimeline: RecordingCameraLayoutTimeline
        let viewportTimeline: ViewportTimeline
        /// Non-nil when the capture hid the OS cursor and the export must
        /// draw the synthetic pointer along this smoothed timeline.
        let pointerTimeline: PointerTimeline?
        let showsPressEffects: Bool
        /// Non-nil when recorded keystroke chords should be captioned.
        let keystrokeTimeline: KeystrokeCaptionTimeline?
        let keystrokePlacement: RecordingKeystrokePlacement
        /// Non-nil when sped-up clips should carry the "2× ›››" badge.
        let speedBadgeTimeline: SpeedBadgeTimeline?
        let speedBadgePlacement: RecordingKeystrokePlacement
        /// Non-nil when transcribed narration should be subtitled.
        let subtitleTimeline: SubtitleTimeline?
        let subtitleStyle: SubtitleBarStyle
        /// Word timings behind the subtitles, for karaoke highlighting.
        let karaokeTimeline: KaraokeTimeline?
        let canvasSize: CGSize
        /// Normalized top-left crop of the screen-video source.
        let videoCropRect: CGRect
        let clipTimeline: RecordingClipTimeline
        var exportSettings: VideoCompressionSettings
        /// Non-nil when an imported soundtrack stands in for the recorded
        /// audio. It is already the finished cut's audio, so it plays flat
        /// from zero instead of being re-cut through the clip timeline.
        let audioReplacementURL: URL?
        let audioVolume: Double
        /// Non-nil when exporting into a different aspect ratio; drives the
        /// crop-and-follow virtual camera in place of the zoom viewport.
        let reframe: ReframeTrack?
        /// Non-nil for Original or a different aspect ratio in Fit
        /// mode: the recording shows in a content-aspect card and
        /// the background fills the rest. Mutually exclusive with
        /// `reframe`.
        let fitContentAspect: CGFloat?
        let usesUniformPadding: Bool
        /// Zoom cameras for fill splits, which crop the screen.
        let motionTimeline: RecordingStudioMotionTimeline
        /// Text over the canvas, on the source clock.
        var textOverlays: [RecordingTextOverlay] = []
        /// Regions of the recorded picture to pixelate or blur.
        var redactions: [RecordingRedaction] = []
        /// Images and GIFs over the canvas, on the source clock.
        var imageOverlays: [RecordingImageOverlay] = []
        /// Music and sound under the video, on the edited clock.
        var audioClips: [RecordingAudioClip] = []
        /// The project's media folder, holding both kinds' files.
        var mediaDirectory: URL?

        init(
            screenURL: URL,
            cameraURL: URL?,
            cameraOffset: TimeInterval,
            cameraAspect: CGFloat? = nil,
            style: RecordingStudioStyle,
            cameraLayoutTimeline: RecordingCameraLayoutTimeline,
            viewportTimeline: ViewportTimeline,
            pointerTimeline: PointerTimeline?,
            showsPressEffects: Bool,
            keystrokeTimeline: KeystrokeCaptionTimeline?,
            keystrokePlacement: RecordingKeystrokePlacement,
            speedBadgeTimeline: SpeedBadgeTimeline? = nil,
            speedBadgePlacement: RecordingKeystrokePlacement = .topRight,
            subtitleTimeline: SubtitleTimeline?,
            subtitleStyle: SubtitleBarStyle,
            karaokeTimeline: KaraokeTimeline? = nil,
            canvasSize: CGSize,
            videoCropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
            clipTimeline: RecordingClipTimeline,
            exportSettings: VideoCompressionSettings,
            audioReplacementURL: URL? = nil,
            audioVolume: Double = 1,
            reframe: ReframeTrack? = nil,
            fitContentAspect: CGFloat? = nil,
            usesUniformPadding: Bool = false,
            motionTimeline: RecordingStudioMotionTimeline = .none,
            textOverlays: [RecordingTextOverlay] = [],
            redactions: [RecordingRedaction] = [],
            imageOverlays: [RecordingImageOverlay] = [],
            audioClips: [RecordingAudioClip] = [],
            mediaDirectory: URL? = nil
        ) {
            self.screenURL = screenURL
            self.cameraURL = cameraURL
            self.cameraOffset = cameraOffset
            self.cameraAspect = cameraAspect
            self.style = style
            self.cameraLayoutTimeline = cameraLayoutTimeline
            self.viewportTimeline = viewportTimeline
            self.pointerTimeline = style.hidesCursor ? nil : pointerTimeline
            self.showsPressEffects = showsPressEffects
            self.keystrokeTimeline = keystrokeTimeline
            self.keystrokePlacement = keystrokePlacement
            self.speedBadgeTimeline = speedBadgeTimeline
            self.speedBadgePlacement = speedBadgePlacement
            self.subtitleTimeline = subtitleTimeline
            self.subtitleStyle = subtitleStyle
            self.karaokeTimeline = karaokeTimeline
            self.canvasSize = canvasSize
            self.videoCropRect = videoCropRect
            self.clipTimeline = clipTimeline
            self.exportSettings = exportSettings
            self.audioReplacementURL = audioReplacementURL
            self.audioVolume = audioVolume
            self.reframe = reframe
            self.fitContentAspect = fitContentAspect
            self.usesUniformPadding = usesUniformPadding
            self.motionTimeline = motionTimeline
            self.textOverlays = textOverlays
            self.redactions = redactions
            self.imageOverlays = imageOverlays
            self.audioClips = audioClips
            self.mediaDirectory = mediaDirectory
        }
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

    /// `@concurrent` keeps the frame loop off the caller's actor. Callers
    /// are main-actor models, and approachable concurrency would otherwise
    /// run this nonisolated async work - blocking reader calls included -
    /// on the main thread alongside the UI.
    @concurrent
    func export(
        _ configuration: Configuration,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let cancelFlag = CancelFlag()
        let started = CFAbsoluteTimeGetCurrent()
        return try await withTaskCancellationHandler {
            let result = try await run(configuration, cancelFlag: cancelFlag, progress: progress)
            Self.logger.info("Export completed totalSeconds=\(CFAbsoluteTimeGetCurrent() - started)")
            return result
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    private func run(
        _ configuration: Configuration,
        cancelFlag: CancelFlag,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let timing = RecordingExportTiming(settings: configuration.exportSettings)
        let sourceAsset = AVURLAsset(url: configuration.screenURL)
        let sourceDuration = try await sourceAsset.load(.duration).seconds
        let clipTimeline = configuration.clipTimeline.normalized(to: sourceDuration)
        guard clipTimeline.duration >= RecordingClipSegment.minimumDuration else {
            throw VideoTrimExportError.invalidRange
        }
        let screenAsset = try RecordingCompositionBuilder.makeAsset(
            from: sourceAsset,
            timeline: clipTimeline,
            sourceDuration: sourceDuration
        )
        guard let videoTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let audioTracks = try await screenAsset.loadTracks(withMediaType: .audio)
        let exportStartTime = CMTime.zero
        let exportTimeRange = CMTimeRange(
            start: exportStartTime,
            duration: CMTime(seconds: clipTimeline.duration, preferredTimescale: 600)
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
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        videoOutput.alwaysCopiesSampleData = false
        screenReader.add(videoOutput)
        screenReader.timeRange = exportTimeRange

        // An imported soundtrack replaces the recorded one wholesale, and it
        // needs its own reader: it is a different file, already carrying the
        // finished cut's timing, so it plays straight through from zero
        // while the screen reader stays on the composed video.
        var audioOutput: AVAssetReaderAudioMixOutput?
        var replacementReader: AVAssetReader?
        // Held for the whole export: the clips' tracks need their assets
        // alive while the audio is read.
        var clipSources: [RecordingAudioClipSource] = []
        if !configuration.exportSettings.removeAudio {
            if let directory = configuration.mediaDirectory {
                for clip in configuration.audioClips {
                    if let source = await RecordingAudioClipSource.load(clip, in: directory) {
                        clipSources.append(source)
                    }
                }
            }
            // Added audio mixes with the soundtrack on a reader of its own,
            // over a composition of the cut's audio and each clip.
            let mixed: (reader: AVAssetReader, output: AVAssetReaderAudioMixOutput)? = clipSources.isEmpty
                ? nil
                : try await Self.makeMixedAudio(
                    recordingTracks: audioTracks,
                    replacementURL: configuration.audioReplacementURL,
                    clips: clipSources,
                    timeRange: exportTimeRange,
                    volume: configuration.audioVolume
                )
            if let mixed {
                replacementReader = mixed.reader
                audioOutput = mixed.output
            } else if let replacementURL = configuration.audioReplacementURL {
                let replacementAsset = AVURLAsset(url: replacementURL)
                let replacementTracks = try await replacementAsset.loadTracks(withMediaType: .audio)
                if !replacementTracks.isEmpty {
                    let reader = try AVAssetReader(asset: replacementAsset)
                    // Clamps a soundtrack that overruns the cut; a shorter
                    // one simply leaves the tail silent.
                    reader.timeRange = exportTimeRange
                    let output = AVAssetReaderAudioMixOutput(
                        audioTracks: replacementTracks,
                        audioSettings: nil
                    )
                    output.audioMix = RecordingAudioGain.makeMix(tracks: replacementTracks, volume: configuration.audioVolume)
                    output.alwaysCopiesSampleData = false
                    reader.add(output)
                    replacementReader = reader
                    audioOutput = output
                }
            } else if !audioTracks.isEmpty {
                let output = AVAssetReaderAudioMixOutput(
                    audioTracks: audioTracks,
                    audioSettings: nil
                )
                output.audioMix = RecordingAudioGain.makeMix(tracks: audioTracks, volume: configuration.audioVolume)
                output.alwaysCopiesSampleData = false
                screenReader.add(output)
                audioOutput = output
            }
        }

        let cameraFeed = try await CameraFrameFeed(
            url: configuration.cameraURL,
            offset: configuration.cameraOffset,
            beauty: StudioCameraBeautyFrameFilter(beauty: configuration.style.camera.beauty)
        )

        // Writer
        let container = configuration.exportSettings.effectiveContainer
        let outputURL = Self.temporaryOutputURL(container: container)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: container.fileType)
        // Faststart puts the index ahead of the media so a shared link plays
        // before it finishes downloading. The writer pays for that with an
        // extra pass at the end, so only MP4 - the container people actually
        // stream - opts in.
        writer.shouldOptimizeForNetworkUse = container.supportsFastStart

        let codec: AVVideoCodecType = configuration.exportSettings.codec == .hevc ? .hevc : .h264
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: Self.averageBitRate(
                width: canvasWidth,
                height: canvasHeight,
                quality: configuration.exportSettings.quality
            ),
            AVVideoExpectedSourceFrameRateKey: timing.framesPerSecond
        ]
        if codec == .hevc {
            // The hardware HEVC encoder is the export's ceiling at Retina
            // sizes; its speed mode runs ~1.75x faster (52 -> 91 fps at
            // 3760x2538 on M4 Pro) for ~1.5 dB PSNR, still above 40 dB.
            // H.264's encoder ignores this flag.
            compressionProperties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: canvasWidth,
            AVVideoHeightKey: canvasHeight,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: canvasWidth,
                kCVPixelBufferHeightKey as String: canvasHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
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
        if let replacementReader, !replacementReader.startReading() {
            screenReader.cancelReading()
            throw replacementReader.error ?? ExportError.writerFailed(nil)
        }
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: exportStartTime)

        let compositor = StudioFrameCompositor(
            canvasSize: canvasSize,
            videoCropRect: configuration.videoCropRect,
            style: configuration.style,
            cameraLayoutTimeline: configuration.cameraLayoutTimeline,
            viewportTimeline: configuration.viewportTimeline,
            pointerTimeline: configuration.pointerTimeline,
            showsPressEffects: configuration.showsPressEffects,
            keystrokeTimeline: configuration.keystrokeTimeline,
            keystrokePlacement: configuration.keystrokePlacement,
            speedBadgeTimeline: configuration.speedBadgeTimeline,
            speedBadgePlacement: configuration.speedBadgePlacement,
            subtitleTimeline: configuration.subtitleTimeline,
            subtitleStyle: configuration.subtitleStyle,
            karaokeTimeline: configuration.karaokeTimeline,
            includeBubble: cameraFeed != nil,
            cameraAspect: configuration.cameraAspect ?? RecordingCameraLayoutResolver.defaultCameraAspect,
            timing: timing,
            reframe: configuration.reframe,
            fitContentAspect: configuration.fitContentAspect,
            usesUniformPadding: configuration.usesUniformPadding,
            motionTimeline: configuration.motionTimeline,
            textOverlays: configuration.textOverlays,
            imageOverlays: configuration.imageOverlays,
            mediaDirectory: configuration.mediaDirectory
        )

        // A cutout's mattes are made ahead of the frames that show them, on
        // their own decode of the camera, for exactly those frames.
        var cutoutMattes: StudioCameraMatteTrack?
        if cameraFeed != nil, configuration.cameraLayoutTimeline.usesCutout, let cameraURL = configuration.cameraURL {
            let frameCount = timing.frameCount(for: clipTimeline.duration)
            let neededTimes = (0..<frameCount).compactMap { frame -> TimeInterval? in
                let editorTime = timing.time(forFrame: frame)
                guard compositor.showsCutout(at: editorTime) else { return nil }
                return clipTimeline.location(at: editorTime)?.sourceTime
            }
            if !neededTimes.isEmpty {
                cutoutMattes = await StudioCameraMatteTrack(
                    url: cameraURL, offset: configuration.cameraOffset, neededTimes: neededTimes
                )
                compositor.cutoutMattes = cutoutMattes
            }
        }

        let screenAudioOutput = audioOutput
        let writerAudioInput = audioInput

        do {
            async let videoDone: Void = pumpVideo(
                output: videoOutput,
                input: videoInput,
                adaptor: adaptor,
                compositor: compositor,
                cameraFeed: cameraFeed,
                redactionFilter: RecordingRedactionFrameFilter(redactions: configuration.redactions),
                clipTimeline: clipTimeline,
                timing: timing,
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
            replacementReader?.cancelReading()
            cameraFeed?.cancel()
            cutoutMattes?.cancel()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        cameraFeed?.cancel()
        cutoutMattes?.cancel()
        withExtendedLifetime(clipSources) {}

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
        redactionFilter: RecordingRedactionFrameFilter?,
        clipTimeline: RecordingClipTimeline,
        timing: RecordingExportTiming,
        cancelFlag: CancelFlag,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Render on a fixed output clock, not per source frame. Screen
        // captures only contain frames where pixels changed, so a static
        // screen has second-long gaps - but the virtual camera animates
        // through them (most zoom-outs happen exactly there, seconds after
        // the last click). Each tick re-renders the newest source frame at
        // or before it; only writing on source arrivals would hold the last
        // zoomed frame through the move and then visibly jump.
        let duration = clipTimeline.duration
        let frameCount = timing.frameCount(for: duration)

        var decodeSeconds = 0.0
        func nextSourceFrame() -> (buffer: CVPixelBuffer, time: TimeInterval)? {
            let decodeStart = CFAbsoluteTimeGetCurrent()
            defer { decodeSeconds += CFAbsoluteTimeGetCurrent() - decodeStart }
            while let sampleBuffer = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                return (buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
            }
            return nil
        }

        var currentBuffer: CVPixelBuffer?
        var pending = nextSourceFrame()
        var previousClipID: UUID?
        var renderSeconds = 0.0
        var writerWaitSeconds = 0.0
        var cameraSeconds = 0.0
        var renderedFrames = 0
        defer {
            Self.logger.info("Export frames=\(renderedFrames) fps=\(timing.framesPerSecond) motionBlur=\(timing.motionBlurEnabled) Metal blur frames=\(compositor.metalFrameCount) reusedScreenFrames=\(compositor.reusedScreenFrameCount) reusedComposedFrames=\(compositor.reusedComposedFrameCount) renderSeconds=\(renderSeconds) metalSeconds=\(compositor.metalSeconds) cutoutWaitSeconds=\(compositor.cutoutWaitSeconds) decodeSeconds=\(decodeSeconds) cameraSeconds=\(cameraSeconds) writerWaitSeconds=\(writerWaitSeconds)")
        }

        // The adaptor's pool appears shortly after writing starts and then
        // stays fixed, but reading it takes the compression session's lock,
        // which the encoder holds while it works. Asked for every frame,
        // that stalled rendering for as long as the encoder was busy.
        var cachedPool: CVPixelBufferPool?

        var inFlight: (frame: StudioFrameCompositor.PendingFrame, index: Int)?
        func finishAndAppend(_ begun: StudioFrameCompositor.PendingFrame, at index: Int) async throws {
            let renderStart = CFAbsoluteTimeGetCurrent()
            try autoreleasepool {
                try compositor.finish(begun)
            }
            renderSeconds += CFAbsoluteTimeGetCurrent() - renderStart
            renderedFrames += 1

            let waitStart = CFAbsoluteTimeGetCurrent()
            while !input.isReadyForMoreMediaData {
                if cancelFlag.isCancelled { throw ExportError.cancelled }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            writerWaitSeconds += CFAbsoluteTimeGetCurrent() - waitStart

            if !adaptor.append(begun.destination, withPresentationTime: timing.presentationTime(forFrame: index)) {
                throw ExportError.writerFailed(nil)
            }
            if index % 10 == 0 {
                progress(min(0.98, Double(index) / Double(frameCount)))
            }
        }

        for frame in 0..<frameCount {
            if cancelFlag.isCancelled { throw ExportError.cancelled }
            let editorTime = timing.time(forFrame: frame)
            guard let location = clipTimeline.location(at: editorTime) else { break }
            let sourceTime = location.sourceTime

            if previousClipID != location.segmentID {
                // Never carry a sparse screen-capture frame across a hard
                // edit boundary - the reader may not have caught up yet to
                // the new clip's starting source position.
                if previousClipID != nil {
                    currentBuffer = nil
                }
                previousClipID = location.segmentID
            }

            while let sample = pending, sample.time <= editorTime {
                currentBuffer = sample.buffer
                pending = nextSourceFrame()
            }
            // Ticks before the first source frame show it early rather than
            // emitting black; a capture with no frames at all has nothing to
            // render.
            guard let decodedBuffer = currentBuffer ?? pending?.buffer else { break }
            // Pixelated regions belong to the recorded picture, so they are
            // filtered in before the frame is laid out on the canvas.
            let sourceBuffer = redactionFilter?.apply(to: decodedBuffer, atSourceTime: sourceTime) ?? decodedBuffer

            if cachedPool == nil { cachedPool = adaptor.pixelBufferPool }
            guard let pool = cachedPool else {
                throw ExportError.writerFailed(nil)
            }
            let cameraStart = CFAbsoluteTimeGetCurrent()
            let camera = cameraFeed?.latestFrame(at: sourceTime)
            cameraSeconds += CFAbsoluteTimeGetCurrent() - cameraStart
            let nextTime = timing.time(forFrame: frame + 1)
            let sourceRepeats = (pending == nil || pending!.time > nextTime)
                && clipTimeline.location(at: nextTime)?.segmentID == location.segmentID
            let renderStart = CFAbsoluteTimeGetCurrent()
            let begun = try autoreleasepool {
                try compositor.begin(
                    screenFrame: sourceBuffer,
                    cameraFrame: camera?.buffer,
                    cameraTime: camera?.time ?? 0,
                    editorTime: editorTime,
                    sourceTime: sourceTime,
                    sourceRepeatsOnNextFrame: sourceRepeats,
                    pool: pool
                )
            }
            renderSeconds += CFAbsoluteTimeGetCurrent() - renderStart

            // The GPU renders this frame while the previous one gets its
            // overlays and goes to the encoder.
            if let previous = inFlight {
                try await finishAndAppend(previous.frame, at: previous.index)
            }
            inFlight = (begun, frame)
        }
        if let previous = inFlight {
            try await finishAndAppend(previous.frame, at: previous.index)
        }
        input.markAsFinished()
    }

    /// The finished video's audio: the recording's cut audio (or the
    /// imported soundtrack standing in for it) at the project's volume,
    /// plus every added clip with its own volume and fades.
    private static func makeMixedAudio(
        recordingTracks: [AVAssetTrack],
        replacementURL: URL?,
        clips: [RecordingAudioClipSource],
        timeRange: CMTimeRange,
        volume: Double
    ) async throws -> (reader: AVAssetReader, output: AVAssetReaderAudioMixOutput)? {
        let composition = AVMutableComposition()
        var recordingTrackIDs: [CMPersistentTrackID] = []
        if let replacementURL {
            let replacement = AVURLAsset(url: replacementURL)
            if let track = try await replacement.loadTracks(withMediaType: .audio).first {
                let length = min(try await replacement.load(.duration), timeRange.duration)
                if let added = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try added.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)
                    recordingTrackIDs.append(added.trackID)
                }
            }
        } else {
            for track in recordingTracks {
                guard let added = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let available = try await track.load(.timeRange)
                let range = CMTimeRangeGetIntersection(timeRange, otherRange: available)
                guard range.duration > .zero else { continue }
                try added.insertTimeRange(range, of: track, at: range.start)
                recordingTrackIDs.append(added.trackID)
            }
        }
        let clipTrackIDs = RecordingAudioClipMixer.insert(clips, into: composition, videoDuration: timeRange.duration.seconds)
        let tracks = composition.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = timeRange
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: nil)
        output.audioMix = RecordingAudioClipMixer.mix(
            recordingTracks: tracks.filter { recordingTrackIDs.contains($0.trackID) },
            recordingVolume: volume,
            clips: clips.map(\.clip),
            trackIDs: clipTrackIDs
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        return (reader, output)
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

    private static func temporaryOutputURL(container: VideoExportContainer) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Screendrop", isDirectory: true)
            .appendingPathComponent("StudioExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString).\(container.fileExtension)")
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
    /// Touches up each frame once, as it becomes the current one.
    private let beauty: StudioCameraBeautyFrameFilter?
    private var currentFrame: (buffer: CVPixelBuffer, time: TimeInterval)?
    private var isCurrentTouchedUp = false
    /// Decoded frames after the current one, oldest first.
    private var ahead: [(buffer: CVPixelBuffer, time: TimeInterval)] = []
    private var isFinished = false

    init?(url: URL?, offset: TimeInterval, beauty: StudioCameraBeautyFrameFilter? = nil) async throws {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                // IOSurface-backed so the bubble scaler can read it on the GPU.
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? RecordingStudioExporter.ExportError.noVideoTrack
        }

        self.reader = reader
        self.output = output
        self.offset = offset
        self.beauty = beauty
    }

    /// `time` is the frame's own time on the screen's clock.
    func latestFrame(at screenTime: TimeInterval) -> (buffer: CVPixelBuffer, time: TimeInterval)? {
        while true {
            if let next = ahead.first {
                // Promote the very first frame unconditionally: the camera
                // starts a beat after the screen (capture warmup), and holding
                // its first frame from t=0 beats the bubble popping in late.
                guard next.time <= screenTime || currentFrame == nil else { break }
                currentFrame = next
                isCurrentTouchedUp = false
                ahead.removeFirst()
            } else if !decodeNext() {
                break
            }
        }
        // Only the frame shown is touched up, not those skipped past.
        if let beauty, let frame = currentFrame, !isCurrentTouchedUp {
            currentFrame = (beauty.apply(to: frame.buffer, time: frame.time), frame.time)
            isCurrentTouchedUp = true
        }
        return currentFrame
    }

    private func decodeNext() -> Bool {
        guard !isFinished else { return false }
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            ahead.append((buffer, CMSampleBufferGetPresentationTimeStamp(sample).seconds + offset))
            return true
        }
        isFinished = true
        return false
    }

    func cancel() {
        reader.cancelReading()
    }
}

/// A layout holding still: settled on the timeline, with a corner camera
/// either full size or fully shrunk for a zoom.
nonisolated private struct SettledLayout: Hashable, Sendable {
    let layout: RecordingCameraLayout
    let isShrunk: Bool
}

// MARK: - Frame compositor

/// Draws one output frame: cached backdrop, then the zoom-transformed screen
/// frame clipped to the rounded card, then the camera.
///
/// The camera layout timeline moves the card and the camera. While a layout
/// is settled, everything static about it - the backdrop with the card's
/// shadow, the Metal clip, the camera's shadow and scaler - is built once
/// and kept for the next time that layout shows. Frames inside a morph are
/// drawn in full by Core Graphics, with the moving screen and camera
/// averaged across the shutter like any other camera move.
nonisolated private final class StudioFrameCompositor: @unchecked Sendable {
    /// Everything that stays fixed while one layout is settled.
    fileprivate final class LayoutResources {
        let layout: RecordingStudioLayout
        let backdrop: CGImage?
        var metalRenderer: StudioMetalScreenRenderer?
        var bubbleShadow: (image: CGImage, rect: CGRect)??
        var cameraScaler: StudioCameraBubbleScaler??
        /// Retained so pixel-buffer pool reuse can't produce a false cache hit.
        var bubbleContentSource: CVPixelBuffer?
        var bubbleContentImage: CGImage?
        var scheduledCameraSource: CVPixelBuffer?
        var scheduledCameraSubmission: StudioCameraBubbleScaler.Submission?

        init(layout: RecordingStudioLayout, backdrop: CGImage?) {
            self.layout = layout
            self.backdrop = backdrop
        }
    }

    private let canvasSize: CGSize
    private let videoCropRect: CGRect
    private let style: RecordingStudioStyle
    /// The resting card, before any camera layout moves it.
    private let baseLayout: RecordingStudioLayout
    private let layoutResolver: RecordingCameraLayoutResolver
    private let layoutTimeline: RecordingCameraLayoutTimeline
    /// The frame being finished. `begin` runs a frame ahead, so it works
    /// from its own resolved layout and never reads this.
    private var layout: RecordingStudioLayout
    /// Settled layouts' resources, most recent last. Two cover the common
    /// back-and-forth between a talking head and the screen without holding
    /// a full-canvas backdrop per layout the export ever used.
    private var layoutResources: [(key: SettledLayout, resources: LayoutResources)] = []
    private static let maxLayoutResources = 2
    /// Morph frames compute the card's clip and shadow on the GPU over the
    /// plain background, so one renderer serves every one of them.
    private var morphRenderer: StudioMetalScreenRenderer?
    private var morphRendererFailed = false
    /// The camera inside a morph; nil until needed or if Metal can't.
    private var morphCameraRenderer: StudioMorphCameraRenderer?
    private var morphCameraRendererFailed = false
    /// The cutout's mattes, made ahead; nil when no layout cuts it out.
    var cutoutMattes: StudioCameraMatteTrack?
    /// Segments a frame the matte track missed, which should be none.
    private lazy var fallbackMattes = StudioCameraMatteGenerator()
    /// Time finishing frames spent waiting for Vision.
    private(set) var cutoutWaitSeconds = 0.0
    /// A quarter-size canvas for the moving card's shadow. A shadow is a
    /// blur, so its resolution doesn't show, and full size costs ten times
    /// as much every frame.
    private lazy var morphShadowContext: CGContext? = {
        let width = max(1, Int((canvasSize.width / Self.morphShadowScale).rounded(.up)))
        let height = max(1, Int((canvasSize.height / Self.morphShadowScale).rounded(.up)))
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }()
    private static let morphShadowScale: CGFloat = 4
    /// Card-space overlays (pointer, captions) fade with the screen.
    private var overlayOpacity: CGFloat = 1
    private let viewportTimeline: ViewportTimeline
    private let pointerTimeline: PointerTimeline?
    private let showsPressEffects: Bool
    private let keystrokeTimeline: KeystrokeCaptionTimeline?
    private let keystrokePlacement: RecordingKeystrokePlacement
    private let speedBadgeTimeline: SpeedBadgeTimeline?
    private let speedBadgePlacement: RecordingKeystrokePlacement
    private let subtitleTimeline: SubtitleTimeline?
    private let subtitleStyle: SubtitleBarStyle
    private let karaokeTimeline: KaraokeTimeline?
    private let reframe: ReframeTrack?
    private let motionTimeline: RecordingStudioMotionTimeline
    private let textOverlays: [RecordingTextOverlay]
    private let imageOverlays: [RecordingImageOverlay]
    private let mediaDirectory: URL?
    private let overlayImages = RecordingOverlayImageStore()
    private var artworkImageCache: [String: CGImage] = [:]
    private lazy var pointerMaterialRenderer = PointerMaterialRenderer()
    private let pointerScale: CGFloat
    private let colorSpace: CGColorSpace
    /// The background alone, for frames inside a layout morph.
    private let plainBackdrop: CGImage?
    private let timing: RecordingExportTiming
    private var metalFailed = false
    private(set) var metalFrameCount = 0
    /// Wall time submitting and waiting on Metal passes. With a frame in
    /// flight this is only the GPU time the CPU could not overlap.
    private(set) var metalSeconds = 0.0
    private let screenLayerCache = StudioScreenLayerCache()
    /// The layer the cache will hold once every begun frame finishes. The
    /// layout is part of the key: the cached layer includes its backdrop.
    private var plannedCacheKey: (source: CVPixelBuffer, rect: CGRect, layout: SettledLayout)?
    private(set) var reusedScreenFrameCount = 0
    private let composedFrameCache = StudioComposedFrameCache<ComposedFrameState>()
    private(set) var reusedComposedFrameCount = 0
    private let bypassFrameCache = ProcessInfo.processInfo.environment["SCREENDROP_EXPORT_BYPASS_FRAME_CACHE"] == "1"
    private let bypassScreenCache = ProcessInfo.processInfo.environment["SCREENDROP_EXPORT_BYPASS_SCREEN_CACHE"] == "1"
    // Developer comparison switch; export settings and saved projects do not change.
    private let forceCoreGraphics = ProcessInfo.processInfo.environment["SCREENDROP_EXPORT_RENDERER"] == "cpu"

    init(
        canvasSize: CGSize,
        videoCropRect: CGRect,
        style: RecordingStudioStyle,
        cameraLayoutTimeline: RecordingCameraLayoutTimeline,
        viewportTimeline: ViewportTimeline,
        pointerTimeline: PointerTimeline?,
        showsPressEffects: Bool,
        keystrokeTimeline: KeystrokeCaptionTimeline?,
        keystrokePlacement: RecordingKeystrokePlacement,
        speedBadgeTimeline: SpeedBadgeTimeline? = nil,
        speedBadgePlacement: RecordingKeystrokePlacement = .topRight,
        subtitleTimeline: SubtitleTimeline?,
        subtitleStyle: SubtitleBarStyle = SubtitleBarStyle(),
        karaokeTimeline: KaraokeTimeline? = nil,
        includeBubble: Bool,
        cameraAspect: CGFloat = RecordingCameraLayoutResolver.defaultCameraAspect,
        timing: RecordingExportTiming,
        reframe: ReframeTrack? = nil,
        fitContentAspect: CGFloat? = nil,
        usesUniformPadding: Bool = false,
        motionTimeline: RecordingStudioMotionTimeline = .none,
        textOverlays: [RecordingTextOverlay] = [],
        imageOverlays: [RecordingImageOverlay] = [],
        mediaDirectory: URL? = nil
    ) {
        self.canvasSize = canvasSize
        self.textOverlays = textOverlays
        self.imageOverlays = mediaDirectory == nil ? [] : imageOverlays
        self.mediaDirectory = mediaDirectory
        self.videoCropRect = RecordingVideoCropGeometry.normalized(videoCropRect)
        self.style = style
        let baseLayout = RecordingStudioLayout.make(
            canvasSize: canvasSize,
            style: style,
            usesUniformPadding: usesUniformPadding,
            contentAspect: reframe?.sourceAspect ?? fitContentAspect,
            contentMode: fitContentAspect != nil && reframe == nil ? .fit : .fill,
            contentCropRect: videoCropRect
        )
        self.baseLayout = baseLayout
        self.layoutResolver = RecordingCameraLayoutResolver(
            base: baseLayout,
            style: style,
            showsCamera: includeBubble,
            cameraAspect: cameraAspect
        )
        self.layoutTimeline = cameraLayoutTimeline
        self.layout = baseLayout
        self.viewportTimeline = viewportTimeline
        self.pointerTimeline = style.hidesCursor ? nil : pointerTimeline
        self.showsPressEffects = showsPressEffects
        self.keystrokeTimeline = keystrokeTimeline
        self.keystrokePlacement = keystrokePlacement
        self.speedBadgeTimeline = speedBadgeTimeline
        self.speedBadgePlacement = speedBadgePlacement
        self.subtitleTimeline = subtitleTimeline
        self.subtitleStyle = subtitleStyle
        self.karaokeTimeline = karaokeTimeline
        self.reframe = reframe
        // Without a camera every layout resolves to the bare screen.
        self.motionTimeline = motionTimeline
        self.timing = timing
        self.pointerScale = style.cursorScale
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.plainBackdrop = Self.renderBackdrop(
            canvasSize: canvasSize,
            layout: nil,
            style: style,
            colorSpace: colorSpace
        )
    }

    /// The layout state and resolved layout at an editor time. The zoom
    /// at that moment sizes a corner camera.
    private func frameLayout(at editorTime: TimeInterval) -> (
        layout: RecordingStudioLayout,
        settled: SettledLayout?
    ) {
        if let frame = motionTimeline.layoutFrame(at: editorTime, canvasSize: canvasSize) {
            let layout = baseLayout.applying(frame)
            guard motionTimeline.isLayoutSettled(at: editorTime) else { return (layout, nil) }
            return (layout, SettledLayout(
                layout: layoutTimeline.layout(at: editorTime),
                isShrunk: motionTimeline.isZoomed(at: editorTime)
            ))
        }
        let state = layoutTimeline.state(at: editorTime)
        let zoomProgress = viewportTimeline.zoomProgress(at: editorTime)
        let layout = layoutResolver.layout(for: state, zoomProgress: zoomProgress)
        guard let settled = state.settledLayout else { return (layout, nil) }
        guard settled.kind == .pictureInPicture || settled.kind == .cutout else {
            return (layout, SettledLayout(layout: settled, isShrunk: false))
        }
        // A camera mid-shrink is moving, so it isn't settled; full
        // size and shrunk are two steady states with their own resources.
        let scale = layoutResolver.cameraScale(forZoomProgress: zoomProgress)
        if abs(scale - 1) < 0.0001 {
            return (layout, SettledLayout(layout: settled, isShrunk: false))
        }
        if abs(scale - layoutResolver.zoomedCameraScale) < 0.0001 {
            return (layout, SettledLayout(layout: settled, isShrunk: true))
        }
        return (layout, nil)
    }

    /// Where the screen draws at an editor time, with the layout at that
    /// same moment - so a morph blurs like any other camera move.
    private func screenDrawRect(at editorTime: TimeInterval) -> CGRect {
        frameLayout(at: editorTime).layout.frameRect(for: viewportFrame(at: editorTime))
    }

    private func resources(for key: SettledLayout, layout: RecordingStudioLayout) -> LayoutResources {
        if let index = layoutResources.firstIndex(where: { $0.key == key }) {
            let entry = layoutResources.remove(at: index)
            layoutResources.append(entry)
            return entry.resources
        }
        let resources = LayoutResources(
            layout: layout,
            backdrop: Self.renderBackdrop(
                canvasSize: canvasSize,
                layout: layout.screenOpacity > 0.001 ? layout : nil,
                style: style,
                colorSpace: colorSpace
            )
        )
        layoutResources.append((key, resources))
        if layoutResources.count > Self.maxLayoutResources {
            layoutResources.removeFirst()
        }
        return resources
    }

    /// The viewport derived from the shared screen-motion rectangle. Older
    /// callers without that track retain the reframe/zoom camera fallback.
    private func viewportFrame(at editorTime: TimeInterval) -> ViewportFrame {
        if let viewport = motionTimeline.viewport(at: editorTime) { return viewport }
        let base = reframe?.frame(at: editorTime) ?? viewportTimeline.frame(at: editorTime)
        return RecordingVideoCropGeometry.viewport(base, crop: videoCropRect)
    }

    /// Only settled, single-sample frames qualify. Include the actual
    /// interpolated geometry and every overlay's displayed state: a layout
    /// label or a stationary cursor alone is insufficient to establish that
    /// the complete frame is unchanged. Buffer identity retains its source.
    private struct ComposedFrameState: Equatable {
        let screen: CVPixelBuffer?
        let camera: CVPixelBuffer?
        let layout: RecordingStudioLayout
        let screenRect: CGRect?
        let pointer: PointerFrame?
        let keystroke: KeystrokeCaptionFrame?
        let speedBadge: SpeedBadgeFrame?
        let subtitle: String?
        let karaoke: KaraokeTimeline.Line?

        static func == (a: Self, b: Self) -> Bool {
            a.screen === b.screen && a.camera === b.camera && a.layout == b.layout
                && a.screenRect == b.screenRect && a.pointer == b.pointer
                && a.keystroke == b.keystroke && a.speedBadge == b.speedBadge
                && a.subtitle == b.subtitle && a.karaoke == b.karaoke
        }
    }

    private func composedState(
        screenFrame: CVPixelBuffer, cameraFrame: CVPixelBuffer?,
        layout: RecordingStudioLayout, settled: SettledLayout?, sampleRects: [CGRect],
        editorTime: TimeInterval, sourceTime: TimeInterval
    ) -> ComposedFrameState? {
        guard !bypassFrameCache, settled != nil, sampleRects.count <= 1 else { return nil }
        // Text animates on its own clock, so a frame showing any is drawn
        // fresh rather than matched against the last one.
        guard !textOverlays.contains(where: { $0.isActive(atSourceTime: sourceTime) }),
              !imageOverlays.contains(where: { $0.isActive(atSourceTime: sourceTime) }) else { return nil }
        let showsScreen = layout.screenOpacity > 0.001
        let showsCamera = layout.cameraOpacity > 0.001 && layout.bubbleRect.width > 0
        let subtitle = subtitleTimeline?.text(at: sourceTime)
        return ComposedFrameState(
            screen: showsScreen ? screenFrame : nil,
            camera: showsCamera ? cameraFrame : nil,
            layout: layout,
            screenRect: sampleRects.first,
            pointer: showsScreen ? pointerTimeline?.frame(at: editorTime) : nil,
            keystroke: showsScreen ? keystrokeTimeline?.frame(at: sourceTime) : nil,
            speedBadge: showsScreen ? speedBadgeTimeline?.frame(at: editorTime) : nil,
            subtitle: subtitle,
            karaoke: subtitle != nil && subtitleStyle.highlightsSpokenWord ? karaokeTimeline?.line(at: sourceTime) : nil
        )
    }

    /// A frame whose screen layer may still be rendering on the GPU.
    struct PendingFrame {
        fileprivate let screenFrame: CVPixelBuffer
        fileprivate let cameraFrame: CVPixelBuffer?
        fileprivate let cameraTime: TimeInterval
        fileprivate let editorTime: TimeInterval
        fileprivate let sourceTime: TimeInterval
        fileprivate let layout: RecordingStudioLayout
        /// Nil while the frame is inside a layout morph.
        fileprivate let settledLayout: SettledLayout?
        fileprivate let sampleRects: [CGRect]
        fileprivate let shouldCacheScreen: Bool
        /// Set when the previous frame leaves this exact screen layer in the
        /// cache; the restore itself waits for finish, which runs in order.
        fileprivate let plansRestore: Bool
        fileprivate let submission: StudioMetalScreenRenderer.Submission?
        fileprivate let resources: LayoutResources?
        fileprivate let cameraSubmission: StudioCameraBubbleScaler.Submission?
        fileprivate let reusesComposedFrame: Bool
        let destination: CVPixelBuffer
    }

    /// Starts a frame: resolves its shutter and submits the GPU screen pass
    /// without waiting, so the caller can finish the previous frame while
    /// this one renders. Frames must be finished in the order they began.
    func begin(
        screenFrame: CVPixelBuffer,
        cameraFrame: CVPixelBuffer?,
        cameraTime: TimeInterval = 0,
        editorTime: TimeInterval,
        sourceTime: TimeInterval,
        sourceRepeatsOnNextFrame: Bool,
        pool: CVPixelBufferPool
    ) throws -> PendingFrame {
        let (frameLayout, settled) = frameLayout(at: editorTime)
        let showsScreen = frameLayout.screenOpacity > 0.001
        let sampleRects = showsScreen
            ? timing.screenSampleRects(at: editorTime, frameRect: screenDrawRect(at:))
            : []
        let sampleCount = sampleRects.count
        let composedState = composedState(
            screenFrame: screenFrame, cameraFrame: cameraFrame,
            layout: frameLayout, settled: settled, sampleRects: sampleRects,
            editorTime: editorTime, sourceTime: sourceTime
        )
        if let composedState, let cached = composedFrameCache.frame(matching: composedState) {
            // The preceding frame finishes before this one, completing the
            // shared buffer exactly once. Subsequent encoder submissions are
            // read-only and keep the full selected 30/60 fps output cadence.
            return PendingFrame(
                screenFrame: screenFrame, cameraFrame: cameraFrame, cameraTime: cameraTime,
                editorTime: editorTime, sourceTime: sourceTime, layout: frameLayout,
                settledLayout: settled, sampleRects: sampleRects, shouldCacheScreen: false,
                plansRestore: false, submission: nil, resources: nil, cameraSubmission: nil,
                reusesComposedFrame: true, destination: cached
            )
        }
        var destinationBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationBuffer) == kCVReturnSuccess,
              let destination = destinationBuffer else {
            throw RecordingStudioExporter.ExportError.writerFailed(nil)
        }
        let plansRestore = !bypassScreenCache && sampleCount == 1
            && plannedCacheKey.map {
                $0.source === screenFrame && $0.rect == sampleRects[0] && $0.layout == settled
            } == true
        // Cache only a settled layer that can be reused on the next tick.
        // Moving frames and continuously changing video avoid the extra copy.
        let shouldCacheScreen = !bypassScreenCache && sourceRepeatsOnNextFrame && sampleCount == 1
            && settled != nil
            && self.frameLayout(at: editorTime + timing.frameInterval).settled == settled
            && sampleRects[0] == screenDrawRect(at: editorTime + timing.frameInterval)
            && StudioScreenLayerCache.canCapture(width: Int(canvasSize.width), height: Int(canvasSize.height))
        // Mirrors the cache transitions finish(_:) applies in order: a
        // restored layer stays cached, a newly cached one replaces it, and
        // anything else clears it.
        if !shouldCacheScreen {
            plannedCacheKey = nil
        } else if !plansRestore, let settled {
            plannedCacheKey = (screenFrame, sampleRects[0], settled)
        }

        let submission: StudioMetalScreenRenderer.Submission? = if plansRestore {
            nil
        } else if settled == nil {
            submitMorphMetal(screenFrame: screenFrame, sampleRects: sampleRects, layout: frameLayout, into: destination)
        } else {
            submitMetal(
                screenFrame: screenFrame, sampleRects: sampleRects, settled: settled,
                layout: frameLayout, into: destination
            )
        }
        let resources = settled.map { resources(for: $0, layout: frameLayout) }
        let showsCamera = cameraFrame != nil && frameLayout.bubbleRect.width > 0 && frameLayout.cameraOpacity > 0.001
        let cameraSubmission = if let resources, let cameraFrame, showsCamera, frameLayout.cameraCutout <= 0.001 {
            prepareCamera(cameraFrame, resources: resources)
        } else {
            nil as StudioCameraBubbleScaler.Submission?
        }
        composedFrameCache.store(destination, state: composedState)
        return PendingFrame(
            screenFrame: screenFrame,
            cameraFrame: cameraFrame,
            cameraTime: cameraTime,
            editorTime: editorTime,
            sourceTime: sourceTime,
            layout: frameLayout,
            settledLayout: settled,
            sampleRects: sampleRects,
            shouldCacheScreen: shouldCacheScreen,
            plansRestore: plansRestore,
            submission: submission,
            resources: resources,
            cameraSubmission: cameraSubmission,
            reusesComposedFrame: false,
            destination: destination
        )
    }

    /// Completes a frame begun earlier: waits for its screen pass, then draws
    /// the CPU overlays into its destination.
    func finish(_ frame: PendingFrame) throws {
        if frame.reusesComposedFrame {
            reusedComposedFrameCount += 1
            return
        }
        layout = frame.layout
        let destination = frame.destination
        let screenFrame = frame.screenFrame
        let sampleRects = frame.sampleRects
        let settled = frame.settledLayout
        let resources = frame.resources
        let reusedScreen = frame.plansRestore && screenLayerCache.restore(
            source: screenFrame, rect: sampleRects[0], into: destination
        )
        if reusedScreen { reusedScreenFrameCount += 1 }
        else { screenLayerCache.invalidate() }

        // Metal completes before the CPU locks this IOSurface for overlays.
        // A planned restore that failed renders its layer now instead.
        var renderedWithMetal = false
        if !reusedScreen,
           let submission = frame.submission ?? submitMetal(
               screenFrame: screenFrame, sampleRects: sampleRects, settled: settled,
               layout: frame.layout, into: destination
           ) {
            let waitStart = CFAbsoluteTimeGetCurrent()
            // The submission holds its own command buffer, so it can be
            // waited on even if its layout's resources were since evicted.
            renderedWithMetal = StudioMetalScreenRenderer.wait(for: submission)
            metalSeconds += CFAbsoluteTimeGetCurrent() - waitStart
            if renderedWithMetal { metalFrameCount += 1 }
            else { metalFailed = true }
        }
        let shouldCacheScreen = frame.shouldCacheScreen
        let editorTime = frame.editorTime
        let sourceTime = frame.sourceTime
        let cameraFrame = frame.cameraFrame
        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        guard var context = lockedContext(for: destination) else {
            throw RecordingStudioExporter.ExportError.writerFailed(nil)
        }

        let screenOpacity = layout.screenOpacity
        if !reusedScreen, !renderedWithMetal {
            if let resources {
                drawBackdrop(resources.backdrop, in: context)
            } else {
                // Inside a morph the card moves, so its shadow does too.
                drawBackdrop(plainBackdrop, in: context)
                drawCardShadow(for: layout, in: context)
            }
        }

        var renderedScreen = reusedScreen || renderedWithMetal
        if !reusedScreen, !renderedWithMetal, !sampleRects.isEmpty,
           let screenImage = Self.makeImage(from: screenFrame, colorSpace: colorSpace) {
            // Motion blur by temporal supersampling: while the virtual camera
            // is moving, average several sub-frame camera states across the
            // frame's shutter interval. Pans smear linearly, zooms radially,
            // and settled frames pay for a single draw. The viewport timeline
            // runs on the gapless output clock, so the shutter is always
            // exactly one output frame - no per-call time tracking needed.
            if settled != nil {
                context.saveGState()
                context.addPath(roundedPath(for: layout.cardRect, radius: layout.cardCornerRadius))
                context.clip()
                for (sample, drawRect) in sampleRects.enumerated() {
                    // Drawing sample i at alpha 1/(i+1) keeps the buffer equal to
                    // the running average of all samples so far.
                    context.setAlpha(1 / CGFloat(sample + 1))
                    context.draw(screenImage, in: flipped(drawRect))
                }
                context.restoreGState()
            } else {
                drawMorphingScreen(screenImage, editorTime: editorTime, opacity: screenOpacity, in: context)
            }
            renderedScreen = true
        }

        if shouldCacheScreen, !reusedScreen, renderedScreen {
            context.flush()
            screenLayerCache.capture(source: screenFrame, rect: sampleRects[0], fromLocked: destination)
        }
        if !shouldCacheScreen { screenLayerCache.invalidate() }

        // Card-space overlays fade with the screen when a layout hides it.
        overlayOpacity = screenOpacity
        if screenOpacity > 0.001 {
            // Pointer motion is resolved independently from viewport shutter
            // blur. Its interaction magnification and tilt stay anchored at the
            // recorded artwork anchor point, while the final point still passes
            // through the same viewport transform and rounded-card clip as the
            // source pixels.
            drawPointer(editorTime: editorTime, in: context)

            // The keystroke caption stays in card space - pinned to its edge and
            // unaffected by the zoom transform, like a broadcast lower third.
            drawKeystrokeCaption(at: sourceTime, in: context)

            // The speed badge is card-space chrome too, paced by editor time
            // so its chevrons sweep at the same rate as the preview's.
            drawSpeedBadge(at: editorTime, in: context)
        }

        if let cameraFrame, layout.bubbleRect.width > 0, layout.cameraOpacity > 0.001 {
            if layout.cameraCutout > 0.001 {
                // The matte changes with every camera frame, so a cutout
                // always composites on the GPU, settled or not.
                context.flush()
                CVPixelBufferUnlockBaseAddress(destination, [])
                let drawn = renderCutoutCamera(
                    cameraFrame, cameraTime: frame.cameraTime, editorTime: editorTime, into: destination
                )
                CVPixelBufferLockBaseAddress(destination, [])
                guard let relocked = lockedContext(for: destination) else {
                    throw RecordingStudioExporter.ExportError.writerFailed(nil)
                }
                context = relocked
                if !drawn {
                    drawMorphingCamera(cameraFrame, editorTime: editorTime, in: context)
                }
            } else if let resources {
                drawCameraBubble(cameraFrame, resources: resources, submission: frame.cameraSubmission, in: context)
            } else {
                // The GPU draws into the buffer while the CPU has it unlocked.
                context.flush()
                CVPixelBufferUnlockBaseAddress(destination, [])
                let drawn = renderMorphingCamera(cameraFrame, editorTime: editorTime, into: destination)
                CVPixelBufferLockBaseAddress(destination, [])
                guard let relocked = lockedContext(for: destination) else {
                    throw RecordingStudioExporter.ExportError.writerFailed(nil)
                }
                context = relocked
                if !drawn {
                    drawMorphingCamera(cameraFrame, editorTime: editorTime, in: context)
                }
            }
        }

        // Images, then text, sit on the canvas above the camera and under
        // the subtitles.
        drawImageOverlays(at: sourceTime, in: context)
        drawTextOverlays(at: sourceTime, in: context)

        // The subtitle bar lives in canvas space - over the background too,
        // not just the card - and above everything else, camera included.
        drawSubtitleBar(at: sourceTime, in: context)
    }

    private func drawImageOverlays(at sourceTime: TimeInterval, in context: CGContext) {
        guard let mediaDirectory else { return }
        let active = imageOverlays.filter { $0.isActive(atSourceTime: sourceTime) }
        guard !active.isEmpty else { return }
        context.saveGState()
        context.translateBy(x: 0, y: canvasSize.height)
        context.scaleBy(x: 1, y: -1)
        for overlay in active {
            guard let image = overlayImages.image(at: mediaDirectory.appendingPathComponent(overlay.fileName)) else { continue }
            RecordingImageOverlayRenderer.draw(overlay, image: image, atSourceTime: sourceTime, canvasSize: canvasSize, in: context)
        }
        context.restoreGState()
    }

    private func drawTextOverlays(at sourceTime: TimeInterval, in context: CGContext) {
        let active = textOverlays.filter { $0.isActive(atSourceTime: sourceTime) }
        guard !active.isEmpty else { return }
        context.saveGState()
        // The shared renderer works top-down, like the preview's canvas.
        context.translateBy(x: 0, y: canvasSize.height)
        context.scaleBy(x: 1, y: -1)
        for overlay in active {
            RecordingTextOverlayRenderer.draw(overlay, atSourceTime: sourceTime, canvasSize: canvasSize, in: context)
        }
        context.restoreGState()
    }

    /// Casts `path`'s shadow without drawing `path` itself. Filling a shape
    /// to get its shadow also leaves the shape, and its antialiased edge
    /// then shows through whatever is composited over it: a dark outline
    /// whose strength changes with the edge's sub-pixel position, so it
    /// flickers as the card or camera moves. The shape is filled off to
    /// the left of everything visible and the shadow offset back by the
    /// same distance. `offset` and `blur` are in base (device) units, which
    /// shadows use whatever the CTM; `baseUnitsPerPoint` converts the
    /// user-space shift when the context is scaled.
    nonisolated static func castShadow(
        of path: CGPath,
        in context: CGContext,
        offset: CGSize,
        blur: CGFloat,
        color: CGColor,
        baseUnitsPerPoint: CGFloat = 1
    ) {
        let visible = context.boundingBoxOfClipPath
        let shape = path.boundingBoxOfPath
        guard !shape.isNull, !visible.isNull else { return }
        // Far enough that the shape and its antialiasing clear the visible
        // area; the shadow lands exactly where it would have.
        let shift = (shape.maxX - visible.minX + 2).rounded(.up)
        context.saveGState()
        context.translateBy(x: -shift, y: 0)
        context.setShadow(
            offset: CGSize(width: offset.width + shift * baseUnitsPerPoint, height: offset.height),
            blur: blur,
            color: color
        )
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()
    }

    private func drawBackdrop(_ backdrop: CGImage?, in context: CGContext) {
        if let backdrop {
            context.draw(backdrop, in: CGRect(origin: .zero, size: canvasSize))
        } else {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(origin: .zero, size: canvasSize))
        }
    }

    /// The moving card's shadow, rendered small and drawn up to size.
    private func drawCardShadow(for layout: RecordingStudioLayout, in context: CGContext) {
        let opacity = layout.screenOpacity
        guard opacity > 0.001, style.shadow > 0.01, style.background != .none,
              let shadowContext = morphShadowContext else { return }
        let scale = Self.morphShadowScale
        let minDimension = min(canvasSize.width, canvasSize.height)
        let blur = minDimension * 0.045 * style.shadow
        let small = CGRect(x: 0, y: 0, width: shadowContext.width, height: shadowContext.height)
        shadowContext.clear(small)
        shadowContext.saveGState()
        shadowContext.scaleBy(x: 1 / scale, y: 1 / scale)
        // Shadows ignore the CTM, so their blur and offset are scaled by hand.
        Self.castShadow(
            of: roundedPath(for: layout.cardRect, radius: layout.cardCornerRadius),
            in: shadowContext,
            offset: CGSize(width: 0, height: -blur * 0.35 / scale),
            blur: blur / scale,
            color: CGColor(gray: 0, alpha: 0.55 * style.shadow * opacity),
            baseUnitsPerPoint: 1 / scale
        )
        shadowContext.restoreGState()
        guard let image = shadowContext.makeImage() else { return }
        context.saveGState()
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: small.width * scale, height: small.height * scale))
        context.restoreGState()
    }

    /// A morph frame's screen pass: the backdrop with the card's shadow
    /// where the card is now, and the card itself as the clip.
    private func submitMorphMetal(
        screenFrame: CVPixelBuffer,
        sampleRects: [CGRect],
        layout: RecordingStudioLayout,
        into destination: CVPixelBuffer
    ) -> StudioMetalScreenRenderer.Submission? {
        guard !sampleRects.isEmpty, !forceCoreGraphics, !metalFailed, !morphRendererFailed,
              StudioMetalScreenRenderer.shouldAccelerate(screenFrame: screenFrame, sampleRects: sampleRects)
        else { return nil }
        if morphRenderer == nil {
            morphRenderer = StudioMetalScreenRenderer(
                canvasSize: canvasSize, backdrop: plainBackdrop,
                cardPath: CGPath(rect: .zero, transform: nil), colorSpace: colorSpace
            )
        }
        let submitStart = CFAbsoluteTimeGetCurrent()
        defer { metalSeconds += CFAbsoluteTimeGetCurrent() - submitStart }
        guard let submission = morphRenderer?.submitMorph(
            screenFrame: screenFrame,
            sampleRects: sampleRects,
            card: StudioMetalScreenRenderer.MorphCard(
                rect: layout.cardRect, cornerRadius: layout.cardCornerRadius,
                opacity: layout.screenOpacity, shadow: cardShadow(for: layout)
            ),
            into: destination
        ) else {
            morphRendererFailed = true
            return nil
        }
        return submission
    }

    /// The card's shadow, as `renderBackdrop` casts it for a settled layout.
    private func cardShadow(for layout: RecordingStudioLayout) -> StudioMorphShadow? {
        guard layout.screenOpacity > 0.001, style.shadow > 0.01, style.background != .none else { return nil }
        let blur = min(canvasSize.width, canvasSize.height) * 0.045 * style.shadow
        return StudioMorphShadow(offset: blur * 0.35, blur: blur, alpha: 0.55 * style.shadow * layout.screenOpacity)
    }

    /// The most samples a morphing layer averages. The Core Graphics path
    /// pays for every one, and a morph is over in a fraction of a second.
    private static let maxMorphSamples = 8

    private func morphSampleTimes(at editorTime: TimeInterval, rect: (TimeInterval) -> CGRect) -> [TimeInterval] {
        let times = timing.sampleTimes(at: editorTime, frameRect: rect)
        guard times.count > Self.maxMorphSamples else { return times }
        guard Self.maxMorphSamples > 1 else { return [editorTime] }
        return (0..<Self.maxMorphSamples).map { index in
            times[index * (times.count - 1) / (Self.maxMorphSamples - 1)]
        }
    }

    /// The screen while its card moves: each shutter sample is clipped to
    /// the card as it stood at that instant and the samples are summed at
    /// equal weight, so the card's edges blur along with its pixels.
    private func drawMorphingScreen(
        _ screenImage: CGImage,
        editorTime: TimeInterval,
        opacity: CGFloat,
        in context: CGContext
    ) {
        let times = morphSampleTimes(at: editorTime, rect: screenDrawRect(at:))
        guard !times.isEmpty else { return }
        context.saveGState()
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setBlendMode(.plusLighter)
        for time in times {
            let sample = frameLayout(at: time).layout
            context.saveGState()
            context.setAlpha(1 / CGFloat(times.count))
            context.addPath(roundedPath(for: sample.cardRect, radius: sample.cardCornerRadius))
            context.clip()
            context.draw(screenImage, in: flipped(sample.frameRect(for: viewportFrame(at: time))))
            context.restoreGState()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// The camera while a layout morph moves or reshapes it, drawn from
    /// scratch: aspect-filled into each shutter sample's rect, clipped to
    /// where it is mid-shutter. A running average needs no offscreen layer,
    /// which at canvas size costs more than the draws themselves.
    private func drawMorphingCamera(_ cameraFrame: CVPixelBuffer, editorTime: TimeInterval, in context: CGContext) {
        guard let cameraImage = Self.makeImage(from: cameraFrame, colorSpace: colorSpace) else { return }
        let opacity = layout.cameraOpacity
        let times = morphCameraSampleTimes(at: editorTime)
        let bubble = layout.bubbleRect
        guard !times.isEmpty, bubble.width > 0, bubble.height > 0 else { return }
        let imageSize = CGSize(width: cameraImage.width, height: cameraImage.height)
        let minDimension = min(canvasSize.width, canvasSize.height)
        let path = roundedPath(for: bubble, radius: layout.bubbleCornerRadius)

        Self.castShadow(
            of: path,
            in: context,
            offset: CGSize(width: 0, height: -minDimension * 0.009),
            blur: minDimension * 0.022,
            color: CGColor(gray: 0, alpha: 0.35 * opacity)
        )

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .medium
        for (index, time) in times.enumerated() {
            let sample = frameLayout(at: time).layout.bubbleRect
            guard sample.width > 0, sample.height > 0 else { continue }
            let scale = max(sample.width / imageSize.width, sample.height / imageSize.height)
            let fillSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let fillRect = CGRect(
                x: sample.midX - fillSize.width / 2,
                y: sample.midY - fillSize.height / 2,
                width: fillSize.width,
                height: fillSize.height
            )
            // Sample i at 1/(i+1) keeps the running average.
            context.setAlpha(index == 0 ? opacity : 1 / CGFloat(index + 1))
            context.draw(cameraImage, in: flipped(fillRect))
        }
        context.restoreGState()

        context.addPath(roundedPath(for: bubble.insetBy(dx: 0.5, dy: 0.5), radius: layout.bubbleCornerRadius))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.25 * opacity))
        context.setLineWidth(max(1, minDimension * 0.0018))
        context.strokePath()
    }

    private static let maxMorphCameraSamples = 4

    private func morphCameraSampleTimes(at editorTime: TimeInterval) -> [TimeInterval] {
        // A running average can't also carry a fade, so a fading camera
        // draws once, mid-shutter.
        let times = layout.cameraOpacity < 0.999
            ? [editorTime]
            : timing.sampleTimes(at: editorTime) { self.frameLayout(at: $0).layout.bubbleRect }
        guard times.count > Self.maxMorphCameraSamples else { return times }
        return (0..<Self.maxMorphCameraSamples).map { index in
            times[index * (times.count - 1) / (Self.maxMorphCameraSamples - 1)]
        }
    }

    /// `drawMorphingCamera` on the GPU, into the unlocked `destination`.
    /// False if Metal can't, leaving the frame untouched.
    private func renderMorphingCamera(
        _ cameraFrame: CVPixelBuffer, editorTime: TimeInterval, into destination: CVPixelBuffer
    ) -> Bool {
        guard !forceCoreGraphics, !morphCameraRendererFailed else { return false }
        if morphCameraRenderer == nil { morphCameraRenderer = StudioMorphCameraRenderer() }
        guard let renderer = morphCameraRenderer else {
            morphCameraRendererFailed = true
            return false
        }
        let bubble = layout.bubbleRect
        guard bubble.width > 0, bubble.height > 0 else { return true }
        let fillRects = morphCameraSampleTimes(at: editorTime).compactMap { time -> CGRect? in
            let sample = frameLayout(at: time).layout
            guard sample.bubbleRect.width > 0, sample.bubbleRect.height > 0 else { return nil }
            return cameraFillRect(cameraFrame, layout: sample)
        }
        guard !fillRects.isEmpty else { return true }
        let opacity = layout.cameraOpacity
        let minDimension = min(canvasSize.width, canvasSize.height)
        let start = CFAbsoluteTimeGetCurrent()
        defer { metalSeconds += CFAbsoluteTimeGetCurrent() - start }
        return renderer.render(
            camera: cameraFrame,
            fillRects: fillRects,
            bubble: StudioMorphCameraRenderer.Bubble(
                rect: bubble,
                cornerRadius: layout.bubbleCornerRadius,
                opacity: opacity,
                borderWidth: max(1, minDimension * 0.0018),
                borderAlpha: 0.25 * opacity,
                shadow: StudioMorphShadow(offset: minDimension * 0.009, blur: minDimension * 0.022, alpha: 0.35 * opacity)
            ),
            into: destination
        )
    }

    /// Whether the camera is cut out at all at an editor time.
    func showsCutout(at editorTime: TimeInterval) -> Bool {
        let layout = frameLayout(at: editorTime).layout
        return layout.cameraCutout > 0.001 && layout.cameraOpacity > 0.001 && layout.bubbleRect.width > 0
    }


    /// The camera cut out of its background by the layout's cutout amount,
    /// over the finished frame in the unlocked `destination`: the framed
    /// camera's shadow and border give way to the person's own shadow as
    /// the background melts. False if Metal or Vision can't, leaving the
    /// frame untouched.
    private func renderCutoutCamera(
        _ cameraFrame: CVPixelBuffer, cameraTime: TimeInterval, editorTime: TimeInterval,
        into destination: CVPixelBuffer
    ) -> Bool {
        guard !forceCoreGraphics, !morphCameraRendererFailed else { return false }
        let waitStart = CFAbsoluteTimeGetCurrent()
        let matte = cutoutMattes?.matte(at: cameraTime)
            ?? fallbackMattes?.matte(for: cameraFrame, time: cameraTime)
        cutoutWaitSeconds += CFAbsoluteTimeGetCurrent() - waitStart
        guard let matte else { return false }
        if morphCameraRenderer == nil { morphCameraRenderer = StudioMorphCameraRenderer() }
        guard let renderer = morphCameraRenderer else {
            morphCameraRendererFailed = true
            return false
        }
        let bubble = layout.bubbleRect
        guard bubble.width > 0, bubble.height > 0 else { return true }
        let fillRects = morphCameraSampleTimes(at: editorTime).compactMap { time -> CGRect? in
            let sample = frameLayout(at: time).layout
            guard sample.bubbleRect.width > 0, sample.bubbleRect.height > 0 else { return nil }
            return cameraFillRect(cameraFrame, layout: sample)
        }
        guard !fillRects.isEmpty else { return true }
        let opacity = layout.cameraOpacity
        let framed = 1 - layout.cameraCutout
        let picture = cameraFillRect(cameraFrame, layout: layout)
        let minDimension = min(canvasSize.width, canvasSize.height)
        let start = CFAbsoluteTimeGetCurrent()
        defer { metalSeconds += CFAbsoluteTimeGetCurrent() - start }
        return renderer.render(
            camera: cameraFrame,
            fillRects: fillRects,
            bubble: StudioMorphCameraRenderer.Bubble(
                rect: bubble,
                cornerRadius: layout.bubbleCornerRadius,
                opacity: opacity,
                borderWidth: max(1, minDimension * 0.0018),
                borderAlpha: 0.25 * opacity * framed,
                shadow: StudioMorphShadow(
                    offset: minDimension * 0.009, blur: minDimension * 0.022, alpha: 0.35 * opacity * framed
                )
            ),
            cutout: StudioMorphCameraRenderer.Cutout(
                matte: matte,
                amount: layout.cameraCutout,
                feather: StudioCutoutStyle.feather(picture: picture, canvas: canvasSize),
                picture: picture,
                shadowAlpha: StudioCutoutStyle.shadowAlpha * opacity * layout.cameraCutout
            ),
            into: destination
        )
    }

    private func lockedContext(for destination: CVPixelBuffer) -> CGContext? {
        guard let base = CVPixelBufferGetBaseAddress(destination),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(destination),
                height: CVPixelBufferGetHeight(destination),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        return context
    }

    private func submitMetal(
        screenFrame: CVPixelBuffer,
        sampleRects: [CGRect],
        settled: SettledLayout?,
        layout: RecordingStudioLayout,
        into destination: CVPixelBuffer
    ) -> StudioMetalScreenRenderer.Submission? {
        // Morph frames move the card clip every frame; Core Graphics draws them.
        guard let settled, !sampleRects.isEmpty, !forceCoreGraphics, !metalFailed,
              StudioMetalScreenRenderer.shouldAccelerate(screenFrame: screenFrame, sampleRects: sampleRects)
        else { return nil }
        let resources = resources(for: settled, layout: layout)
        if resources.metalRenderer == nil {
            resources.metalRenderer = StudioMetalScreenRenderer(
                canvasSize: canvasSize, backdrop: resources.backdrop,
                cardPath: roundedPath(for: layout.cardRect, radius: layout.cardCornerRadius), colorSpace: colorSpace
            )
        }
        let submitStart = CFAbsoluteTimeGetCurrent()
        defer { metalSeconds += CFAbsoluteTimeGetCurrent() - submitStart }
        guard let submission = resources.metalRenderer?.submit(
            screenFrame: screenFrame, sampleRects: sampleRects, into: destination
        ) else {
            metalFailed = true
            return nil
        }
        return submission
    }

    /// Shadow + hairline border match the live preview's bubble styling.
    /// The camera sits over moving video, so it composites every frame -
    /// but while a layout is settled its geometry is fixed: the blurred
    /// shadow renders once, the clipped camera layer once per camera frame,
    /// and each output frame only blits them 1:1.
    private func drawCameraBubble(
        _ cameraFrame: CVPixelBuffer, resources: LayoutResources,
        submission: StudioCameraBubbleScaler.Submission?, in context: CGContext
    ) {
        if resources.bubbleContentSource !== cameraFrame {
            resources.bubbleContentImage = renderBubbleContent(cameraFrame, resources: resources, submission: submission)
            resources.bubbleContentSource = resources.bubbleContentImage == nil ? nil : cameraFrame
        }
        guard let content = resources.bubbleContentImage else { return }
        if let shadow = bubbleShadow(for: resources) {
            context.draw(shadow.image, in: shadow.rect)
        }
        context.draw(content, in: bubbleContentRect(for: resources.layout))
    }

    /// The bubble in bottom-up canvas pixels, grown to whole pixels so its
    /// cached layer blits without resampling.
    private func bubbleContentRect(for layout: RecordingStudioLayout) -> CGRect {
        flipped(layout.bubbleRect).integral
    }

    private func bubbleShadow(for resources: LayoutResources) -> (image: CGImage, rect: CGRect)? {
        if let cached = resources.bubbleShadow { return cached }
        let layout = resources.layout
        let minDimension = min(canvasSize.width, canvasSize.height)
        let blur = minDimension * 0.022
        let offset = minDimension * 0.009
        let rect = bubbleContentRect(for: layout)
            .insetBy(dx: -(blur * 2 + offset), dy: -(blur * 2 + offset))
            .intersection(CGRect(origin: .zero, size: canvasSize))
            .integral
        let image = renderLayer(covering: rect, draw: { context in
            Self.castShadow(
                of: roundedPath(for: layout.bubbleRect, radius: layout.bubbleCornerRadius),
                in: context,
                offset: CGSize(width: 0, height: -offset),
                blur: blur,
                color: CGColor(gray: 0, alpha: 0.35)
            )
        })
        let shadow = image.map { ($0, rect) }
        resources.bubbleShadow = .some(shadow)
        return shadow
    }

    private func cameraScaler(for resources: LayoutResources) -> StudioCameraBubbleScaler? {
        if let cached = resources.cameraScaler { return cached }
        let scaler = forceCoreGraphics
            ? nil
            : StudioCameraBubbleScaler(size: bubbleContentRect(for: resources.layout).size, colorSpace: colorSpace)
        resources.cameraScaler = .some(scaler)
        return scaler
    }

    private func cameraFillRect(_ cameraFrame: CVPixelBuffer, layout: RecordingStudioLayout) -> CGRect {
        let bubble = layout.bubbleRect
        let scale = max(bubble.width / CGFloat(CVPixelBufferGetWidth(cameraFrame)),
                        bubble.height / CGFloat(CVPixelBufferGetHeight(cameraFrame)))
        let size = CGSize(width: CGFloat(CVPixelBufferGetWidth(cameraFrame)) * scale,
                          height: CGFloat(CVPixelBufferGetHeight(cameraFrame)) * scale)
        return CGRect(x: bubble.midX - size.width / 2, y: bubble.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Schedule the camera before finishing the previous frame's overlays.
    /// Consecutive output ticks sharing one decoded camera frame also share
    /// its scale submission; the resulting image is still clipped identically.
    private func prepareCamera(
        _ cameraFrame: CVPixelBuffer, resources: LayoutResources
    ) -> StudioCameraBubbleScaler.Submission? {
        guard resources.bubbleContentSource !== cameraFrame else { return nil }
        if resources.scheduledCameraSource === cameraFrame { return resources.scheduledCameraSubmission }
        let layerRect = bubbleContentRect(for: resources.layout)
        let fillRect = cameraFillRect(cameraFrame, layout: resources.layout)
        let submission = cameraScaler(for: resources)?.submit(
            cameraFrame,
            fillRect: fillRect.offsetBy(dx: -layerRect.minX, dy: -(canvasSize.height - layerRect.maxY))
        )
        resources.scheduledCameraSource = submission == nil ? nil : cameraFrame
        resources.scheduledCameraSubmission = submission
        return submission
    }

    private func renderBubbleContent(
        _ cameraFrame: CVPixelBuffer, resources: LayoutResources,
        submission: StudioCameraBubbleScaler.Submission?
    ) -> CGImage? {
        let layout = resources.layout
        let bubble = layout.bubbleRect
        let imageSize = CGSize(width: CVPixelBufferGetWidth(cameraFrame), height: CVPixelBufferGetHeight(cameraFrame))
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let fillRect = cameraFillRect(cameraFrame, layout: layout)
        let minDimension = min(canvasSize.width, canvasSize.height)
        let layerRect = bubbleContentRect(for: layout)
        // The GPU scales straight into the layer's pixel box, so the draw
        // below is 1:1; Core Graphics resamples the full frame otherwise.
        let scaledCamera = submission.flatMap { cameraScaler(for: resources)?.image(for: $0) }
        let cameraImage = scaledCamera == nil ? Self.makeImage(from: cameraFrame, colorSpace: colorSpace) : nil
        guard scaledCamera != nil || cameraImage != nil else { return nil }
        return renderLayer(covering: layerRect) { context in
            context.saveGState()
            context.addPath(roundedPath(for: bubble, radius: layout.bubbleCornerRadius))
            context.clip()
            if let scaledCamera {
                context.draw(scaledCamera, in: layerRect)
            } else if let cameraImage {
                context.draw(cameraImage, in: flipped(fillRect))
            }
            context.restoreGState()

            context.addPath(roundedPath(for: bubble.insetBy(dx: 0.5, dy: 0.5), radius: layout.bubbleCornerRadius))
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
            context.setLineWidth(max(1, minDimension * 0.0018))
            context.strokePath()
        }
    }

    /// Renders canvas-space (bottom-up) drawing into an image covering only
    /// `rect`, which must be in whole pixels.
    private func renderLayer(covering rect: CGRect, draw: (CGContext) -> Void) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1,
              let context = CGContext(
                data: nil,
                width: Int(rect.width),
                height: Int(rect.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: -rect.minX, y: -rect.minY)
        draw(context)
        return context.makeImage()
    }

    private func drawPointer(editorTime: TimeInterval, in context: CGContext) {
        guard let pointerTimeline,
              let pointer = pointerTimeline.frame(at: editorTime) else {
            return
        }

        let drawRect = layout.frameRect(for: viewportFrame(at: editorTime))
        let tip = CGPoint(
            x: drawRect.minX + pointer.location.x * drawRect.width,
            y: canvasSize.height - (drawRect.minY + pointer.location.y * drawRect.height)
        )

        var pressGeometry: (tip: CGPoint, effect: PointerPressEffectGeometry)?
        if showsPressEffects, let press = pointer.press {
            pressGeometry = (
                CGPoint(
                    x: drawRect.minX + press.location.x * drawRect.width,
                    y: canvasSize.height - (drawRect.minY + press.location.y * drawRect.height)
                ),
                PointerPressEffectStyle.geometry(
                    progress: press.progress,
                    referenceHeight: layout.contentFillSize.height,
                    cursorScale: pointerScale
                )
            )
        }
        var artworkPlacement: (image: CGImage, rect: CGRect, transform: CGAffineTransform)?
        var material: (material: PointerMaterial, radius: CGFloat)?
        if let resolved = artwork(for: pointer, in: pointerTimeline) {
            let height = layout.contentFillSize.height
                * PointerArtworkMetrics.heightRatio
                * pointerScale
                * resolved.intrinsicScale
            let size = CGSize(width: height * resolved.aspectRatio, height: height)
            let interactionScale = CGFloat(max(pointer.magnification, 0.1))
            if let pointerMaterial = resolved.material {
                material = (pointerMaterial, size.width * PointerShape.circleRadiusRatio * interactionScale)
            }
            let transform = CGAffineTransform(translationX: tip.x, y: tip.y)
                .rotated(by: resolved.leans ? -CGFloat(pointer.tiltDegrees * .pi / 180) : 0)
                .scaledBy(x: interactionScale, y: interactionScale)
            artworkPlacement = (
                resolved.image,
                CGRect(
                    x: -resolved.anchor.x * size.width,
                    y: -(1 - resolved.anchor.y) * size.height,
                    width: size.width,
                    height: size.height
                ),
                transform
            )
        }

        // The pointer is clipped to the rounded card like the screen pixels
        // beneath it, but a full-canvas clip mask costs more than the whole
        // draw. When everything drawn sits inside the card's corner-free
        // interior the clip removes nothing, so skip it.
        var bounds = CGRect.null
        if let pressGeometry {
            let reach = max(pressGeometry.effect.impactRadius, pressGeometry.effect.rippleRadius)
                + pressGeometry.effect.rippleLineWidth
            bounds = bounds.union(CGRect(
                x: pressGeometry.tip.x - reach, y: pressGeometry.tip.y - reach,
                width: reach * 2, height: reach * 2
            ))
        }
        if let artworkPlacement {
            bounds = bounds.union(artworkPlacement.rect.applying(artworkPlacement.transform))
        }
        guard !bounds.isNull else { return }
        let card = flipped(layout.cardRect)
        let radius = min(layout.cardCornerRadius, min(card.width, card.height) / 2)
        let paddedBounds = bounds.insetBy(dx: -2, dy: -2)
        let needsClip = !card.insetBy(dx: radius, dy: 0).contains(paddedBounds)
            && !card.insetBy(dx: 0, dy: radius).contains(paddedBounds)

        context.saveGState()
        context.setAlpha(overlayOpacity)
        if needsClip {
            context.addPath(roundedPath(for: layout.cardRect, radius: layout.cardCornerRadius))
            context.clip()
        }
        if let pressGeometry {
            let (pressTip, effect) = pressGeometry
            let accent = PointerPressEffectStyle.color
            context.saveGState()
            context.setFillColor(CGColor(
                red: accent.red,
                green: accent.green,
                blue: accent.blue,
                alpha: effect.impactOpacity
            ))
            context.fillEllipse(in: CGRect(
                x: pressTip.x - effect.impactRadius,
                y: pressTip.y - effect.impactRadius,
                width: effect.impactRadius * 2,
                height: effect.impactRadius * 2
            ))
            context.setStrokeColor(CGColor(
                red: accent.red,
                green: accent.green,
                blue: accent.blue,
                alpha: effect.rippleOpacity
            ))
            context.setLineWidth(effect.rippleLineWidth)
            context.strokeEllipse(in: CGRect(
                x: pressTip.x - effect.rippleRadius,
                y: pressTip.y - effect.rippleRadius,
                width: effect.rippleRadius * 2,
                height: effect.rippleRadius * 2
            ))
            context.restoreGState()
        }

        if let artworkPlacement {
            context.setAlpha(CGFloat(min(max(pointer.opacity, 0), 1)) * overlayOpacity)
            if let material {
                pointerMaterialRenderer.draw(material.material, center: tip, radius: material.radius, in: context)
            }
            context.concatenate(artworkPlacement.transform)
            context.draw(artworkPlacement.image, in: artworkPlacement.rect)
        }
        context.restoreGState()
    }

    private func drawKeystrokeCaption(at time: TimeInterval, in context: CGContext) {
        guard let keystrokeTimeline,
              let caption = keystrokeTimeline.frame(at: time) else {
            return
        }

        let metrics = KeystrokeCaptionMetrics(cardHeight: layout.cardRect.height)
        let font = Self.captionFont(size: metrics.fontSize)
        let (modifierText, keyText) = KeystrokeCaptionMetrics.text(for: caption)

        let text = NSMutableAttributedString()
        if !modifierText.isEmpty {
            text.append(NSAttributedString(string: modifierText, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 1, alpha: KeystrokeCaptionMetrics.modifierAlpha)
            ]))
        }
        text.append(NSAttributedString(string: keyText, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 1, alpha: 1)
        ]))

        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        guard textWidth > 0 else { return }

        let pillSize = CGSize(
            width: textWidth + metrics.paddingHorizontal * 2,
            height: ascent + descent + metrics.paddingVertical * 2
        )
        let origin = metrics.pillOrigin(
            pillSize: pillSize,
            cardRect: layout.cardRect,
            placement: keystrokePlacement
        )
        let pillRect = flipped(CGRect(origin: origin, size: pillSize))

        context.saveGState()
        context.setAlpha(CGFloat(caption.opacity) * overlayOpacity)
        context.translateBy(x: pillRect.midX, y: pillRect.midY)
        context.scaleBy(x: CGFloat(caption.scale), y: CGFloat(caption.scale))
        context.translateBy(x: -pillRect.midX, y: -pillRect.midY)

        let radius = min(metrics.cornerRadius, pillRect.height / 2)
        context.addPath(CGPath(
            roundedRect: pillRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.setFillColor(CGColor(gray: 0, alpha: KeystrokeCaptionMetrics.backgroundAlpha))
        context.fillPath()

        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: pillRect.minX + metrics.paddingHorizontal,
            y: pillRect.midY - (ascent - descent) / 2
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawSpeedBadge(at time: TimeInterval, in context: CGContext) {
        guard let speedBadgeTimeline,
              let badge = speedBadgeTimeline.frame(at: time),
              badge.opacity > 0.001 else {
            return
        }

        let metrics = SpeedBadgeMetrics(cardHeight: layout.cardRect.height)
        let font = Self.captionFont(size: metrics.fontSize)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: badge.title, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        guard textWidth > 0 else { return }

        let badgeSize = CGSize(
            width: metrics.badgeWidth(textWidth: textWidth),
            height: ascent + descent + metrics.paddingVertical * 2
        )
        let origin = metrics.badgeOrigin(
            badgeSize: badgeSize,
            cardRect: layout.cardRect,
            placement: speedBadgePlacement
        )
        let badgeRect = flipped(CGRect(origin: origin, size: badgeSize))

        context.saveGState()
        context.setAlpha(CGFloat(badge.opacity) * overlayOpacity)
        context.translateBy(x: badgeRect.midX, y: badgeRect.midY)
        context.scaleBy(x: CGFloat(badge.scale), y: CGFloat(badge.scale))
        context.translateBy(x: -badgeRect.midX, y: -badgeRect.midY)

        let radius = min(metrics.cornerRadius, badgeRect.height / 2)
        context.addPath(CGPath(
            roundedRect: badgeRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.setFillColor(CGColor(gray: 0, alpha: SpeedBadgeMetrics.backgroundAlpha))
        context.fillPath()

        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: badgeRect.minX + metrics.paddingHorizontal,
            y: badgeRect.midY - (ascent - descent) / 2
        )
        CTLineDraw(line, context)

        context.setLineWidth(metrics.chevronLineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let firstChevronX = badgeRect.minX + metrics.paddingHorizontal + textWidth + metrics.textGap
        for index in 0..<SpeedBadgeMetrics.chevronCount {
            context.addPath(metrics.chevronPath(
                minX: firstChevronX + metrics.chevronAdvance * CGFloat(index),
                midY: badgeRect.midY
            ))
            context.setStrokeColor(CGColor(gray: 1, alpha: CGFloat(badge.chevronAlpha(index))))
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawSubtitleBar(at time: TimeInterval, in context: CGContext) {
        guard let subtitleTimeline,
              let text = subtitleTimeline.text(at: time) else {
            return
        }

        let metrics = SubtitleBarMetrics(canvasSize: canvasSize, style: subtitleStyle)
        let maximumTextWidth = metrics.maximumTextWidth(canvasWidth: canvasSize.width)

        // On narrow canvases the text wraps into centered lines rather
        // than shrinking into a full-width sliver; the font only scales
        // down when even the maximum line count can't hold it.
        var fontSize = metrics.fontSize
        var wrappedLines: [CTLine] = []
        for _ in 0..<3 {
            let font = Self.captionFont(size: fontSize)
            let attributed = subtitleAttributedText(plainText: text, at: time, font: font)
            wrappedLines = Self.wrapLines(attributed, width: maximumTextWidth)
            if wrappedLines.count <= SubtitleBarMetrics.maximumLineCount || fontSize <= 11 {
                break
            }
            fontSize *= CGFloat(SubtitleBarMetrics.maximumLineCount) / CGFloat(wrappedLines.count)
        }
        guard !wrappedLines.isEmpty else { return }

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidths = wrappedLines.map {
            CGFloat(CTLineGetTypographicBounds($0, &ascent, &descent, &leading))
        }
        guard let widestLine = lineWidths.max(), widestLine > 0 else { return }
        let lineAdvance = (ascent + descent) * SubtitleBarMetrics.lineSpacingFactor
        let textHeight = ascent + descent + lineAdvance * CGFloat(wrappedLines.count - 1)

        let barSize = CGSize(
            width: widestLine + metrics.paddingHorizontal * 2,
            height: textHeight + metrics.paddingVertical * 2
        )
        let barCenterY = canvasSize.height * CGFloat(subtitleStyle.clampedVerticalPosition)
        let origin = CGPoint(
            x: canvasSize.width / 2 - barSize.width / 2,
            y: barCenterY - barSize.height / 2
        )
        let barRect = flipped(CGRect(origin: origin, size: barSize))

        context.saveGState()
        let radius = min(metrics.cornerRadius, barRect.height / 2)
        context.addPath(CGPath(
            roundedRect: barRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.setFillColor(CGColor(gray: 0, alpha: SubtitleBarMetrics.backgroundAlpha))
        context.fillPath()

        context.textMatrix = .identity
        // The CG context is bottom-up, so the first wrapped line sits at
        // the top of the bar and subsequent lines step downward.
        let firstBaseline = barRect.maxY - metrics.paddingVertical - ascent
        for (index, wrappedLine) in wrappedLines.enumerated() {
            context.textPosition = CGPoint(
                x: barRect.midX - lineWidths[index] / 2,
                y: firstBaseline - lineAdvance * CGFloat(index)
            )
            CTLineDraw(wrappedLine, context)
        }
        context.restoreGState()
    }

    /// Word-wraps an attributed string into CTLines within a width.
    private static func wrapLines(
        _ attributed: NSAttributedString,
        width: CGFloat
    ) -> [CTLine] {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: max(24, width), height: 100_000),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        return (CTFrameGetLines(frame) as? [CTLine]) ?? []
    }

    /// The bar's text: karaoke-colored words when word timings exist and
    /// the style asks for them, the plain cue text otherwise. Colors match
    /// StudioSubtitleBarView exactly.
    private func subtitleAttributedText(
        plainText: String,
        at time: TimeInterval,
        font: CTFont
    ) -> NSAttributedString {
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

        guard subtitleStyle.highlightsSpokenWord,
              let karaokeTimeline,
              let karaokeLine = karaokeTimeline.line(at: time),
              !karaokeLine.words.isEmpty else {
            return NSAttributedString(string: plainText, attributes: [
                fontKey: font,
                colorKey: CGColor(gray: 1, alpha: 1)
            ])
        }

        let text = NSMutableAttributedString()
        for (index, word) in karaokeLine.words.enumerated() {
            let color: CGColor
            if index == karaokeLine.activeIndex {
                color = SubtitleBarMetrics.karaokeAccent
            } else if index < karaokeLine.spokenCount {
                color = CGColor(gray: 1, alpha: 1)
            } else {
                color = CGColor(gray: 1, alpha: SubtitleBarMetrics.karaokeUpcomingAlpha)
            }
            text.append(NSAttributedString(
                string: index > 0 ? " \(word)" : word,
                attributes: [fontKey: font, colorKey: color]
            ))
        }
        return text
    }

    private static func captionFont(size: CGFloat) -> CTFont {
        let descriptor = NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor
        let rounded = descriptor.withDesign(.rounded) ?? descriptor
        return CTFontCreateWithFontDescriptor(rounded as CTFontDescriptor, size, nil)
    }

    private func artwork(
        for pointer: PointerFrame,
        in timeline: PointerTimeline
    ) -> (
        image: CGImage,
        anchor: CGPoint,
        aspectRatio: CGFloat,
        intrinsicScale: CGFloat,
        material: PointerMaterial?,
        leans: Bool
    )? {
        if let resolved = timeline.artwork(id: pointer.artworkID),
           let image = artworkImage(for: resolved) {
            return (
                image,
                resolved.normalizedAnchor,
                resolved.aspectRatio,
                resolved.intrinsicScale,
                PointerShape(artworkID: resolved.artworkID)?.material,
                resolved.leans
            )
        }
        return nil
    }

    private func artworkImage(for artwork: PointerArtwork) -> CGImage? {
        if let cached = artworkImageCache[artwork.artworkID] {
            return cached
        }
        guard let source = CGImageSourceCreateWithData(artwork.imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        artworkImageCache[artwork.artworkID] = image
        return image
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

    /// The background, plus the card's shadow when `layout` is given.
    private static func renderBackdrop(
        canvasSize: CGSize,
        layout: RecordingStudioLayout?,
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

        // Card shadow: static, so it lives in the backdrop. Only the shadow:
        // the card's own shape would show through its antialiased edge.
        if let layout, style.shadow > 0.01, style.background != .none {
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

            castShadow(
                of: path,
                in: context,
                offset: CGSize(width: 0, height: -blur * 0.35),
                blur: blur,
                color: CGColor(gray: 0, alpha: 0.55 * style.shadow)
            )
        }

        return context.makeImage()
    }
}
