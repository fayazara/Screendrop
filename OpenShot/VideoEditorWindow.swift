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
    @State private var copySucceeded = false
    @State private var feedback: String?
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            playbackArea
            editorControls
        }
        .frame(minWidth: 860, minHeight: 620)
        .navigationTitle("OpenShot Video Editor")
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .task(id: url) {
            await loadVideo(url)
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
        .frame(minHeight: 460)
    }

    private var editorControls: some View {
        VStack(spacing: 12) {
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

            VideoTrimTimelineView(
                selection: $selection,
                playheadTime: $playheadTime,
                duration: duration,
                frames: timelineFrames,
                onSeek: seekPreview
            )
            .frame(height: 72)

            HStack(spacing: 10) {
                Button(action: togglePlayback) {
                    Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(!canPreview)

                Button(action: resetTrim) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset trim")
                .disabled(!canPreview || isFullSelection)

                Spacer()

                if let feedback {
                    Text(feedback)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button(action: copyTrim) {
                    Label(copySucceeded ? "Copied" : "Copy", systemImage: copySucceeded ? "checkmark" : "doc.on.doc")
                }
                .disabled(!canExport)

                Button(action: saveTrimAs) {
                    Label("Save As", systemImage: "square.and.arrow.down")
                }
                .disabled(!canExport)

                Button(action: applyTrimToPreview) {
                    Label("Apply", systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.defaultAction)
                .help("Replace preview with trimmed recording")
                .disabled(!canExport)
            }
        }
        .padding(16)
        .background(.bar)
    }

    private var canPreview: Bool {
        !isLoading && duration > 0 && errorMessage == nil
    }

    private var canExport: Bool {
        canPreview && !isExporting && selection.clamped(to: duration).duration >= VideoTrimSelection.minimumDuration
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
