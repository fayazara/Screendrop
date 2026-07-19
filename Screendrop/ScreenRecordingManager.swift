//
//  ScreenRecordingManager.swift
//  Screendrop
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
        RecordingControlPresenter.shared.show(displayID: targetDisplayID)

        Task {
            do {
                let outputURL = Self.generateTemporaryRecordingURL()
                let content = try await ScreenRecordingCapture.availableContent()
                let recordMicrophoneAudio = ScreendropPreferences.recordMicrophoneAudio
                let target = try Self.captureTarget(
                    for: source,
                    content: content,
                    recordMicrophoneAudio: recordMicrophoneAudio
                )
                let mouseIndicatorStore = ScreendropPreferences.showRecordingMouseIndicators
                    ? RecordingMouseIndicatorController.shared.start(mapping: target.mouseIndicatorMapping)
                    : nil
                let keyCaptionStore = ScreendropPreferences.showRecordingKeyPressCaptions
                    ? RecordingKeyCaptionController.shared.start(mapping: target.keyCaptionMapping)
                    : nil

                try writer.setupWriter(
                    outputURL: outputURL,
                    videoWidth: target.width,
                    videoHeight: target.height,
                    recordMicrophoneAudio: recordMicrophoneAudio,
                    mouseIndicatorStore: mouseIndicatorStore,
                    keyCaptionStore: keyCaptionStore
                )

                capture.onVideoFrame = { [writer] sampleBuffer in
                    writer.writeVideoSample(sampleBuffer)
                }
                capture.onMicrophoneSample = { [writer] sampleBuffer in
                    writer.writeAudioSample(sampleBuffer)
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
        RecordingMouseIndicatorController.shared.pause()
        RecordingKeyCaptionController.shared.pause()
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
        RecordingMouseIndicatorController.shared.resume()
        RecordingKeyCaptionController.shared.resume()
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
            RecordingControlPresenter.shared.hide()
            return
        }

        switch action {
        case .preview:
            RecordingControlPresenter.shared.hide()
            onFinishRecording?(url, restartDisplayID)
        case .discard:
            deleteFile(at: url)
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
        capture.onMicrophoneSample = nil
        capture.onError = nil
        RecordingMouseIndicatorController.shared.stop()
        RecordingKeyCaptionController.shared.stop()
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

    private static func captureTarget(
        for source: ScreenRecordingSource,
        content: SCShareableContent,
        recordMicrophoneAudio: Bool
    ) throws -> ScreenRecordingCaptureTarget {
        let filter: SCContentFilter
        let sourceSize: CGSize
        var sourceRect: CGRect?
        let captureRect: CGRect
        let displayID: CGDirectDisplayID?

        switch source.kind {
        case .fullscreen(let display):
            let freshDisplay = content.displays.first(where: { $0.displayID == display.displayID }) ?? display
            filter = ScreenRecordingCapture.displayFilter(display: freshDisplay, content: content)
            sourceSize = CGSize(width: freshDisplay.width, height: freshDisplay.height)
            captureRect = freshDisplay.frame
            displayID = freshDisplay.displayID
        case .window(let window):
            let freshWindow = content.windows.first(where: { $0.windowID == window.windowID }) ?? window
            filter = SCContentFilter(desktopIndependentWindow: freshWindow)
            sourceSize = freshWindow.frame.size
            captureRect = freshWindow.frame
            displayID = nil
        case .area(let display, let rect):
            let freshDisplay = content.displays.first(where: { $0.displayID == display.displayID }) ?? display
            filter = ScreenRecordingCapture.displayFilter(display: freshDisplay, content: content)
            let mappedSourceRect = Self.sourceRect(
                forAppKitSelectionRect: rect,
                screenFrame: ActiveDisplayResolver.screen(for: freshDisplay.displayID)?.frame,
                contentRect: filter.contentRect
            )
            sourceRect = mappedSourceRect
            sourceSize = mappedSourceRect.size
            captureRect = rect
            displayID = freshDisplay.displayID
        }

        let scaleFactor = max(1, CGFloat(filter.pointPixelScale))
        let width = max(2, Int((sourceSize.width * scaleFactor).rounded(.toNearestOrAwayFromZero)))
        let height = max(2, Int((sourceSize.height * scaleFactor).rounded(.toNearestOrAwayFromZero)))
        let configuration = ScreenRecordingCapture.buildConfiguration(
            width: width,
            height: height,
            sourceRect: sourceRect,
            recordMicrophoneAudio: recordMicrophoneAudio
        )
        let mouseIndicatorMapping = RecordingMouseIndicatorMapping(
            captureRect: captureRect,
            pixelWidth: width,
            pixelHeight: height
        )
        let keyCaptionMapping = RecordingKeyCaptionMapping(
            captureRect: captureRect,
            pixelWidth: width,
            pixelHeight: height
        )
        return ScreenRecordingCaptureTarget(
            filter: filter,
            configuration: configuration,
            width: width,
            height: height,
            displayID: displayID,
            mouseIndicatorMapping: mouseIndicatorMapping,
            keyCaptionMapping: keyCaptionMapping
        )
    }

    private static func sourceRect(
        forAppKitSelectionRect selectionRect: CGRect,
        screenFrame: CGRect?,
        contentRect: CGRect
    ) -> CGRect {
        guard let screenFrame,
              screenFrame.width > 0,
              screenFrame.height > 0,
              contentRect.width > 0,
              contentRect.height > 0 else {
            return clamped(selectionRect, to: contentRect)
        }

        let minLocalX = min(max(selectionRect.minX - screenFrame.minX, 0), screenFrame.width)
        let maxLocalX = min(max(selectionRect.maxX - screenFrame.minX, 0), screenFrame.width)
        let minLocalY = min(max(selectionRect.minY - screenFrame.minY, 0), screenFrame.height)
        let maxLocalY = min(max(selectionRect.maxY - screenFrame.minY, 0), screenFrame.height)

        let scaleX = contentRect.width / screenFrame.width
        let scaleY = contentRect.height / screenFrame.height
        let sourceX = contentRect.minX + minLocalX * scaleX
        let sourceY = contentRect.minY + (screenFrame.height - maxLocalY) * scaleY
        let sourceWidth = max(1, (maxLocalX - minLocalX) * scaleX)
        let sourceHeight = max(1, (maxLocalY - minLocalY) * scaleY)

        return clamped(
            CGRect(x: sourceX, y: sourceY, width: sourceWidth, height: sourceHeight),
            to: contentRect
        )
    }

    private static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else {
            return .zero
        }

        let width = min(max(rect.width, 1), bounds.width)
        let height = min(max(rect.height, 1), bounds.height)
        let minX = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let minY = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        let maxX = minX + width
        let maxY = minY + height

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func generateTemporaryRecordingURL() -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Screendrop_Recording_\(timestamp)_\(UUID().uuidString.prefix(6)).mov")
    }
}

private struct ScreenRecordingCaptureTarget {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let width: Int
    let height: Int
    let displayID: CGDirectDisplayID?
    let mouseIndicatorMapping: RecordingMouseIndicatorMapping
    let keyCaptionMapping: RecordingKeyCaptionMapping
}

private enum ScreenRecordingAudioSettings {
    nonisolated static let sampleRate = 48_000
    nonisolated static let channelCount = 2
    nonisolated static let bitRate = 128_000
}

nonisolated final class ScreenRecordingCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var isMicrophoneOutputAdded = false
    private let videoQueue = DispatchQueue(label: "com.screendrop.screen-recording.video", qos: .userInteractive)
    private let microphoneQueue = DispatchQueue(label: "com.screendrop.screen-recording.microphone", qos: .userInitiated)

    var onVideoFrame: ((CMSampleBuffer) -> Void)?
    var onMicrophoneSample: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    static func availableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    func startCapture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        var isScreenOutputAdded = false
        var isMicrophoneOutputAdded = false

        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            isScreenOutputAdded = true

            if configuration.captureMicrophone {
                do {
                    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
                    isMicrophoneOutputAdded = true
                } catch {
                    print("Screen recording microphone capture unavailable: \(error)")
                }
            }

            try await stream.startCapture()
            self.stream = stream
            self.isMicrophoneOutputAdded = isMicrophoneOutputAdded
        } catch {
            if isMicrophoneOutputAdded {
                try? stream.removeStreamOutput(self, type: .microphone)
            }
            if isScreenOutputAdded {
                try? stream.removeStreamOutput(self, type: .screen)
            }
            throw error
        }
    }

    func stopCapture() async throws {
        guard let stream else { return }
        let isMicrophoneOutputAdded = isMicrophoneOutputAdded
        self.stream = nil
        self.isMicrophoneOutputAdded = false
        defer {
            try? stream.removeStreamOutput(self, type: .screen)
            if isMicrophoneOutputAdded {
                try? stream.removeStreamOutput(self, type: .microphone)
            }
        }
        try await stream.stopCapture()
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

    static func buildConfiguration(
        width: Int,
        height: Int,
        sourceRect: CGRect?,
        recordMicrophoneAudio: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        if let sourceRect {
            configuration.sourceRect = sourceRect
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.showMouseClicks = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = recordMicrophoneAudio
        if recordMicrophoneAudio {
            configuration.sampleRate = ScreenRecordingAudioSettings.sampleRate
            configuration.channelCount = ScreenRecordingAudioSettings.channelCount
        }
        return configuration
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            if let status = Self.frameStatus(for: sampleBuffer),
               status == .blank || status == .suspended || status == .stopped {
                return
            }
            onVideoFrame?(sampleBuffer)
        case .microphone:
            onMicrophoneSample?(sampleBuffer)
        default:
            return
        }
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
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let writingQueue = DispatchQueue(label: "com.screendrop.screen-recording.writer", qos: .userInitiated)
    private var outputURL: URL?
    private var isSessionStarted = false
    private var sessionStartTime: CMTime?
    private var isPaused = false
    private var pauseStartTime: CMTime?
    private var totalPauseDuration: CMTime = .zero
    private var latestSampleTime: CMTime?
    private var needsPauseDurationUpdate = false
    private var mouseIndicatorStore: RecordingMouseIndicatorStore?
    private var keyCaptionStore: RecordingKeyCaptionStore?

    func setupWriter(
        outputURL: URL,
        videoWidth: Int,
        videoHeight: Int,
        recordMicrophoneAudio: Bool,
        mouseIndicatorStore: RecordingMouseIndicatorStore?,
        keyCaptionStore: RecordingKeyCaptionStore?
    ) throws {
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
        try Self.add(input, to: writer)

        let audioInput = try Self.makeAudioInputIfNeeded(for: writer, recordMicrophoneAudio: recordMicrophoneAudio)

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
        self.audioInput = audioInput
        pixelBufferAdaptor = adaptor
        self.outputURL = outputURL
        self.mouseIndicatorStore = mouseIndicatorStore
        self.keyCaptionStore = keyCaptionStore
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
            autoreleasepool {
                guard let self = self,
                      let videoInput = self.videoInput,
                      let pixelBufferAdaptor = self.pixelBufferAdaptor else {
                    return
                }

                let sampleBuffer = sendableSampleBuffer.sampleBuffer
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                guard let adjustedPTS = self.adjustedTimeForWritableSample(sampleBuffer),
                      videoInput.isReadyForMoreMediaData else {
                    return
                }

                if let snapshot = self.mouseIndicatorStore?.snapshot(at: adjustedPTS.seconds) {
                    RecordingMouseIndicatorRenderer.render(snapshot: snapshot, into: pixelBuffer)
                }
                if let snapshot = self.keyCaptionStore?.snapshot(at: adjustedPTS.seconds) {
                    RecordingKeyCaptionRenderer.render(snapshot: snapshot, into: pixelBuffer)
                }

                pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: adjustedPTS)
            }
        }
    }

    func writeAudioSample(_ sampleBuffer: CMSampleBuffer) {
        let sendableSampleBuffer = SendableSampleBuffer(sampleBuffer)
        writingQueue.async { [weak self, sendableSampleBuffer] in
            autoreleasepool {
                guard let self, let audioInput = self.audioInput else { return }

                let sampleBuffer = sendableSampleBuffer.sampleBuffer
                guard let adjustedPTS = self.adjustedTimeForWritableSample(sampleBuffer),
                      audioInput.isReadyForMoreMediaData,
                      let retimedSampleBuffer = Self.retime(sampleBuffer, to: adjustedPTS) else {
                    return
                }

                audioInput.append(retimedSampleBuffer)
            }
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
                audioInput?.markAsFinished()
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

    private func adjustedTimeForWritableSample(_ sampleBuffer: CMSampleBuffer) -> CMTime? {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !isSessionStarted {
            startSession(at: time)
        }

        guard handlePauseState(sampleTime: time) else { return nil }

        let adjustedPTS = adjustedTime(time)
        return adjustedPTS >= .zero ? adjustedPTS : nil
    }

    private static func add(_ input: AVAssetWriterInput, to writer: AVAssetWriter) throws {
        guard writer.canAdd(input) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }

        writer.add(input)
    }

    private static func makeAudioInputIfNeeded(
        for writer: AVAssetWriter,
        recordMicrophoneAudio: Bool
    ) throws -> AVAssetWriterInput? {
        guard recordMicrophoneAudio else { return nil }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: ScreenRecordingAudioSettings.channelCount,
            AVSampleRateKey: ScreenRecordingAudioSettings.sampleRate,
            AVEncoderBitRateKey: ScreenRecordingAudioSettings.bitRate
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        try add(audioInput, to: writer)
        return audioInput
    }

    private func startSession(at sampleTime: CMTime) {
        sessionStartTime = sampleTime
        latestSampleTime = sampleTime
        assetWriter?.startSession(atSourceTime: .zero)
        isSessionStarted = true
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
        audioInput = nil
        pixelBufferAdaptor = nil
        outputURL = nil
        mouseIndicatorStore = nil
        keyCaptionStore = nil
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
