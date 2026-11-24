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
    private(set) var subtitleTimeline = SubtitleTimeline.empty {
        didSet { refreshPlayheadMarks() }
    }
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
    /// Sound under the video, on audio lanes on the edited video's clock.
    /// Linked clips are cut with the video above them; the rest keep their
    /// place (`StudioAudioConform`).
    private(set) var audioClips: [RecordingAudioClip] = []
    /// The audio clip the inspector shows: the last one clicked.
    var selectedAudioClipID: UUID? {
        didSet {
            // Picking one clip on its own drops the rest of a multiple
            // selection; extending a selection sets both.
            if let selectedAudioClipID {
                if !selectedAudioClipIDs.contains(selectedAudioClipID) { selectedAudioClipIDs = [selectedAudioClipID] }
            } else {
                selectedAudioClipIDs = []
            }
        }
    }
    /// Every selected audio clip; ⇧- or ⌘-click adds to it. Move, delete,
    /// mute and link act on all of them.
    private(set) var selectedAudioClipIDs: Set<UUID> = []
    /// A stretch of the edited video marked with I and O, for deleting
    /// the stretch in one go.
    var rangeSelection: ClosedRange<TimeInterval>?
    /// Moments flagged with M, on the source clock so they follow the
    /// footage through cuts.
    private(set) var markers: [RecordingMarker] = []
    /// A short word shown over the picture when a key does something
    /// that is otherwise hard to see ("Muted", "2×").
    private(set) var notice: StudioNotice?
    private var noticeTask: Task<Void, Never>?
    /// One frame of the recording, for frame stepping and timecode.
    private(set) var frameDuration: TimeInterval = 1.0 / 30
    /// Decoded overlay images, shared with the canvas.
    let overlayImages = RecordingOverlayImageStore()
    /// Moves on when an overlay image finishes decoding, so the canvas
    /// draws it.
    private(set) var overlayImageRevision = 0
    /// Waveform outlines of the audio files, by file name, and of the
    /// recording's own audio and the soundtrack replacing it under
    /// `recordingPeaksKey` and `soundtrackPeaksKey`.
    private(set) var audioPeaks: [String: [Float]] = [:]
    static let recordingPeaksKey = "\u{1}recording"
    static let soundtrackPeaksKey = "\u{1}soundtrack"
    /// Why the last media import was turned down, if it was.
    var mediaImportError: String?
    private(set) var clipTimeline = RecordingClipTimeline(segments: []) {
        didSet {
            if clipTimeline != oldValue {
                speedBadgeTimeline = SpeedBadgeTimeline(clipTimeline: clipTimeline)
                refreshPlayheadMarks()
            }
        }
    }
    /// Where the cut plays faster than recorded, for the speed badge.
    private(set) var speedBadgeTimeline = SpeedBadgeTimeline.empty
    var selectedClipID: UUID?
    var timelineHoverTime: TimeInterval?
    /// A block or a clip edge is being dragged on the timeline. The preview
    /// stays on the playhead meanwhile.
    var isDraggingTimelineBlock = false
    /// An audio clip is being moved; the audio lanes keep a spare row to
    /// drag it into. Only audio grows the lanes, so dragging a zoom or text
    /// block never changes the dock's height.
    var isMovingAudioClip = false {
        didSet {
            if isMovingAudioClip, !oldValue { laneCountAtDragStart = usedAudioLaneCount }
        }
    }
    private var laneCountAtDragStart = 1
    /// A video clip's edge is being dragged; the preview shows the frame
    /// at that edge rather than skimming.
    var isTrimmingClip = false
    /// Storyboard tiles for the clip lane, sampled on demand at whatever
    /// density the lane's current zoom needs.
    let timelineThumbnails = RecordingTimelineThumbnailStore()

    private(set) var isPlaying = false
    var currentTime: TimeInterval = 0 {
        didSet {
            if currentTime != oldValue { refreshPlayheadMarks() }
        }
    }
    /// The clip and the subtitle under the playhead. Stored, and assigned
    /// only when the playhead crosses into another one, so the inspector
    /// and the tool row that show them are not redrawn on every 20 ms
    /// playback tick the way a read of `currentTime` would redraw them.
    private(set) var playheadClipID: UUID?
    private(set) var activeSubtitleCueID: UUID?
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

    /// Everything that should be heard right now, for the composer.
    private var audioPlan: StudioAudioPlan {
        StudioAudioPlan(
            timeline: clipTimeline,
            sync: replacementAudio == nil ? nil : replacementAudioSync,
            clips: audioClips,
            volume: Double(audioVolume)
        )
    }

    /// Levels and fades only change the mix; the player item stays.
    private func updatePlaybackVolume() {
        guard let item = screenPlayer.currentItem else { return }
        item.audioMix = StudioAudioComposer.mix(for: playbackAudioLayout, plan: audioPlan)
    }

    /// Format the audio-only export writes.
    var audioExportFormat: RecordingAudioFormat = .m4a {
        didSet { scheduleProjectSave() }
    }
    /// Mixes the audio lanes into the audio-only export. Off by default,
    /// so the cleanup round trip never bakes music into the replacement.
    var audioExportIncludesClips = false
    /// The soundtrack standing in for the recording's own audio, resolved
    /// so both playback and export can use it without reloading tracks.
    private(set) var replacementAudio: RecordingReplacementAudio?
    /// How that soundtrack lines up with the recording. It is what lets a
    /// cut of the video cut the soundtrack in the same place.
    private(set) var replacementAudioSync: RecordingAudioSync?
    /// Every soundtrack and media file this editor has used since it
    /// opened. Undo can bring any of them back, so cleaning up after a save
    /// leaves them alone until the editor closes.
    private var undoReferencedFiles = Set<String>()
    private var soundtrackOffsetSnapshot: TimeInterval?
    private var soundtrackOffsetTask: Task<Void, Never>?
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
    /// What each edit still waiting on its pause will be called in Undo.
    private var pendingActionNames: [String: String] = [:]
    /// Every audio track the project plays, resolved once so the player
    /// item can be rebuilt synchronously.
    private var audioSources = StudioAudioSources()
    /// Where the playback composition put each sound, for the mix.
    private var playbackAudioLayout = StudioAudioLayout()
    /// What the playback composition was built for; a plan that places
    /// sound differently needs a new one.
    private var playbackAudioPlacement: StudioAudioPlan?
    /// Playback speed and direction for J/K/L shuttling; 1 plays normally.
    private(set) var shuttleRate: Float = 1
    private var clipSoundSnapshot: RecordingClipTimeline?
    private var clipSoundCoalesceTask: Task<Void, Never>?
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
                let (naturalSize, frameRate) = try await videoTrack.load(.naturalSize, .nominalFrameRate)
                guard !isTornDown, !Task.isCancelled else { return }
                if frameRate.isFinite, frameRate >= 1 {
                    frameDuration = 1 / Double(frameRate)
                }
                if naturalSize.width > 0, naturalSize.height > 0 {
                    videoSize = naturalSize
                }
            }
            audioSources.recording = await StudioAudioSources.Track.loadAll(of: asset)
            guard !isTornDown, !Task.isCancelled else { return }
            hasRecordedAudio = !audioSources.recording.isEmpty
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
                adoptReplacementAudio(loadedAudio, sync: document?.replacementAudioSync)
            }
        }
        // Lanes are kept tidy on every edit; do the same for what was stored.
        audioClips = StudioAudioConform.resolvingLanes(audioClips.map { $0.sanitized() })
        if hasRecordedAudio {
            loadPeaks(for: Self.recordingPeaksKey, url: screenURL)
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
        markers = (document.markers ?? []).sorted { $0.sourceTime < $1.sourceTime }
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
        replacementAudioSync = nil
        audioSources = StudioAudioSources()
        playbackAudioLayout = StudioAudioLayout()
        playbackAudioPlacement = nil
        clipSoundCoalesceTask?.cancel()
        clipSoundSnapshot = nil
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
        markers.removeAll()
        rangeSelection = nil
        noticeTask?.cancel()
        soundtrackOffsetTask?.cancel()
        audioPeaks.removeAll()
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
        shuttleRate = 1
        startPlayback()
    }

    private func startPlayback() {
        if hoverPreviewTime != nil {
            hoverPreviewTime = nil
        }
        guard duration >= RecordingClipSegment.minimumDuration else { return }
        if shuttleRate > 0, currentTime < 0 || currentTime >= duration - 0.05 {
            seek(to: 0)
        } else if shuttleRate < 0, currentTime <= 0.05 {
            seek(to: duration)
        }
        isPlaying = true
        screenPlayer.rate = shuttleRate
        syncCameraPlayback()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        shuttleRate = 1
        screenPlayer.pause()
        cameraPlayer.pause()
    }

    /// J/K/L. Forward plays, and each further press doubles the speed up
    /// to 8x; backward does the same in reverse. Turning around starts
    /// again from normal speed.
    func shuttle(forward: Bool) {
        guard isLoaded else { return }
        let direction: Float = forward ? 1 : -1
        if !forward, screenPlayer.currentItem?.canPlayReverse != true {
            // Nothing to play backward: step back a second instead.
            pause()
            seek(to: currentTime - 1)
            return
        }
        if isPlaying, shuttleRate * direction > 0 {
            shuttleRate = direction * min(abs(shuttleRate) * 2, 8)
            screenPlayer.rate = shuttleRate
            syncCameraPlayback()
        } else {
            if isPlaying {
                screenPlayer.pause()
                cameraPlayer.pause()
                isPlaying = false
            }
            shuttleRate = direction
            startPlayback()
        }
        showNotice(Self.shuttleTitle(shuttleRate))
    }

    /// "2×", "◀ 1×".
    static func shuttleTitle(_ rate: Float) -> String {
        let speed = RecordingClipSegment.speedTitle(Double(abs(rate)))
        return rate < 0 ? "◀ \(speed)" : speed
    }

    /// Moves the paused playhead by whole frames of the recording.
    func stepFrames(_ count: Int) {
        pause()
        seek(to: currentTime + Double(count) * frameDuration)
    }

    /// Shows a word over the picture for a moment.
    func showNotice(_ text: String) {
        notice = StudioNotice(text: text)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Every moment worth stopping at: the video's cuts, the ends of the
    /// audio clips, and markers.
    private var editPoints: [TimeInterval] {
        var points = clipTimeline.editPoints
        for clip in audioClips {
            points.append(clip.start)
            points.append(clip.end)
        }
        points.append(contentsOf: markerEditorTimes.map(\.time))
        return points.filter { $0 >= 0 && $0 <= duration }.sorted()
    }

    // MARK: Range

    /// I and O: mark where a stretch starts and ends.
    func markRange(_ edge: TrimEdge) {
        let time = currentTime
        let current = rangeSelection
        switch edge {
        case .start:
            let end = current.map { max($0.upperBound, time) } ?? duration
            rangeSelection = time...max(time, end)
        case .end:
            let start = current.map { min($0.lowerBound, time) } ?? 0
            rangeSelection = min(start, time)...time
        }
        if let range = rangeSelection, range.upperBound - range.lowerBound < RecordingClipSegment.minimumDuration {
            // An in point at the end and nothing marked out yet: wait for O.
            if edge == .start { rangeSelection = time...duration }
        }
    }

    func clearRange() {
        rangeSelection = nil
    }

    /// Removes the marked stretch of video, everything after closing up.
    /// Linked audio goes with it, as with any cut.
    func deleteRange() {
        guard let range = rangeSelection else { return }
        guard let next = clipTimeline.removingEditorRange(range) else {
            showNotice("Can't remove the whole video")
            return
        }
        rangeSelection = nil
        applyClipTimeline(
            next,
            selectedID: nil,
            selectsClip: false,
            playheadTime: range.lowerBound,
            actionName: "Delete Range"
        )
    }

    // MARK: Markers

    /// Markers that still have footage in the cut, at their edited time.
    var markerEditorTimes: [(marker: RecordingMarker, time: TimeInterval)] {
        markers.compactMap { marker in
            clipTimeline.editorTime(forSourceTime: marker.sourceTime).map { (marker, $0) }
        }
    }

    /// M: a marker at the playhead, or off again if one is already there.
    func toggleMarker() {
        guard isLoaded else { return }
        let tolerance = max(frameDuration, 0.02)
        if let existing = markerEditorTimes.first(where: { abs($0.time - currentTime) <= tolerance }) {
            applyMarkers(markers.filter { $0.id != existing.marker.id }, actionName: "Remove Marker")
            showNotice("Marker Removed")
        } else {
            let marker = RecordingMarker(sourceTime: clipTimeline.sourceTime(at: currentTime))
            applyMarkers(markers + [marker], actionName: "Add Marker")
            showNotice("Marker")
        }
    }

    func removeMarker(id: UUID) {
        applyMarkers(markers.filter { $0.id != id }, actionName: "Remove Marker")
    }

    private func applyMarkers(_ next: [RecordingMarker], actionName: String) {
        let sorted = next.sorted { $0.sourceTime < $1.sourceTime }
        guard sorted != markers else { return }
        let previous = markers
        registerUndo(actionName) { target in
            target.applyMarkers(previous, actionName: actionName)
        }
        markers = sorted
        scheduleProjectSave()
    }

    /// Jumps the playhead to the next or previous cut.
    func seekToEditPoint(forward: Bool) {
        let points = editPoints
        let target = forward
            ? points.first { $0 > currentTime + 0.01 } ?? duration
            : points.last { $0 < currentTime - 0.01 } ?? 0
        pause()
        seek(to: target)
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
                    if self.shuttleRate < 0, seconds <= 0.001 {
                        self.pause()
                        self.seek(to: 0)
                        return
                    }
                    if self.shuttleRate > 0, seconds >= self.duration - 0.001 {
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
                self.shuttleRate = 1
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
        selectedAudioClipIDs = []
        selectedCueID = nil
        selectedClipID = nil
        selectedLayoutCueID = nil
        selectedTextID = nil
        selectedRedactionID = nil
        selectedImageID = nil
        selectedAudioClipID = nil
    }

    /// Registers slider sweeps and typing that are still waiting for their
    /// pause before landing as an undo step, so undo, save and structural
    /// edits never act past them.
    func flushPendingEdits() {
        textCoalesceTask?.cancel()
        redactionCoalesceTask?.cancel()
        imageCoalesceTask?.cancel()
        audioCoalesceTask?.cancel()
        clipSoundCoalesceTask?.cancel()
        let names = pendingActionNames
        pendingActionNames = [:]
        endTextEdit(actionName: names["text"] ?? "Edit Text")
        endRedactionEdit(actionName: names["redaction"] ?? "Edit Pixelate")
        endImageEdit(actionName: names["image"] ?? "Edit Image")
        endAudioClipEdit(actionName: names["audio"] ?? "Edit Audio")
        endClipSoundEdit(actionName: names["clipSound"] ?? "Change Clip Volume")
        endSoundtrackOffsetEdit()
    }

    func undo() {
        flushPendingEdits()
        guard editUndoManager.canUndo else { return }
        pause()
        editUndoManager.undo()
        undoRevision &+= 1
    }

    func redo() {
        flushPendingEdits()
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

    // MARK: Blade and trim

    /// The blade. With an audio clip selected under the playhead it cuts
    /// that clip; otherwise it cuts the video, and `everything` cuts the
    /// video and every audio clip under the playhead in one step.
    func blade(at editorTime: TimeInterval, everything: Bool = false) {
        guard isLoaded else { return }
        let time = min(max(editorTime, 0), duration)
        if !everything, let clip = selectedAudioClip, clip.start < time, time < clip.end {
            guard let halves = StudioAudioConform.split(clip, at: time) else {
                showNotice("Too close to the end of the clip")
                return
            }
            applyAudioClips(
                audioClips.flatMap { $0.id == clip.id ? [halves.leading, halves.trailing] : [$0] },
                actionName: "Split Audio"
            )
            selectAudioClip(id: halves.trailing.id)
            return
        }

        let video = clipTimeline.split(at: time)
        if video == nil, !everything {
            showNotice(clipTimeline.editPoints.contains { abs($0 - time) < 0.01 } ? "Already a cut here" : "Too close to a cut")
            return
        }
        var audio: [RecordingAudioClip]?
        if everything {
            let cut = audioClips.flatMap { clip -> [RecordingAudioClip] in
                guard let halves = StudioAudioConform.split(clip, at: time) else { return [clip] }
                return [halves.leading, halves.trailing]
            }
            if cut != audioClips { audio = cut }
        }
        guard video != nil || audio != nil else { return }
        applyClipTimeline(
            video?.timeline ?? clipTimeline,
            audio: audio,
            selectedID: video?.selectedID ?? selectedClipID,
            selectsClip: video != nil || selectedClipID != nil,
            playheadTime: time,
            actionName: everything ? "Split All" : "Split Clip"
        )
    }

    enum TrimEdge {
        case start
        case end
    }

    /// Trims to the playhead: the selected audio clip when the playhead is
    /// inside it, otherwise the video clip under the playhead. Everything
    /// after closes up, and linked audio is trimmed with the video.
    func trimToPlayhead(_ edge: TrimEdge) {
        guard isLoaded else { return }
        let time = currentTime
        if let clip = selectedAudioClip, let halves = StudioAudioConform.split(clip, at: time) {
            var kept = edge == .start ? halves.trailing : halves.leading
            kept.id = clip.id
            if edge == .start { kept.fadeIn = clip.fadeIn } else { kept.fadeOut = clip.fadeOut }
            applyAudioClips(
                audioClips.map { $0.id == clip.id ? kept : $0 },
                actionName: edge == .start ? "Trim Audio Start" : "Trim Audio End"
            )
            return
        }
        guard let location = clipTimeline.location(at: time) else { return }
        var segment = clipTimeline.segments[location.segmentIndex]
        let minimum = RecordingClipSegment.minimumDuration
        switch edge {
        case .start:
            guard segment.sourceEnd - location.sourceTime >= minimum,
                  location.sourceTime - segment.sourceStart > 0.001 else { return }
            segment.sourceStart = location.sourceTime
        case .end:
            guard location.sourceTime - segment.sourceStart >= minimum,
                  segment.sourceEnd - location.sourceTime > 0.001 else { return }
            segment.sourceEnd = location.sourceTime
        }
        let next = clipTimeline.replacing(segment)
        applyClipTimeline(
            next,
            selectedID: segment.id,
            // Either way the playhead ends on the new cut.
            playheadTime: edge == .start ? location.editorStart : time,
            actionName: edge == .start ? "Trim Start" : "Trim End"
        )
    }

    // MARK: Clip sound

    /// The clip a sound command applies to: the selected one, else the one
    /// under the playhead.
    var soundTargetClip: RecordingClipSegment? {
        selectedClip ?? clipTimeline.segment(at: currentTime)
    }

    /// Changes a clip's own level or mute. Only the mix changes, so the
    /// player keeps playing; a slider sweep undoes as one step.
    func editClipSound(id: UUID, actionName: String, _ change: (inout RecordingClipSegment) -> Void) {
        guard var segment = clipTimeline.segments.first(where: { $0.id == id }) else { return }
        change(&segment)
        segment.volume = min(
            max(segment.volume, RecordingClipSegment.volumeRange.lowerBound),
            RecordingClipSegment.volumeRange.upperBound
        )
        let next = clipTimeline.replacing(segment)
        guard next != clipTimeline else { return }
        if clipSoundSnapshot == nil { clipSoundSnapshot = clipTimeline }
        setClipSound(next)
        pendingActionNames["clipSound"] = actionName
        clipSoundCoalesceTask?.cancel()
        clipSoundCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.endClipSoundEdit(actionName: actionName)
        }
    }

    private func endClipSoundEdit(actionName: String) {
        guard let previous = clipSoundSnapshot else { return }
        clipSoundSnapshot = nil
        guard previous != clipTimeline else { return }
        registerClipSoundUndo(previous, actionName: actionName)
    }

    private func registerClipSoundUndo(_ previous: RecordingClipTimeline, actionName: String) {
        registerUndo(actionName) { target in
            let current = target.clipTimeline
            // Only sound is restored: the clips themselves may not match
            // any more if this is replayed out of order.
            guard current.segments.map(\.id) == previous.segments.map(\.id) else { return }
            target.registerClipSoundUndo(current, actionName: actionName)
            target.setClipSound(previous)
        }
    }

    private func setClipSound(_ timeline: RecordingClipTimeline) {
        clipTimeline = timeline
        updatePlaybackVolume()
        scheduleProjectSave()
    }

    func toggleClipMuted(id: UUID) {
        guard let segment = clipTimeline.segments.first(where: { $0.id == id }) else { return }
        editClipSound(id: id, actionName: segment.isMuted ? "Unmute Clip" : "Mute Clip") {
            $0.isMuted.toggle()
        }
        clipSoundCoalesceTask?.cancel()
        pendingActionNames["clipSound"] = nil
        endClipSoundEdit(actionName: segment.isMuted ? "Unmute Clip" : "Mute Clip")
        showNotice(segment.isMuted ? "Clip Unmuted" : "Clip Muted")
    }

    /// True when the clip still plays its own sound, so there is something
    /// to detach.
    func canDetachAudio(fromClipID id: UUID) -> Bool {
        guard hasAudio, let segment = clipTimeline.segments.first(where: { $0.id == id }) else { return false }
        return !segment.isMuted
    }

    /// Lifts a clip's own sound off its picture onto an audio lane, where
    /// it can be trimmed, moved, split and faded on its own. The new audio
    /// clip stays linked to the video, so later cuts still cut both; the
    /// clip's own sound is muted in its place.
    func detachAudio(fromClipID id: UUID) {
        guard canDetachAudio(fromClipID: id),
              let index = clipTimeline.segments.firstIndex(where: { $0.id == id }),
              let editorRange = clipTimeline.editorRange(for: id) else { return }
        var segment = clipTimeline.segments[index]
        let speed = max(segment.speed, RecordingClipSegment.minimumSpeed)
        let lane = (audioClips.map(\.lane).max() ?? -1) + 1

        func piece(
            _ source: RecordingAudioClip.Source,
            name: String,
            sourceStart: TimeInterval,
            sourceEnd: TimeInterval,
            fileStart: TimeInterval,
            fileEnd: TimeInterval,
            fileDuration: TimeInterval
        ) -> RecordingAudioClip? {
            let length = (sourceEnd - sourceStart) / speed
            guard length >= RecordingAudioClip.minimumDuration, fileEnd > fileStart else { return nil }
            var clip = RecordingAudioClip(
                fileName: "",
                displayName: name,
                start: editorRange.lowerBound + (sourceStart - segment.sourceStart) / speed,
                fileDuration: max(fileDuration, fileEnd)
            )
            clip.source = source
            clip.trimStart = fileStart
            clip.trimEnd = fileEnd
            clip.speed = (fileEnd - fileStart) / length
            clip.volume = min(segment.volume, RecordingAudioClip.volumeRange.upperBound)
            clip.isLinked = true
            clip.lane = lane
            return clip
        }

        var detached: [RecordingAudioClip] = []
        var cursor = segment.sourceStart
        func recorded(to end: TimeInterval) {
            guard hasRecordedAudio, end - cursor > 0.01,
                  let clip = piece(.recording, name: "\(projectDisplayName) audio",
                                   sourceStart: cursor, sourceEnd: end,
                                   fileStart: cursor, fileEnd: end,
                                   fileDuration: sourceDuration) else { return }
            detached.append(clip)
        }
        if let replacementAudio, let sync = replacementAudioSync {
            for part in sync.pieces(from: segment.sourceStart, to: segment.sourceEnd, fileDuration: replacementAudio.duration) {
                recorded(to: part.sourceStart)
                if let clip = piece(.replacement, name: replacementAudio.displayName,
                                    sourceStart: part.sourceStart, sourceEnd: part.sourceEnd,
                                    fileStart: part.fileStart, fileEnd: part.fileEnd,
                                    fileDuration: replacementAudio.duration) {
                    detached.append(clip)
                }
                cursor = part.sourceEnd
            }
        }
        recorded(to: segment.sourceEnd)
        guard !detached.isEmpty else { return }

        segment.isMuted = true
        clearTimelineSelection()
        applyClipTimeline(
            clipTimeline.replacing(segment),
            audio: audioClips + detached,
            selectedID: nil,
            selectsClip: false,
            playheadTime: currentTime,
            actionName: "Detach Audio"
        )
        selectedAudioClipID = detached.first?.id
    }

    /// Puts a clip at another place in the list. The zoom and pointer land
    /// on cuts that jump back in the recording rather than easing across;
    /// linked audio moves with its picture.
    func moveClip(id: UUID, to index: Int) {
        guard let next = clipTimeline.moving(segmentID: id, to: index) else { return }
        let playhead = next.editorRange(for: id)?.lowerBound ?? currentTime
        applyClipTimeline(
            next,
            selectedID: id,
            playheadTime: playhead,
            actionName: "Move Clip"
        )
    }

    /// Plays the clip's recording moment in the preview while its edge is
    /// dragged, when that moment is in the cut; nil hands back to the
    /// playhead.
    func previewSourceTime(_ time: TimeInterval?) {
        guard let time else {
            hoverPreviewTime = nil
            return
        }
        if let editor = clipTimeline.editorTime(forSourceTime: time) {
            hoverPreviewTime = editor
        }
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

    /// The one way the video's clips change. The audio clips change with
    /// them in the same undo step: `audio` when the edit says exactly what
    /// they become, otherwise whatever carrying them through the edit
    /// gives (linked clips are cut with the video, the rest keep their
    /// place).
    private func applyClipTimeline(
        _ requestedTimeline: RecordingClipTimeline,
        audio requestedAudio: [RecordingAudioClip]? = nil,
        selectedID: UUID?,
        selectsClip: Bool = true,
        playheadTime: TimeInterval,
        actionName: String,
        hoverTime: TimeInterval? = nil
    ) {
        flushPendingEdits()
        let next = requestedTimeline.normalized(to: sourceDuration)
        guard !next.segments.isEmpty else { return }
        let nextAudio = requestedAudio.map { StudioAudioConform.resolvingLanes($0) }
            ?? StudioAudioConform.conform(audioClips, from: clipTimeline, to: next)
        guard next != clipTimeline || nextAudio != audioClips else { return }

        let previousTimeline = clipTimeline
        let previousAudio = audioClips
        let previousSelection = selectedClipID
        let hadSelection = selectedClipID != nil
        let previousTime = currentTime
        registerUndo(actionName) { target in
            target.applyClipTimeline(
                previousTimeline,
                audio: previousAudio,
                selectedID: previousSelection,
                selectsClip: previousSelection != nil,
                playheadTime: previousTime,
                actionName: actionName
            )
        }

        pause()
        hoverPreviewTime = nil
        timelineHoverTime = nil
        clipTimeline = next
        audioClips = nextAudio
        duration = next.duration
        if let selectedAudioClipID, !nextAudio.contains(where: { $0.id == selectedAudioClipID }) {
            self.selectedAudioClipID = nil
        }
        if selectsClip {
            // The clip asked for; failing that, whatever is under the new
            // playhead, but only when a clip was selected to begin with.
            // Never the first clip: undoing an edit near the end must not
            // hand the inspector and Delete a clip far away.
            let clamped = min(max(playheadTime, 0), next.duration)
            selectedClipID = selectedID.flatMap { id in
                next.segments.contains(where: { $0.id == id }) ? id : nil
            } ?? (hadSelection ? next.location(at: clamped)?.segmentID : nil)
        } else {
            selectedClipID = nil
        }
        // Both motion timelines integrate along editor time, so a cut, trim,
        // or speed change invalidates them even when their source data did not
        // change. A change to a clip's sound alone leaves them be.
        if Self.motionShape(of: next) != Self.motionShape(of: previousTimeline) {
            rebuildPointerTimeline()
            rebuildViewportTimeline()
        }

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

    /// What the motion timelines depend on: the clips' ranges and speeds.
    private static func motionShape(of timeline: RecordingClipTimeline) -> [Double] {
        timeline.segments.flatMap { [$0.sourceStart, $0.sourceEnd, $0.speed] }
    }

    private func rebuildScreenPlayerItem(preserving editorTime: TimeInterval) throws {
        guard let screenAsset else { return }
        let composedAsset: AVAsset
        if let screenVideoTrack {
            // The cut's picture, then all of its sound: each clip's own
            // audio cut where the picture is, and the audio lanes.
            let composition = try RecordingCompositionBuilder.makeVideoComposition(
                videoTrack: screenVideoTrack,
                timeline: clipTimeline
            )
            let plan = audioPlan
            playbackAudioLayout = StudioAudioComposer.add(plan, sources: audioSources, to: composition)
            playbackAudioPlacement = plan.placement
            composedAsset = composition
        } else {
            playbackAudioLayout = StudioAudioLayout()
            playbackAudioPlacement = nil
            composedAsset = screenAsset
        }
        let item = AVPlayerItem(asset: composedAsset)
        // Sped-up speech keeps its pitch, as it does in the export.
        item.audioTimePitchAlgorithm = .timeDomain
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
        let rate = Float(speed(atEditorTime: currentTime)) * shuttleRate
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
        let targetRate = Float(speed(atEditorTime: currentTime)) * shuttleRate
        if abs(cameraPlayer.rate - targetRate) > 0.01 {
            cameraPlayer.rate = targetRate
        }
        let expected = sourceTime - cameraOffset
        let actual = cameraPlayer.currentTime().seconds
        guard expected.isFinite, actual.isFinite else { return }
        if abs(expected - actual) > 0.12 * Double(max(1, abs(shuttleRate))) {
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
        pendingActionNames["text"] = actionName
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
        pendingActionNames["redaction"] = actionName
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
        let asset = AVURLAsset(url: storedURL)
        let tracks = Array(await StudioAudioSources.Track.loadAll(of: asset).prefix(1))
        guard !tracks.isEmpty,
              let fileDuration = try? await asset.load(.duration).seconds,
              fileDuration.isFinite, fileDuration >= RecordingAudioClip.minimumDuration, !isTornDown else {
            try? FileManager.default.removeItem(at: storedURL)
            return nil
        }
        audioSources.files[fileName] = tracks
        undoReferencedFiles.insert(fileName)
        loadPeaks(for: fileName, url: storedURL)
        // A file dropped right at the end starts from the top instead of
        // landing past everything.
        // Dropped at the very end, it ends there instead of starting past
        // everything.
        let start = time > duration - 0.5
            ? max(0, duration - min(fileDuration, duration))
            : max(0, time)
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
            guard let self else { return }
            // A soundtrack replaced while this one was being read must not
            // have its outline taken over by the old file's.
            if fileName == Self.soundtrackPeaksKey, self.replacementAudio?.url != url { return }
            self.audioPeaks[fileName] = peaks
        }
    }

    /// Decodes a project's overlay images and resolves its audio files in
    /// the background after it opens; the canvas and player pick them up as
    /// they arrive.
    private func loadOverlayMedia() {
        mediaLoadTask?.cancel()
        guard let directory = mediaDirectoryURL, !imageOverlays.isEmpty || !audioClips.isEmpty else { return }
        let imageFiles = Set(imageOverlays.map(\.fileName))
        undoReferencedFiles.formUnion(imageFiles)
        undoReferencedFiles.formUnion(audioClips.filter { $0.source == .file }.map(\.fileName))
        let audioFiles = Set(audioClips.filter { $0.source == .file }.map(\.fileName))
            .subtracting(audioSources.files.keys)
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
                let tracks = Array(await StudioAudioSources.Track.loadAll(of: AVURLAsset(url: url)).prefix(1))
                guard !Task.isCancelled else { return }
                if !tracks.isEmpty {
                    self.audioSources.files[name] = tracks
                    resolvedAny = true
                }
                self.loadPeaks(for: name, url: url)
            }
            if resolvedAny, self.isLoaded {
                try? self.rebuildScreenPlayerItem(preserving: self.currentTime)
            }
        }
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
        pendingActionNames["image"] = actionName
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

    /// Audio clips that start after the last frame and so never play,
    /// usually left there by removing video under unlinked music.
    var audioClipsPastEnd: [RecordingAudioClip] {
        audioClips.filter { $0.start >= duration - 0.01 }
    }

    func removeAudioClipsPastEnd() {
        let ids = Set(audioClipsPastEnd.map(\.id))
        guard !ids.isEmpty else { return }
        applyAudioClips(audioClips.filter { !ids.contains($0.id) }, actionName: "Remove Audio After the End")
    }

    /// How many audio lanes the timeline shows: every lane in use, and
    /// always at least one.
    var audioLaneCount: Int {
        // While a clip is dragged, lanes never close under it, and one spare
        // lane waits below to drop it into.
        isMovingAudioClip
            ? max(usedAudioLaneCount, laneCountAtDragStart) + 1
            : usedAudioLaneCount
    }

    private var usedAudioLaneCount: Int {
        max(1, (audioClips.map(\.lane).max() ?? 0) + 1)
    }

    /// The waveform outline of whatever a clip plays.
    func waveformPeaks(for clip: RecordingAudioClip) -> [Float] {
        switch clip.source {
        case .file: audioPeaks[clip.fileName] ?? []
        case .recording: audioPeaks[Self.recordingPeaksKey] ?? []
        case .replacement: audioPeaks[Self.soundtrackPeaksKey] ?? []
        }
    }

    /// The loudness of the video's own sound over a stretch of the
    /// recording, 0...1, for the waveform along the clips: the soundtrack
    /// where one stands in, the recorded audio elsewhere.
    func clipSoundPeak(fromSource start: TimeInterval, to end: TimeInterval) -> Float {
        let perSecond = Double(RecordingAudioPeaks.peaksPerSecond)
        func peak(_ peaks: [Float], _ from: TimeInterval, _ to: TimeInterval) -> Float {
            guard !peaks.isEmpty else { return 0 }
            let low = max(0, min(peaks.count - 1, Int(from * perSecond)))
            let high = max(low + 1, min(peaks.count, Int((to * perSecond).rounded(.up))))
            var value: Float = 0
            for index in low..<high { value = max(value, peaks[index]) }
            return value
        }
        if let replacementAudio, let sync = replacementAudioSync,
           let part = sync.pieces(from: start, to: max(end, start + 0.001), fileDuration: replacementAudio.duration).first {
            return peak(audioPeaks[Self.soundtrackPeaksKey] ?? [], part.fileStart, part.fileEnd)
        }
        return peak(audioPeaks[Self.recordingPeaksKey] ?? [], start, end)
    }

    /// Bumped whenever the clips' waveform would draw differently.
    var clipSoundRevision: Int {
        var hasher = Hasher()
        hasher.combine(audioPeaks[Self.recordingPeaksKey]?.count ?? 0)
        hasher.combine(audioPeaks[Self.soundtrackPeaksKey]?.count ?? 0)
        hasher.combine(replacementAudio?.url)
        hasher.combine(replacementAudioSync?.spans.count ?? 0)
        return hasher.finalize()
    }

    func selectAudioClip(id: UUID) {
        guard audioClips.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedAudioClipID = id
    }

    /// ⇧- or ⌘-click: adds a clip to the selection, or takes a selected one
    /// back out.
    func toggleAudioClipInSelection(id: UUID) {
        guard audioClips.contains(where: { $0.id == id }) else { return }
        var ids = selectedAudioClipIDs
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        let primary = ids.contains(id) ? id : ids.first
        clearTimelineSelection()
        selectedAudioClipIDs = ids
        selectedAudioClipID = primary
    }

    /// The clips an audio command acts on: the whole selection when the
    /// clip is part of it, otherwise just that clip.
    private func audioTargets(for id: UUID) -> Set<UUID> {
        selectedAudioClipIDs.contains(id) ? selectedAudioClipIDs : [id]
    }

    /// Moves every selected clip by the same amount, measured from where
    /// the drag started.
    func moveSelectedAudioClips(by delta: TimeInterval, lanes laneDelta: Int, anchor: UUID) {
        let base = audioEditSnapshot ?? audioClips
        let ids = audioTargets(for: anchor)
        let earliest = base.filter { ids.contains($0.id) }.map(\.start).min() ?? 0
        let shift = max(delta, -earliest)
        let topLane = base.filter { ids.contains($0.id) }.map(\.lane).min() ?? 0
        let laneShift = max(laneDelta, -topLane)
        replaceAudioClips(base.map { clip in
            guard ids.contains(clip.id) else { return clip }
            var moved = clip
            moved.start = clip.start + shift
            moved.lane = clip.lane + laneShift
            return moved
        })
    }

    /// Mutes or unmutes every clip on a lane in one step.
    func setAudioLaneMuted(_ muted: Bool, lane: Int) {
        let next = audioClips.map { clip in
            var clip = clip
            if clip.lane == lane { clip.isMuted = muted }
            return clip
        }
        applyAudioClips(next, actionName: muted ? "Mute Lane" : "Unmute Lane")
    }

    /// Mutes every lane but `lane`, or, given the lanes' earlier state,
    /// puts them back.
    func soloAudioLane(_ lane: Int) -> [UUID: Bool] {
        let before = Dictionary(uniqueKeysWithValues: audioClips.map { ($0.id, $0.isMuted) })
        let next = audioClips.map { clip in
            var clip = clip
            clip.isMuted = clip.lane != lane
            return clip
        }
        applyAudioClips(next, actionName: "Solo Lane")
        return before
    }

    func restoreAudioMutes(_ mutes: [UUID: Bool]) {
        let next = audioClips.map { clip in
            var clip = clip
            if let muted = mutes[clip.id] { clip.isMuted = muted }
            return clip
        }
        applyAudioClips(next, actionName: "Unsolo Lane")
    }

    func isAudioLaneMuted(_ lane: Int) -> Bool {
        let onLane = audioClips.filter { $0.lane == lane }
        return !onLane.isEmpty && onLane.allSatisfy(\.isMuted)
    }

    func removeAudioClip(id: UUID) {
        let ids = audioTargets(for: id)
        applyAudioClips(audioClips.filter { !ids.contains($0.id) }, actionName: ids.count > 1 ? "Remove Audio Clips" : "Remove Audio")
        if let selectedAudioClipID, ids.contains(selectedAudioClipID) { self.selectedAudioClipID = nil }
    }

    func beginAudioClipEdit() {
        if audioEditSnapshot == nil { audioEditSnapshot = audioClips }
    }

    func endAudioClipEdit(actionName: String = "Edit Audio") {
        guard let previous = audioEditSnapshot else { return }
        audioEditSnapshot = nil
        // A clip dropped onto another moves to a lane with room.
        let settled = StudioAudioConform.resolvingLanes(audioClips, last: selectedAudioClipID)
        if settled != audioClips { replaceAudioClips(settled) }
        guard previous != audioClips else { return }
        registerUndo(actionName) { target in
            target.applyAudioClips(previous, actionName: actionName)
        }
    }

    /// Applies an edited clip, keeping its trim inside the file.
    func setAudioClip(_ clip: RecordingAudioClip) {
        guard let index = audioClips.firstIndex(where: { $0.id == clip.id }) else { return }
        var all = audioClips
        all[index] = clip.sanitized()
        replaceAudioClips(all)
    }

    func editAudioClip(_ clip: RecordingAudioClip, actionName: String) {
        beginAudioClipEdit()
        setAudioClip(clip)
        pendingActionNames["audio"] = actionName
        audioCoalesceTask?.cancel()
        audioCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.endAudioClipEdit(actionName: actionName)
        }
    }

    /// One whole change to a clip, as its own undo step.
    func changeAudioClip(id: UUID, actionName: String, _ change: (inout RecordingAudioClip) -> Void) {
        guard var clip = audioClips.first(where: { $0.id == id }) else { return }
        change(&clip)
        clip = clip.sanitized()
        applyAudioClips(audioClips.map { $0.id == id ? clip : $0 }, actionName: actionName)
    }

    func toggleAudioClipMuted(id: UUID) {
        guard let clip = audioClips.first(where: { $0.id == id }) else { return }
        let ids = audioTargets(for: id)
        let muted = !clip.isMuted
        applyAudioClips(audioClips.map { other in
            var other = other
            if ids.contains(other.id) { other.isMuted = muted }
            return other
        }, actionName: muted ? "Mute Audio" : "Unmute Audio")
        showNotice(muted ? "Muted" : "Unmuted")
    }

    /// Whether the clip is cut along with the video above it.
    func setAudioClipLinked(_ linked: Bool, id: UUID) {
        let ids = audioTargets(for: id)
        applyAudioClips(audioClips.map { other in
            var other = other
            if ids.contains(other.id) { other.isLinked = linked }
            return other
        }, actionName: linked ? "Link Audio to Video" : "Unlink Audio")
    }

    /// Plays an unlinked clip faster or slower; it keeps its start.
    func setAudioClipSpeed(_ speed: Double, id: UUID) {
        changeAudioClip(id: id, actionName: "Change Audio Speed") { $0.speed = speed }
    }

    /// Moves a clip a lane up or down. Whatever is in the way there makes
    /// room by moving down itself.
    func moveAudioClip(id: UUID, byLanes delta: Int) {
        guard let clip = audioClips.first(where: { $0.id == id }) else { return }
        let lane = max(0, clip.lane + delta)
        guard lane != clip.lane else { return }
        applyAudioClips(
            audioClips.map {
                var clip = $0
                if clip.id == id { clip.lane = lane }
                return clip
            },
            actionName: "Move Audio to Lane \(lane + 1)",
            keeping: id
        )
    }

    /// A copy placed straight after the clip.
    func duplicateAudioClip(id: UUID) {
        guard let clip = audioClips.first(where: { $0.id == id }) else { return }
        // A copy past the end of the video would never play.
        guard clip.end < duration - RecordingAudioClip.minimumDuration else {
            NSSound.beep()
            showNotice("No room after the video ends")
            return
        }
        var copy = clip
        copy.id = UUID()
        copy.start = clip.end
        applyAudioClips(audioClips + [copy], actionName: "Duplicate Audio")
        selectAudioClip(id: copy.id)
    }

    private func replaceAudioClips(_ all: [RecordingAudioClip]) {
        audioClips = all
        scheduleProjectSave()
        // Volume and fades only change the mix; anything that moves audio
        // in time needs the composition rebuilt.
        if audioPlan.placement != playbackAudioPlacement {
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
            let rate = self.shuttleRate
            self.pause()
            try? self.rebuildScreenPlayerItem(preserving: self.currentTime)
            if wasPlaying {
                self.shuttleRate = rate
                self.startPlayback()
            }
        }
    }

    /// `keeping` names a clip that gets the lane it asks for; anything in
    /// its way moves down.
    private func applyAudioClips(_ requested: [RecordingAudioClip], actionName: String, keeping: UUID? = nil) {
        let all = StudioAudioConform.resolvingLanes(requested, first: keeping)
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
                guard let span = clipTimeline.editorSpan(overlapping: cue.start, sourceEnd: cue.end) else { return nil }
                return RecordingZoomTimelineBlock(
                    cue: cue,
                    editorStart: span.lowerBound,
                    editorEnd: span.upperBound
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
            replacementAudioSync: replacementAudio == nil ? nil : replacementAudioSync,
            markers: markers.isEmpty ? nil : markers,
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
        flushPendingEdits()
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
        // How the soundtrack lines up stays as it is; only its offset is
        // an agent's to change.
        var sync = previous.replacementAudioSync
        if let requestedOffset = requested.replacementAudioSync?.offset {
            sync?.offset = min(max(requestedOffset, -RecordingAudioSync.offsetLimit), RecordingAudioSync.offsetLimit)
        }
        document.replacementAudioSync = sync
        guard document != previous else { return }

        registerUndo(actionName) { target in
            target.applyAgentDocument(previous, actionName: actionName)
        }
        pause()
        clearTimelineSelection()
        hoverPreviewTime = nil
        timelineHoverTime = nil

        let implicitZoomCues = zoomCues.filter(\.isImplicit)
        if replacementAudio != nil { replacementAudioSync = document.replacementAudioSync }
        applyDocumentSettings(document)
        isApplyingDocument = true
        zoomCues = document.zoomCues + implicitZoomCues
        let previousTimeline = clipTimeline
        if let clips = document.clips, !clips.isEmpty {
            clipTimeline = RecordingClipTimeline(segments: clips).normalized(to: sourceDuration)
        }
        duration = clipTimeline.duration
        // An edit that changed the video's clips and left the audio clips
        // alone gets what a cut in the editor gets: linked audio is cut
        // with the video and the rest keeps its place.
        let stored = (document.audioClips ?? []).map { $0.sanitized() }
        audioClips = (document.audioClips ?? []) == (previous.audioClips ?? [])
            ? StudioAudioConform.conform(stored, from: previousTimeline, to: clipTimeline)
            : StudioAudioConform.resolvingLanes(stored)
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
        flushPendingEdits()
        projectSaveTask?.cancel()
        let document = currentDocument()
        do {
            try session.writeEditDocument(document)
            session.removeDraftDocument()
            removeUnreferencedFiles(in: session, keeping: document)
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
                adoptReplacementAudio(loadedAudio, sync: document.replacementAudioSync)
            } else if replacementAudio != nil {
                replacementAudioSync = document.replacementAudioSync ?? .flat(over: clipTimeline)
            }
        } else {
            adoptReplacementAudio(nil, sync: nil)
        }
        audioClips = StudioAudioConform.resolvingLanes(audioClips.map { $0.sanitized() })

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

    private func refreshPlayheadMarks() {
        let clipID = clipTimeline.location(at: currentTime)?.segmentID
        if clipID != playheadClipID { playheadClipID = clipID }
        let cueID = subtitleTimeline.isEmpty
            ? nil
            : subtitleTimeline.cue(at: clipTimeline.sourceTime(at: currentTime))?.id
        if cueID != activeSubtitleCueID { activeSubtitleCueID = cueID }
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
            audioReplacementSync: replacementAudio == nil ? nil : replacementAudioSync,
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
        guard let replacementAudio, let replacementAudioSync else { return nil }
        // Against the cut it was brought in over, not today's: cutting the
        // video afterwards cuts the soundtrack with it.
        let drift = replacementAudio.duration - replacementAudioSync.coveredFileDuration
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
            replacementSync: replacementAudio == nil ? nil : replacementAudioSync,
            format: audioExportFormat,
            volume: Double(audioVolume),
            audioClips: audioExportIncludesClips ? audioClips : [],
            mediaDirectory: audioExportIncludesClips ? mediaDirectoryURL : nil
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
    /// audio. The file is copied into the session under a name of its own,
    /// so the project keeps playing after the original is moved, and the
    /// previous soundtrack stays on disk for undo. Files nothing refers to
    /// any more are cleared up when the project is saved.
    func replaceAudio(with pickedURL: URL) {
        guard isLoaded else { return }
        pause()
        replacementAudioTask?.cancel()

        replacementAudioError = nil
        let displayName = pickedURL.lastPathComponent
        var copiedURL: URL?
        let storedURL: URL
        if let session {
            let destination = session.directoryURL
                .appendingPathComponent(
                    "\(RecordingSession.replacementAudioBaseName)-\(UUID().uuidString.prefix(8).lowercased())"
                )
                .appendingPathExtension(pickedURL.pathExtension.isEmpty ? "m4a" : pickedURL.pathExtension)
            do {
                let accessing = pickedURL.startAccessingSecurityScopedResource()
                defer { if accessing { pickedURL.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: pickedURL, to: destination)
            } catch {
                replacementAudioError = "Could not import that file: \(error.localizedDescription)"
                return
            }
            storedURL = destination
            copiedURL = destination
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
                // Never adopted, so nothing can refer to the copy.
                if let copiedURL { try? FileManager.default.removeItem(at: copiedURL) }
                self.replacementAudioError = "That file has no audio track."
                return
            }
            // The file is the sound of the cut as it stands; from here on
            // it follows the picture.
            self.setSoundtrack(
                SoundtrackState(audio: resolved, sync: .flat(over: self.clipTimeline), clips: self.audioClips),
                actionName: "Replace Audio"
            )
        }
    }

    private func adoptReplacementAudio(_ audio: RecordingReplacementAudio?, sync: RecordingAudioSync?) {
        replacementAudio = audio
        if let audio { undoReferencedFiles.insert(audio.url.lastPathComponent) }
        audioPeaks[Self.soundtrackPeaksKey] = nil
        guard let audio else {
            replacementAudioSync = nil
            audioSources.replacement = []
            return
        }
        replacementAudioSync = sync ?? .flat(over: clipTimeline)
        audioSources.replacement = [
            StudioAudioSources.Track(track: audio.track, range: audio.range, asset: audio.asset)
        ]
        loadPeaks(for: Self.soundtrackPeaksKey, url: audio.url)
    }

    /// Slides the soundtrack against the picture. A slider sweep undoes
    /// as one step; the player is rebuilt once it settles.
    func setReplacementAudioOffset(_ offset: TimeInterval) {
        guard var sync = replacementAudioSync, replacementAudio != nil else { return }
        let clamped = min(max(offset, -RecordingAudioSync.offsetLimit), RecordingAudioSync.offsetLimit)
        guard abs(sync.offset - clamped) > 0.000_1 else { return }
        if soundtrackOffsetSnapshot == nil { soundtrackOffsetSnapshot = sync.offset }
        sync.offset = clamped
        replacementAudioSync = sync
        scheduleProjectSave()
        scheduleAudioPlaybackRebuild()
        soundtrackOffsetTask?.cancel()
        soundtrackOffsetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.endSoundtrackOffsetEdit()
        }
    }

    private func endSoundtrackOffsetEdit() {
        soundtrackOffsetTask?.cancel()
        guard let previous = soundtrackOffsetSnapshot else { return }
        soundtrackOffsetSnapshot = nil
        guard let current = replacementAudioSync?.offset, abs(current - previous) > 0.000_1 else { return }
        registerUndo("Change Audio Sync") { target in
            target.restoreSoundtrackOffset(previous, redoing: current)
        }
    }

    private func restoreSoundtrackOffset(_ offset: TimeInterval, redoing other: TimeInterval) {
        guard var sync = replacementAudioSync else { return }
        registerUndo("Change Audio Sync") { target in
            target.restoreSoundtrackOffset(other, redoing: offset)
        }
        sync.offset = offset
        replacementAudioSync = sync
        scheduleProjectSave()
        scheduleAudioPlaybackRebuild()
    }

    func removeReplacementAudio() {
        guard replacementAudio != nil else { return }
        replacementAudioTask?.cancel()
        replacementAudioTask = nil
        replacementAudioError = nil
        // Sound detached from the soundtrack has nothing left to play.
        setSoundtrack(
            SoundtrackState(audio: nil, sync: nil, clips: audioClips.filter { $0.source != .replacement }),
            actionName: "Remove Replaced Audio"
        )
    }

    /// The soundtrack and everything that depends on it, as one undoable
    /// value. Holding the resolved audio makes undo synchronous.
    private struct SoundtrackState {
        var audio: RecordingReplacementAudio?
        var sync: RecordingAudioSync?
        var clips: [RecordingAudioClip]
    }

    private func setSoundtrack(_ state: SoundtrackState, actionName: String) {
        flushPendingEdits()
        let previous = SoundtrackState(audio: replacementAudio, sync: replacementAudioSync, clips: audioClips)
        registerUndo(actionName) { target in
            target.setSoundtrack(previous, actionName: actionName)
        }
        pause()
        adoptReplacementAudio(state.audio, sync: state.sync)
        audioClips = StudioAudioConform.resolvingLanes(state.clips)
        if let selectedAudioClipID, !audioClips.contains(where: { $0.id == selectedAudioClipID }) {
            self.selectedAudioClipID = nil
        }
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

    /// Deletes soundtracks and media files that neither the saved project
    /// nor anything this editor has used refers to. Only run after a save:
    /// until then undo, a discard or the draft may still need any of them.
    private func removeUnreferencedFiles(in session: RecordingSession, keeping document: RecordingEditDocument) {
        var kept = undoReferencedFiles
        if let name = document.replacementAudioFileName { kept.insert(name) }
        for image in document.imageOverlays ?? [] { kept.insert(image.fileName) }
        for clip in document.audioClips ?? [] where clip.source == .file { kept.insert(clip.fileName) }
        let directory = session.directoryURL
        let mediaDirectory = directory.appendingPathComponent("media", isDirectory: true)
        let prefix = RecordingSession.replacementAudioBaseName
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            where name.hasPrefix(prefix) && !kept.contains(name) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
            for name in (try? fileManager.contentsOfDirectory(atPath: mediaDirectory.path)) ?? []
            where !kept.contains(name) {
                try? fileManager.removeItem(at: mediaDirectory.appendingPathComponent(name))
            }
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
