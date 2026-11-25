import AVFoundation
@preconcurrency import CoreMedia
import Foundation

nonisolated struct CameraRecordingResult: Sendable {
    var url: URL?
    var error: Error?
    /// Host-clock seconds of the first accepted camera frame.
    let firstFrameUptime: TimeInterval?
    let pixelWidth: Int
    let pixelHeight: Int
    var fileIsUsable = false

    var warningMessage: String? {
        guard error != nil || !fileIsUsable else { return nil }
        let detail = error.map { " (\($0.localizedDescription))" } ?? ""
        if fileIsUsable {
            return "The camera recording ended early\(detail). Its readable footage was kept with the screen recording."
        }
        let location = url.map { " Any partial camera file was kept at \($0.path) for recovery; it may not be playable." } ?? ""
        return "The camera recording could not be finalized\(detail).\(location)"
    }
}

nonisolated final class CameraMovieWriter: @unchecked Sendable {
    private let writingQueue = DispatchQueue(label: "com.screendrop.camera.writer", qos: .userInitiated)
    private let makeAssetWriter: @Sendable (URL) throws -> AVAssetWriter
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var finalURL: URL?
    private var isSessionStarted = false
    private var sessionStartTime: CMTime?
    private var isPaused = false
    private var pauseStartTime: CMTime?
    private var totalPauseDuration: CMTime = .zero
    private var needsPauseDurationUpdate = false
    private var latestSampleTime: CMTime?
    private var latestWrittenTime: CMTime?
    private var failureError: Error?
    private var pixelWidth = 0
    private var pixelHeight = 0

    init(makeAssetWriter: @escaping @Sendable (URL) throws -> AVAssetWriter = {
        try AVAssetWriter(outputURL: $0, fileType: .mov)
    }) {
        self.makeAssetWriter = makeAssetWriter
    }

    func setup(outputURL: URL, width: Int, height: Int) throws {
        let partialURL = outputURL.deletingPathExtension().appendingPathExtension("partial.mov")
        guard !FileManager.default.fileExists(atPath: outputURL.path),
              !FileManager.default.fileExists(atPath: partialURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let writer = try makeAssetWriter(partialURL)
        // A failed writer can still leave playable fragments. Only a validated
        // movie is promoted to camera.mov, which Studio treats as playable.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(6_000_000, width * height * 6),
                AVVideoExpectedSourceFrameRateKey: 30
            ] as [String: Any]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }

        writingQueue.sync {
            assetWriter = writer
            videoInput = input
            self.outputURL = partialURL
            finalURL = outputURL
            isSessionStarted = false
            sessionStartTime = nil
            isPaused = false
            pauseStartTime = nil
            totalPauseDuration = .zero
            needsPauseDurationUpdate = false
            latestSampleTime = nil
            latestWrittenTime = nil
            failureError = nil
            pixelWidth = width
            pixelHeight = height
        }
    }

    func pause() {
        writingQueue.async { [weak self] in
            guard let self, !isPaused else { return }
            isPaused = true
            pauseStartTime = latestSampleTime
        }
    }

    func resume() {
        writingQueue.async { [weak self] in
            guard let self, isPaused else { return }
            isPaused = false
            needsPauseDurationUpdate = true
        }
    }

    func writeVideoSample(_ sampleBuffer: CMSampleBuffer) {
        let sendable = SendableCameraSampleBuffer(sampleBuffer)
        // Bound retained capture buffers: encoder backpressure must shed
        // frames rather than build an unbounded queue of camera images.
        writingQueue.sync { [weak self] in
            autoreleasepool {
                guard let self, let assetWriter = self.assetWriter,
                      let videoInput = self.videoInput, self.failureError == nil else { return }
                guard assetWriter.status == .writing else {
                    self.recordFailure(assetWriter.error ?? CocoaError(.fileWriteUnknown))
                    return
                }
                let sampleBuffer = sendable.sampleBuffer
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard time.isNumeric else { return }
                if self.isPaused {
                    if self.pauseStartTime == nil { self.pauseStartTime = time }
                    return
                }
                if self.needsPauseDurationUpdate {
                    if let pauseStartTime = self.pauseStartTime {
                        self.totalPauseDuration = CMTimeAdd(
                            self.totalPauseDuration, CMTimeSubtract(time, pauseStartTime)
                        )
                        self.pauseStartTime = nil
                    }
                    self.needsPauseDurationUpdate = false
                }
                if !self.isSessionStarted {
                    self.sessionStartTime = time
                    self.totalPauseDuration = .zero
                    assetWriter.startSession(atSourceTime: .zero)
                    self.isSessionStarted = true
                }
                self.latestSampleTime = time
                let startTime = self.sessionStartTime ?? time
                let adjusted = CMTimeSubtract(CMTimeSubtract(time, startTime), self.totalPauseDuration)
                // Removing a pause maps its first resumed frame to the last
                // pre-pause timestamp. Duplicate PTS breaks fragmented MOVs.
                guard adjusted >= .zero,
                      self.latestWrittenTime.map({ adjusted > $0 }) ?? true,
                      videoInput.isReadyForMoreMediaData,
                      let retimed = Self.retime(sampleBuffer, to: adjusted) else { return }
                if videoInput.append(retimed) {
                    self.sessionStartTime = startTime
                    self.latestWrittenTime = adjusted
                } else {
                    self.recordFailure(assetWriter.error ?? CocoaError(.fileWriteUnknown))
                }
            }
        }
    }

    private func recordFailure(_ error: Error) {
        guard failureError == nil else { return }
        failureError = error
        NSLog("[Screendrop] Camera movie writer failed; preserving partial footage: \(error)")
    }

    func finish() async -> CameraRecordingResult? {
        let destination = writingQueue.sync { finalURL }
        let snapshot: CameraRecordingResult? = await withCheckedContinuation { continuation in
            writingQueue.async { [self] in
                guard let assetWriter else {
                    continuation.resume(returning: nil)
                    return
                }
                let complete: @Sendable () -> Void = { [self] in
                    writingQueue.async { [self] in
                        let completed = self.assetWriter?.status == .completed
                        let error = failureError ?? self.assetWriter?.error
                        let result = CameraRecordingResult(
                            url: outputURL,
                            error: error ?? (completed ? nil : CocoaError(.fileWriteUnknown)),
                            firstFrameUptime: latestWrittenTime == nil ? nil : sessionStartTime?.seconds,
                            pixelWidth: pixelWidth,
                            pixelHeight: pixelHeight
                        )
                        reset()
                        continuation.resume(returning: result)
                    }
                }
                // Calling finishWriting on a writer that already failed can
                // throw an Objective-C exception. Its fragments stay on disk.
                if assetWriter.status == .writing, isSessionStarted {
                    videoInput?.markAsFinished()
                    assetWriter.finishWriting(completionHandler: complete)
                } else {
                    if assetWriter.status == .writing { assetWriter.cancelWriting() }
                    complete()
                }
            }
        }
        guard var result = snapshot, let url = result.url else { return snapshot }
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration)
            guard !tracks.isEmpty, duration.isNumeric, duration > .zero,
                  result.firstFrameUptime != nil, let destination else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try FileManager.default.moveItem(at: url, to: destination)
            result.url = destination
            result.fileIsUsable = true
        } catch {
            result.error = result.error ?? error
            NSLog("[Screendrop] Could not finalize camera footage at \(url.path): \(error)")
        }
        if !FileManager.default.fileExists(atPath: url.path), !result.fileIsUsable {
            result.url = nil
        }
        return result
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            writingQueue.async { [self] in
                assetWriter?.cancelWriting()
                if let outputURL {
                    do { try FileManager.default.removeItem(at: outputURL) }
                    catch let error as CocoaError where error.code == .fileNoSuchFile {}
                    catch { NSLog("[Screendrop] Could not discard camera footage: \(error)") }
                }
                reset()
                continuation.resume()
            }
        }
    }

    private func reset() {
        assetWriter = nil
        videoInput = nil
        outputURL = nil
        finalURL = nil
        isSessionStarted = false
        sessionStartTime = nil
        isPaused = false
        pauseStartTime = nil
        totalPauseDuration = .zero
        needsPauseDurationUpdate = false
        latestSampleTime = nil
        latestWrittenTime = nil
        failureError = nil
    }

    private static func retime(_ sampleBuffer: CMSampleBuffer, to newPTS: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: newPTS,
            decodeTimeStamp: .invalid
        )
        var newBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &newBuffer
        )
        return status == noErr ? newBuffer : nil
    }
}

nonisolated private struct SendableCameraSampleBuffer: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    init(_ sampleBuffer: CMSampleBuffer) { self.sampleBuffer = sampleBuffer }
}
