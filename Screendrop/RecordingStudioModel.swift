//
//  RecordingStudioModel.swift
//  Screendrop
//
//  View-model for the recording studio: loads a recording session (screen
//  movie + optional camera movie + pointer-capture sidecar), owns the style
//  settings and zoom cues, and keeps the screen and camera players in
//  sync. Layout math lives in RecordingStudioLayout so the live preview and
//  the exporter compose frames identically.
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation

enum RecordingStudioExportState: Equatable {
    case idle
    case exporting(progress: Double)
    case finished(URL)
    case failed(String)

    var isExporting: Bool {
        if case .exporting = self { return true }
        return false
    }
}

@MainActor
@Observable
final class RecordingStudioModel {
    let sessionURL: URL
    private(set) var session: RecordingSession?
    private(set) var manifest: CaptureManifest?
    private(set) var pointerCapture = PointerCaptureFile()
    private(set) var recordedPressTimes: [TimeInterval] = []
    private(set) var duration: TimeInterval = 0
    private(set) var videoSize = CGSize(width: 1920, height: 1080)
    private(set) var hasCameraVideo = false
    private(set) var cameraOffset: TimeInterval = 0
    private(set) var isLoaded = false
    private(set) var loadError: String?

    let screenPlayer = AVPlayer()
    let cameraPlayer = AVPlayer()

    var style = RecordingStudioStyle(background: RecordingStudioDefaults.background) {
        didSet {
            if isLoaded, oldValue.background != style.background {
                RecordingStudioDefaults.background = style.background
            }
            scheduleProjectSave()
        }
    }
    var zoomEnabled = true {
        didSet { scheduleProjectSave() }
    }
    var exportSettings = VideoCompressionSettings() {
        didSet { scheduleProjectSave() }
    }
    private(set) var zoomCues: [ZoomCue] = []
    private(set) var viewportTimeline = ViewportTimeline.identity
    private(set) var pointerTimeline = PointerTimeline.empty
    var selectedCueID: UUID?
    private(set) var trimSelection = VideoTrimSelection(start: 0, end: 0)
    private(set) var timelineFrames: [NSImage] = []

    private(set) var isPlaying = false
    var currentTime: TimeInterval = 0
    var exportState: RecordingStudioExportState = .idle

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var exportTask: Task<Void, Never>?
    private var projectSaveTask: Task<Void, Never>?
    private var timelineTask: Task<Void, Never>?

    /// Accepts either a recording session folder or a bare video file (so
    /// history items and old recordings still open, just without events).
    init(url: URL) {
        sessionURL = url
        if RecordingSession.isSessionDirectory(url) {
            session = RecordingSession(directoryURL: url)
        } else {
            session = nil
        }
    }

    var screenURL: URL {
        session?.screenURL ?? sessionURL
    }

    func load() async {
        guard !isLoaded else { return }

        if let session {
            manifest = session.loadCaptureManifest()
            pointerCapture = session.loadPointerCapture() ?? PointerCaptureFile()
        }

        let asset = AVURLAsset(url: screenURL)
        do {
            let (durationTime, tracks) = try await asset.load(.duration, .tracks)
            duration = durationTime.seconds
            if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
                let naturalSize = try await videoTrack.load(.naturalSize)
                if naturalSize.width > 0, naturalSize.height > 0 {
                    videoSize = naturalSize
                }
            }
        } catch {
            loadError = "Could not open the recording: \(error.localizedDescription)"
            return
        }

        if session != nil {
            let pointScale = max(manifest?.pixelScale ?? 1, 1)
            let stream = PointerStreamSanitizer.sanitize(
                pointerCapture,
                options: PointerSanitizeOptions(
                    recordingSizeInPoints: CGSize(
                        width: videoSize.width / CGFloat(pointScale),
                        height: videoSize.height / CGFloat(pointScale)
                    )
                )
            )
            pointerCapture = stream.sanitizedCapture
            recordedPressTimes = pointerCapture.presses
                .filter { $0.phase == .down }
                .map(\.time)
        }

        screenPlayer.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        screenPlayer.actionAtItemEnd = .pause

        if let session, session.hasCamera {
            hasCameraVideo = true
            cameraOffset = manifest?.cameraLeadIn ?? 0
            cameraPlayer.replaceCurrentItem(with: AVPlayerItem(url: session.cameraURL))
            cameraPlayer.actionAtItemEnd = .pause
            cameraPlayer.isMuted = true
        } else {
            style.camera.isVisible = false
        }

        let document = session?.loadEditDocument()
        if let document {
            style = document.style.value
            zoomEnabled = document.zoomEnabled
            zoomCues = document.zoomCues
            exportSettings = document.exportSettings ?? VideoCompressionSettings()
        } else if session == nil {
            // Legacy bare movies use the same editor, but open visually
            // unchanged until the user explicitly adds styling.
            style = RecordingStudioStyle(
                background: .none,
                padding: 0,
                cornerRadius: 0,
                shadow: 0,
                camera: RecordingCameraBubbleSettings(isVisible: false)
            )
            zoomEnabled = false
        } else {
            zoomCues = ZoomCueSynthesizer.cues(from: pointerCapture, duration: duration)
        }
        trimSelection = VideoTrimSelection(
            start: document?.trimStart ?? 0,
            end: document?.trimEnd ?? duration
        ).clamped(to: duration)
        if pointerIsSynthesized {
            pointerTimeline = PointerTimeline.build(
                capture: pointerCapture,
                duration: duration,
                recordingSizeInPoints: recordingPointSize,
                fallbackArtwork: PointerArtworkCapture.defaultArtwork()
            )
        }
        rebuildViewportTimeline()
        installObservers()
        isLoaded = true
        scheduleProjectSave()
        loadTimelineFrames()
    }

    func teardown() {
        exportTask?.cancel()
        projectSaveTask?.cancel()
        timelineTask?.cancel()
        saveProjectNow()
        pause()
        if let timeObserver {
            screenPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        screenPlayer.replaceCurrentItem(with: nil)
        cameraPlayer.replaceCurrentItem(with: nil)
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard !isPlaying else { return }
        let selection = trimSelection.clamped(to: duration)
        guard selection.duration >= VideoTrimSelection.minimumDuration else { return }
        if currentTime < selection.start || currentTime >= selection.end - 0.05 {
            seek(to: selection.start)
        }
        isPlaying = true
        screenPlayer.play()
        syncCameraPlayback()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        screenPlayer.pause()
        cameraPlayer.pause()
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), max(duration, 0))
        currentTime = clamped
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        screenPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if hasCameraVideo {
            if clamped >= cameraOffset {
                let cameraTime = CMTime(seconds: max(0, clamped - cameraOffset), preferredTimescale: 600)
                cameraPlayer.seek(to: cameraTime, toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                cameraPlayer.pause()
                cameraPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        if isPlaying {
            syncCameraPlayback()
        }
    }

    /// Time the preview canvas should render right now.
    var displayTime: TimeInterval {
        if isPlaying {
            let time = screenPlayer.currentTime().seconds
            return time.isFinite ? time : currentTime
        }
        return currentTime
    }

    private func installObservers() {
        timeObserver = screenPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.02, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isPlaying {
                    let seconds = time.seconds
                    let selection = self.trimSelection.clamped(to: self.duration)
                    if seconds >= selection.end - 0.001 {
                        self.pause()
                        self.currentTime = selection.end
                        self.screenPlayer.seek(
                            to: CMTime(seconds: selection.end, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                        return
                    }
                    self.currentTime = seconds
                    self.correctCameraDriftIfNeeded()
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: screenPlayer.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.cameraPlayer.pause()
                self.currentTime = self.trimSelection.clamped(to: self.duration).end
            }
        }
    }

    // MARK: - Clip

    func setTrimSelection(_ selection: VideoTrimSelection) {
        let clamped = selection.clamped(to: duration)
        guard clamped != trimSelection else { return }
        trimSelection = clamped
        if currentTime < clamped.start || currentTime > clamped.end {
            seek(to: min(max(currentTime, clamped.start), clamped.end))
        }
        scheduleProjectSave()
    }

    func resetTrim() {
        setTrimSelection(VideoTrimSelection(start: 0, end: duration))
        seek(to: 0)
    }

    var isTrimmed: Bool {
        let selection = trimSelection.clamped(to: duration)
        return selection.start > 0.001 || abs(selection.end - duration) > 0.001
    }

    private func loadTimelineFrames() {
        timelineTask?.cancel()
        let url = screenURL
        let videoDuration = duration
        timelineTask = Task { [weak self] in
            let frames = await Task.detached(priority: .userInitiated) {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                generator.maximumSize = CGSize(width: 180, height: 110)

                let frameCount = 18
                return (0..<frameCount).compactMap { index -> SendableRecordingTimelineFrame? in
                    guard videoDuration > 0 else { return nil }
                    let seconds = videoDuration * (Double(index) + 0.5) / Double(frameCount)
                    let time = CMTime(seconds: seconds, preferredTimescale: 600)
                    guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else {
                        return nil
                    }
                    return SendableRecordingTimelineFrame(
                        image: NSImage(cgImage: image, size: .zero)
                    )
                }
            }.value
            guard !Task.isCancelled else { return }
            self?.timelineFrames = frames.map(\.image)
        }
    }

    private func syncCameraPlayback() {
        guard hasCameraVideo else { return }
        guard currentTime >= cameraOffset else {
            cameraPlayer.pause()
            cameraPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        let cameraTime = CMTime(seconds: max(0, currentTime - cameraOffset), preferredTimescale: 600)
        cameraPlayer.seek(to: cameraTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.cameraPlayer.play()
            }
        }
    }

    private func correctCameraDriftIfNeeded() {
        guard hasCameraVideo, isPlaying else { return }
        guard currentTime >= cameraOffset else {
            cameraPlayer.pause()
            return
        }
        if cameraPlayer.rate == 0 {
            syncCameraPlayback()
            return
        }
        let expected = screenPlayer.currentTime().seconds - cameraOffset
        let actual = cameraPlayer.currentTime().seconds
        guard expected.isFinite, actual.isFinite else { return }
        if abs(expected - actual) > 0.12 {
            cameraPlayer.seek(
                to: CMTime(seconds: max(0, expected), preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    // MARK: - Zoom cues

    func setZoomCues(_ cues: [ZoomCue]) {
        zoomCues = cues.sorted { $0.start < $1.start }
        rebuildViewportTimeline()
        scheduleProjectSave()
    }

    func resynthesizeZoomCues() {
        setZoomCues(ZoomCueSynthesizer.cues(from: pointerCapture, duration: duration))
    }

    func addZoomCue(at time: TimeInterval) {
        let start = min(max(0, time), max(0, duration - 1))
        let hasPointerTrack = !pointerCapture.travel.isEmpty || !pointerCapture.presses.isEmpty
        let target = pointerTimeline.location(at: time) ?? CGPoint(x: 0.5, y: 0.5)
        let cue = ZoomCue(
            start: start,
            end: min(duration, start + 3),
            zoom: 1.5,
            anchorMode: hasPointerTrack ? .pointerAnchor : .pinnedAnchor,
            pinnedPoint: target,
            boundsBias: hasPointerTrack ? 0.25 : 0
        )
        var cues = zoomCues
        cues.append(cue)
        setZoomCues(cues)
        selectedCueID = cue.id
    }

    func removeZoomCue(id: UUID) {
        setZoomCues(zoomCues.filter { $0.id != id })
        if selectedCueID == id {
            selectedCueID = nil
        }
    }

    func updateZoomCue(_ cue: ZoomCue) {
        var cues = zoomCues
        guard let index = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        var updated = cue
        updated.start = min(max(0, updated.start), duration)
        updated.end = min(max(updated.start + 0.5, updated.end), duration)
        updated.zoom = min(max(updated.zoom, 1), 4)
        updated.boundsBias = min(max(updated.boundsBias, 0), 1)
        updated.pinnedPoint = CGPoint(
            x: min(max(updated.pinnedPoint.x, 0), 1),
            y: min(max(updated.pinnedPoint.y, 0), 1)
        )
        cues[index] = updated
        setZoomCues(cues)
    }

    var selectedCue: ZoomCue? {
        zoomCues.first { $0.id == selectedCueID }
    }

    private func rebuildViewportTimeline() {
        guard duration > 0 else {
            viewportTimeline = .identity
            return
        }
        viewportTimeline = ViewportTimeline.build(
            cues: zoomCues,
            capture: pointerCapture,
            duration: duration
        )
    }

    private func scheduleProjectSave() {
        guard isLoaded, session != nil else { return }
        projectSaveTask?.cancel()
        projectSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.saveProjectNow()
        }
    }

    private func saveProjectNow() {
        guard isLoaded, let session else { return }
        let document = RecordingEditDocument(
            style: style,
            zoomEnabled: zoomEnabled,
            zoomCues: zoomCues.filter { !$0.isImplicit },
            trimSelection: trimSelection,
            exportSettings: exportSettings
        )
        do {
            try session.writeEditDocument(document)
        } catch {
            print("Failed to save recording project: \(error)")
        }
    }

    /// Viewport frame to render at a given time, honoring the zoom toggle.
    func viewportFrame(at time: TimeInterval) -> ViewportFrame {
        guard zoomEnabled else { return .identity }
        return viewportTimeline.frame(at: time)
    }

    /// True when this session was captured without the OS cursor, so the
    /// preview and export draw the synthetic pointer.
    var pointerIsSynthesized: Bool {
        manifest?.pointerSynthesized == true
    }

    /// Smoothed normalized pointer location for the preview overlay; nil when
    /// the recording carries its cursor in the pixels.
    func pointerLocation(at time: TimeInterval) -> CGPoint? {
        guard pointerIsSynthesized else { return nil }
        return pointerTimeline.location(at: time)
    }

    func pointerFrame(at time: TimeInterval) -> PointerFrame? {
        guard pointerIsSynthesized else { return nil }
        return pointerTimeline.frame(at: time)
    }

    func artwork(id: String?) -> PointerArtwork? {
        pointerTimeline.artwork(id: id)
    }

    var showsPressEffects: Bool {
        manifest?.pressEffectsBaked == false
            && manifest?.pressEffectsEnabled == true
    }

    private var recordingPointSize: CGSize {
        let scale = max(CGFloat(manifest?.pixelScale ?? 1), 1)
        return CGSize(width: videoSize.width / scale, height: videoSize.height / scale)
    }

    func isCameraVisible(at time: TimeInterval) -> Bool {
        // No time gate: before cameraOffset the player is parked on the
        // camera's first frame, which beats the bubble popping in late.
        hasCameraVideo && style.camera.isVisible
    }

    // MARK: - Export

    func export() {
        guard !exportState.isExporting, isLoaded else { return }
        pause()
        exportState = .exporting(progress: 0)

        let configuration = RecordingStudioExporter.Configuration(
            screenURL: screenURL,
            cameraURL: hasCameraVideo && style.camera.isVisible ? session?.cameraURL : nil,
            cameraOffset: cameraOffset,
            style: style,
            viewportTimeline: zoomEnabled ? viewportTimeline : .identity,
            pointerTimeline: pointerIsSynthesized ? pointerTimeline : nil,
            showsPressEffects: showsPressEffects,
            canvasSize: videoSize,
            trimSelection: trimSelection,
            exportSettings: exportSettings
        )
        let suggestedFileName = session.map {
            $0.directoryURL.deletingPathExtension().lastPathComponent.appending(".mov")
        } ?? VideoFileActions.exportFileName(for: screenURL)

        exportTask = Task { [weak self] in
            do {
                let exporter = RecordingStudioExporter()
                let temporaryURL = try await exporter.export(configuration) { progress in
                    Task { @MainActor [weak self] in
                        if self?.exportState.isExporting == true {
                            self?.exportState = .exporting(progress: progress)
                        }
                    }
                }
                let savedURL = try VideoFileActions.saveToDefaultLocation(
                    from: temporaryURL,
                    suggestedFileName: suggestedFileName
                )
                try? FileManager.default.removeItem(at: temporaryURL)
                self?.exportState = .finished(savedURL)
            } catch is CancellationError {
                self?.exportState = .idle
            } catch {
                self?.exportState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        if exportState.isExporting {
            exportState = .idle
        }
    }
}

private struct SendableRecordingTimelineFrame: @unchecked Sendable {
    let image: NSImage
}
