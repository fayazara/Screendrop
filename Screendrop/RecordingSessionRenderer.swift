//
//  RecordingSessionRenderer.swift
//  Screendrop
//
//  On-demand utility for workflows that require a single flattened movie.
//  The capture pipeline keeps screen and camera as separate safety masters;
//  this renderer must not run on the recording Stop/presentation path.
//

import AppKit
import AVFoundation
import CoreGraphics

@MainActor
enum RecordingSessionRenderer {
    private enum RenderError: LocalizedError {
        case missingCameraTrack

        var errorDescription: String? {
            "The camera recording does not contain a readable video track."
        }
    }

    /// Creates a flattened deliverable when explicitly requested for a session
    /// with a camera source or a cursor-hidden capture. Screen-only sessions
    /// recorded with the OS cursor already contain their complete audio/video
    /// result and need no expensive second encode.
    static func ensureDeliverable(for session: RecordingSession) async throws -> URL {
        let manifest = session.loadCaptureManifest()
        let pointerSynthesized = manifest?.pointerSynthesized == true
        guard session.hasCamera || pointerSynthesized else { return session.screenURL }
        if session.hasFinalVideo { return session.finalURL }

        let asset = AVURLAsset(url: session.screenURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw RecordingStudioExporter.ExportError.noVideoTrack
        }

        if session.hasCamera {
            let cameraAsset = AVURLAsset(url: session.cameraURL)
            guard try await !cameraAsset.loadTracks(withMediaType: .video).isEmpty else {
                throw RenderError.missingCameraTrack
            }
        }

        let canvasSize = try await outputSize(for: asset, manifest: manifest)
        let recordingPointScale = max(manifest?.pixelScale ?? 1, 1)
        let recordingPointSize = CGSize(
            width: canvasSize.width / CGFloat(recordingPointScale),
            height: canvasSize.height / CGFloat(recordingPointScale)
        )
        let capture = PointerStreamSanitizer.sanitize(
            session.loadPointerCapture() ?? PointerCaptureFile(),
            options: PointerSanitizeOptions(
                recordingSizeInPoints: recordingPointSize
            )
        ).sanitizedCapture
        let document = session.loadEditDocument()
        var style = document?.style.value ?? RecordingStudioStyle()
        // Selecting a camera means the default delivered recording includes
        // it. Hiding it remains an explicit Studio/manual-export choice.
        style.camera.isVisible = session.hasCamera
        let zoomEnabled = document?.zoomEnabled ?? true
        let zoomCues = document?.zoomCues
            ?? ZoomCueSynthesizer.cues(from: capture, duration: duration)
        let clipTimeline: RecordingClipTimeline
        if let clips = document?.clips, !clips.isEmpty {
            clipTimeline = RecordingClipTimeline(segments: clips).normalized(to: duration)
        } else {
            clipTimeline = .legacyTrim(
                start: document?.trimStart,
                end: document?.trimEnd,
                sourceDuration: duration
            )
        }
        let viewportTimeline = zoomEnabled
            ? ViewportTimeline.build(cues: zoomCues, capture: capture, clipTimeline: clipTimeline)
            : .identity
        let showsPressEffects = pointerSynthesized
            && manifest?.pressEffectsBaked == false
            && (document?.showsClickEffects ?? manifest?.pressEffectsEnabled ?? true)
        let showsKeystrokes = (document?.showsKeystrokes ?? true) && !capture.keystrokes.isEmpty
        let configuration = RecordingStudioExporter.Configuration(
            screenURL: session.screenURL,
            cameraURL: session.hasCamera ? session.cameraURL : nil,
            cameraOffset: manifest?.cameraLeadIn ?? 0,
            style: style,
            viewportTimeline: viewportTimeline,
            pointerTimeline: pointerSynthesized
                ? PointerTimeline.build(
                    capture: capture,
                    duration: duration,
                    recordingSizeInPoints: recordingPointSize,
                    fallbackArtwork: PointerArtworkCapture.defaultArtwork()
                )
                : nil,
            showsPressEffects: showsPressEffects,
            keystrokeTimeline: showsKeystrokes
                ? KeystrokeCaptionTimeline(events: capture.keystrokes)
                : nil,
            keystrokePlacement: document?.keystrokePlacement ?? .bottomCenter,
            subtitleTimeline: {
                let cues = document?.subtitleCues ?? []
                let shows = document?.showsSubtitles ?? true
                return shows && !cues.isEmpty ? SubtitleTimeline(cues: cues) : nil
            }(),
            canvasSize: canvasSize,
            clipTimeline: clipTimeline,
            exportSettings: document?.exportSettings ?? VideoCompressionSettings()
        )

        let temporaryURL = try await RecordingStudioExporter().export(configuration) { _ in }
        do {
            if FileManager.default.fileExists(atPath: session.finalURL.path) {
                _ = try FileManager.default.replaceItemAt(session.finalURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: session.finalURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        return session.finalURL
    }

    static func presentFailure(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The camera video could not be added"
        alert.informativeText = "Your screen, camera, and audio masters are safe in the recording project, but Screendrop could not create the combined video: \(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func outputSize(
        for asset: AVURLAsset,
        manifest: CaptureManifest?
    ) async throws -> CGSize {
        if let manifest, manifest.pixelWidth > 0, manifest.pixelHeight > 0 {
            return CGSize(width: manifest.pixelWidth, height: manifest.pixelHeight)
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingStudioExporter.ExportError.noVideoTrack
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = size.applying(transform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }
}
