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

enum RecordingTranscriptionState: Equatable {
    case idle
    case transcribing
    case failed(String)

    var isTranscribing: Bool {
        self == .transcribing
    }
}

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

/// Share-to-cloud pipeline: render the current edits, upload, copy link.
enum RecordingStudioShareState: Equatable {
    case idle
    case rendering(progress: Double)
    case uploading
    case finished(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .rendering, .uploading: true
        default: false
        }
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
    private(set) var hasRecordedAudio = false
    private(set) var cameraOffset: TimeInterval = 0
    /// The camera picture's width over its height, which a cutout takes.
    private(set) var cameraVideoAspect = RecordingCameraLayoutResolver.defaultCameraAspect
    private(set) var isLoaded = false
    private(set) var loadError: String?

    let screenPlayer = AVPlayer()
    let cameraPlayer = AVPlayer()

    var style = RecordingStudioStyle(background: RecordingStudioDefaults.background) {
        didSet {
            if isLoaded, oldValue.background != style.background {
                RecordingStudioDefaults.background = style.background
            }
            if oldValue.camera.isVisible != style.camera.isVisible {
                updateCameraMatteCache()
            }
            if oldValue.camera.beauty != style.camera.beauty {
                updateCameraBeautyPreview()
            }
            var unchangedCamera = oldValue.camera
            unchangedCamera.beauty = style.camera.beauty
            if oldValue.camera.layout != style.camera.layout {
                rebuildCameraLayoutTimeline()
            } else if unchangedCamera != style.camera || oldValue.padding != style.padding
                || oldValue.cornerRadius != style.cornerRadius {
                rebuildMotionTimeline()
            }
            scheduleProjectSave()
        }
    }
    /// A background shown in the preview while the pointer rests on it in
    /// the picker. Never saved or exported; picking it writes `style`.
    var previewBackground: AnnotationBackgroundStyle?

    /// Shows or clears a hovered background. Leaving one fill can arrive
    /// after entering the next, so only the fill being left is cleared.
    func previewBackground(_ background: AnnotationBackgroundStyle, isHovering: Bool) {
        if isHovering {
            previewBackground = background
        } else if previewBackground == background {
            previewBackground = nil
        }
    }

    /// The style preset currently applied, so the Studio's preset bar can
    /// show its name and detect whether the user has since edited away from
    /// it. Not persisted in the project file: reapplied by content match.
    var appliedStylePresetID: RecordingStudioStylePreset.ID?
    var zoomEnabled = true {
        didSet {
            scheduleProjectSave()
            rebuildPreviewReframe()
        }
    }
    var exportSettings = VideoCompressionSettings() {
        didSet { scheduleProjectSave() }
    }
    /// Studio-side input feedback: both are reconstructed from the sidecar,
    /// so they can be toggled after the fact without touching the footage.
    var showsClickEffects = true {
        didSet { scheduleProjectSave() }
    }
    var showsKeystrokes = true {
        didSet { scheduleProjectSave() }
    }
    var keystrokePlacement: RecordingKeystrokePlacement = .bottomCenter {
        didSet { scheduleProjectSave() }
    }
    /// The "2× ›››" badge over sped-up clips; off unless asked for.
    var showsSpeedBadge = false {
        didSet { scheduleProjectSave() }
    }
    var speedBadgePlacement: RecordingKeystrokePlacement = .topRight {
        didSet { scheduleProjectSave() }
    }
    var showsSubtitles = true {
        didSet { scheduleProjectSave() }
    }
    var subtitleStyle = SubtitleBarStyle() {
        didSet { scheduleProjectSave() }
    }
    /// Output aspect for Export/Share. Anything but `.original` crops the
    /// render with a virtual camera that follows the pointer and zooms;
    /// the Studio preview shows the same crop live.
    var exportAspect: ExportAspectPreset = .original {
        didSet {
            scheduleProjectSave()
            rebuildPreviewReframe()
        }
    }
    /// Fill crops with the follow camera; Fit shows the whole recording
    /// framed on the background.
    var exportAspectMode: ExportAspectContentMode = .fill {
        didSet {
            scheduleProjectSave()
            rebuildPreviewReframe()
        }
    }
    /// Non-destructive crop of the screen-video source. The Studio background,
    /// camera bubble and captions remain in canvas space around the reshaped
    /// video card.
    var videoCropRect = CropGeometry.unit {
        didSet {
            scheduleProjectSave()
            if oldValue != videoCropRect { rebuildMotionTimeline() }
        }
    }
    private(set) var isCroppingVideo = false
    var workingVideoCropRect = CropGeometry.unit
    /// The crop drag in progress, in the video's pixels.
    private(set) var videoCropDrag: CropDrag?
    var videoCropAspect: CropAspectRatio = .freeform
    /// The preview's copy of the reframe camera, kept current with every
    /// edit that would change the exported crop.
    private(set) var previewReframe: ReframeTrack?
    /// Shared screen, clipping-card, and camera motion for preview and export.
    private(set) var motionTimeline = RecordingStudioMotionTimeline.none
    private var reframeFocusTimeline: PointerTimeline?
    private var reframeFocusResolved = false
    private(set) var subtitleCues: [RecordingSubtitleCue] = []
    private(set) var subtitleTimeline = SubtitleTimeline.empty
    /// Word-level timing behind the cues; empty for projects transcribed
    /// before transcript editing shipped (cues only).
    private(set) var transcriptWords: [RecordingTranscriptWord] = []
    /// Word-timing lookup for karaoke captions; rebuilt with the cues.
    private(set) var karaokeTimeline = KaraokeTimeline.empty
    /// Word under the playhead, updated only on word boundaries so the
    /// transcript view isn't invalidated on every 20 ms playback tick.
    private(set) var activeTranscriptWordIndex: Int?
    var transcriptionState = RecordingTranscriptionState.idle
    private(set) var zoomCues: [ZoomCue] = []
    private(set) var viewportTimeline = ViewportTimeline.identity
    private(set) var pointerTimeline = PointerTimeline.empty
    private(set) var keystrokeTimeline = KeystrokeCaptionTimeline.empty
    var selectedCueID: UUID?
    /// Stretches of the recording in a layout other than the default.
    private(set) var cameraLayoutCues: [RecordingCameraLayoutCue] = []
    /// The default layout and every cue resolved along editor time.
    private(set) var cameraLayoutTimeline = RecordingCameraLayoutTimeline.constant(RecordingCameraLayout())
    var selectedLayoutCueID: UUID?
    /// Text over the recording, on the source clock. Later texts draw on
    /// top of earlier ones.
    private(set) var textOverlays: [RecordingTextOverlay] = []
    var selectedTextID: UUID?
    /// Pixelated or blurred regions of the recorded picture, on the source
    /// clock.
    private(set) var redactions: [RecordingRedaction] = []
    var selectedRedactionID: UUID?
    /// What the screen player's composition filters each frame through.
    let redactionPreview = RecordingRedactionPreviewSource()
    /// What the camera player's composition touches each frame up with.
    let cameraBeautyPreview = StudioCameraBeautyPreviewSource()
    /// Images and GIFs over the canvas, on the source clock, drawn above
    /// the camera and below text.
    private(set) var imageOverlays: [RecordingImageOverlay] = []
    var selectedImageID: UUID?
    /// Music and sound under the video, on the edited video's clock.
    private(set) var audioClips: [RecordingAudioClip] = []
    var selectedAudioClipID: UUID?
    /// Decoded overlay images, shared with the canvas.
    let overlayImages = RecordingOverlayImageStore()
    /// Moves on when an overlay image finishes decoding, so the canvas
    /// draws it.
    private(set) var overlayImageRevision = 0
    /// Waveform outlines of the audio files, by file name.
    private(set) var audioPeaks: [String: [Float]] = [:]
    /// Why the last media import was turned down, if it was.
    var mediaImportError: String?
    private(set) var clipTimeline = RecordingClipTimeline(segments: []) {
        didSet {
            if clipTimeline != oldValue {
                speedBadgeTimeline = SpeedBadgeTimeline(clipTimeline: clipTimeline)
            }
        }
    }
    /// Where the cut plays faster than recorded, for the speed badge.
    private(set) var speedBadgeTimeline = SpeedBadgeTimeline.empty
    var selectedClipID: UUID?
    var timelineHoverTime: TimeInterval?
    /// Storyboard tiles for the clip lane, sampled on demand at whatever
    /// density the lane's current zoom needs.
    let timelineThumbnails = RecordingTimelineThumbnailStore()

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
    var exportState: RecordingStudioExportState = .idle {
        didSet { updateCameraMatteCache() }
    }
    var audioExportState: RecordingStudioExportState = .idle
    var shareState: RecordingStudioShareState = .idle {
        didSet { updateCameraMatteCache() }
    }
    /// Makes the cutout's mattes for the whole camera in the background.
    private var cameraMatteTask: Task<Void, Never>?
    /// Upload identity while sharing, so the UI can read the uploader's
    /// live progress and the history card mirrors the state.
    private(set) var shareItemID: UUID?

    /// Gain shared by playback and video/audio export; 1 preserves the source.
    var audioVolume: CGFloat = 1 {
        didSet {
            updatePlaybackVolume()
            scheduleProjectSave()
        }
    }

    private func updatePlaybackVolume() {
        guard let item = screenPlayer.currentItem else { return }
        // The recording's gain applies to its own tracks; added audio
        // carries its own volume and fades.
        let clipTrackIDs = Set(playbackClipTrackIDs.values)
        let recordingTracks = item.asset.tracks(withMediaType: .audio).filter { !clipTrackIDs.contains($0.trackID) }
        item.audioMix = RecordingAudioClipMixer.mix(
            recordingTracks: recordingTracks,
            recordingVolume: Double(audioVolume),
            clips: audioClips,
            trackIDs: playbackClipTrackIDs
        )
    }

    /// Format the audio-only export writes.
    var audioExportFormat: RecordingAudioFormat = .m4a {
        didSet { scheduleProjectSave() }
    }
    /// The soundtrack standing in for the recording's own audio, resolved
    /// so both playback and export can use it without reloading tracks.
    private(set) var replacementAudio: RecordingReplacementAudio?
    /// Why the last import was rejected, shown next to the Replace control.
    private(set) var replacementAudioError: String?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var exportTask: Task<Void, Never>?
    private var audioExportTask: Task<Void, Never>?
    private var replacementAudioTask: Task<Void, Never>?
    /// The screen movie's video track, kept from load so the player item
    /// can be rebuilt synchronously when an imported soundtrack means the
    /// composition has to be assembled track by track.
    private var screenVideoTrack: AVAssetTrack?
    private var shareTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var projectSaveTask: Task<Void, Never>?
    private var screenAsset: AVURLAsset?
    private var isTornDown = false
    private var isLoading = false
    private var wallpaperCacheLease: BoundedCGImageCache.Lease?
    private let editUndoManager = UndoManager()
    private(set) var undoRevision = 0
    private var zoomEditSnapshot: [ZoomCue]?
    private var viewportRebuildTask: Task<Void, Never>?
    private var layoutEditSnapshot: [RecordingCameraLayoutCue]?
    private var textEditSnapshot: [RecordingTextOverlay]?
    private var redactionEditSnapshot: [RecordingRedaction]?
    /// Re-renders the paused frame after a region changes, at most once a
    /// display frame however fast a drag reports.
    private var redactionRefreshTask: Task<Void, Never>?
    /// Re-renders the paused camera frame after a touch-up changes.
    private var cameraBeautyRefreshTask: Task<Void, Never>?
    /// Ends an inspector edit once its control has rested, so a slider
    /// sweep or a run of typing undoes as one step.
    private var textCoalesceTask: Task<Void, Never>?
    private var redactionCoalesceTask: Task<Void, Never>?
    private var imageEditSnapshot: [RecordingImageOverlay]?
    private var audioEditSnapshot: [RecordingAudioClip]?
    private var imageCoalesceTask: Task<Void, Never>?
    private var audioCoalesceTask: Task<Void, Never>?
    /// Each audio file's track, resolved once so the player item can be
    /// rebuilt synchronously.
    private var audioTracksByFile: [String: RecordingAudioFileTrack] = [:]
    /// The playback composition's track for each audio clip.
    private var playbackClipTrackIDs: [UUID: CMPersistentTrackID] = [:]
    private var audioPlaybackRebuildTask: Task<Void, Never>?
    private var mediaLoadTask: Task<Void, Never>?
    /// The document as of the last explicit save. Everything the user does
    /// after that lives in memory and in the autosaved draft until they save
    /// again, which is what makes the close prompt meaningful.
    private var lastSavedDocument: RecordingEditDocument?
    /// Set while a stored document is being applied to the model, so the
    /// resulting property writes don't register as user edits.
    private var isApplyingDocument = false
    /// Loaded by the agent server with no window behind it. Such a model
    /// edits and exports like any other but doesn't count as an open editor.
    var isAgentSession = false
    /// Whether the editor holds edits that have not been committed with an
    /// explicit save. Stored rather than derived: the title bar and the Save
    /// button read it on every body evaluation, and rebuilding the whole
    /// document to compare it there would cost real time while dragging.
    private(set) var hasUnsavedChanges = false
    private(set) var saveFlash = false

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

    /// False for a bare movie opened from disk: there is no project package
    /// behind it, so there is nothing to save into.
    var isProject: Bool { session != nil }

    /// What the window title, share sheet, and Projects browser call this
    /// project. A bare movie falls back to its file name.
    var projectDisplayName: String {
        session?.displayName ?? sessionURL.deletingPathExtension().lastPathComponent
    }

    func load() async {
        guard !isLoaded, !isLoading, !isTornDown, !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        wallpaperCacheLease = AnnotationBackgroundRenderer.beginWallpaperUse()

        if let session {
            manifest = session.loadCaptureManifest()
            pointerCapture = session.loadPointerCapture() ?? PointerCaptureFile()
        }

        let asset = AVURLAsset(url: screenURL)
        screenAsset = asset
        do {
            let (durationTime, tracks) = try await asset.load(.duration, .tracks)
            guard !isTornDown, !Task.isCancelled else { return }
            sourceDuration = durationTime.seconds
            duration = sourceDuration
            if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
                screenVideoTrack = videoTrack
                let naturalSize = try await videoTrack.load(.naturalSize)
                guard !isTornDown, !Task.isCancelled else { return }
                if naturalSize.width > 0, naturalSize.height > 0 {
                    videoSize = naturalSize
                }
            }
            hasRecordedAudio = tracks.contains { $0.mediaType == .audio }
        } catch {
            guard !isTornDown, !Task.isCancelled else { return }
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
            keystrokeTimeline = KeystrokeCaptionTimeline(events: pointerCapture.keystrokes)
        }

        if let session, session.hasCamera {
            hasCameraVideo = true
            cameraOffset = manifest?.cameraLeadIn ?? 0
            if let aspect = await RecordingCameraVideo.aspect(of: session.cameraURL) {
                guard !isTornDown, !Task.isCancelled else { return }
                cameraVideoAspect = aspect
            }
            // A cutout's first frame shouldn't wait on Vision loading its model.
            StudioCameraMatteGenerator.prewarm()
            cameraPlayer.replaceCurrentItem(with: AVPlayerItem(url: session.cameraURL))
            cameraPlayer.actionAtItemEnd = .pause
            cameraPlayer.isMuted = true
            updateCameraBeautyPreview()
        } else {
            style.camera.isVisible = false
        }

        lastSavedDocument = session?.loadEditDocument()
        // A draft that outlived its editor means the last session ended
        // without a save - a crash, a force quit, or a Studio window that is
        // still open elsewhere. Reopen on the draft so nothing is lost; the
        // project simply opens dirty.
        let document = session?.effectiveEditDocument()
        // Sessions recorded before the toggle moved into Studio stored the
        // choice in the manifest; honor it as the default.
        showsClickEffects = manifest?.pressEffectsEnabled ?? true
        // A brand new recording has no project yet, so it also starts from
        // the remembered export choice.
        exportSettings = RecordingExportPreferences.lastSettings
        if let document {
            applyDocumentSettings(document)
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
            if let defaultPreset = RecordingStudioStylePresetStore.shared.activePreset {
                style = defaultPreset.value
                appliedStylePresetID = defaultPreset.id
            }
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
        // Nothing is selected until the user picks a clip; an unsplit
        // recording would otherwise open wrapped in selection chrome.
        selectedClipID = nil

        // Resolve the imported soundtrack before the first player item is
        // built, so the editor opens already playing what it will export.
        if let session, let fileName = document?.replacementAudioFileName {
            let url = session.directoryURL.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                let loadedAudio = await RecordingReplacementAudio.load(
                    url: url,
                    displayName: document?.replacementAudioDisplayName ?? fileName
                )
                guard !isTornDown, !Task.isCancelled else { return }
                replacementAudio = loadedAudio
            }
        }

        do {
            try rebuildScreenPlayerItem(preserving: 0)
        } catch {
            loadError = "Could not prepare the recording timeline: \(error.localizedDescription)"
            return
        }
        rebuildPointerTimeline()
        rebuildViewportTimeline()
        installObservers()
        isLoaded = true
        updateCameraMatteCache()
        rebuildPreviewReframe()
        loadTimelineThumbnails()

        if let session {
            if session.hasUnsavedDraft {
                // Reopened on a draft that outlived its editor.
                hasUnsavedChanges = true
            } else if lastSavedDocument == nil {
                // A recording that has never been saved is unsaved work by
                // definition, which is what makes the close prompt offer to
                // throw the whole thing away.
                hasUnsavedChanges = true
            } else {
                hasUnsavedChanges = false
                // Adopt the loaded document in its normalized in-memory form
                // as the baseline. Defaults filled in during load (an export
                // preset an older project never stored, clips normalized to
                // the real duration) would otherwise read as edits.
                lastSavedDocument = currentDocument()
            }
            session.updateProjectMetadata { $0.lastOpenedAt = Date() }
        }
        StudioProjectRegistry.shared.register(self)
    }

    /// Copies a stored project onto the model. Shared by the initial load and
    /// by discarding changes, so both routes can never drift apart.
    private func applyDocumentSettings(_ document: RecordingEditDocument) {
        isApplyingDocument = true
        defer { isApplyingDocument = false }

        style = document.style.value
        zoomEnabled = document.zoomEnabled
        zoomCues = document.zoomCues
        cameraLayoutCues = (document.cameraLayoutCues ?? []).sorted { $0.start < $1.start }
        textOverlays = document.textOverlays ?? []
        redactions = document.redactions ?? []
        imageOverlays = document.imageOverlays ?? []
        audioClips = document.audioClips ?? []
        loadOverlayMedia()
        redactionPreview.update(redactions: redactions, clipTimeline: clipTimeline)
        // A project that never chose its own settings inherits whatever
        // was picked last, so "export as MP4" sticks across recordings.
        exportSettings = document.exportSettings ?? RecordingExportPreferences.lastSettings
        if document.exportSettings == nil {
            // Old projects without export settings may inherit quality/codec
            // preferences, but keep their original cadence and blur policy.
            exportSettings.frameRate = nil
            exportSettings.motionBlurEnabled = nil
        }
        showsClickEffects = document.showsClickEffects ?? showsClickEffects
        showsKeystrokes = document.showsKeystrokes ?? true
        keystrokePlacement = document.keystrokePlacement ?? .bottomCenter
        showsSpeedBadge = document.showsSpeedBadge ?? false
        speedBadgePlacement = document.speedBadgePlacement ?? .topRight
        showsSubtitles = document.showsSubtitles ?? true
        subtitleCues = document.subtitleCues ?? []
        subtitleTimeline = SubtitleTimeline(cues: subtitleCues)
        transcriptWords = document.subtitleWords ?? []
        karaokeTimeline = KaraokeTimeline(cues: subtitleCues, words: transcriptWords)
        subtitleStyle = document.subtitleStyle
        exportAspect = document.exportAspectPreset
        exportAspectMode = document.exportAspectContentMode
        videoCropRect = document.normalizedVideoCropRect
        audioExportFormat = document.audioExportFormatValue
        audioVolume = CGFloat(RecordingAudioGain.normalized(document.audioVolume ?? 1))
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        // Persist only a fully loaded document, before releasing its data.
        if isLoaded { writeDraftNow() }
        isLoaded = false
        StudioProjectRegistry.shared.unregister(self)
        exportTask?.cancel()
        audioExportTask?.cancel()
        replacementAudioTask?.cancel()
        cancelShare()
        transcriptionTask?.cancel()
        projectSaveTask?.cancel()
        cameraMatteTask?.cancel()
        cameraMatteTask = nil
        exportTask = nil
        audioExportTask = nil
        replacementAudioTask = nil
        shareTask = nil
        transcriptionTask = nil
        projectSaveTask = nil
        timelineThumbnails.releaseResources()
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
        screenAsset?.cancelLoading()
        screenAsset = nil
        screenVideoTrack = nil
        replacementAudio = nil
        editUndoManager.removeAllActions()
        zoomEditSnapshot = nil
        viewportRebuildTask?.cancel()
        viewportRebuildTask = nil
        layoutEditSnapshot = nil
        textEditSnapshot = nil
        redactionEditSnapshot = nil
        redactionRefreshTask?.cancel()
        redactionRefreshTask = nil
        cameraBeautyRefreshTask?.cancel()
        cameraBeautyRefreshTask = nil
        textCoalesceTask?.cancel()
        redactionCoalesceTask?.cancel()
        imageCoalesceTask?.cancel()
        audioCoalesceTask?.cancel()
        audioPlaybackRebuildTask?.cancel()
        mediaLoadTask?.cancel()
        imageEditSnapshot = nil
        audioEditSnapshot = nil
        lastSavedDocument = nil
        pointerCapture = PointerCaptureFile()
        pointerTimeline = .empty
        keystrokeTimeline = .empty
        viewportTimeline = .identity
        previewReframe = nil
        reframeFocusTimeline = nil
        recordedPressTimes.removeAll()
        zoomCues.removeAll()
        cameraLayoutCues.removeAll()
        textOverlays.removeAll()
        redactions.removeAll()
        imageOverlays.removeAll()
        audioClips.removeAll()
        audioTracksByFile.removeAll()
        overlayImages.removeAll()
        subtitleCues.removeAll()
        transcriptWords.removeAll()
        subtitleTimeline = .empty
        karaokeTimeline = .empty
        clipTimeline = RecordingClipTimeline(segments: [])
        wallpaperCacheLease = nil
    }

    // MARK: - Style presets

    func applyStylePreset(_ preset: RecordingStudioStylePreset) {
        style = preset.value
        appliedStylePresetID = preset.id
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
        updateActiveTranscriptWord()
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
                    self.updateActiveTranscriptWord()
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
        clearTimelineSelection()
        selectedClipID = id
    }

    func selectZoomCue(id: UUID) {
        guard zoomCues.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedCueID = id
    }

    func selectLayoutCue(id: UUID) {
        guard cameraLayoutCues.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedLayoutCueID = id
    }

    /// Lets go of whatever is selected on the timeline, like clicking
    /// empty canvas.
    func clearTimelineSelection() {
        selectedCueID = nil
        selectedClipID = nil
        selectedLayoutCueID = nil
        selectedTextID = nil
        selectedRedactionID = nil
        selectedImageID = nil
        selectedAudioClipID = nil
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

    func setClipSpeed(_ speed: Double, forClipID id: UUID) {
        guard let segment = clipTimeline.segments.first(where: { $0.id == id }) else { return }
        let clamped = min(max(speed, RecordingClipSegment.minimumSpeed), RecordingClipSegment.maximumSpeed)
        guard abs(segment.speed - clamped) > 0.000_001 else { return }
        var replacement = segment
        replacement.speed = clamped
        let next = clipTimeline.replacing(replacement)
        applyClipTimeline(
            next,
            selectedID: id,
            playheadTime: min(currentTime, next.duration),
            actionName: "Change Clip Speed"
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
        // Both motion timelines integrate along editor time, so a cut, trim,
        // or speed change invalidates them even when their source data did not
        // change.
        rebuildPointerTimeline()
        rebuildViewportTimeline()

        do {
            try rebuildScreenPlayerItem(preserving: min(max(playheadTime, 0), duration))
            if let hoverTime {
                hoverPreviewTime = min(max(hoverTime, 0), duration)
            }
        } catch {
            loadError = "Could not update the recording timeline: \(error.localizedDescription)"
        }
        updateActiveTranscriptWord()
        scheduleProjectSave()
    }

    private func rebuildScreenPlayerItem(preserving editorTime: TimeInterval) throws {
        guard let screenAsset else { return }
        let playbackAsset: AVAsset
        if let replacementAudio, let screenVideoTrack {
            playbackAsset = try RecordingCompositionBuilder.makeAsset(
                videoTrack: screenVideoTrack,
                timeline: clipTimeline,
                sourceDuration: sourceDuration,
                replacementAudio: replacementAudio
            )
        } else {
            playbackAsset = try RecordingCompositionBuilder.makeAsset(
                from: screenAsset,
                timeline: clipTimeline,
                sourceDuration: sourceDuration
            )
        }

        // Added music sits on its own tracks beside the recording's audio.
        let composedAsset = try addingAudioClips(to: playbackAsset)
        let item = AVPlayerItem(asset: composedAsset)
        // Regions are filtered into the picture before the card draws it,
        // so the preview's zoom and crop carry them exactly as the export's.
        redactionPreview.update(redactions: redactions, clipTimeline: clipTimeline)
        if !redactions.isEmpty {
            item.videoComposition = redactionPreview.makeVideoComposition(for: composedAsset)
        }
        screenPlayer.replaceCurrentItem(with: item)
        updatePlaybackVolume()
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

    private func loadTimelineThumbnails() {
        timelineThumbnails.prepare(url: screenURL, duration: sourceDuration)
    }

    /// Speed of whichever clip covers this editor time; 1 when nothing
    /// covers it (e.g. past the end of the timeline).
    private func speed(atEditorTime time: TimeInterval) -> Double {
        guard let location = clipTimeline.location(at: time) else { return 1 }
        return clipTimeline.segments[location.segmentIndex].speed
    }

    private func syncCameraPlayback() {
        guard hasCameraVideo else { return }
        let sourceTime = clipTimeline.sourceTime(at: currentTime)
        guard sourceTime >= cameraOffset else {
            cameraPlayer.pause()
            cameraPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        // The camera master is a separate, unedited recording - it has no
        // composition to bake speed into, so a sped-up clip must also play
        // the camera bubble at that rate or the two drift apart immediately.
        let rate = Float(speed(atEditorTime: currentTime))
        let cameraTime = CMTime(seconds: max(0, sourceTime - cameraOffset), preferredTimescale: 600)
        cameraPlayer.seek(to: cameraTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.cameraPlayer.rate = rate
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
        let targetRate = Float(speed(atEditorTime: currentTime))
        if abs(cameraPlayer.rate - targetRate) > 0.01 {
            cameraPlayer.rate = targetRate
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
        if zoomEditSnapshot != nil {
            // A drag reports dozens of moves a second, and planning the
            // camera integrates the whole recording. The block follows the
            // pointer from `zoomCues`; the plan catches up when it rests.
            scheduleViewportRebuild()
        } else {
            rebuildViewportTimeline()
        }
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
        if viewportRebuildTask != nil {
            viewportRebuildTask?.cancel()
            viewportRebuildTask = nil
            rebuildViewportTimeline()
        }
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
        insertZoomCue(start: start, end: min(sourceDuration, start + 3))
    }

    /// Room a cue has to grow or slide into before it would run into a
    /// neighbor. Cues are kept sorted and non-overlapping, so the only cues
    /// that can be in the way are the ones on either side.
    private func neighborBounds(
        forCueAt index: Int,
        in cues: [ZoomCue]
    ) -> (lower: TimeInterval, upper: TimeInterval) {
        (
            lower: index > 0 ? max(0, cues[index - 1].end) : 0,
            upper: index + 1 < cues.count
                ? min(cues[index + 1].start, sourceDuration)
                : sourceDuration
        )
    }

    /// Where a new cue can actually go. A request landing inside an existing
    /// zoom is pushed past it rather than dropped, and the span is trimmed to
    /// the next cue; nil when no gap from here on is long enough to use.
    private func freeSpan(
        from start: TimeInterval,
        preferredEnd: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        guard sourceDuration > 0 else { return nil }
        let length = max(preferredEnd - start, ZoomCue.minimumDuration)
        var lower = min(max(start, 0), sourceDuration)
        // Walks chains of touching cues, so "add at playhead" inside a run of
        // zooms lands in the first real gap after them.
        while let covering = zoomCues.first(where: { $0.start <= lower && $0.end > lower }) {
            lower = covering.end
        }
        let upper = zoomCues
            .filter { $0.start > lower }
            .map(\.start)
            .min() ?? sourceDuration
        guard upper - lower >= ZoomCue.minimumDuration else { return nil }
        return lower...min(lower + length, upper)
    }

    /// Adds a zoom over a range drawn on the zoom track, in editor time.
    /// The track has already fitted the range between the neighbouring
    /// blocks and grown it to `ZoomCue.minimumDuration`, and shown it that
    /// way, so this adds it as is: it neither moves nor stretches it.
    func addZoomCue(overEditorRange range: ClosedRange<TimeInterval>) {
        guard let span = drawnSourceSpan(
            for: range,
            among: zoomCues.map { $0.start...$0.end },
            minimum: ZoomCue.minimumDuration
        ) else { return }
        appendZoomCue(span)
    }

    private func insertZoomCue(start: TimeInterval, end: TimeInterval) {
        guard let span = freeSpan(from: start, preferredEnd: end) else { return }
        appendZoomCue(span)
    }

    private func appendZoomCue(_ span: ClosedRange<TimeInterval>) {
        let hasPointerTrack = !pointerCapture.travel.isEmpty || !pointerCapture.presses.isEmpty
        let editorTime = clipTimeline.editorTime(forSourceTime: span.lowerBound) ?? currentTime
        let target = pointerTimeline.location(at: editorTime) ?? CGPoint(x: 0.5, y: 0.5)
        let cue = ZoomCue(
            start: span.lowerBound,
            end: span.upperBound,
            zoom: 1.5,
            anchorMode: hasPointerTrack ? .pointerAnchor : .pinnedAnchor,
            pinnedPoint: target,
            boundsBias: hasPointerTrack ? 0.25 : 0
        )
        var cues = zoomCues
        cues.append(cue)
        applyZoomCues(cues, actionName: "Add Zoom")
        clearTimelineSelection()
        selectedCueID = cue.id
    }

    func removeZoomCue(id: UUID) {
        applyZoomCues(zoomCues.filter { $0.id != id }, actionName: "Remove Zoom")
        if selectedCueID == id {
            selectedCueID = nil
        }
    }

    /// Applies an edited cue, stopping either edge at the neighboring cues so
    /// blocks can be resized right up to each other but never through.
    func updateZoomCue(_ cue: ZoomCue) {
        var cues = zoomCues
        guard let index = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        let bounds = neighborBounds(forCueAt: index, in: cues)
        var updated = sanitized(cue)
        updated.start = min(
            max(updated.start, bounds.lower),
            max(bounds.lower, bounds.upper - ZoomCue.minimumDuration)
        )
        updated.end = min(
            max(updated.end, updated.start + ZoomCue.minimumDuration),
            bounds.upper
        )
        cues[index] = updated
        replaceZoomCues(cues)
    }

    /// Slides a cue without changing its length. Unlike a resize, running into
    /// a neighbor parks the block against it rather than squashing it.
    func moveZoomCue(_ cue: ZoomCue) {
        var cues = zoomCues
        guard let index = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        let bounds = neighborBounds(forCueAt: index, in: cues)
        let room = max(bounds.upper - bounds.lower, ZoomCue.minimumDuration)
        let length = min(max(cue.duration, ZoomCue.minimumDuration), room)
        var moved = sanitized(cue)
        moved.start = min(max(cue.start, bounds.lower), max(bounds.lower, bounds.upper - length))
        moved.end = min(moved.start + length, bounds.upper)
        cues[index] = moved
        replaceZoomCues(cues)
    }

    /// Everything about a cue except its placement, which the caller clamps
    /// against its neighbors.
    private func sanitized(_ cue: ZoomCue) -> ZoomCue {
        var cue = cue
        cue.start = min(max(0, cue.start), sourceDuration)
        cue.end = min(max(cue.start, cue.end), sourceDuration)
        cue.zoom = min(max(cue.zoom, 1), 4)
        cue.boundsBias = min(max(cue.boundsBias, 0), 1)
        cue.pinnedPoint = CGPoint(
            x: min(max(cue.pinnedPoint.x, 0), 1),
            y: min(max(cue.pinnedPoint.y, 0), 1)
        )
        return cue
    }

    var selectedCue: ZoomCue? {
        zoomCues.first { $0.id == selectedCueID }
    }

    // MARK: - Camera layouts

    var selectedLayoutCue: RecordingCameraLayoutCue? {
        cameraLayoutCues.first { $0.id == selectedLayoutCueID }
    }

    var cameraLayoutTimelineBlocks: [RecordingCameraLayoutTimelineBlock] {
        RecordingCameraLayoutTimeline.blocks(for: cameraLayoutCues, clipTimeline: clipTimeline)
    }

    /// The cue covering an editor time, if any.
    func layoutCue(atEditorTime time: TimeInterval) -> RecordingCameraLayoutCue? {
        cameraLayoutTimelineBlocks
            .first { $0.editorStart <= time && time < $0.editorEnd }?
            .cue
    }

    /// Changes whichever layout is showing at `time`: the cue covering it,
    /// or the default when none does. Used by direct edits on the canvas.
    func editLayout(atEditorTime time: TimeInterval, actionName: String, _ change: (inout RecordingCameraLayout) -> Void) {
        if var cue = layoutCue(atEditorTime: time) {
            change(&cue.layout)
            updateLayoutCue(cue, actionName: actionName)
        } else {
            change(&style.camera.layout)
        }
    }

    private func rebuildCameraLayoutTimeline(rebuildsZoom: Bool = true) {
        let next = RecordingCameraLayoutTimeline.build(
            defaultLayout: style.camera.layout,
            cues: cameraLayoutCues,
            clipTimeline: clipTimeline
        )
        if next != cameraLayoutTimeline {
            cameraLayoutTimeline = next
            updateCameraMatteCache()
        }
        if rebuildsZoom { rebuildMotionTimeline() }
    }

    /// Once a cutout appears anywhere on the timeline, the whole camera is
    /// segmented in the background so exports can read the mattes instead
    /// of running Vision. A render segments for itself, so the cache steps
    /// aside while one runs - Vision shared between them would slow both -
    /// and starts over after.
    private func updateCameraMatteCache() {
        let isRendering = exportState.isExporting || shareState.isBusy
        guard isLoaded, !isTornDown, !isRendering, showsCameraLayer,
              cameraLayoutTimeline.usesCutout, let session,
              !StudioCameraMatteCache.isComplete(forCamera: session.cameraURL)
        else {
            if isRendering || isTornDown {
                cameraMatteTask?.cancel()
                cameraMatteTask = nil
            }
            return
        }
        guard cameraMatteTask == nil else { return }
        let cameraURL = session.cameraURL
        cameraMatteTask = Task(priority: .utility) { [weak self] in
            await StudioCameraMatteCache.generate(cameraURL: cameraURL)
            guard !Task.isCancelled else { return }
            self?.cameraMatteTask = nil
        }
    }

    private func replaceLayoutCues(_ cues: [RecordingCameraLayoutCue]) {
        cameraLayoutCues = cues.sorted { $0.start < $1.start }
        rebuildCameraLayoutTimeline()
        scheduleProjectSave()
    }

    private func applyLayoutCues(_ cues: [RecordingCameraLayoutCue], actionName: String) {
        let sorted = cues.sorted { $0.start < $1.start }
        guard sorted != cameraLayoutCues else { return }
        let previous = cameraLayoutCues
        registerUndo(actionName) { target in
            target.applyLayoutCues(previous, actionName: actionName)
        }
        replaceLayoutCues(sorted)
    }

    /// Opens a continuous edit (a drag); `endLayoutCueEdit` registers it as
    /// one undo step.
    func beginLayoutCueEdit() {
        if layoutEditSnapshot == nil {
            layoutEditSnapshot = cameraLayoutCues
        }
    }

    func endLayoutCueEdit(actionName: String = "Edit Layout") {
        guard let previous = layoutEditSnapshot else { return }
        layoutEditSnapshot = nil
        guard previous != cameraLayoutCues else { return }
        registerUndo(actionName) { target in
            target.applyLayoutCues(previous, actionName: actionName)
        }
    }

    /// Adds a cue at the playhead, three seconds long or up to the next cue.
    func addLayoutCue(at time: TimeInterval, layout: RecordingCameraLayout? = nil) {
        let sourceTime = clipTimeline.sourceTime(at: time)
        let start = min(max(0, sourceTime), max(0, sourceDuration - RecordingCameraLayoutCue.minimumDuration))
        insertLayoutCue(start: start, end: min(sourceDuration, start + 3), layout: layout)
    }

    /// Adds a cue over a range drawn on the layout track, in editor time,
    /// as is - see `addZoomCue(overEditorRange:)`.
    func addLayoutCue(overEditorRange range: ClosedRange<TimeInterval>) {
        guard let span = drawnSourceSpan(
            for: range,
            among: cameraLayoutCues.map { $0.start...$0.end },
            minimum: RecordingCameraLayoutCue.minimumDuration
        ) else { return }
        appendLayoutCue(span, layout: nil)
    }

    private func insertLayoutCue(start: TimeInterval, end: TimeInterval, layout: RecordingCameraLayout?) {
        guard let span = freeLayoutSpan(from: start, preferredEnd: end) else { return }
        appendLayoutCue(span, layout: layout)
    }

    private func appendLayoutCue(_ span: ClosedRange<TimeInterval>, layout: RecordingCameraLayout?) {
        let cue = RecordingCameraLayoutCue(
            start: span.lowerBound,
            end: span.upperBound,
            layout: layout ?? .suggestedCue(over: style.camera.layout)
        )
        var cues = cameraLayoutCues
        cues.append(cue)
        applyLayoutCues(cues, actionName: "Add Layout")
        selectLayoutCue(id: cue.id)
    }

    /// Mirrors zoom cue placement: a request inside a cue is pushed past it,
    /// and the span stops at the next cue.
    private func freeLayoutSpan(from start: TimeInterval, preferredEnd: TimeInterval) -> ClosedRange<TimeInterval>? {
        guard sourceDuration > 0 else { return nil }
        let minimum = RecordingCameraLayoutCue.minimumDuration
        let length = max(preferredEnd - start, minimum)
        var lower = min(max(start, 0), sourceDuration)
        while let covering = cameraLayoutCues.first(where: { $0.start <= lower && $0.end > lower }) {
            lower = covering.end
        }
        let upper = cameraLayoutCues
            .filter { $0.start > lower }
            .map(\.start)
            .min() ?? sourceDuration
        guard upper - lower >= minimum else { return nil }
        return lower...min(lower + length, upper)
    }

    private func layoutNeighborBounds(forCueAt index: Int) -> (lower: TimeInterval, upper: TimeInterval) {
        let cues = cameraLayoutCues
        return (
            lower: index > 0 ? max(0, cues[index - 1].end) : 0,
            upper: index + 1 < cues.count ? min(cues[index + 1].start, sourceDuration) : sourceDuration
        )
    }

    func removeLayoutCue(id: UUID) {
        applyLayoutCues(cameraLayoutCues.filter { $0.id != id }, actionName: "Remove Layout")
        if selectedLayoutCueID == id {
            selectedLayoutCueID = nil
        }
    }

    /// Applies an edited cue as its own undo step.
    func updateLayoutCue(_ cue: RecordingCameraLayoutCue, actionName: String) {
        beginLayoutCueEdit()
        resizeLayoutCue(cue)
        endLayoutCueEdit(actionName: actionName)
    }

    /// Applies an edited cue during a continuous edit, stopping either edge
    /// at the neighboring cues.
    func resizeLayoutCue(_ cue: RecordingCameraLayoutCue) {
        var cues = cameraLayoutCues
        guard let index = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        let bounds = layoutNeighborBounds(forCueAt: index)
        let minimum = RecordingCameraLayoutCue.minimumDuration
        var updated = cue
        updated.start = min(max(updated.start, bounds.lower), max(bounds.lower, bounds.upper - minimum))
        updated.end = min(max(updated.end, updated.start + minimum), bounds.upper)
        cues[index] = updated
        replaceLayoutCues(cues)
    }

    /// Slides a cue without changing its length, parking it against a
    /// neighbor rather than squashing it.
    func moveLayoutCue(_ cue: RecordingCameraLayoutCue) {
        var cues = cameraLayoutCues
        guard let index = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        let bounds = layoutNeighborBounds(forCueAt: index)
        let minimum = RecordingCameraLayoutCue.minimumDuration
        let room = max(bounds.upper - bounds.lower, minimum)
        let length = min(max(cue.duration, minimum), room)
        var moved = cue
        moved.start = min(max(cue.start, bounds.lower), max(bounds.lower, bounds.upper - length))
        moved.end = min(moved.start + length, bounds.upper)
        cues[index] = moved
        replaceLayoutCues(cues)
    }

    // MARK: - Text

    var selectedText: RecordingTextOverlay? {
        textOverlays.first { $0.id == selectedTextID }
    }

    var textTimelineBlocks: [RecordingOverlayTimelineBlock<RecordingTextOverlay>] {
        RecordingOverlayTimelineBlock.blocks(for: textOverlays, clipTimeline: clipTimeline) {
            ($0.start, $0.end)
        }
    }

    /// The texts showing at an editor time, bottom to top.
    func texts(atEditorTime time: TimeInterval) -> [RecordingTextOverlay] {
        guard !textOverlays.isEmpty, clipTimeline.location(at: time) != nil else { return [] }
        let sourceTime = clipTimeline.sourceTime(at: time)
        return textOverlays.filter { $0.isActive(atSourceTime: sourceTime) }
    }

    func selectText(id: UUID) {
        guard textOverlays.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedTextID = id
    }

    /// Adds a text at the playhead, three seconds long.
    func addText(atEditorTime time: TimeInterval) {
        let range = sourceRange(startingAt: time, length: RecordingTextOverlay.defaultDuration,
                                minimum: RecordingTextOverlay.minimumDuration)
        guard let range else { return }
        insertText(RecordingTextOverlay(start: range.lowerBound, end: range.upperBound))
    }

    /// Adds a text over a range dragged across the text track. Times are
    /// editor time and need not be ordered.
    func addText(fromEditorTime editorStart: TimeInterval, toEditorTime editorEnd: TimeInterval) {
        guard let range = sourceRange(fromEditorTime: editorStart, toEditorTime: editorEnd,
                                      minimum: RecordingTextOverlay.minimumDuration) else { return }
        insertText(RecordingTextOverlay(start: range.lowerBound, end: range.upperBound))
    }

    private func insertText(_ overlay: RecordingTextOverlay) {
        applyTexts(textOverlays + [overlay], actionName: "Add Text")
        selectText(id: overlay.id)
    }

    func removeText(id: UUID) {
        applyTexts(textOverlays.filter { $0.id != id }, actionName: "Remove Text")
        if selectedTextID == id { selectedTextID = nil }
    }

    /// Opens a continuous edit (a drag, or typing); `endTextEdit` registers
    /// it as one undo step.
    func beginTextEdit() {
        if textEditSnapshot == nil { textEditSnapshot = textOverlays }
    }

    func endTextEdit(actionName: String = "Edit Text") {
        guard let previous = textEditSnapshot else { return }
        textEditSnapshot = nil
        guard previous != textOverlays else { return }
        registerUndo(actionName) { target in
            target.applyTexts(previous, actionName: actionName)
        }
    }

    /// Applies an edited text during a continuous edit, keeping it inside
    /// the recording.
    func setText(_ overlay: RecordingTextOverlay) {
        guard let index = textOverlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        var texts = textOverlays
        var updated = overlay
        let range = clampedSourceRange(start: overlay.start, end: overlay.end, minimum: RecordingTextOverlay.minimumDuration)
        updated.start = range.lowerBound
        updated.end = range.upperBound
        updated.fontSize = min(max(updated.fontSize, RecordingTextOverlay.fontSizeRange.lowerBound),
                               RecordingTextOverlay.fontSizeRange.upperBound)
        updated.center = CGPoint(x: min(max(updated.center.x, 0), 1), y: min(max(updated.center.y, 0), 1))
        texts[index] = updated
        replaceTexts(texts)
    }

    /// Applies an inspector edit; edits that follow each other closely,
    /// like a slider sweep or typing, undo together.
    func editText(_ overlay: RecordingTextOverlay, actionName: String) {
        beginTextEdit()
        setText(overlay)
        textCoalesceTask?.cancel()
        textCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.endTextEdit(actionName: actionName)
        }
    }

    /// Applies an edited text as its own undo step.
    func updateText(_ overlay: RecordingTextOverlay, actionName: String) {
        beginTextEdit()
        setText(overlay)
        endTextEdit(actionName: actionName)
    }

    private func replaceTexts(_ texts: [RecordingTextOverlay]) {
        textOverlays = texts
        scheduleProjectSave()
    }

    private func applyTexts(_ texts: [RecordingTextOverlay], actionName: String) {
        guard texts != textOverlays else { return }
        let previous = textOverlays
        registerUndo(actionName) { target in
            target.applyTexts(previous, actionName: actionName)
        }
        replaceTexts(texts)
        if let selectedTextID, !texts.contains(where: { $0.id == selectedTextID }) {
            self.selectedTextID = nil
        }
    }

    // MARK: - Pixelate

    var selectedRedaction: RecordingRedaction? {
        redactions.first { $0.id == selectedRedactionID }
    }

    var redactionTimelineBlocks: [RecordingOverlayTimelineBlock<RecordingRedaction>] {
        RecordingOverlayTimelineBlock.blocks(for: redactions, clipTimeline: clipTimeline) {
            ($0.start, $0.end)
        }
    }

    /// The regions showing at an editor time.
    func redactions(atEditorTime time: TimeInterval) -> [RecordingRedaction] {
        guard !redactions.isEmpty, clipTimeline.location(at: time) != nil else { return [] }
        let sourceTime = clipTimeline.sourceTime(at: time)
        return redactions.filter { $0.start <= sourceTime && sourceTime < $0.end }
    }

    func selectRedaction(id: UUID) {
        guard redactions.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedRedactionID = id
    }

    /// Pixelates the middle of the picture from the playhead for three
    /// seconds; the region is then moved and sized on the canvas.
    func addRedaction(atEditorTime time: TimeInterval, style: RecordingRedaction.Style = .pixelate) {
        guard let range = sourceRange(startingAt: time, length: RecordingRedaction.defaultDuration,
                                      minimum: RecordingRedaction.minimumDuration) else { return }
        var redaction = RecordingRedaction(start: range.lowerBound, end: range.upperBound)
        redaction.style = style
        applyRedactions(redactions + [redaction], actionName: style == .blur ? "Add Blur" : "Add Pixelate")
        selectRedaction(id: redaction.id)
    }

    func removeRedaction(id: UUID) {
        applyRedactions(redactions.filter { $0.id != id }, actionName: "Remove Pixelate")
        if selectedRedactionID == id { selectedRedactionID = nil }
    }

    func beginRedactionEdit() {
        if redactionEditSnapshot == nil { redactionEditSnapshot = redactions }
    }

    func endRedactionEdit(actionName: String = "Edit Pixelate") {
        guard let previous = redactionEditSnapshot else { return }
        redactionEditSnapshot = nil
        guard previous != redactions else { return }
        registerUndo(actionName) { target in
            target.applyRedactions(previous, actionName: actionName)
        }
    }

    /// Applies an edited region during a continuous edit, keeping it inside
    /// the recording and the picture.
    func setRedaction(_ redaction: RecordingRedaction) {
        guard let index = redactions.firstIndex(where: { $0.id == redaction.id }) else { return }
        var updated = redaction
        let range = clampedSourceRange(start: redaction.start, end: redaction.end, minimum: RecordingRedaction.minimumDuration)
        updated.start = range.lowerBound
        updated.end = range.upperBound
        updated.rect = RecordingRedaction.clamped(redaction.rect)
        updated.amount = min(max(updated.amount, 0), 1)
        var all = redactions
        all[index] = updated
        replaceRedactions(all)
    }

    func editRedaction(_ redaction: RecordingRedaction, actionName: String) {
        beginRedactionEdit()
        setRedaction(redaction)
        redactionCoalesceTask?.cancel()
        redactionCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.endRedactionEdit(actionName: actionName)
        }
    }

    func updateRedaction(_ redaction: RecordingRedaction, actionName: String) {
        beginRedactionEdit()
        setRedaction(redaction)
        endRedactionEdit(actionName: actionName)
    }

    private func replaceRedactions(_ all: [RecordingRedaction]) {
        let wasEmpty = redactions.isEmpty
        redactions = all
        redactionPreview.update(redactions: all, clipTimeline: clipTimeline)
        if let item = screenPlayer.currentItem {
            if all.isEmpty {
                item.videoComposition = nil
            } else if wasEmpty {
                item.videoComposition = redactionPreview.makeVideoComposition(for: item.asset)
            }
        }
        scheduleRedactionRefresh()
        scheduleProjectSave()
    }

    private func applyRedactions(_ all: [RecordingRedaction], actionName: String) {
        guard all != redactions else { return }
        let previous = redactions
        registerUndo(actionName) { target in
            target.applyRedactions(previous, actionName: actionName)
        }
        replaceRedactions(all)
        if let selectedRedactionID, !all.contains(where: { $0.id == selectedRedactionID }) {
            self.selectedRedactionID = nil
        }
    }

    /// The player renders a paused frame once, so a region edited while
    /// paused needs the frame drawn again. A fresh composition makes the
    /// player re-render; the seek puts the same moment back on screen.
    private func scheduleRedactionRefresh() {
        guard !isPlaying, redactionRefreshTask == nil else { return }
        redactionRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            self.redactionRefreshTask = nil
            guard !self.isPlaying, let item = self.screenPlayer.currentItem else { return }
            if !self.redactions.isEmpty {
                item.videoComposition = self.redactionPreview.makeVideoComposition(for: item.asset)
            }
            self.movePlayers(to: self.displayTime)
        }
    }

    /// The camera player runs a touch-up composition only while there's
    /// something to touch up, so an untouched camera plays as recorded.
    private func updateCameraBeautyPreview() {
        let beauty = style.camera.beauty
        cameraBeautyPreview.update(beauty)
        guard let item = cameraPlayer.currentItem else { return }
        if !beauty.isActive {
            item.videoComposition = nil
        } else if item.videoComposition == nil {
            item.videoComposition = cameraBeautyPreview.makeVideoComposition(for: item.asset)
        }
        scheduleCameraBeautyRefresh()
    }

    /// Like a region edit, a touch-up changed while paused needs the
    /// camera's frame drawn again.
    private func scheduleCameraBeautyRefresh() {
        guard !isPlaying, cameraBeautyRefreshTask == nil else { return }
        cameraBeautyRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            self.cameraBeautyRefreshTask = nil
            guard !self.isPlaying, let item = self.cameraPlayer.currentItem else { return }
            if self.style.camera.beauty.isActive {
                item.videoComposition = self.cameraBeautyPreview.makeVideoComposition(for: item.asset)
            }
            self.movePlayers(to: self.displayTime)
        }
    }

    // MARK: - Media

    /// Where imported images and audio are copied; nil for a bare movie,
    /// which has no project folder to keep them in.
    var mediaDirectoryURL: URL? {
        session?.directoryURL.appendingPathComponent("media", isDirectory: true)
    }

    var canImportMedia: Bool { mediaDirectoryURL != nil && isLoaded }

    /// Copies picked images, GIFs and audio into the project and places
    /// them from `time`: images on the Images & Effects track, audio on the
    /// Audio track, several of a kind one after another.
    func importMedia(_ urls: [URL], atEditorTime time: TimeInterval) {
        guard let directory = mediaDirectoryURL else { return }
        mediaImportError = nil
        Task { [weak self] in
            var imageTime = time
            var audioTime = time
            var rejected: [String] = []
            for url in urls {
                guard let self, !self.isTornDown else { return }
                if RecordingOverlayImage.canImport(url) {
                    if let placed = await self.importImage(url, into: directory, atEditorTime: imageTime) {
                        imageTime = placed
                    } else {
                        rejected.append(url.lastPathComponent)
                    }
                } else if RecordingAudioClip.canImport(url) {
                    if let placed = await self.importAudio(url, into: directory, atEditorTime: audioTime) {
                        audioTime = placed
                    } else {
                        rejected.append(url.lastPathComponent)
                    }
                } else {
                    rejected.append(url.lastPathComponent)
                }
            }
            if !rejected.isEmpty {
                self?.mediaImportError = "Couldn't add \(rejected.joined(separator: ", ")). Images, GIFs and audio files can be added."
            }
        }
    }

    /// One file, awaited: the agent server needs to know it landed before
    /// it reports back. False when the file isn't an image, GIF, or audio.
    func importMediaFile(_ url: URL, atEditorTime time: TimeInterval) async -> Bool {
        guard let directory = mediaDirectoryURL, !isTornDown else { return false }
        if RecordingOverlayImage.canImport(url) {
            return await importImage(url, into: directory, atEditorTime: time) != nil
        }
        if RecordingAudioClip.canImport(url) {
            return await importAudio(url, into: directory, atEditorTime: time) != nil
        }
        return false
    }

    private func copyIntoProject(_ url: URL, directory: URL) -> String? {
        let fileName = UUID().uuidString + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension.lowercased())")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(fileName))
            return fileName
        } catch {
            return nil
        }
    }

    /// Adds one image at an editor time. Returns where the next one goes.
    private func importImage(_ url: URL, into directory: URL, atEditorTime time: TimeInterval) async -> TimeInterval? {
        guard let fileName = copyIntoProject(url, directory: directory) else { return nil }
        let storedURL = directory.appendingPathComponent(fileName)
        let store = overlayImages
        let decoded = await Task.detached(priority: .userInitiated) { store.image(at: storedURL) }.value
        guard let decoded, !isTornDown,
              let range = sourceRange(startingAt: time, length: RecordingImageOverlay.defaultDuration,
                                      minimum: RecordingImageOverlay.minimumDuration) else {
            try? FileManager.default.removeItem(at: storedURL)
            return nil
        }
        var overlay = RecordingImageOverlay(
            fileName: fileName,
            displayName: url.deletingPathExtension().lastPathComponent,
            start: range.lowerBound,
            end: range.upperBound
        )
        overlay.aspect = decoded.aspect
        overlay.isAnimated = decoded.isAnimated
        // At most 40% of the canvas wide and half of it tall.
        let canvas = basePreviewCanvasSize
        let heightLimitedWidth = canvas.width > 0 ? 0.5 * canvas.height * decoded.aspect / canvas.width : 0.4
        overlay.width = min(0.4, heightLimitedWidth)
        overlayImageRevision &+= 1
        applyImages(imageOverlays + [overlay], actionName: "Add Image")
        selectImage(id: overlay.id)
        return clipTimeline.editorTime(forSourceTime: range.upperBound) ?? time + RecordingImageOverlay.defaultDuration
    }

    /// Adds one audio file at an editor time. Returns where the next one goes.
    private func importAudio(_ url: URL, into directory: URL, atEditorTime time: TimeInterval) async -> TimeInterval? {
        guard let fileName = copyIntoProject(url, directory: directory) else { return nil }
        let storedURL = directory.appendingPathComponent(fileName)
        guard let file = await RecordingAudioFileTrack.load(url: storedURL),
              let fileDuration = try? await file.asset.load(.duration).seconds,
              fileDuration.isFinite, fileDuration >= RecordingAudioClip.minimumDuration, !isTornDown else {
            try? FileManager.default.removeItem(at: storedURL)
            return nil
        }
        audioTracksByFile[fileName] = file
        loadPeaks(for: fileName, url: storedURL)
        // A file dropped right at the end starts from the top instead of
        // landing past everything.
        let start = time > duration - 0.5 ? 0 : max(0, time)
        var clip = RecordingAudioClip(
            fileName: fileName,
            displayName: url.deletingPathExtension().lastPathComponent,
            start: start,
            fileDuration: fileDuration
        )
        clip.trimEnd = min(fileDuration, max(RecordingAudioClip.minimumDuration, duration - start))
        applyAudioClips(audioClips + [clip], actionName: "Add Audio")
        selectAudioClip(id: clip.id)
        return clip.end
    }

    private func loadPeaks(for fileName: String, url: URL) {
        guard audioPeaks[fileName] == nil else { return }
        Task { [weak self] in
            let peaks = await Task.detached(priority: .utility) { await RecordingAudioPeaks.load(url: url) }.value
            self?.audioPeaks[fileName] = peaks
        }
    }

    /// Decodes a project's overlay images and resolves its audio files in
    /// the background after it opens; the canvas and player pick them up as
    /// they arrive.
    private func loadOverlayMedia() {
        mediaLoadTask?.cancel()
        guard let directory = mediaDirectoryURL, !imageOverlays.isEmpty || !audioClips.isEmpty else { return }
        let imageFiles = Set(imageOverlays.map(\.fileName))
        let audioFiles = Set(audioClips.map(\.fileName)).subtracting(audioTracksByFile.keys)
        let store = overlayImages
        mediaLoadTask = Task { [weak self] in
            await Task.detached(priority: .userInitiated) {
                for name in imageFiles {
                    _ = store.image(at: directory.appendingPathComponent(name))
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.overlayImageRevision &+= 1
            var resolvedAny = false
            for name in audioFiles {
                let url = directory.appendingPathComponent(name)
                if let file = await RecordingAudioFileTrack.load(url: url) {
                    guard !Task.isCancelled else { return }
                    self.audioTracksByFile[name] = file
                    resolvedAny = true
                }
                self.loadPeaks(for: name, url: url)
            }
            if resolvedAny, self.isLoaded {
                try? self.rebuildScreenPlayerItem(preserving: self.currentTime)
            }
        }
    }

    /// The playback asset with every resolved audio clip on its own track.
    private func addingAudioClips(to asset: AVAsset) throws -> AVAsset {
        playbackClipTrackIDs = [:]
        let sources = audioClips.compactMap { clip in
            audioTracksByFile[clip.fileName].map { RecordingAudioClipSource(clip: clip, file: $0) }
        }
        guard !sources.isEmpty else { return asset }
        let composition: AVMutableComposition
        if let existing = asset as? AVMutableComposition {
            composition = existing
        } else {
            // The unedited recording plays as-is; music needs a composition
            // to sit in.
            composition = AVMutableComposition()
            try composition.insertTimeRange(
                CMTimeRange(start: .zero, duration: CMTime(seconds: sourceDuration, preferredTimescale: 600)),
                of: asset,
                at: .zero
            )
        }
        playbackClipTrackIDs = RecordingAudioClipMixer.insert(sources, into: composition, videoDuration: duration)
        return composition
    }

    // MARK: - Images

    var selectedImage: RecordingImageOverlay? {
        imageOverlays.first { $0.id == selectedImageID }
    }

    var imageTimelineBlocks: [RecordingOverlayTimelineBlock<RecordingImageOverlay>] {
        RecordingOverlayTimelineBlock.blocks(for: imageOverlays, clipTimeline: clipTimeline) {
            ($0.start, $0.end)
        }
    }

    /// The images showing at an editor time, bottom to top.
    func images(atEditorTime time: TimeInterval) -> [RecordingImageOverlay] {
        guard !imageOverlays.isEmpty, clipTimeline.location(at: time) != nil else { return [] }
        let sourceTime = clipTimeline.sourceTime(at: time)
        return imageOverlays.filter { $0.isActive(atSourceTime: sourceTime) }
    }

    func overlayImageURL(for overlay: RecordingImageOverlay) -> URL? {
        mediaDirectoryURL?.appendingPathComponent(overlay.fileName)
    }

    func selectImage(id: UUID) {
        guard imageOverlays.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedImageID = id
    }

    func removeImage(id: UUID) {
        applyImages(imageOverlays.filter { $0.id != id }, actionName: "Remove Image")
        if selectedImageID == id { selectedImageID = nil }
    }

    func beginImageEdit() {
        if imageEditSnapshot == nil { imageEditSnapshot = imageOverlays }
    }

    func endImageEdit(actionName: String = "Edit Image") {
        guard let previous = imageEditSnapshot else { return }
        imageEditSnapshot = nil
        guard previous != imageOverlays else { return }
        registerUndo(actionName) { target in
            target.applyImages(previous, actionName: actionName)
        }
    }

    func setImage(_ overlay: RecordingImageOverlay) {
        guard let index = imageOverlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        var updated = overlay
        let range = clampedSourceRange(start: overlay.start, end: overlay.end, minimum: RecordingImageOverlay.minimumDuration)
        updated.start = range.lowerBound
        updated.end = range.upperBound
        updated.width = min(max(updated.width, RecordingImageOverlay.widthRange.lowerBound),
                            RecordingImageOverlay.widthRange.upperBound)
        updated.center = CGPoint(x: min(max(updated.center.x, 0), 1), y: min(max(updated.center.y, 0), 1))
        updated.opacity = min(max(updated.opacity, 0), 1)
        var all = imageOverlays
        all[index] = updated
        imageOverlays = all
        scheduleProjectSave()
    }

    func editImage(_ overlay: RecordingImageOverlay, actionName: String) {
        beginImageEdit()
        setImage(overlay)
        imageCoalesceTask?.cancel()
        imageCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.endImageEdit(actionName: actionName)
        }
    }

    private func applyImages(_ all: [RecordingImageOverlay], actionName: String) {
        guard all != imageOverlays else { return }
        let previous = imageOverlays
        registerUndo(actionName) { target in
            target.applyImages(previous, actionName: actionName)
        }
        imageOverlays = all
        scheduleProjectSave()
        if let selectedImageID, !all.contains(where: { $0.id == selectedImageID }) {
            self.selectedImageID = nil
        }
    }

    // MARK: - Audio

    var selectedAudioClip: RecordingAudioClip? {
        audioClips.first { $0.id == selectedAudioClipID }
    }

    func selectAudioClip(id: UUID) {
        guard audioClips.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedAudioClipID = id
    }

    func removeAudioClip(id: UUID) {
        applyAudioClips(audioClips.filter { $0.id != id }, actionName: "Remove Audio")
        if selectedAudioClipID == id { selectedAudioClipID = nil }
    }

    func beginAudioClipEdit() {
        if audioEditSnapshot == nil { audioEditSnapshot = audioClips }
    }

    func endAudioClipEdit(actionName: String = "Edit Audio") {
        guard let previous = audioEditSnapshot else { return }
        audioEditSnapshot = nil
        guard previous != audioClips else { return }
        registerUndo(actionName) { target in
            target.applyAudioClips(previous, actionName: actionName)
        }
    }

    /// Applies an edited clip, keeping its trim inside the file.
    func setAudioClip(_ clip: RecordingAudioClip) {
        guard let index = audioClips.firstIndex(where: { $0.id == clip.id }) else { return }
        var updated = clip
        let minimum = RecordingAudioClip.minimumDuration
        updated.trimStart = min(max(0, updated.trimStart), max(0, updated.fileDuration - minimum))
        updated.trimEnd = min(max(updated.trimEnd, updated.trimStart + minimum), updated.fileDuration)
        updated.start = max(0, updated.start)
        updated.volume = min(max(updated.volume, 0), 1)
        var all = audioClips
        all[index] = updated
        replaceAudioClips(all)
    }

    func editAudioClip(_ clip: RecordingAudioClip, actionName: String) {
        beginAudioClipEdit()
        setAudioClip(clip)
        audioCoalesceTask?.cancel()
        audioCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.endAudioClipEdit(actionName: actionName)
        }
    }

    private func replaceAudioClips(_ all: [RecordingAudioClip]) {
        let previous = audioClips
        audioClips = all
        scheduleProjectSave()
        // Volume and fades only change the mix; anything that moves audio
        // in time needs the composition rebuilt.
        let placement: (RecordingAudioClip) -> [Double] = { [$0.start, $0.trimStart, $0.trimEnd] }
        let movedAudio = previous.map(\.id) != all.map(\.id)
            || zip(previous, all).contains { placement($0) != placement($1) || $0.fileName != $1.fileName }
        if movedAudio {
            scheduleAudioPlaybackRebuild()
        } else {
            updatePlaybackVolume()
        }
    }

    /// A drag reports many moves; the player item is rebuilt once they
    /// settle.
    private func scheduleAudioPlaybackRebuild() {
        audioPlaybackRebuildTask?.cancel()
        audioPlaybackRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled, self.isLoaded else { return }
            let wasPlaying = self.isPlaying
            self.pause()
            try? self.rebuildScreenPlayerItem(preserving: self.currentTime)
            if wasPlaying { self.play() }
        }
    }

    private func applyAudioClips(_ all: [RecordingAudioClip], actionName: String) {
        guard all != audioClips else { return }
        let previous = audioClips
        registerUndo(actionName) { target in
            target.applyAudioClips(previous, actionName: actionName)
        }
        replaceAudioClips(all)
        if let selectedAudioClipID, !all.contains(where: { $0.id == selectedAudioClipID }) {
            self.selectedAudioClipID = nil
        }
    }

    // MARK: - Overlay ranges

    /// A source range `length` long from the recording moment under an
    /// editor time, kept inside the recording.
    private func sourceRange(
        startingAt editorTime: TimeInterval,
        length: TimeInterval,
        minimum: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        guard sourceDuration >= minimum else { return nil }
        let source = clipTimeline.sourceTime(at: min(max(editorTime, 0), duration))
        let start = min(max(0, source), sourceDuration - minimum)
        return start...min(sourceDuration, start + length)
    }

    private func sourceRange(
        fromEditorTime editorStart: TimeInterval,
        toEditorTime editorEnd: TimeInterval,
        minimum: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        guard sourceDuration >= minimum else { return nil }
        let low = clipTimeline.sourceTime(at: min(editorStart, editorEnd))
        let high = clipTimeline.sourceTime(at: max(editorStart, editorEnd))
        return clampedSourceRange(start: low, end: high, minimum: minimum)
    }

    private func clampedSourceRange(start: TimeInterval, end: TimeInterval, minimum: TimeInterval) -> ClosedRange<TimeInterval> {
        let lower = min(max(0, start), max(0, sourceDuration - minimum))
        let upper = min(max(end, lower + minimum), sourceDuration)
        return lower...max(lower, upper)
    }

    /// The recording under a range drawn on a track whose blocks can't
    /// overlap. The track has fitted the range between the blocks it draws,
    /// so this only trims away what it couldn't see: a cue cut out of the
    /// edit draws nothing, and the round trip through editor time can land
    /// a hair inside a neighbour. Nil when that leaves less than `minimum`,
    /// which the track already measured, in editor time.
    private func drawnSourceSpan(
        for range: ClosedRange<TimeInterval>,
        among occupied: [ClosedRange<TimeInterval>],
        minimum: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        var lower = min(max(0, clipTimeline.sourceTime(at: range.lowerBound)), sourceDuration)
        let end = min(max(lower, clipTimeline.sourceTime(at: range.upperBound)), sourceDuration)
        while let covering = occupied.first(where: { $0.lowerBound <= lower && lower < $0.upperBound }) {
            lower = covering.upperBound
        }
        let ceiling = occupied.map(\.lowerBound).filter { $0 >= lower }.min() ?? sourceDuration
        let upper = min(end, ceiling)
        // Speed only ever packs more recording into a timeline second, so a
        // block drawn `minimum` long covers at least that much recording;
        // the slack absorbs rounding.
        guard upper - lower >= minimum - 0.001 else { return nil }
        return lower...upper
    }

    var visibleRecordedPressTimes: [TimeInterval] {
        recordedPressTimes.compactMap { clipTimeline.editorTime(forSourceTime: $0) }
    }

    /// One visual block per cue on the edited timeline. A cue's per-segment
    /// slices are always contiguous in editor time (a cut removes the editor
    /// time between them), so they merge into a single block - cutting a clip
    /// inside a zoom never splits the zoom's lane representation.
    var zoomTimelineBlocks: [RecordingZoomTimelineBlock] {
        zoomCues
            .filter { !$0.isImplicit }
            .compactMap { cue in
                let slices = clipTimeline.slices(overlapping: cue.start, sourceEnd: cue.end)
                guard let first = slices.first, let last = slices.last else { return nil }
                return RecordingZoomTimelineBlock(
                    cue: cue,
                    editorStart: first.editorStart,
                    editorEnd: last.editorEnd
                )
            }
    }

    func sourceTime(atEditorTime time: TimeInterval) -> TimeInterval {
        clipTimeline.sourceTime(at: time)
    }

    func editorTime(forSourceTime time: TimeInterval) -> TimeInterval? {
        clipTimeline.editorTime(forSourceTime: time)
    }

    private func rebuildPointerTimeline() {
        reframeFocusTimeline = nil
        reframeFocusResolved = false
        guard pointerIsSynthesized, sourceDuration > 0 else {
            pointerTimeline = .empty
            return
        }
        pointerTimeline = PointerTimeline.build(
            capture: pointerCapture,
            duration: sourceDuration,
            recordingSizeInPoints: recordingPointSize,
            fallbackArtwork: PointerArtworkCapture.defaultArtwork(),
            clipTimeline: clipTimeline
        )
    }

    private func scheduleViewportRebuild() {
        viewportRebuildTask?.cancel()
        viewportRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            self.viewportRebuildTask = nil
            self.rebuildViewportTimeline()
        }
    }

    private func rebuildViewportTimeline() {
        // Layout cues live on the edited timeline. Rebuild their shared
        // motion with every cut, trim, speed change, or zoom edit.
        rebuildCameraLayoutTimeline(rebuildsZoom: false)
        guard sourceDuration > 0 else {
            viewportTimeline = .identity
            return
        }
        viewportTimeline = ViewportTimeline.build(
            cues: zoomCues,
            capture: pointerCapture,
            clipTimeline: clipTimeline
        )
        // The reframe camera derives from the viewport, so it follows
        // every rebuild (zoom edits, cuts, speed changes).
        rebuildPreviewReframe()
    }

    private func scheduleProjectSave() {
        guard isLoaded, !isApplyingDocument, session != nil else { return }
        hasUnsavedChanges = true
        projectSaveTask?.cancel()
        projectSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.writeDraftNow()
        }
    }

    /// Every edit in the editor, as a storable document.
    private func currentDocument() -> RecordingEditDocument {
        RecordingEditDocument(
            style: style,
            zoomEnabled: zoomEnabled,
            zoomCues: zoomCues.filter { !$0.isImplicit },
            cameraLayoutCues: cameraLayoutCues.isEmpty ? nil : cameraLayoutCues,
            textOverlays: textOverlays.isEmpty ? nil : textOverlays,
            redactions: redactions.isEmpty ? nil : redactions,
            imageOverlays: imageOverlays.isEmpty ? nil : imageOverlays,
            audioClips: audioClips.isEmpty ? nil : audioClips,
            clipTimeline: clipTimeline,
            exportSettings: exportSettings,
            showsClickEffects: showsClickEffects,
            showsKeystrokes: showsKeystrokes,
            keystrokePlacement: keystrokePlacement,
            // Written only when they differ from the defaults, so projects
            // that never touch the badge stay byte-identical on disk.
            showsSpeedBadge: showsSpeedBadge ? true : nil,
            speedBadgePlacement: speedBadgePlacement == .topRight ? nil : speedBadgePlacement,
            showsSubtitles: showsSubtitles,
            subtitleCues: subtitleCues.isEmpty ? nil : subtitleCues,
            subtitleWords: transcriptWords.isEmpty ? nil : transcriptWords,
            subtitleStyle: subtitleStyle,
            exportAspect: exportAspect,
            exportAspectMode: exportAspectMode,
            videoCropRect: isVideoCropped ? videoCropRect : nil,
            replacementAudioFileName: replacementAudio?.url.lastPathComponent,
            replacementAudioDisplayName: replacementAudio?.displayName,
            audioExportFormat: audioExportFormat,
            audioVolume: Double(audioVolume)
        )
    }

    /// True until the project has been saved at least once. Only these get
    /// offered "Delete and close" - throwing away a project the user already
    /// committed to would be unrecoverable.
    var hasNeverBeenSaved: Bool {
        guard let session else { return false }
        return !session.hasSavedProject
    }

    /// Persists the working copy. Cheap, debounced, and never touches the
    /// committed `edit.json`, so a crash costs nothing and Save still means
    /// something.
    private func writeDraftNow() {
        guard isLoaded, let session else { return }
        let document = currentDocument()
        if document == lastSavedDocument {
            // Edited back to the saved state (undo, or a discard landing):
            // the draft is now noise and would reopen the project dirty.
            session.removeDraftDocument()
            hasUnsavedChanges = false
        } else {
            try? session.writeDraftDocument(document)
            hasUnsavedChanges = true
        }
        dropStaleRender(for: document, in: session)
    }

    /// A cached flatten that no longer matches the edits is worse than no
    /// cache: History previews it and Share would upload it.
    private func dropStaleRender(for document: RecordingEditDocument, in session: RecordingSession) {
        guard session.existingFinalURL != nil else { return }
        guard session.freshFinalURL(matching: document) == nil else { return }
        session.removeFinalVideos()
    }

    /// Writes the working copy immediately, bypassing the debounce. Used on
    /// teardown and on quit so no edit is left only in memory.
    func flushDraft() {
        projectSaveTask?.cancel()
        writeDraftNow()
    }

    // MARK: - Agent edits

    /// Every edit as a storable document, for the agent server to read and
    /// transform.
    var editDocument: RecordingEditDocument {
        currentDocument()
    }

    /// Runs one agent edit as exactly one undo step. Undo groups normally
    /// close at the end of a UI event, and edits arriving over the agent
    /// socket never get one, so without an explicit group every agent edit
    /// would pile into a single step that undoes them all at once.
    func performAgentEdit(_ edit: () throws -> Void) rethrows {
        let manager = editUndoManager
        closeOpenUndoGroups()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        defer {
            manager.endUndoGrouping()
            manager.groupsByEvent = true
        }
        try edit()
    }

    /// Ends a group left open by an edit that arrived outside a UI event,
    /// such as a media import an agent awaited.
    func closeOpenUndoGroups() {
        while editUndoManager.groupingLevel > 0 {
            editUndoManager.endUndoGrouping()
        }
    }

    /// Applies a whole document an agent produced as one undo step, so the
    /// user can ⌘Z an agent's change like their own. The imported soundtrack
    /// is the one thing that stays put: swapping it loads a file, which this
    /// synchronous path (and undo) can't wait for.
    func applyAgentDocument(_ requested: RecordingEditDocument, actionName: String) {
        guard isLoaded else { return }
        var document = requested
        let previous = currentDocument()
        document.replacementAudioFileName = previous.replacementAudioFileName
        document.replacementAudioDisplayName = previous.replacementAudioDisplayName
        guard document != previous else { return }

        registerUndo(actionName) { target in
            target.applyAgentDocument(previous, actionName: actionName)
        }
        pause()
        clearTimelineSelection()
        hoverPreviewTime = nil
        timelineHoverTime = nil

        let implicitZoomCues = zoomCues.filter(\.isImplicit)
        applyDocumentSettings(document)
        isApplyingDocument = true
        zoomCues = document.zoomCues + implicitZoomCues
        if let clips = document.clips, !clips.isEmpty {
            clipTimeline = RecordingClipTimeline(segments: clips).normalized(to: sourceDuration)
        }
        duration = clipTimeline.duration
        isApplyingDocument = false

        try? rebuildScreenPlayerItem(preserving: min(currentTime, duration))
        rebuildCameraLayoutTimeline()
        rebuildPointerTimeline()
        rebuildViewportTimeline()
        rebuildPreviewReframe()
        updateActiveTranscriptWord()
        scheduleProjectSave()
    }

    /// ⌘S. Commits the working copy to `edit.json` and clears the draft.
    @discardableResult
    func saveProject() -> Bool {
        guard isLoaded, let session else { return false }
        projectSaveTask?.cancel()
        let document = currentDocument()
        do {
            try session.writeEditDocument(document)
            session.removeDraftDocument()
            lastSavedDocument = document
            hasUnsavedChanges = false
            session.updateProjectMetadata { $0.savedAt = Date() }
            dropStaleRender(for: document, in: session)
            RecordingProjectStore.shared.reload()
            flashSaveConfirmation()
            return true
        } catch {
            FailureAlert.present(message: "The recording project could not be saved", error: error,
                                 detail: "Your editor will stay open. Try saving again after resolving the problem.")
            return false
        }
    }

    /// Throws away everything since the last save and returns the editor to
    /// that state. Only offered for projects that have actually been saved.
    func discardChanges() async {
        guard isLoaded, let session else { return }
        projectSaveTask?.cancel()
        session.removeDraftDocument()
        guard let document = lastSavedDocument else { return }
        applyDocumentSettings(document)
        await applyDocumentTimeline(document)
        // Rebuilding the timeline touches published state; let the normal
        // draft path settle the dirty flag rather than assuming it landed.
        flushDraft()
    }

    /// Deletes the whole recording package - footage included - and its
    /// History entry. Reserved for a project that was never saved.
    func deleteProject() {
        guard let session else { return }
        teardown()
        RecordingProjectStore.shared.delete(session)
    }

    private func flashSaveConfirmation() {
        saveFlash = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            self?.saveFlash = false
        }
    }

    /// The parts of a stored project that need the timeline rebuilt around
    /// them: cuts, the imported soundtrack, and everything derived from both.
    private func applyDocumentTimeline(_ document: RecordingEditDocument) async {
        guard !isTornDown, !Task.isCancelled, let session else { return }
        isApplyingDocument = true
        defer { isApplyingDocument = false }

        if let storedClips = document.clips, !storedClips.isEmpty {
            clipTimeline = RecordingClipTimeline(segments: storedClips)
                .normalized(to: sourceDuration)
        } else {
            clipTimeline = .legacyTrim(
                start: document.trimStart,
                end: document.trimEnd,
                sourceDuration: sourceDuration
            )
        }
        duration = clipTimeline.duration
        // Nothing is selected until the user picks a clip; an unsplit
        // recording would otherwise open wrapped in selection chrome.
        selectedClipID = nil

        if let fileName = document.replacementAudioFileName {
            let url = session.directoryURL.appendingPathComponent(fileName)
            if url != replacementAudio?.url, FileManager.default.fileExists(atPath: url.path) {
                let loadedAudio = await RecordingReplacementAudio.load(
                    url: url,
                    displayName: document.replacementAudioDisplayName ?? fileName
                )
                guard !isTornDown, !Task.isCancelled else { return }
                replacementAudio = loadedAudio
            }
        } else {
            replacementAudio = nil
        }

        isApplyingDocument = false

        try? rebuildScreenPlayerItem(preserving: currentTime)
        rebuildPointerTimeline()
        rebuildViewportTimeline()
        rebuildPreviewReframe()
        editUndoManager.removeAllActions()
        undoRevision += 1
    }

    /// Viewport frame to render at a given time, honoring the zoom toggle.
    func viewportFrame(at time: TimeInterval) -> ViewportFrame {
        guard zoomEnabled else { return .identity }
        return viewportTimeline.frame(at: time)
    }

    /// How far the zoom has travelled toward its target, 0...1.
    func zoomProgress(at time: TimeInterval) -> Double {
        guard zoomEnabled else { return 0 }
        return viewportTimeline.zoomProgress(at: time)
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
        guard !style.hidesCursor, pointerIsSynthesized else { return nil }
        return pointerTimeline.frame(at: time)
    }

    func artwork(id: String?) -> PointerArtwork? {
        pointerTimeline.artwork(id: id)?.styled(style.cursorStyle, inverted: style.invertsCursor)
    }

    /// Legacy sessions may already contain baked-in press feedback; only
    /// sidecar-reconstructed sessions can re-render it on demand.
    var canShowPressEffects: Bool {
        pointerIsSynthesized && manifest?.pressEffectsBaked == false
    }

    var showsPressEffects: Bool {
        canShowPressEffects && showsClickEffects
    }

    var hasKeystrokes: Bool {
        !keystrokeTimeline.isEmpty
    }

    // MARK: - Transcription

    /// Only narrated sessions can be transcribed; the mic requirement means
    /// legacy bare movies and silent captures never show the section.
    var canTranscribe: Bool {
        manifest?.includesMicrophone == true
    }

    var hasSubtitles: Bool {
        !subtitleTimeline.isEmpty
    }

    /// Subtitle text to draw over the card right now; nil when hidden or
    /// nobody is speaking.
    func subtitleText(at time: TimeInterval) -> String? {
        guard showsSubtitles, hasSubtitles else { return nil }
        return subtitleTimeline.text(at: clipTimeline.sourceTime(at: time))
    }

    /// Karaoke word state for the bar at this editor time; nil when the
    /// style doesn't highlight words or no timings exist, in which case
    /// the bar renders `subtitleText` plainly.
    func subtitleKaraokeLine(at time: TimeInterval) -> KaraokeTimeline.Line? {
        guard showsSubtitles, subtitleStyle.highlightsSpokenWord,
              !karaokeTimeline.isEmpty else {
            return nil
        }
        return karaokeTimeline.line(at: clipTimeline.sourceTime(at: time))
    }

    func transcribe() {
        guard !transcriptionState.isTranscribing, isLoaded else { return }
        transcriptionState = .transcribing
        let movieURL = screenURL
        transcriptionTask = Task { [weak self] in
            do {
                let transcript = try await RecordingTranscriptionService.transcribe(screenMovieURL: movieURL)
                guard !Task.isCancelled else { return }
                self?.applyTranscription(transcript)
            } catch {
                guard !Task.isCancelled else { return }
                self?.transcriptionState = .failed(error.localizedDescription)
            }
        }
    }

    private func applyTranscription(_ transcript: RecordingTranscript) {
        subtitleCues = transcript.cues
        subtitleTimeline = SubtitleTimeline(cues: transcript.cues)
        transcriptWords = transcript.words
        karaokeTimeline = KaraokeTimeline(cues: transcript.cues, words: transcript.words)
        showsSubtitles = true
        transcriptionState = .idle
        updateActiveTranscriptWord()
        scheduleProjectSave()
    }

    func removeTranscription() {
        subtitleCues = []
        subtitleTimeline = .empty
        transcriptWords = []
        karaokeTimeline = .empty
        activeTranscriptWordIndex = nil
        transcriptionState = .idle
        scheduleProjectSave()
    }

    func updateSubtitleText(id: UUID, text: String) {
        guard let index = subtitleCues.firstIndex(where: { $0.id == id }),
              subtitleCues[index].text != text else {
            return
        }
        subtitleCues[index].text = text
        subtitleTimeline = SubtitleTimeline(cues: subtitleCues)
        karaokeTimeline = KaraokeTimeline(cues: subtitleCues, words: transcriptWords)
        scheduleProjectSave()
    }

    /// Moves the paused playhead to a cue's first surviving frame; a cue
    /// whose audio was cut out entirely has no home on the edited timeline.
    func seekToSubtitle(_ cue: RecordingSubtitleCue) {
        let target = clipTimeline.editorTime(forSourceTime: cue.start)
            ?? clipTimeline.editorTime(forSourceTime: (cue.start + cue.end) / 2)
        guard let target else { return }
        pause()
        seek(to: target)
    }

    /// Cue under the playhead right now, for highlighting the list row.
    var activeSubtitleCue: RecordingSubtitleCue? {
        guard hasSubtitles else { return nil }
        return subtitleTimeline.cue(at: clipTimeline.sourceTime(at: currentTime))
    }

    // MARK: - Transcript editing

    /// Cues-only projects (transcribed before words were stored) can still
    /// show captions but need a fresh transcription to edit by text.
    var hasTranscriptWords: Bool {
        !transcriptWords.isEmpty
    }

    /// Whether this word's audio still exists on the edited timeline.
    func transcriptWordSurvives(_ index: Int) -> Bool {
        guard transcriptWords.indices.contains(index) else { return false }
        return clipTimeline.editorTime(forSourceTime: transcriptWords[index].midpoint) != nil
    }

    func isFillerWord(_ index: Int) -> Bool {
        guard transcriptWords.indices.contains(index) else { return false }
        return TranscriptEditPlanner.isFiller(transcriptWords[index])
    }

    /// Fillers that would actually be cut - ones already removed don't count.
    var removableFillerWordCount: Int {
        TranscriptEditPlanner.fillerIndices(in: transcriptWords)
            .count { transcriptWordSurvives($0) }
    }

    /// Narration pauses long enough to trim that still exist in the edit.
    var trimmableSilenceCount: Int {
        TranscriptEditPlanner.silenceCutRanges(in: transcriptWords, sourceDuration: sourceDuration)
            .count { !clipTimeline.slices(overlapping: $0.lowerBound, sourceEnd: $0.upperBound).isEmpty }
    }

    /// Moves the paused playhead to a word's first surviving frame.
    func seekToTranscriptWord(at index: Int) {
        guard transcriptWords.indices.contains(index) else { return }
        let word = transcriptWords[index]
        let target = clipTimeline.editorTime(forSourceTime: word.start)
            ?? clipTimeline.editorTime(forSourceTime: word.midpoint)
        guard let target else { return }
        pause()
        seek(to: target)
    }

    /// Cuts the selected words' footage out of the video.
    func cutTranscriptWords(in range: ClosedRange<Int>) {
        guard let cut = TranscriptEditPlanner.cutRange(
            forWordsAt: range,
            in: transcriptWords,
            sourceDuration: sourceDuration
        ) else { return }
        cutSourceRanges([cut], actionName: range.count == 1 ? "Cut Word" : "Cut Words")
    }

    func removeFillerWords() {
        cutSourceRanges(
            TranscriptEditPlanner.fillerCutRanges(in: transcriptWords, sourceDuration: sourceDuration),
            actionName: "Remove Filler Words"
        )
    }

    func trimNarrationSilences() {
        cutSourceRanges(
            TranscriptEditPlanner.silenceCutRanges(in: transcriptWords, sourceDuration: sourceDuration),
            actionName: "Trim Silences"
        )
    }

    /// The shared transcript-cut path: removes source ranges from the clip
    /// timeline and drops the cut words from any overlapping captions. Both
    /// registrations land in one undo group, so a single ⌘Z restores the
    /// footage and the caption text together.
    func cutSourceRanges(_ ranges: [ClosedRange<TimeInterval>], actionName: String) {
        let merged = RecordingClipTimeline.mergedRanges(ranges)
        guard !merged.isEmpty,
              let next = clipTimeline.removingSourceRanges(merged)?.normalized(to: sourceDuration),
              next != clipTimeline else {
            return
        }

        let updatedCues = Self.rebuildingCueTexts(
            subtitleCues,
            words: transcriptWords,
            cutRanges: merged,
            surviving: next
        )
        if updatedCues != subtitleCues {
            applySubtitleCues(updatedCues, actionName: actionName)
        }

        // Park the playhead on the first splice so the result is audible
        // right where the cut happened.
        let playhead = next.editorTime(forSourceTime: merged[0].upperBound)
            ?? min(currentTime, next.duration)
        applyClipTimeline(
            next,
            selectedID: selectedClipID,
            playheadTime: playhead,
            actionName: actionName
        )
    }

    private func applySubtitleCues(_ cues: [RecordingSubtitleCue], actionName: String) {
        guard cues != subtitleCues else { return }
        let previous = subtitleCues
        registerUndo(actionName) { target in
            target.applySubtitleCues(previous, actionName: actionName)
        }
        subtitleCues = cues
        subtitleTimeline = SubtitleTimeline(cues: cues)
        karaokeTimeline = KaraokeTimeline(cues: cues, words: transcriptWords)
        scheduleProjectSave()
    }

    /// Rewrites the text of cues touched by a cut so captions stop showing
    /// words whose audio is gone. Only touched cues are rebuilt, so manual
    /// caption edits elsewhere survive. A word belongs to the last cue that
    /// starts at or before it.
    private static func rebuildingCueTexts(
        _ cues: [RecordingSubtitleCue],
        words: [RecordingTranscriptWord],
        cutRanges: [ClosedRange<TimeInterval>],
        surviving timeline: RecordingClipTimeline
    ) -> [RecordingSubtitleCue] {
        guard !words.isEmpty, !cues.isEmpty else { return cues }
        var result = cues
        let byStart = result.indices.sorted { result[$0].start < result[$1].start }

        for (position, index) in byStart.enumerated() {
            let cue = result[index]
            let overlapsCut = cutRanges.contains {
                $0.lowerBound < cue.end && $0.upperBound > cue.start
            }
            guard overlapsCut else { continue }

            let nextCueStart = position < byStart.count - 1
                ? result[byStart[position + 1]].start
                : .infinity
            result[index].text = words
                .filter { word in
                    word.start >= cue.start - 0.001
                        && word.start < nextCueStart - 0.001
                        && timeline.editorTime(forSourceTime: word.midpoint) != nil
                }
                .map(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// Recomputes which word the playhead is on; assigns only on change so
    /// observation-driven views wake on word boundaries, not every tick.
    private func updateActiveTranscriptWord() {
        guard !transcriptWords.isEmpty else {
            if activeTranscriptWordIndex != nil {
                activeTranscriptWordIndex = nil
            }
            return
        }
        let index = Self.transcriptWordIndex(
            at: clipTimeline.sourceTime(at: currentTime),
            in: transcriptWords
        )
        if activeTranscriptWordIndex != index {
            activeTranscriptWordIndex = index
        }
    }

    /// Last word started at or before this source time, if the time is
    /// still within it (with a small bridge across inter-word gaps so the
    /// highlight doesn't flicker between words).
    private static func transcriptWordIndex(
        at sourceTime: TimeInterval,
        in words: [RecordingTranscriptWord]
    ) -> Int? {
        guard sourceTime.isFinite, !words.isEmpty else { return nil }
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle].start <= sourceTime {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = low - 1
        guard index >= 0 else { return nil }
        return sourceTime <= words[index].end + 0.25 ? index : nil
    }

    /// Caption to draw over the card right now; nil when hidden or silent.
    /// Whether any clip plays faster than recorded.
    var hasSpedUpClips: Bool {
        !speedBadgeTimeline.isEmpty
    }

    func speedBadge(at time: TimeInterval) -> SpeedBadgeFrame? {
        guard showsSpeedBadge else { return nil }
        return speedBadgeTimeline.frame(at: time)
    }

    func keystrokeCaption(at time: TimeInterval) -> KeystrokeCaptionFrame? {
        guard showsKeystrokes, hasKeystrokes else { return nil }
        return keystrokeTimeline.frame(at: clipTimeline.sourceTime(at: time))
    }

    private var recordingPointSize: CGSize {
        let scale = max(CGFloat(manifest?.pixelScale ?? 1), 1)
        return CGSize(width: videoSize.width / scale, height: videoSize.height / scale)
    }

    // MARK: - Video crop

    var isVideoCropped: Bool {
        RecordingVideoCropGeometry.isCropped(videoCropRect)
    }

    var videoCropPixelSize: CGSize {
        let crop = isCroppingVideo ? workingVideoCropRect : videoCropRect
        return CGSize(
            width: (videoSize.width * crop.width).rounded(),
            height: (videoSize.height * crop.height).rounded()
        )
    }

    func beginVideoCrop() {
        guard !isCroppingVideo, videoSize.width > 0, videoSize.height > 0 else {
            return
        }
        pause()
        workingVideoCropRect = videoCropRect
        videoCropAspect = .freeform
        videoCropDrag = nil
        isCroppingVideo = true
    }

    func cancelVideoCrop() {
        guard isCroppingVideo else { return }
        workingVideoCropRect = videoCropRect
        videoCropAspect = .freeform
        videoCropDrag = nil
        isCroppingVideo = false
    }

    func resetVideoCrop() {
        guard isCroppingVideo else { return }
        if let ratio = videoCropAspect.pixelRatio(imageSize: videoSize) {
            workingVideoCropRect = normalizedVideoCrop(
                CropGeometry.snapped(CropGeometry.largest(aspect: ratio, in: videoCropBounds), in: videoCropBounds)
            )
        } else {
            workingVideoCropRect = CropGeometry.unit
        }
    }

    func setVideoCropAspect(_ aspect: CropAspectRatio) {
        videoCropAspect = aspect
        guard isCroppingVideo,
              let ratio = aspect.pixelRatio(imageSize: videoSize) else {
            return
        }
        workingVideoCropRect = normalizedVideoCrop(CropGeometry.snapped(
            CropGeometry.reshaped(pixelVideoCrop(workingVideoCropRect), aspect: ratio, in: videoCropBounds),
            in: videoCropBounds
        ))
    }

    /// Arrow keys: moves the selection by whole pixels.
    func nudgeVideoCrop(by delta: CGSize) {
        guard isCroppingVideo, videoCropDrag == nil else { return }
        workingVideoCropRect = normalizedVideoCrop(CropGeometry.snapped(
            CropGeometry.move(pixelVideoCrop(workingVideoCropRect), by: delta, in: videoCropBounds),
            in: videoCropBounds
        ))
    }

    // MARK: Crop dragging
    //
    // The same interaction as the screenshot editor's crop: the press is
    // hit-tested against the box as drawn, and every update re-applies the
    // pointer's total travel to the selection the drag started with.
    // Pointers arrive in view points over `videoFrame`, the uncropped video.

    var isVideoCropDragging: Bool { videoCropDrag != nil }

    func videoCropViewRect(in videoFrame: CGRect) -> CGRect {
        let crop = workingVideoCropRect.standardized
        return CGRect(
            x: videoFrame.minX + crop.minX * videoFrame.width,
            y: videoFrame.minY + crop.minY * videoFrame.height,
            width: crop.width * videoFrame.width,
            height: crop.height * videoFrame.height
        )
    }

    func videoCropTarget(at pointer: CGPoint, in videoFrame: CGRect) -> CropDragTarget {
        CropHitTest.target(at: pointer, box: videoCropViewRect(in: videoFrame))
    }

    func beginVideoCropDrag(at pointer: CGPoint, in videoFrame: CGRect) {
        guard isCroppingVideo, let point = videoCropPixelPoint(at: pointer, in: videoFrame) else { return }
        let target = videoCropTarget(at: pointer, in: videoFrame)
        videoCropDrag = CropDrag(
            target: target,
            startRect: pixelVideoCrop(workingVideoCropRect),
            startPoint: point,
            startPointer: pointer,
            pointer: pointer,
            hasTravelled: target != .newSelection
        )
    }

    func updateVideoCropDrag(to pointer: CGPoint, in videoFrame: CGRect) {
        guard var drag = videoCropDrag else { return }
        drag.pointer = pointer
        if !drag.hasTravelled {
            drag.hasTravelled = hypot(pointer.x - drag.startPointer.x, pointer.y - drag.startPointer.y) >= 3
        }
        videoCropDrag = drag
        guard drag.hasTravelled, let point = videoCropPixelPoint(at: pointer, in: videoFrame) else { return }

        let flags = NSEvent.modifierFlags
        workingVideoCropRect = normalizedVideoCrop(drag.rect(
            at: point,
            in: videoCropBounds,
            lockedAspect: videoCropAspect.pixelRatio(imageSize: videoSize),
            minimumSize: CGSize(width: min(24, videoSize.width), height: min(24, videoSize.height)),
            holdsAspect: flags.contains(.shift),
            fromCenter: flags.contains(.option)
        ))
    }

    func endVideoCropDrag() {
        videoCropDrag = nil
    }

    private func videoCropPixelPoint(at pointer: CGPoint, in videoFrame: CGRect) -> CGPoint? {
        guard videoFrame.width > 0, videoFrame.height > 0 else { return nil }
        return CGPoint(
            x: (pointer.x - videoFrame.minX) * videoSize.width / videoFrame.width,
            y: (pointer.y - videoFrame.minY) * videoSize.height / videoFrame.height
        )
    }

    /// The crop engine works in pixels so aspect ratios are exact; Studio
    /// stores its crop normalized to the video.
    private var videoCropBounds: CGRect { CGRect(origin: .zero, size: videoSize) }

    private func pixelVideoCrop(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * videoSize.width,
            y: rect.minY * videoSize.height,
            width: rect.width * videoSize.width,
            height: rect.height * videoSize.height
        )
    }

    private func normalizedVideoCrop(_ rect: CGRect) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return CropGeometry.unit }
        return CGRect(
            x: rect.minX / videoSize.width,
            y: rect.minY / videoSize.height,
            width: rect.width / videoSize.width,
            height: rect.height / videoSize.height
        )
    }

    func applyVideoCrop() {
        guard isCroppingVideo else { return }
        let next = RecordingVideoCropGeometry.normalized(workingVideoCropRect)
        isCroppingVideo = false
        videoCropAspect = .freeform
        workingVideoCropRect = next
        applyVideoCrop(next, actionName: "Crop Video")
    }

    private func applyVideoCrop(_ requested: CGRect, actionName: String) {
        let next = RecordingVideoCropGeometry.normalized(requested)
        guard next != videoCropRect else { return }
        let previous = videoCropRect
        registerUndo(actionName) { target in
            target.applyVideoCrop(previous, actionName: actionName)
        }
        videoCropRect = next
    }

    /// Whether any layout on the timeline can show the camera at all.
    /// No time gate: before cameraOffset the player is parked on the
    /// camera's first frame, which beats the camera popping in late.
    var showsCameraLayer: Bool {
        hasCameraVideo && style.camera.isVisible
    }

    // MARK: - Export

    private func makeExportConfiguration() -> RecordingStudioExporter.Configuration {
        let reframe = makeReframeTrack()
        let fitContentAspect: CGFloat? =
            (exportAspect == .original || exportAspectMode == .fit) && videoSize.height > 0
                ? videoSize.width / videoSize.height
                : nil
        return RecordingStudioExporter.Configuration(
            screenURL: screenURL,
            cameraURL: showsCameraLayer && cameraLayoutTimeline.usesCamera ? session?.cameraURL : nil,
            cameraOffset: cameraOffset,
            cameraAspect: cameraVideoAspect,
            style: style,
            cameraLayoutTimeline: cameraLayoutTimeline,
            viewportTimeline: zoomEnabled ? viewportTimeline : .identity,
            pointerTimeline: pointerIsSynthesized
                ? pointerTimeline.mappingArtwork {
                    $0.styled(style.cursorStyle, inverted: style.invertsCursor)
                }
                : nil,
            showsPressEffects: showsPressEffects,
            keystrokeTimeline: showsKeystrokes && hasKeystrokes ? keystrokeTimeline : nil,
            keystrokePlacement: keystrokePlacement,
            speedBadgeTimeline: showsSpeedBadge && !speedBadgeTimeline.isEmpty ? speedBadgeTimeline : nil,
            speedBadgePlacement: speedBadgePlacement,
            subtitleTimeline: showsSubtitles && hasSubtitles ? subtitleTimeline : nil,
            subtitleStyle: subtitleStyle,
            karaokeTimeline: showsSubtitles && hasSubtitles && !karaokeTimeline.isEmpty
                ? karaokeTimeline
                : nil,
            canvasSize: basePreviewCanvasSize,
            videoCropRect: videoCropRect,
            clipTimeline: clipTimeline,
            exportSettings: exportSettings,
            audioReplacementURL: replacementAudio?.url,
            audioVolume: Double(audioVolume),
            reframe: reframe,
            fitContentAspect: fitContentAspect,
            usesUniformPadding: exportAspect == .original,
            motionTimeline: makeMotionTimeline(reframe: reframe),
            textOverlays: textOverlays,
            redactions: redactions,
            imageOverlays: imageOverlays,
            audioClips: audioClips,
            mediaDirectory: mediaDirectoryURL
        )
    }

    /// Shared screen and camera motion, on the same canvas used by export.
    private func makeMotionTimeline(reframe: ReframeTrack?) -> RecordingStudioMotionTimeline {
        guard sourceDuration > 0 else { return .none }
        let fitContentAspect: CGFloat? =
            (exportAspect == .original || exportAspectMode == .fit) && videoSize.height > 0
                ? videoSize.width / videoSize.height
                : nil
        return RecordingStudioMotionTimeline.build(
            canvasSize: basePreviewCanvasSize,
            style: style,
            usesUniformPadding: exportAspect == .original,
            contentAspect: reframe?.sourceAspect ?? fitContentAspect,
            contentMode: fitContentAspect != nil && reframe == nil ? .fit : .fill,
            contentCropRect: videoCropRect,
            showsCamera: showsCameraLayer,
            cameraAspect: cameraVideoAspect,
            layoutTimeline: cameraLayoutTimeline,
            cues: zoomEnabled ? zoomCues : [],
            capture: pointerCapture,
            clipTimeline: clipTimeline
        )
    }

    private func rebuildMotionTimeline() {
        guard isLoaded else { return }
        motionTimeline = makeMotionTimeline(reframe: previewReframe)
    }

    /// The crop-and-follow camera for non-original aspect exports. Focus
    /// comes from the recorded pointer whenever the session captured one,
    /// whether or not the cursor is drawn synthetically.
    private func makeReframeTrack() -> ReframeTrack? {
        guard exportAspect != .original, exportAspectMode == .fill else { return nil }
        let focusTimeline = reframeFocusPointer()
        let effectiveViewport = zoomEnabled ? viewportTimeline : .identity
        return ReframeTrack.build(
            preset: exportAspect,
            sourceSize: videoSize,
            viewportTimeline: effectiveViewport,
            duration: duration
        ) { editorTime in
            focusTimeline?.location(at: editorTime)
        }
    }

    /// The focus source is immutable per session, so it resolves once.
    private func reframeFocusPointer() -> PointerTimeline? {
        if reframeFocusResolved { return reframeFocusTimeline }
        reframeFocusResolved = true
        if pointerIsSynthesized {
            reframeFocusTimeline = pointerTimeline
        } else if !pointerCapture.travel.isEmpty || !pointerCapture.presses.isEmpty {
            reframeFocusTimeline = PointerTimeline.build(
                capture: pointerCapture,
                duration: sourceDuration,
                recordingSizeInPoints: recordingPointSize,
                fallbackArtwork: PointerArtworkCapture.defaultArtwork(),
                clipTimeline: clipTimeline
            )
        }
        return reframeFocusTimeline
    }

    private func rebuildPreviewReframe() {
        guard isLoaded else { return }
        previewReframe = makeReframeTrack()
        motionTimeline = makeMotionTimeline(reframe: previewReframe)
    }

    // MARK: - Preview canvas

    /// What the Studio canvas shows: the target-aspect canvas when a
    /// non-original aspect is selected, the visible source plus padding otherwise.
    var basePreviewCanvasSize: CGSize {
        exportAspect == .original
            ? RecordingStudioLayout.originalCanvasSize(
                sourceSize: videoSize, style: style, contentCropRect: videoCropRect
            )
            : exportAspect.canvasSize(for: videoSize)
    }

    var previewCanvasSize: CGSize {
        if exportAspect == .original, isCroppingVideo {
            RecordingStudioLayout.originalCanvasSize(
                sourceSize: videoSize, style: style, contentCropRect: CropGeometry.unit
            )
        } else {
            basePreviewCanvasSize
        }
    }

    var sourceVideoAspect: CGFloat {
        videoSize.height > 0 ? videoSize.width / videoSize.height : 1
    }

    /// The source aspect remains independent of the padded canvas and video crop.
    var previewContentAspect: CGFloat? {
        guard videoSize.height > 0 else { return nil }
        return sourceVideoAspect
    }

    var previewVideoCropRect: CGRect {
        isCroppingVideo ? CropGeometry.unit : videoCropRect
    }

    /// How the content occupies the card on a target-aspect canvas.
    var previewContentMode: RecordingStudioLayout.ContentMode {
        exportAspect == .original || exportAspectMode == .fit ? .fit : .fill
    }

    /// Shared rendered viewport, with the uncomposed camera retained while
    /// the user edits the source crop.
    func previewViewportFrame(at time: TimeInterval) -> ViewportFrame {
        if !isCroppingVideo, let viewport = motionTimeline.viewport(at: time) { return viewport }
        let base = previewReframe?.frame(at: time) ?? viewportFrame(at: time)
        return RecordingVideoCropGeometry.viewport(base, crop: previewVideoCropRect)
    }

    /// The flattened deliverable when it provably matches the current
    /// in-memory edits - the render is stamped with the document that
    /// produced it. Both Export and Share can then skip the render entirely.
    private var freshDeliverableURL: URL? {
        // Measure the actual renderer during development comparisons, even
        // when this exact document already has a flattened deliverable.
        guard ProcessInfo.processInfo.environment["SCREENDROP_EXPORT_BYPASS_CACHE"] != "1" else { return nil }
        guard let session else { return nil }
        return session.freshFinalURL(matching: currentDocument())
    }

    private var exportSuggestedFileName: String {
        let container = exportSettings.effectiveContainer
        return session.map {
            $0.directoryURL
                .deletingPathExtension()
                .lastPathComponent
                .appending(".\(container.fileExtension)")
        } ?? VideoFileActions.exportFileName(for: screenURL, container: container)
    }

    /// Entry point for the export options popover. Assigning settings marks
    /// the project dirty and drops the cached render, so an unchanged
    /// confirmation must not touch them.
    func export(settings: VideoCompressionSettings) {
        if settings != exportSettings {
            exportSettings = settings
        }
        export()
    }

    func export() {
        // One render at a time: the share pipeline uses the same exporter,
        // so a second encode would just fight it for the media engine.
        guard !exportState.isExporting, !shareState.isBusy, isLoaded else { return }
        pause()
        let previewURL = sessionURL

        // A fresh deliverable (e.g. right after a share) is byte-identical
        // to what this render would produce - same configuration builds
        // both - so exporting becomes a plain copy into the save folder.
        if let cached = freshDeliverableURL {
            let suggestedFileName = exportSuggestedFileName
            exportTask = Task { [weak self] in
                do {
                    let savedURL = try await VideoFileActions.saveToDefaultLocation(
                        from: cached,
                        suggestedFileName: suggestedFileName
                    )
                    RecordingExportNotifier.notifySuccess(fileURL: savedURL)
                    RecordingExportNotifier.revealIfPreferred(fileURL: savedURL)
                    CaptureShelf.shared.dismissVideo(for: previewURL)
                    self?.exportState = .finished(savedURL)
                } catch {
                    self?.exportState = .failed(error.localizedDescription)
                }
            }
            return
        }

        exportState = .exporting(progress: 0)

        let configuration = makeExportConfiguration()
        let suggestedFileName = exportSuggestedFileName

        let dockProgressID = DockExportProgressCoordinator.shared.start()

        exportTask = Task { [weak self] in
            do {
                let exporter = RecordingStudioExporter()
                let temporaryURL = try await exporter.export(configuration) { progress in
                    Task { @MainActor [weak self] in
                        DockExportProgressCoordinator.shared.update(dockProgressID, progress: progress)
                        if self?.exportState.isExporting == true {
                            self?.exportState = .exporting(progress: progress)
                        }
                    }
                }
                let savedURL = try await VideoFileActions.saveToDefaultLocation(
                    from: temporaryURL,
                    suggestedFileName: suggestedFileName
                )
                try? FileManager.default.removeItem(at: temporaryURL)
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                RecordingExportNotifier.notifySuccess(fileURL: savedURL)
                RecordingExportNotifier.revealIfPreferred(fileURL: savedURL)
                CaptureShelf.shared.dismissVideo(for: previewURL)
                self?.exportState = .finished(savedURL)
            } catch is CancellationError {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.exportState = .idle
            } catch RecordingStudioExporter.ExportError.cancelled {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.exportState = .idle
            } catch {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
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

    // MARK: - Audio only

    /// True once there is a soundtrack to export or swap - the recording's
    /// own audio, or one already imported over it.
    var hasAudio: Bool {
        hasRecordedAudio || replacementAudio != nil
    }

    /// How far the imported soundtrack falls short of (or overruns) the
    /// edited timeline. Nil when there is nothing imported or the two
    /// agree closely enough to be the same take.
    var replacementAudioDrift: TimeInterval? {
        guard let replacementAudio else { return nil }
        let drift = replacementAudio.duration - duration
        return abs(drift) > 0.25 ? drift : nil
    }

    private var audioExportSuggestedFileName: String {
        let base = session.map {
            $0.directoryURL.deletingPathExtension().lastPathComponent
        } ?? screenURL.deletingPathExtension().lastPathComponent
        return "\(base).\(audioExportFormat.fileExtension)"
    }

    /// Writes the edited soundtrack on its own, for cleanup in a tool that
    /// has no API - the outbound half of the replace-audio round trip.
    func exportAudio() {
        guard !audioExportState.isExporting, isLoaded, hasAudio else { return }
        pause()

        audioExportState = .exporting(progress: 0)

        let configuration = RecordingAudioExporter.Configuration(
            screenURL: screenURL,
            clipTimeline: clipTimeline,
            replacementURL: replacementAudio?.url,
            format: audioExportFormat,
            volume: Double(audioVolume)
        )
        let suggestedFileName = audioExportSuggestedFileName
        let dockProgressID = DockExportProgressCoordinator.shared.start()

        audioExportTask = Task { [weak self] in
            do {
                let temporaryURL = try await RecordingAudioExporter().export(configuration) { progress in
                    Task { @MainActor [weak self] in
                        DockExportProgressCoordinator.shared.update(dockProgressID, progress: progress)
                        if self?.audioExportState.isExporting == true {
                            self?.audioExportState = .exporting(progress: progress)
                        }
                    }
                }
                let savedURL = try await VideoFileActions.saveToDefaultLocation(
                    from: temporaryURL,
                    suggestedFileName: suggestedFileName
                )
                try? FileManager.default.removeItem(at: temporaryURL)
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                RecordingExportNotifier.notifySuccess(fileURL: savedURL)
                RecordingExportNotifier.revealIfPreferred(fileURL: savedURL)
                self?.audioExportState = .finished(savedURL)
            } catch is CancellationError {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.audioExportState = .idle
            } catch {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.audioExportState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelAudioExport() {
        audioExportTask?.cancel()
        audioExportTask = nil
        if audioExportState.isExporting {
            audioExportState = .idle
        }
    }

    /// The inbound half: adopts a cleaned-up soundtrack as the project's
    /// audio. The file is copied into the session so the project keeps
    /// playing after the original is moved, and playback switches to it
    /// immediately rather than only revealing itself at export.
    func replaceAudio(with pickedURL: URL) {
        guard isLoaded else { return }
        pause()
        replacementAudioTask?.cancel()

        replacementAudioError = nil
        let displayName = pickedURL.lastPathComponent
        let storedURL: URL
        if let session {
            let destination = session.directoryURL
                .appendingPathComponent(RecordingSession.replacementAudioBaseName)
                .appendingPathExtension(pickedURL.pathExtension.isEmpty ? "m4a" : pickedURL.pathExtension)
            do {
                // Clear every previous import, whatever extension it had,
                // so the session never accumulates orphaned soundtracks.
                removeStoredReplacementAudio(in: session)
                try FileManager.default.copyItem(at: pickedURL, to: destination)
            } catch {
                replacementAudioError = "Could not import that file: \(error.localizedDescription)"
                clearReplacementAudio()
                return
            }
            storedURL = destination
        } else {
            // Bare movies have no project folder to copy into; they
            // reference the picked file where it sits.
            storedURL = pickedURL
        }

        replacementAudioTask = Task { [weak self] in
            let resolved = await RecordingReplacementAudio.load(
                url: storedURL,
                displayName: displayName
            )
            guard let self, !Task.isCancelled else { return }
            guard let resolved else {
                if let session = self.session {
                    self.removeStoredReplacementAudio(in: session)
                }
                self.replacementAudioError = "That file has no audio track."
                self.clearReplacementAudio()
                return
            }
            self.replacementAudio = resolved
            self.applyReplacementAudioToPlayback()
        }
    }

    func removeReplacementAudio() {
        guard replacementAudio != nil else { return }
        replacementAudioTask?.cancel()
        replacementAudioTask = nil
        pause()
        if let session {
            removeStoredReplacementAudio(in: session)
        }
        replacementAudioError = nil
        clearReplacementAudio()
    }

    /// Drops back to the recorded audio, whether that follows a removal or
    /// a failed import that already deleted the copy.
    private func clearReplacementAudio() {
        guard replacementAudio != nil else { return }
        replacementAudio = nil
        applyReplacementAudioToPlayback()
    }

    private func applyReplacementAudioToPlayback() {
        do {
            try rebuildScreenPlayerItem(preserving: currentTime)
        } catch {
            loadError = "Could not update the recording timeline: \(error.localizedDescription)"
        }
        scheduleProjectSave()
    }

    private func removeStoredReplacementAudio(in session: RecordingSession) {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: session.directoryURL.path
        )) ?? []
        for name in names
        where name.hasPrefix("\(RecordingSession.replacementAudioBaseName).") {
            try? FileManager.default.removeItem(
                at: session.directoryURL.appendingPathComponent(name)
            )
        }
    }

    // MARK: - Share to cloud

    var canShareToCloud: Bool {
        CloudUploader.shared.isConfigured
    }

    /// The Loom loop: render the current edits, cache the result as the
    /// session's flattened deliverable, upload it, and copy the share
    /// link - without leaving the Studio or touching a save panel.
    func shareToCloud(options: CloudUploadOptions) {
        guard !shareState.isBusy, !exportState.isExporting, isLoaded,
              canShareToCloud else {
            return
        }
        pause()
        // Flush the draft first so the deliverable-invalidation in the
        // debounced autosave can't race the file this render produces.
        projectSaveTask?.cancel()
        writeDraftNow()

        // A fresh deliverable (e.g. sharing again without edits) skips
        // the render and goes straight to upload.
        let cachedDeliverable = freshDeliverableURL
        let configuration = cachedDeliverable == nil ? makeExportConfiguration() : nil
        let session = session
        let renderedDocument = session == nil ? nil : currentDocument()
        shareState = cachedDeliverable == nil ? .rendering(progress: 0) : .uploading

        shareTask = Task { [weak self] in
            // Bare (session-less) videos upload straight from the render's
            // temp file; whatever happens, it must not outlive the share.
            var temporaryUploadURL: URL?
            defer {
                if let temporaryUploadURL {
                    try? FileManager.default.removeItem(at: temporaryUploadURL)
                }
            }
            do {
                let uploadURL: URL
                if let cachedDeliverable {
                    uploadURL = cachedDeliverable
                } else if let configuration {
                    // The render leg gets its own Dock entry; the upload
                    // leg's Dock progress is owned by CloudUploader, so
                    // the two never overlap.
                    let dockProgressID = DockExportProgressCoordinator.shared.start()
                    let temporaryURL: URL
                    do {
                        temporaryURL = try await RecordingStudioExporter().export(configuration) { progress in
                            Task { @MainActor [weak self] in
                                DockExportProgressCoordinator.shared.update(dockProgressID, progress: progress)
                                if case .rendering = self?.shareState {
                                    self?.shareState = .rendering(progress: progress)
                                }
                            }
                        }
                        DockExportProgressCoordinator.shared.finish(dockProgressID)
                    } catch {
                        DockExportProgressCoordinator.shared.finish(dockProgressID)
                        throw error
                    }
                    // From here the deferred cleanup owns the temp render;
                    // once it moves into the session the delete is a
                    // harmless no-op.
                    temporaryUploadURL = temporaryURL

                    // Session recordings keep the render as the flattened
                    // deliverable, so history, preview, and sidecar mapping
                    // all agree on what was shared.
                    if let session {
                        uploadURL = try session.installFinalVideo(
                            movingFrom: temporaryURL,
                            renderedFrom: renderedDocument
                        )
                    } else {
                        uploadURL = temporaryURL
                    }
                } else {
                    return
                }

                guard let self, !Task.isCancelled else { return }
                self.shareState = .uploading
                let itemID = self.historyItemID(for: session) ?? UUID()
                self.shareItemID = itemID
                let result = try await CloudUploader.shared.upload(
                    itemID: itemID,
                    fileURL: uploadURL,
                    title: options.trimmedTitleOrNil,
                    socialEnabled: options.socialEnabled
                )

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.url, forType: .string)
                if session != nil {
                    ScreenshotHistoryStore.shared.setCloudURL(for: uploadURL, cloudURL: result.url)
                }
                CaptureShelf.shared.dismissVideo(for: self.sessionURL)
                self.shareState = .finished(result.url)
            } catch is CancellationError {
                self?.shareState = .idle
            } catch RecordingStudioExporter.ExportError.cancelled {
                self?.shareState = .idle
            } catch {
                self?.shareState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelShare() {
        shareTask?.cancel()
        shareTask = nil
        if let shareItemID {
            CloudUploader.shared.cancelUpload(for: shareItemID)
        }
        if shareState.isBusy {
            shareState = .idle
        }
    }

    /// History item for this session, so the share upload's progress and
    /// resulting link also appear on the preview card.
    private func historyItemID(for session: RecordingSession?) -> UUID? {
        guard let session else { return nil }
        let standardizedPath = session.directoryURL.standardizedFileURL.path
        return ScreenshotHistoryStore.shared.items
            .first { $0.recordingSessionPath == standardizedPath }?
            .id
    }
}

/// A zoom cue's single merged footprint on the edited timeline.
struct RecordingZoomTimelineBlock: Identifiable, Equatable, Sendable {
    let cue: ZoomCue
    let editorStart: TimeInterval
    let editorEnd: TimeInterval

    var id: UUID {
        cue.id
    }
}
