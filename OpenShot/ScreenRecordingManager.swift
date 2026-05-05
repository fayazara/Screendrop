//
//  ScreenRecordingManager.swift
//  OpenShot
//
//  Created by Codex on 01/05/26.
//

import AppKit
import AVFoundation
@preconcurrency import CoreMedia
import Observation
import ScreenCaptureKit

enum ScreenRecordingState: Equatable {
    case idle
    case starting
    case recording
    case paused
    case finishing
}

enum ScreenRecordingSourceMode: String, CaseIterable, Identifiable {
    case fullscreen
    case window
    case area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullscreen:
            "Full Screen"
        case .window:
            "Window"
        case .area:
            "Area"
        }
    }

    var systemImage: String {
        switch self {
        case .fullscreen:
            "display"
        case .window:
            "macwindow"
        case .area:
            "rectangle.dashed"
        }
    }
}

struct ScreenRecordingSource {
    enum Kind {
        case fullscreen(SCDisplay)
        case window(SCWindow)
        case area(display: SCDisplay, rect: CGRect)
    }

    let kind: Kind

    var displayID: CGDirectDisplayID? {
        switch kind {
        case .fullscreen(let display):
            display.displayID
        case .window:
            nil
        case .area(let display, _):
            display.displayID
        }
    }
}

private enum ScreenRecordingFinishAction {
    case preview
    case discard
    case restart
}

@MainActor
@Observable
final class ScreenRecordingManager {
    static let shared = ScreenRecordingManager()

    var state: ScreenRecordingState = .idle
    var elapsedTime: TimeInterval = 0
    var errorMessage: String?
    var onFinishRecording: ((URL, CGDirectDisplayID?) -> Void)?

    private let capture = ScreenRecordingCapture()
    private let writer = ScreenRecordingWriter()
    private var displayID: CGDirectDisplayID?
    private var outputURL: URL?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var accumulatedPauseDuration: TimeInterval = 0
    private var timer: Timer?
    private var finishAction: ScreenRecordingFinishAction = .preview
    private var isStopping = false
    private var currentSource: ScreenRecordingSource?

    var isActive: Bool {
        state != .idle
    }

    var formattedElapsedTime: String {
        let totalSeconds = max(0, Int(elapsedTime.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private init() {}

    func startRecording(source: ScreenRecordingSource) {
        guard state == .idle else { return }

        let targetDisplayID = source.displayID ?? ActiveDisplayResolver.activeDisplayID(preferPointer: true) ?? CGMainDisplayID()
        state = .starting
        errorMessage = nil
        displayID = targetDisplayID
        currentSource = source
        finishAction = .preview
        isStopping = false

        PreviewWindowPlacement.shared.setTargetDisplayID(targetDisplayID)
        PreviewWindowCaptureExclusion.shared.hideForCapture()
        RecordingControlPresenter.shared.show(displayID: targetDisplayID)

        Task {
            do {
                let outputURL = Self.generateTemporaryRecordingURL()
                let content = try await ScreenRecordingCapture.availableContent()
                let target = try Self.captureTarget(for: source, content: content)

                try writer.setupWriter(outputURL: outputURL, videoWidth: target.width, videoHeight: target.height)

                capture.onVideoFrame = { [writer] sampleBuffer in
                    writer.writeVideoSample(sampleBuffer)
                }
                capture.onError = { [weak self] error in
                    Task { @MainActor in
                        self?.handleCaptureError(error)
                    }
                }

                try await capture.startCapture(filter: target.filter, configuration: target.configuration)

                self.outputURL = outputURL
                startedAt = Date()
                pausedAt = nil
                accumulatedPauseDuration = 0
                elapsedTime = 0
                state = .recording
                startTimer()
            } catch {
                await finishFailedStart(error: error)
            }
        }
    }

    func stopRecording() {
        guard state == .recording || state == .paused else { return }
        finishAction = .preview
        stopCaptureAndFinish()
    }

    func pauseRecording() {
        guard state == .recording else { return }

        writer.pause()
        pausedAt = Date()
        state = .paused
        updateElapsedTime()
    }

    func resumeRecording() {
        guard state == .paused else { return }

        if let pausedAt {
            accumulatedPauseDuration += Date().timeIntervalSince(pausedAt)
        }

        self.pausedAt = nil
        writer.resume()
        state = .recording
        updateElapsedTime()
    }

    func restartRecording() {
        guard state == .recording || state == .paused else { return }
        finishAction = .restart
        stopCaptureAndFinish()
    }

    func deleteRecording() {
        guard state != .idle else {
            RecordingControlPresenter.shared.hide()
            return
        }

        finishAction = .discard
        stopCaptureAndFinish()
    }

    private func stopCaptureAndFinish() {
        guard !isStopping else { return }

        isStopping = true
        state = .finishing
        timer?.invalidate()

        Task {
            do {
                try await capture.stopCapture()
            } catch {
                print("Screen recording capture stop failed: \(error)")
            }

            let url = await writer.finishWriting()
            handleFinishedRecording(url: url)
        }
    }

    private func handleFinishedRecording(url: URL?) {
        let action = finishAction
        let restartSource = currentSource
        let restartDisplayID = displayID

        cleanupAfterRecording()

        guard let url else {
            errorMessage = "Failed to finish recording."
            PreviewWindowCaptureExclusion.shared.restoreAfterCapture()
            RecordingControlPresenter.shared.hide()
            return
        }

        switch action {
        case .preview:
            PreviewWindowCaptureExclusion.shared.restoreAfterCapture()
            RecordingControlPresenter.shared.hide()
            onFinishRecording?(url, restartDisplayID)
        case .discard:
            deleteFile(at: url)
            PreviewWindowCaptureExclusion.shared.restoreAfterCapture()
            RecordingControlPresenter.shared.hide()
        case .restart:
            deleteFile(at: url)
            if let restartSource {
                startRecording(source: restartSource)
            }
        }
    }

    private func handleCaptureError(_ error: Error) {
        guard state == .recording || state == .paused || state == .starting else { return }

        errorMessage = "Screen recording failed: \(error.localizedDescription)"
        finishAction = .discard
        stopCaptureAndFinish()
    }

    private func finishFailedStart(error: Error) async {
        await writer.cancel()
        cleanupAfterRecording()
        errorMessage = "Failed to start screen recording: \(error.localizedDescription)"
        PreviewWindowCaptureExclusion.shared.restoreAfterCapture()
        RecordingControlPresenter.shared.hide()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                ScreenRecordingManager.shared.updateElapsedTime()
            }
        }
    }

    private func updateElapsedTime() {
        guard let startedAt else {
            elapsedTime = 0
            return
        }

        let pauseDuration: TimeInterval
        if state == .paused, let pausedAt {
            pauseDuration = accumulatedPauseDuration + Date().timeIntervalSince(pausedAt)
        } else {
            pauseDuration = accumulatedPauseDuration
        }

        elapsedTime = max(0, Date().timeIntervalSince(startedAt) - pauseDuration)
    }

    private func cleanupAfterRecording() {
        timer?.invalidate()
        timer = nil
        capture.onVideoFrame = nil
        capture.onError = nil
        outputURL = nil
        displayID = nil
        currentSource = nil
        startedAt = nil
        pausedAt = nil
        accumulatedPauseDuration = 0
        finishAction = .preview
        isStopping = false
        state = .idle
    }

    private func deleteFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("Failed to delete recording: \(error)")
        }
    }

    private static func captureTarget(for source: ScreenRecordingSource, content: SCShareableContent) throws -> ScreenRecordingCaptureTarget {
        let filter: SCContentFilter
        let sourceSize: CGSize
        var sourceRect: CGRect?
        let displayID: CGDirectDisplayID?

        switch source.kind {
        case .fullscreen(let display):
            let freshDisplay = content.displays.first(where: { $0.displayID == display.displayID }) ?? display
            filter = ScreenRecordingCapture.displayFilter(display: freshDisplay, content: content)
            sourceSize = CGSize(width: freshDisplay.width, height: freshDisplay.height)
            displayID = freshDisplay.displayID
        case .window(let window):
            let freshWindow = content.windows.first(where: { $0.windowID == window.windowID }) ?? window
            filter = SCContentFilter(desktopIndependentWindow: freshWindow)
            sourceSize = freshWindow.frame.size
            displayID = nil
        case .area(let display, let rect):
            let freshDisplay = content.displays.first(where: { $0.displayID == display.displayID }) ?? display
            filter = ScreenRecordingCapture.displayFilter(display: freshDisplay, content: content)
            sourceRect = rect
            sourceSize = rect.size
            displayID = freshDisplay.displayID
        }

        let scaleFactor = max(1, CGFloat(filter.pointPixelScale))
        let width = max(2, Int((sourceSize.width * scaleFactor).rounded(.toNearestOrAwayFromZero)))
        let height = max(2, Int((sourceSize.height * scaleFactor).rounded(.toNearestOrAwayFromZero)))
        let configuration = ScreenRecordingCapture.buildConfiguration(width: width, height: height, sourceRect: sourceRect)
        return ScreenRecordingCaptureTarget(filter: filter, configuration: configuration, width: width, height: height, displayID: displayID)
    }

    private static func generateTemporaryRecordingURL() -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenShot_Recording_\(timestamp)_\(UUID().uuidString.prefix(6)).mov")
    }
}

private struct ScreenRecordingCaptureTarget {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let width: Int
    let height: Int
    let displayID: CGDirectDisplayID?
}

nonisolated final class ScreenRecordingCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "com.openshot.screen-recording.video", qos: .userInteractive)

    var onVideoFrame: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    static func availableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    func startCapture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stopCapture() async throws {
        guard let stream else { return }
        try await stream.stopCapture()
        self.stream = nil
    }

    static func displayFilter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let excludedApps = content.applications.filter { application in
            application.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        return SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )
    }

    static func buildConfiguration(width: Int, height: Int, sourceRect: CGRect?) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        if let sourceRect {
            configuration.sourceRect = sourceRect
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 8
        configuration.showsCursor = true
        configuration.showMouseClicks = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        return configuration
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if let status = Self.frameStatus(for: sampleBuffer),
           status == .blank || status == .suspended || status == .stopped {
            return
        }
        onVideoFrame?(sampleBuffer)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    private static func frameStatus(for sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let rawValue = attachments.first?[SCStreamFrameInfo.status] as? Int else {
            return nil
        }

        return SCFrameStatus(rawValue: rawValue)
    }
}

nonisolated private final class ScreenRecordingWriter: @unchecked Sendable {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let writingQueue = DispatchQueue(label: "com.openshot.screen-recording.writer", qos: .userInitiated)
    private var outputURL: URL?
    private var isSessionStarted = false
    private var sessionStartTime: CMTime?
    private var isPaused = false
    private var pauseStartTime: CMTime?
    private var totalPauseDuration: CMTime = .zero
    private var latestSampleTime: CMTime?
    private var needsPauseDurationUpdate = false

    func setupWriter(outputURL: URL, videoWidth: Int, videoHeight: Int) throws {
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let bitRate = max(20_000_000, videoWidth * videoHeight * 4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 60
            ] as [String: Any]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight
            ]
        )

        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }

        assetWriter = writer
        videoInput = input
        pixelBufferAdaptor = adaptor
        self.outputURL = outputURL
        isSessionStarted = false
        sessionStartTime = nil
        isPaused = false
        pauseStartTime = nil
        totalPauseDuration = .zero
        latestSampleTime = nil
        needsPauseDurationUpdate = false
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
        let sendableSampleBuffer = SendableSampleBuffer(sampleBuffer)
        writingQueue.async { [weak self, sendableSampleBuffer] in
            guard let self, let videoInput, let pixelBufferAdaptor else { return }

            let sampleBuffer = sendableSampleBuffer.sampleBuffer
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if !isSessionStarted {
                sessionStartTime = time
                latestSampleTime = time
                assetWriter?.startSession(atSourceTime: .zero)
                isSessionStarted = true
            }

            guard handlePauseState(sampleTime: time) else { return }

            let adjustedPTS = adjustedTime(time)
            guard adjustedPTS >= .zero, videoInput.isReadyForMoreMediaData else { return }

            pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: adjustedPTS)
        }
    }

    func finishWriting() async -> URL? {
        let url = outputURL

        return await withCheckedContinuation { continuation in
            writingQueue.async { [weak self] in
                guard let self, let assetWriter else {
                    continuation.resume(returning: url)
                    return
                }

                videoInput?.markAsFinished()
                assetWriter.finishWriting {
                    self.cleanup()
                    continuation.resume(returning: url)
                }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            writingQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                assetWriter?.cancelWriting()
                if let outputURL {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                cleanup()
                continuation.resume()
            }
        }
    }

    private func adjustedTime(_ originalTime: CMTime) -> CMTime {
        var adjusted = originalTime
        if let sessionStartTime {
            adjusted = CMTimeSubtract(adjusted, sessionStartTime)
        }
        if totalPauseDuration > .zero {
            adjusted = CMTimeSubtract(adjusted, totalPauseDuration)
        }
        return adjusted
    }

    private func handlePauseState(sampleTime: CMTime) -> Bool {
        if isPaused {
            if pauseStartTime == nil {
                pauseStartTime = sampleTime
            }
            return false
        }

        if needsPauseDurationUpdate, let pauseStartTime {
            totalPauseDuration = CMTimeAdd(totalPauseDuration, CMTimeSubtract(sampleTime, pauseStartTime))
            self.pauseStartTime = nil
            needsPauseDurationUpdate = false
        } else if needsPauseDurationUpdate {
            needsPauseDurationUpdate = false
        }

        latestSampleTime = sampleTime
        return true
    }

    private static func retime(_ sampleBuffer: CMSampleBuffer, to newPTS: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: newPTS,
            decodeTimeStamp: .invalid
        )
        var newBuffer: CMSampleBuffer?

        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &newBuffer
        )
        return status == noErr ? newBuffer : nil
    }

    private func cleanup() {
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        outputURL = nil
        isSessionStarted = false
        sessionStartTime = nil
        isPaused = false
        pauseStartTime = nil
        totalPauseDuration = .zero
        latestSampleTime = nil
        needsPauseDurationUpdate = false
    }
}

nonisolated private struct SendableSampleBuffer: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer

    init(_ sampleBuffer: CMSampleBuffer) {
        self.sampleBuffer = sampleBuffer
    }
}
