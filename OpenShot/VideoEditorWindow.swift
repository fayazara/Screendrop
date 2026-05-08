//
//  VideoEditorWindow.swift
//  OpenShot
//

import AppKit
import AVFoundation
@preconcurrency import CoreMedia
import SwiftUI

struct VideoEditorWindow: View {
    @Binding var url: URL?

    @State private var player = AVPlayer()
    @State private var sourceURL: URL?
    @State private var duration: Double = 0
    @State private var selection = VideoTrimSelection(start: 0, end: 0)
    @State private var timelineFrames: [NSImage] = []
    @State private var playheadTime: Double = 0
    @State private var timeObserver: Any?
    @State private var boundaryObserver: Any?
    @State private var isLoading = true
    @State private var isPlaying = false
    @State private var isExporting = false
    @State private var isCompressingVideo = false
    @State private var isDetectingFFmpeg = false
    @State private var feedback: String?
    @State private var errorMessage: String?
    @State private var ffmpegPath: String?
    @State private var compressionSettings = VideoCompressionSettings()
    @State private var compressionProgress: Double?
    @State private var compressionResult: VideoCompressionResult?
    @State private var showInspector = true

    @Environment(\.dismiss) private var dismissWindow

    var body: some View {
        mainContent
            .frame(minWidth: 980, minHeight: 720)
            .navigationTitle("OpenShot Video Editor")
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    VideoInspectorToggleButton(isPresented: $showInspector)
                }
            }
            .inspector(isPresented: $showInspector) {
                videoInspector
            }
            .task(id: url) {
                await loadVideo(url)
            }
            .task {
                await detectFFmpeg()
            }
            .onChange(of: selection) { _, _ in
                updatePlaybackBoundsForSelection()
            }
            .onAppear {
                AppActivationPolicy.enter(hidePreview: true)
            }
            .onDisappear {
                player.pause()
                removePlaybackObservers()
                AppActivationPolicy.leave(restorePreview: true)
            }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            playbackArea
            VStack(spacing: 10) {
                transportTimelinePill
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var playbackArea: some View {
        ZStack {
            Color.black

            VideoEditorPlayerSurface(player: player)
                .opacity(sourceURL == nil ? 0 : 1)

            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }

            if isExporting {
                VideoTrimExportIndicator()
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(18)
            }
        }
        .frame(minHeight: 390)
    }

    private var transportTimelinePill: some View {
        HStack(spacing: 10) {
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Pause" : "Play")
            .disabled(!canPreview)

            VideoTrimTimelineView(
                selection: $selection,
                playheadTime: $playheadTime,
                duration: duration,
                frames: timelineFrames,
                onSeek: seekPreview
            )
            .frame(height: 54)

            Button(action: resetTrim) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.55))
            .help("Reset trim")
            .disabled(!canPreview || isFullSelection)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
    }



    private var videoInspector: some View {
        VideoInspectorPanel {
            clipInspectorSection
            VideoInspectorDivider()
            qualityInspectorSection
            speedInspectorSection
            resolutionInspectorSection
            codecInspectorSection
            audioInspectorSection
            VideoInspectorDivider()
            ffmpegInspectorSection
            compressionStatusInspectorSection
            actionsInspectorSection
        }
    }

    private var clipInspectorSection: some View {
        VideoInspectorSection("Clip") {
            let boundedSelection = selection.clamped(to: duration)
            VideoInspectorValueRow(title: "Start", value: timecode(boundedSelection.start))
            VideoInspectorValueRow(title: "End", value: timecode(boundedSelection.end))
            VideoInspectorValueRow(title: "Length", value: timecode(boundedSelection.duration))
        }
    }

    private var qualityInspectorSection: some View {
        VideoInspectorSection("Quality") {
            VideoInspectorSegmentedControl(
                options: Array(VideoCompressionQuality.allCases),
                selection: $compressionSettings.quality,
                title: { $0.rawValue }
            )

            VideoInspectorHint(text: qualityHint(for: compressionSettings.quality))
        }
    }

    private var speedInspectorSection: some View {
        VideoInspectorSection("Speed") {
            VideoInspectorSegmentedControl(
                options: Array(VideoCompressionSpeed.allCases),
                selection: $compressionSettings.speed,
                title: { $0.rawValue }
            )

            VideoInspectorHint(text: speedHint(for: compressionSettings.speed))
        }
    }

    private var resolutionInspectorSection: some View {
        VideoInspectorSection("Resolution") {
            VideoInspectorMenuPicker(
                options: Array(VideoCompressionResolution.allCases),
                selection: $compressionSettings.resolution,
                title: { $0.rawValue }
            )
        }
    }

    private var codecInspectorSection: some View {
        VideoInspectorSection("Codec") {
            VideoInspectorSegmentedControl(
                options: Array(VideoCompressionCodec.allCases),
                selection: $compressionSettings.codec,
                title: { $0.rawValue }
            )

            VideoInspectorHint(text: codecHint(for: compressionSettings.codec))
        }
    }

    private var audioInspectorSection: some View {
        VideoInspectorSection("Audio") {
            Toggle("Remove audio", isOn: $compressionSettings.removeAudio)
                .font(.callout)
                .disabled(isExporting || isCompressingVideo)
        }
    }

    private var ffmpegInspectorSection: some View {
        VideoInspectorSection("FFmpeg") {
            ffmpegStatus
        }
    }

    @ViewBuilder
    private var compressionStatusInspectorSection: some View {
        if isCompressingVideo || compressionResult != nil {
            VideoInspectorSection("Status") {
                compressionStatus
            }
        }
    }

    private var actionsInspectorSection: some View {
        VideoInspectorSection {
            VideoInspectorActions(
                primaryLabel: primaryConversionTitle,
                primaryIcon: "arrow.down.right.and.arrow.up.left",
                onPrimary: applyCompressedToPreview,
                secondaryLabel: trimOnlyActionLabel,
                onSecondary: trimOnlyAction,
                isSecondaryDisabled: !canExport,
                isPrimaryDisabled: !canConvert,
                isProcessing: isCompressingVideo || isExporting
            )
        }
    }



    @ViewBuilder
    private var ffmpegStatus: some View {
        if isDetectingFFmpeg {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text("Checking FFmpeg...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if ffmpegPath == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Install FFmpeg with Homebrew to convert recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text("brew install ffmpeg")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Button(action: copyFFmpegInstallCommand) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy Homebrew install command")
                }

                Button("Check Again") {
                    Task { await detectFFmpeg() }
                }
                .controlSize(.small)
            }
        } else {
            Label("Ready to convert", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var compressionStatus: some View {
        if isCompressingVideo {
            VideoInspectorProgressStatus(
                progress: compressionProgress ?? 0,
                label: "Converting recording"
            )
        } else if let compressionResult {
            VideoInspectorHint(text: compressionSummary(for: compressionResult))
        }
    }

    private var canPreview: Bool {
        !isLoading && duration > 0 && errorMessage == nil
    }

    private var canExport: Bool {
        canPreview && !isExporting && !isCompressingVideo && selection.clamped(to: duration).duration >= VideoTrimSelection.minimumDuration
    }

    private var canCompress: Bool {
        canPreview
        && !isExporting
        && !isCompressingVideo
        && ffmpegPath != nil
        && selection.clamped(to: duration).duration >= VideoTrimSelection.minimumDuration
    }

    private var canConvert: Bool {
        canCompress
    }

    private var primaryConversionTitle: String {
        isTrimmedSelection ? "Trim & Convert" : "Convert"
    }

    private var trimOnlyActionLabel: String? {
        isTrimmedSelection ? "Trim Only" : nil
    }

    private var trimOnlyAction: (() -> Void)? {
        guard isTrimmedSelection else { return nil }
        return { applyTrimToPreview() }
    }

    private var isFullSelection: Bool {
        abs(selection.start) < 0.001 && abs(selection.end - duration) < 0.001
    }

    private var isTrimmedSelection: Bool {
        let boundedSelection = selection.clamped(to: duration)
        return boundedSelection.start > 0.001 || abs(boundedSelection.end - duration) > 0.001
    }

    private func loadVideo(_ url: URL?) async {
        removePlaybackObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        sourceURL = nil
        duration = 0
        selection = VideoTrimSelection(start: 0, end: 0)
        playheadTime = 0
        timelineFrames = []
        feedback = nil
        errorMessage = nil
        compressionSettings = VideoCompressionSettings()
        compressionProgress = nil
        compressionResult = nil
        isPlaying = false

        guard let url else {
            dismissWindow()
            return
        }

        sourceURL = url
        isLoading = true
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        installPeriodicTimeObserver()

        do {
            let asset = AVURLAsset(url: url)
            let loadedDuration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(loadedDuration)
            guard seconds.isFinite, seconds > 0 else {
                throw VideoTrimExportError.invalidDuration
            }

            guard !Task.isCancelled, sourceURL == url else { return }

            duration = seconds
            selection = VideoTrimSelection(start: 0, end: seconds)
            playheadTime = 0
            isLoading = false
            installEndBoundaryObserver()

            let frames = await generateTimelineFrames(url: url, duration: seconds)
            guard !Task.isCancelled, sourceURL == url else { return }
            timelineFrames = frames
        } catch {
            guard !Task.isCancelled else { return }
            isLoading = false
            errorMessage = "Unable to load recording: \(error.localizedDescription)"
        }
    }

    private func installPeriodicTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.02, preferredTimescale: 600),
            queue: .main
        ) { time in
            Task { @MainActor in
                updatePlaybackTime(time)
            }
        }
    }

    private func removePlaybackObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        removeEndBoundaryObserver()
    }

    private func removeEndBoundaryObserver() {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
    }

    private func updatePlaybackTime(_ time: CMTime) {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return }

        let boundedSelection = selection.clamped(to: duration)
        if isPlaying, seconds >= boundedSelection.end - 0.001 {
            stopPlaybackAtSelectionEnd()
            return
        }

        playheadTime = min(max(seconds, boundedSelection.start), boundedSelection.end)
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            startBoundedPlayback()
        }
    }

    private func seekPreview(_ seconds: Double) {
        let boundedSelection = selection.clamped(to: duration)
        let boundedSeconds = min(max(seconds, boundedSelection.start), boundedSelection.end)
        let shouldResumePlayback = isPlaying && boundedSeconds < boundedSelection.end - 0.001

        if !shouldResumePlayback {
            player.pause()
            isPlaying = false
        }

        playheadTime = boundedSeconds
        player.seek(
            to: CMTime(seconds: boundedSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { finished in
            guard finished, shouldResumePlayback else { return }
            Task { @MainActor in
                player.play()
                isPlaying = true
            }
        }
    }

    private func startBoundedPlayback() {
        let boundedSelection = selection.clamped(to: duration)
        guard boundedSelection.end > boundedSelection.start else { return }

        installEndBoundaryObserver()

        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        let startSeconds: Double
        if currentSeconds.isFinite,
           currentSeconds >= boundedSelection.start,
           currentSeconds < boundedSelection.end - 0.001 {
            startSeconds = currentSeconds
        } else {
            startSeconds = boundedSelection.start
        }

        playheadTime = startSeconds
        player.seek(
            to: CMTime(seconds: startSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { finished in
            guard finished else { return }
            Task { @MainActor in
                player.play()
                isPlaying = true
            }
        }
    }

    private func updatePlaybackBoundsForSelection() {
        installEndBoundaryObserver()

        guard isPlaying else { return }

        let boundedSelection = selection.clamped(to: duration)
        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        guard currentSeconds.isFinite else { return }

        if currentSeconds >= boundedSelection.end - 0.001 {
            stopPlaybackAtSelectionEnd()
        } else if currentSeconds < boundedSelection.start {
            seekPreview(boundedSelection.start)
        }
    }

    private func installEndBoundaryObserver() {
        removeEndBoundaryObserver()

        let boundedSelection = selection.clamped(to: duration)
        guard boundedSelection.end > boundedSelection.start else { return }

        let endTime = CMTime(seconds: boundedSelection.end, preferredTimescale: 600)
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: endTime)], queue: .main) {
            Task { @MainActor in
                stopPlaybackAtSelectionEnd()
            }
        }
    }

    private func stopPlaybackAtSelectionEnd() {
        let endSeconds = selection.clamped(to: duration).end
        player.pause()
        isPlaying = false
        playheadTime = endSeconds
        player.seek(
            to: CMTime(seconds: endSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func resetTrim() {
        selection = VideoTrimSelection(start: 0, end: duration)
        seekPreview(0)
        feedback = nil
    }

    private func applyTrimToPreview() {
        guard let sourceURL else { return }
        let boundedSelection = selection.clamped(to: duration)

        runExport(destinationURL: nil) {
            let outputURL = try VideoTrimExportService.temporaryURL(for: sourceURL)
            return try await VideoTrimExportService.exportTrim(
                sourceURL: sourceURL,
                selection: boundedSelection,
                to: outputURL
            )
        } onSuccess: { trimmedURL in
            _ = ScreenshotPreviewStack.shared.replaceVideo(originalURL: sourceURL, with: trimmedURL)
            dismissWindow()
        }
    }

    private func applyCompressedToPreview() {
        guard let sourceURL else { return }
        let settingsSnapshot = compressionSettings
        let boundedSelection = selection.clamped(to: duration)

        do {
            let outputURL = try VideoCompressionService.temporaryURL(for: sourceURL, settings: settingsSnapshot)
            runCompression(
                selection: boundedSelection,
                settings: settingsSnapshot,
                outputURL: outputURL
            ) { result in
                _ = ScreenshotPreviewStack.shared.replaceVideo(originalURL: sourceURL, with: result.outputURL)
                dismissWindow()
            }
        } catch {
            errorMessage = "Compression failed: \(error.localizedDescription)"
        }
    }

    private func runCompression(
        selection: VideoTrimSelection,
        settings: VideoCompressionSettings,
        outputURL: URL,
        onSuccess: @escaping (VideoCompressionResult) -> Void
    ) {
        guard let sourceURL, let ffmpegPath else {
            errorMessage = VideoCompressionError.ffmpegNotFound.localizedDescription
            return
        }

        guard !isCompressingVideo else { return }

        isCompressingVideo = true
        compressionProgress = 0
        compressionResult = nil
        feedback = nil
        errorMessage = nil
        player.pause()
        isPlaying = false

        Task {
            do {
                let result = try await VideoCompressionService.compress(
                    sourceURL: sourceURL,
                    duration: duration,
                    selection: selection,
                    settings: settings,
                    outputURL: outputURL,
                    ffmpegPath: ffmpegPath
                ) { progress in
                    compressionProgress = progress
                }

                compressionProgress = nil
                compressionResult = result
                onSuccess(result)
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                compressionProgress = nil
                errorMessage = "Compression failed: \(error.localizedDescription)"
            }

            isCompressingVideo = false
        }
    }

    private func detectFFmpeg() async {
        guard !isDetectingFFmpeg else { return }

        isDetectingFFmpeg = true
        ffmpegPath = await FFmpegToolLocator.findFFmpeg()
        isDetectingFFmpeg = false
    }

    private func copyFFmpegInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
        feedback = "Copied FFmpeg install command."
    }

    private func runExport(
        destinationURL: URL?,
        operation: @escaping () async throws -> URL,
        onSuccess: @escaping (URL) -> Void
    ) {
        guard !isExporting else { return }

        isExporting = true
        feedback = nil
        errorMessage = nil
        player.pause()
        isPlaying = false

        Task {
            do {
                let outputURL = try await operation()
                onSuccess(outputURL)
            } catch {
                if let destinationURL {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
                errorMessage = "Export failed: \(error.localizedDescription)"
            }

            isExporting = false
        }
    }

    private func generateTimelineFrames(url: URL, duration: Double) async -> [NSImage] {
        guard duration > 0 else {
            return []
        }

        let frames = await Task.detached(priority: .userInitiated) { () -> [SendableTimelineFrame] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 180, height: 110)

            let frameCount = 18
            return (0..<frameCount).compactMap { index in
                let seconds = duration * (Double(index) + 0.5) / Double(frameCount)
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                    return nil
                }

                return SendableTimelineFrame(image: NSImage(cgImage: cgImage, size: .zero))
            }
        }.value

        return frames.map(\.image)
    }

    private func timecode(_ seconds: Double) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
        let totalSeconds = Int(safeSeconds.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    private func compressionSummary(for result: VideoCompressionResult) -> String {
        let sizes = "\(formatFileSize(result.inputSize)) -> \(formatFileSize(result.outputSize))"
        guard let reduction = result.reduction else {
            return sizes
        }

        let percentage = abs(reduction * 100).rounded()
        if reduction >= 0 {
            return "\(sizes), \(Int(percentage))% smaller"
        } else {
            return "\(sizes), \(Int(percentage))% larger"
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func qualityHint(for quality: VideoCompressionQuality) -> String {
        switch quality {
        case .high:
            "Best visual quality, larger output files."
        case .balanced:
            "Good quality with a practical file size."
        case .small:
            "Smallest output, with more visible compression."
        }
    }

    private func speedHint(for speed: VideoCompressionSpeed) -> String {
        switch speed {
        case .ultrafast:
            "Fastest conversion, least compression efficiency."
        case .fast:
            "Good default for screen recordings."
        case .medium:
            "Smaller files, slower conversion."
        case .slow:
            "Best compression efficiency, slowest conversion."
        }
    }

    private func codecHint(for codec: VideoCompressionCodec) -> String {
        switch codec {
        case .h264:
            "Most compatible across apps and browsers."
        case .hevc:
            "Smaller files on modern Apple devices."
        }
    }
}

private struct VideoEditorPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> VideoEditorPlayerContainerView {
        let view = VideoEditorPlayerContainerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: VideoEditorPlayerContainerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

private final class VideoEditorPlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

private struct VideoTrimExportIndicator: View {
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.24), lineWidth: 2.5)

            Circle()
                .trim(from: 0.08, to: 0.74)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(rotation))
        }
        .padding(3)
        .background(.black.opacity(0.36), in: Circle())
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

private struct SendableTimelineFrame: @unchecked Sendable {
    let image: NSImage
}

private struct VideoInspectorToggleButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "sidebar.right")
        }
        .help(isPresented ? "Hide Inspector" : "Show Inspector")
    }
}

private struct VideoInspectorPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .inspectorColumnWidth(300)
        .frame(width: 300)
    }
}

private struct VideoInspectorSection<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct VideoInspectorDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, 4)
    }
}

private struct VideoInspectorHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

private struct VideoInspectorValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }
}

private struct VideoInspectorSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    @Binding private var selection: Option
    private let title: (Option) -> String

    init(
        options: [Option],
        selection: Binding<Option>,
        title: @escaping (Option) -> String
    ) {
        self.options = options
        self._selection = selection
        self.title = title
    }

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    segment(for: option)
                }
            }
            .padding(3)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .frame(height: 34)
    }

    private func segment(for option: Option) -> some View {
        let isSelected = selection == option
        let label = title(option)

        return Button {
            selection = option
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background {
            if isSelected {
                Capsule()
                    .fill(Color.accentColor)
            }
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct VideoInspectorMenuPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding private var selection: Option
    private let title: (Option) -> String

    init(
        options: [Option],
        selection: Binding<Option>,
        title: @escaping (Option) -> String
    ) {
        self.options = options
        self._selection = selection
        self.title = title
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    HStack {
                        Text(title(option))

                        if option == selection {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(title(selection))
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VideoInspectorActions: View {
    let primaryLabel: String
    let primaryIcon: String
    let onPrimary: () -> Void
    var secondaryLabel: String?
    var onSecondary: (() -> Void)?
    var isSecondaryDisabled = false
    var isPrimaryDisabled = false
    var isProcessing = false

    var body: some View {
        VStack(spacing: 10) {
            Button(action: onPrimary) {
                HStack(spacing: 6) {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: primaryIcon)
                    }

                    Text(isProcessing ? "Processing..." : primaryLabel)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(isPrimaryDisabled || isProcessing)

            if let secondaryLabel, let onSecondary {
                Button(action: onSecondary) {
                    Text(secondaryLabel)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .disabled(isSecondaryDisabled || isProcessing)
            }
        }
    }
}

private struct VideoInspectorProgressStatus: View {
    let progress: Double
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)

            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
