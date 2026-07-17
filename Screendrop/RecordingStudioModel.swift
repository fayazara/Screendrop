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
    private(set) var sourceDuration: TimeInterval = 0
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
    private(set) var clipTimeline = RecordingClipTimeline(segments: [])
    var selectedClipID: UUID?
    var timelineHoverTime: TimeInterval?
    private(set) var timelineFrames: [RecordingTimelineFrame] = []

    private(set) var isPlaying = false
    var currentTime: TimeInterval = 0
    /// Live scrub-preview time while the pointer hovers the trim strip
    /// without committing to a new playhead position, matching Final
    /// Cut/iMovie skimming. `nil` shows the real playhead again.
    var hoverPreviewTime: TimeInterval? {
        didSet {
            guard isLoaded, duration > 0, !isPlaying else { return }
            movePlayers(to: hoverPreviewTime ?? currentTime)
        }
    }
    var exportState: RecordingStudioExportState = .idle

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var exportTask: Task<Void, Never>?
    private var projectSaveTask: Task<Void, Never>?
    private var timelineTask: Task<Void, Never>?
    private var screenAsset: AVURLAsset?
    private let editUndoManager = UndoManager()
    private(set) var undoRevision = 0
    private var zoomEditSnapshot: [ZoomCue]?
    private var lastSavedDocument: RecordingEditDocument?
    private var hasUnsavedChanges = false

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
        screenAsset = asset
        do {
            let (durationTime, tracks) = try await asset.load(.duration, .tracks)
            sourceDuration = durationTime.seconds
            duration = sourceDuration
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
        lastSavedDocument = document
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
            zoomCues = ZoomCueSynthesizer.cues(from: pointerCapture, duration: sourceDuration)
        }

        if let storedClips = document?.clips, !storedClips.isEmpty {
            clipTimeline = RecordingClipTimeline(segments: storedClips)
                .normalized(to: sourceDuration)
        } else {
            clipTimeline = .legacyTrim(
                start: document?.trimStart,
                end: document?.trimEnd,
                sourceDuration: sourceDuration
            )
        }
        duration = clipTimeline.duration
        selectedClipID = clipTimeline.segments.first?.id

        do {
            try rebuildScreenPlayerItem(preserving: 0)
        } catch {
            loadError = "Could not prepare the recording timeline: \(error.localizedDescription)"
            return
        }
        if pointerIsSynthesized {
            pointerTimeline = PointerTimeline.build(
                capture: pointerCapture,
                duration: sourceDuration,
                recordingSizeInPoints: recordingPointSize,
                fallbackArtwork: PointerArtworkCapture.defaultArtwork()
            )
        }
        rebuildViewportTimeline()
        installObservers()
        isLoaded = true
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
        if hoverPreviewTime != nil {
            hoverPreviewTime = nil
        }
        guard duration >= RecordingClipSegment.minimumDuration else { return }
        if currentTime < 0 || currentTime >= duration - 0.05 {
            seek(to: 0)
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
        movePlayers(to: clamped)
        if isPlaying {
            syncCameraPlayback()
        }
    }

    /// Moves both players to a source time without touching `currentTime`,
    /// so hover skimming can preview a frame and cleanly hand back to the
    /// real playhead position afterward.
    private func movePlayers(to time: TimeInterval) {
        let editorTime = min(max(time, 0), max(duration, 0))
        let sourceTime = clipTimeline.sourceTime(at: editorTime)
        let target = CMTime(seconds: editorTime, preferredTimescale: 600)
        screenPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if hasCameraVideo {
            if sourceTime >= cameraOffset {
                let cameraTime = CMTime(seconds: max(0, sourceTime - cameraOffset), preferredTimescale: 600)
                cameraPlayer.seek(to: cameraTime, toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                cameraPlayer.pause()
                cameraPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    /// Time the preview canvas should render right now.
    var displayTime: TimeInterval {
        if isPlaying {
            let time = screenPlayer.currentTime().seconds
            return time.isFinite ? time : currentTime
        }
        return hoverPreviewTime ?? currentTime
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
                    if seconds >= self.duration - 0.001 {
                        self.pause()
                        self.currentTime = self.duration
                        self.screenPlayer.seek(
                            to: CMTime(seconds: self.duration, preferredTimescale: 600),
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

        installEndObserver()
    }

    private func installEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
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
                self.currentTime = self.duration
            }
        }
    }

    // MARK: - Clips

    var canUndo: Bool {
        _ = undoRevision
        return editUndoManager.canUndo
    }

    var canRedo: Bool {
        _ = undoRevision
        return editUndoManager.canRedo
    }

    var selectedClip: RecordingClipSegment? {
        guard let selectedClipID else { return nil }
        return clipTimeline.segments.first { $0.id == selectedClipID }
    }

    var hasClipEdits: Bool {
        !clipTimeline.isUnedited(sourceDuration: sourceDuration)
    }

    var canDeleteSelectedClip: Bool {
        selectedClipID != nil && clipTimeline.segments.count > 1
    }

    func selectClip(id: UUID) {
        guard clipTimeline.segments.contains(where: { $0.id == id }) else { return }
        selectedClipID = id
        selectedCueID = nil
    }

    func selectZoomCue(id: UUID) {
        guard zoomCues.contains(where: { $0.id == id }) else { return }
        selectedCueID = id
        selectedClipID = nil
    }

    func undo() {
        guard editUndoManager.canUndo else { return }
        pause()
        editUndoManager.undo()
        undoRevision &+= 1
    }

    func redo() {
        guard editUndoManager.canRedo else { return }
        pause()
        editUndoManager.redo()
        undoRevision &+= 1
    }

    func splitClip(at editorTime: TimeInterval) {
        guard let result = clipTimeline.split(at: editorTime) else { return }
        applyClipTimeline(
            result.timeline,
            selectedID: result.selectedID,
            playheadTime: min(max(editorTime, 0), duration),
            actionName: "Split Clip"
        )
    }

    func splitClipAtHover() {
        guard let timelineHoverTime else { return }
        splitClip(at: timelineHoverTime)
    }

    func deleteSelectedClip() {
        guard let selectedClipID,
              let deletedRange = clipTimeline.editorRange(for: selectedClipID),
              let next = clipTimeline.deleting(segmentID: selectedClipID) else {
            return
        }
        let seekTime = min(deletedRange.lowerBound, next.duration)
        let nextSelection = next.location(at: seekTime)?.segmentID
            ?? next.segments.last?.id
        applyClipTimeline(
            next,
            selectedID: nextSelection,
            playheadTime: seekTime,
            actionName: "Delete Clip"
        )
    }

    func trimClip(_ replacement: RecordingClipSegment) {
        let next = clipTimeline.replacing(replacement)
        guard next != clipTimeline else { return }
        let editorTime = next.editorRange(for: replacement.id)?.lowerBound ?? currentTime
        applyClipTimeline(
            next,
            selectedID: replacement.id,
            playheadTime: min(currentTime, next.duration),
            actionName: "Trim Clip",
            hoverTime: editorTime
        )
    }

    func resetClips() {
        let full = RecordingClipTimeline.full(sourceDuration: sourceDuration)
        guard full != clipTimeline else { return }
        applyClipTimeline(
            full,
            selectedID: full.segments.first?.id,
            playheadTime: 0,
            actionName: "Reset Clips"
        )
    }

    private func applyClipTimeline(
        _ requestedTimeline: RecordingClipTimeline,
        selectedID: UUID?,
        playheadTime: TimeInterval,
        actionName: String,
        hoverTime: TimeInterval? = nil
    ) {
        let next = requestedTimeline.normalized(to: sourceDuration)
        guard !next.segments.isEmpty, next != clipTimeline else { return }

        let previousTimeline = clipTimeline
        let previousSelection = selectedClipID
        let previousTime = currentTime
        registerUndo(actionName) { target in
            target.applyClipTimeline(
                previousTimeline,
                selectedID: previousSelection,
                playheadTime: previousTime,
                actionName: actionName
            )
        }

        pause()
        hoverPreviewTime = nil
        timelineHoverTime = nil
        clipTimeline = next
        duration = next.duration
        selectedClipID = selectedID.flatMap { id in
            next.segments.contains(where: { $0.id == id }) ? id : nil
        } ?? next.segments.first?.id

        do {
            try rebuildScreenPlayerItem(preserving: min(max(playheadTime, 0), duration))
            if let hoverTime {
                hoverPreviewTime = min(max(hoverTime, 0), duration)
            }
        } catch {
            loadError = "Could not update the recording timeline: \(error.localizedDescription)"
        }
        scheduleProjectSave()
    }

    private func rebuildScreenPlayerItem(preserving editorTime: TimeInterval) throws {
        guard let screenAsset else { return }
        let playbackAsset = try RecordingCompositionBuilder.makeAsset(
            from: screenAsset,
            timeline: clipTimeline,
            sourceDuration: sourceDuration
        )

        screenPlayer.replaceCurrentItem(with: AVPlayerItem(asset: playbackAsset))
        screenPlayer.actionAtItemEnd = .pause
        currentTime = min(max(editorTime, 0), duration)
        movePlayers(to: currentTime)
        if timeObserver != nil {
            installEndObserver()
        }
    }

    private func registerUndo(
        _ actionName: String,
        operation: @escaping @MainActor (RecordingStudioModel) -> Void
    ) {
        editUndoManager.registerUndo(withTarget: self) { target in
            operation(target)
        }
        editUndoManager.setActionName(actionName)
        undoRevision &+= 1
    }

    private func loadTimelineFrames() {
        timelineTask?.cancel()
        let url = screenURL
        let videoDuration = sourceDuration
        timelineTask = Task { [weak self] in
            let frames = await Task.detached(priority: .userInitiated) {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                generator.maximumSize = CGSize(width: 180, height: 110)

                let frameCount = 32
                return (0..<frameCount).compactMap { index -> RecordingTimelineFrame? in
                    guard videoDuration > 0 else { return nil }
                    let seconds = videoDuration * (Double(index) + 0.5) / Double(frameCount)
                    let time = CMTime(seconds: seconds, preferredTimescale: 600)
                    guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else {
                        return nil
                    }
                    return RecordingTimelineFrame(
                        sourceTime: seconds,
                        image: NSImage(cgImage: image, size: .zero)
                    )
                }
            }.value
            guard !Task.isCancelled else { return }
            self?.timelineFrames = frames
        }
    }

    private func syncCameraPlayback() {
        guard hasCameraVideo else { return }
        let sourceTime = clipTimeline.sourceTime(at: currentTime)
        guard sourceTime >= cameraOffset else {
            cameraPlayer.pause()
            cameraPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        let cameraTime = CMTime(seconds: max(0, sourceTime - cameraOffset), preferredTimescale: 600)
        cameraPlayer.seek(to: cameraTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.cameraPlayer.play()
            }
        }
    }

    private func correctCameraDriftIfNeeded() {
        guard hasCameraVideo, isPlaying else { return }
        let sourceTime = clipTimeline.sourceTime(at: currentTime)
        guard sourceTime >= cameraOffset else {
            cameraPlayer.pause()
            return
        }
        if cameraPlayer.rate == 0 {
            syncCameraPlayback()
            return
        }
        let expected = sourceTime - cameraOffset
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

    private func replaceZoomCues(_ cues: [ZoomCue]) {
        zoomCues = cues.sorted { $0.start < $1.start }
        rebuildViewportTimeline()
        scheduleProjectSave()
    }

    private func applyZoomCues(_ cues: [ZoomCue], actionName: String) {
        let sorted = cues.sorted { $0.start < $1.start }
        guard sorted != zoomCues else { return }
        let previous = zoomCues
        registerUndo(actionName) { target in
            target.applyZoomCues(previous, actionName: actionName)
        }
        replaceZoomCues(sorted)
    }

    func beginZoomCueEdit() {
        if zoomEditSnapshot == nil {
            zoomEditSnapshot = zoomCues
        }
    }

    func endZoomCueEdit(actionName: String = "Edit Zoom") {
        guard let previous = zoomEditSnapshot else { return }
        zoomEditSnapshot = nil
        guard previous != zoomCues else { return }
        registerUndo(actionName) { target in
            target.applyZoomCues(previous, actionName: actionName)
        }
    }

    func resynthesizeZoomCues() {
        applyZoomCues(
            ZoomCueSynthesizer.cues(from: pointerCapture, duration: sourceDuration),
            actionName: "Reset Zooms"
        )
    }

    func addZoomCue(at time: TimeInterval) {
        let sourceTime = clipTimeline.sourceTime(at: time)
        let start = min(max(0, sourceTime), max(0, sourceDuration - 1))
        let hasPointerTrack = !pointerCapture.travel.isEmpty || !pointerCapture.presses.isEmpty
        let target = pointerTimeline.location(at: sourceTime) ?? CGPoint(x: 0.5, y: 0.5)
        let cue = ZoomCue(
            start: start,
            end: min(sourceDuration, start + 3),
            zoom: 1.5,
            anchorMode: hasPointerTrack ? .pointerAnchor : .pinnedAnchor,
            pinnedPoint: target,
            boundsBias: hasPointerTrack ? 0.25 : 0
        )
        var cues = zoomCues
        cues.append(cue)
        applyZoomCues(cues, actionName: "Add Zoom")
        selectedCueID = cue.id
        selectedClipID = nil
    }

    func removeZoomCue(id: UUID) {
        applyZoomCues(zoomCues.filter { $0.id != id }, actionName: "Remove Zoom")
        if selectedCueID == id {
            selectedCueID = nil
        }
    }

    func updateZoomCue(_ cue: ZoomCue) {
        var cues = zoomCues
        guard let index = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        var updated = cue
        updated.start = min(max(0, updated.start), sourceDuration)
        updated.end = min(max(updated.start + 0.5, updated.end), sourceDuration)
        updated.zoom = min(max(updated.zoom, 1), 4)
        updated.boundsBias = min(max(updated.boundsBias, 0), 1)
        updated.pinnedPoint = CGPoint(
            x: min(max(updated.pinnedPoint.x, 0), 1),
            y: min(max(updated.pinnedPoint.y, 0), 1)
        )
        cues[index] = updated
        replaceZoomCues(cues)
    }

    var selectedCue: ZoomCue? {
        zoomCues.first { $0.id == selectedCueID }
    }

    var visibleRecordedPressTimes: [TimeInterval] {
        recordedPressTimes.compactMap { clipTimeline.editorTime(forSourceTime: $0) }
    }

    var zoomTimelineSlices: [RecordingZoomTimelineSlice] {
        zoomCues
            .filter { !$0.isImplicit }
            .flatMap { cue in
                clipTimeline.slices(overlapping: cue.start, sourceEnd: cue.end).map { slice in
                    RecordingZoomTimelineSlice(cue: cue, slice: slice)
                }
            }
    }

    func sourceTime(atEditorTime time: TimeInterval) -> TimeInterval {
        clipTimeline.sourceTime(at: time)
    }

    func editorTime(forSourceTime time: TimeInterval) -> TimeInterval? {
        clipTimeline.editorTime(forSourceTime: time)
    }

    private func rebuildViewportTimeline() {
        guard sourceDuration > 0 else {
            viewportTimeline = .identity
            return
        }
        viewportTimeline = ViewportTimeline.build(
            cues: zoomCues,
            capture: pointerCapture,
            duration: sourceDuration
        )
    }

    private func scheduleProjectSave() {
        guard isLoaded, session != nil else { return }
        hasUnsavedChanges = true
        projectSaveTask?.cancel()
        projectSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.saveProjectNow()
        }
    }

    private func saveProjectNow() {
        guard isLoaded, hasUnsavedChanges, let session else { return }
        let document = RecordingEditDocument(
            style: style,
            zoomEnabled: zoomEnabled,
            zoomCues: zoomCues.filter { !$0.isImplicit },
            clipTimeline: clipTimeline,
            exportSettings: exportSettings
        )
        guard document != lastSavedDocument else {
            hasUnsavedChanges = false
            return
        }
        do {
            try session.writeEditDocument(document)
            lastSavedDocument = document
            hasUnsavedChanges = false
            if session.hasFinalVideo {
                try? FileManager.default.removeItem(at: session.finalURL)
            }
        } catch {
            print("Failed to save recording project: \(error)")
        }
    }

    /// Viewport frame to render at a given time, honoring the zoom toggle.
    func viewportFrame(at time: TimeInterval) -> ViewportFrame {
        guard zoomEnabled else { return .identity }
        return viewportTimeline.frame(at: clipTimeline.sourceTime(at: time))
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
        return pointerTimeline.location(at: clipTimeline.sourceTime(at: time))
    }

    func pointerFrame(at time: TimeInterval) -> PointerFrame? {
        guard pointerIsSynthesized else { return nil }
        return pointerTimeline.frame(at: clipTimeline.sourceTime(at: time))
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
            clipTimeline: clipTimeline,
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
            } catch RecordingStudioExporter.ExportError.cancelled {
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

struct RecordingTimelineFrame: @unchecked Sendable {
    let sourceTime: TimeInterval
    let image: NSImage
}

struct RecordingZoomTimelineSlice: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let cueID: UUID
        let segmentID: UUID
    }

    let cue: ZoomCue
    let slice: RecordingClipTimeline.Slice

    var id: ID {
        ID(cueID: cue.id, segmentID: slice.segmentID)
    }
}
