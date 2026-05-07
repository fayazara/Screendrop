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
    @State private var copySucceeded = false
    @State private var feedback: String?
    @State private var errorMessage: String?
    @State private var ffmpegPath: String?
    @State private var compressionSettings = VideoCompressionSettings()
    @State private var compressionProgress: Double?
    @State private var compressionResult: VideoCompressionResult?
    @State private var isInspectorPresented = true

    @Environment(\.dismiss) private var dismissWindow

    var body: some View {
        mainContent
            .frame(minWidth: 880, minHeight: 640)
            .navigationTitle("OpenShot Video Editor")
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        isInspectorPresented.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
                }
            }
            .inspector(isPresented: $isInspectorPresented) {
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
            editorControls
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
        .frame(minHeight: 420)
    }

    private var editorControls: some View {
        VStack(spacing: 12) {
            timelineHeader

            VideoTrimTimelineView(
                selection: $selection,
                playheadTime: $playheadTime,
                duration: duration,
                frames: timelineFrames,
                onSeek: seekPreview
            )
            .frame(height: 72)

            HStack(spacing: 8) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                .help(isPlaying ? "Pause" : "Play")
                .disabled(!canPreview)

                Button(action: resetTrim) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset trim")
                .disabled(!canPreview || isFullSelection)

                Spacer()

                statusLabel
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(.bar)
    }

    private var timelineHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(timecode(playheadTime))
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .foregroundStyle(.primary)

            Text("\(timecode(selection.start)) - \(timecode(selection.end))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Text(timecode(duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if isExporting {
            ProgressView()
                .controlSize(.small)
        } else if let feedback {
            Text(feedback)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var videoInspector: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    clipInspectorSection

                    VideoInspectorDivider()

                    compressionInspectorSection
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Button(action: applyTrimToPreview) {
                Text("Apply Clip")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canExport)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var clipInspectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoInspectorSectionHeader("CLIP")

            VStack(alignment: .leading, spacing: 8) {
                VideoInspectorValueRow(title: "Start", value: timecode(selection.clamped(to: duration).start))
                VideoInspectorValueRow(title: "End", value: timecode(selection.clamped(to: duration).end))
                VideoInspectorValueRow(title: "Length", value: timecode(selection.clamped(to: duration).duration))
            }

            HStack(spacing: 8) {
                Button(action: copyTrim) {
                    Label(copySucceeded ? "Copied" : "Copy", systemImage: copySucceeded ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canExport)

                Button(action: saveTrimAs) {
                    Label("Save As", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canExport)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    private var compressionInspectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VideoInspectorSectionHeader("COMPRESSION")
                compressionStatus
            }

            VideoInspectorPickerRow(title: "Quality") {
                Picker("Quality", selection: $compressionSettings.quality) {
                    ForEach(VideoCompressionQuality.allCases) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
            }

            VideoInspectorPickerRow(title: "Codec") {
                Picker("Codec", selection: $compressionSettings.codec) {
                    ForEach(VideoCompressionCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
            }

            VideoInspectorPickerRow(title: "Size") {
                Picker("Size", selection: $compressionSettings.resolution) {
                    ForEach(VideoCompressionResolution.allCases) { resolution in
                        Text(resolution.rawValue).tag(resolution)
                    }
                }
            }

            VideoInspectorPickerRow(title: "Speed") {
                Picker("Speed", selection: $compressionSettings.speed) {
                    ForEach(VideoCompressionSpeed.allCases) { speed in
                        Text(speed.rawValue).tag(speed)
                    }
                }
            }

            Toggle("Remove audio", isOn: $compressionSettings.removeAudio)
                .font(.system(size: 12))
                .disabled(isCompressingVideo)

            compressionActionGroup
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var compressionActionGroup: some View {
        if ffmpegPath == nil {
            VStack(spacing: 8) {
                Button(action: copyFFmpegInstallCommand) {
                    Label("Copy Install Command", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }

                Button(action: { Task { await detectFFmpeg() } }) {
                    Label("Check Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isDetectingFFmpeg)
            }
            .controlSize(.large)
        } else {
            VStack(spacing: 8) {
                Button(action: saveCompressedAs) {
                    Label("Save Compressed", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canCompress)

                Button(action: applyCompressedToPreview) {
                    Label("Apply Compressed", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canCompress)
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var compressionStatus: some View {
        if isCompressingVideo {
            ProgressView(value: compressionProgress ?? 0)
                .progressViewStyle(.linear)
                .frame(width: 96)
        } else if isDetectingFFmpeg {
            Text("Checking FFmpeg...")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if ffmpegPath == nil {
            Text("FFmpeg required")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let compressionResult {
            Text(compressionSummary(for: compressionResult))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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

    private var isFullSelection: Bool {
        abs(selection.start) < 0.001 && abs(selection.end - duration) < 0.001
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
        copySucceeded = false
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

    private func copyTrim() {
        guard let sourceURL else { return }
        let boundedSelection = selection.clamped(to: duration)

        runExport(destinationURL: nil) {
            let outputURL = try VideoTrimExportService.temporaryURL(for: sourceURL)
            let trimmedURL = try await VideoTrimExportService.exportTrim(
                sourceURL: sourceURL,
                selection: boundedSelection,
                to: outputURL
            )
            try VideoFileActions.copyToClipboard(from: trimmedURL)
            return trimmedURL
        } onSuccess: { _ in
            feedback = "Copied trimmed recording."
            copySucceeded = true
            Task {
                try? await Task.sleep(for: .seconds(1))
                copySucceeded = false
            }
        }
    }

    private func saveTrimAs() {
        guard let sourceURL else { return }
        let boundedSelection = selection.clamped(to: duration)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [VideoFileActions.exportContentType]
        panel.nameFieldStringValue = VideoTrimExportService.suggestedFileName(
            for: sourceURL,
            selection: boundedSelection
        )
        panel.canCreateDirectories = true
        panel.title = "Save Trimmed Recording"

        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            Task { @MainActor in
                runExport(destinationURL: destinationURL) {
                    try await VideoTrimExportService.exportTrim(
                        sourceURL: sourceURL,
                        selection: boundedSelection,
                        to: destinationURL
                    )
                } onSuccess: { _ in
                    feedback = "Saved trimmed recording."
                }
            }
        }
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

    private func saveCompressedAs() {
        guard let sourceURL else { return }
        let settingsSnapshot = compressionSettings
        let boundedSelection = selection.clamped(to: duration)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [VideoFileActions.exportContentType]
        panel.nameFieldStringValue = VideoCompressionService.suggestedFileName(
            for: sourceURL,
            selection: boundedSelection,
            duration: duration,
            settings: settingsSnapshot
        )
        panel.canCreateDirectories = true
        panel.title = "Save Compressed Recording"

        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            Task { @MainActor in
                runCompression(
                    selection: boundedSelection,
                    settings: settingsSnapshot,
                    outputURL: destinationURL
                ) { result in
                    feedback = "Saved compressed recording."
                    compressionResult = result
                }
            }
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

private struct VideoInspectorSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
    }
}

private struct VideoInspectorDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 14)
    }
}

private struct VideoInspectorValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            Spacer()

            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}

private struct VideoInspectorPickerRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
