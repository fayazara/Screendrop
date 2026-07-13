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
    /// with a camera source. Screen-only sessions already contain their complete
    /// audio/video result and need no expensive second encode.
    static func ensureDeliverable(for session: RecordingSession) async throws -> URL {
        guard session.hasCamera else { return session.screenURL }
        if session.hasFinalVideo { return session.finalURL }

        let asset = AVURLAsset(url: session.screenURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw RecordingStudioExporter.ExportError.noVideoTrack
        }

        let cameraAsset = AVURLAsset(url: session.cameraURL)
        guard try await !cameraAsset.loadTracks(withMediaType: .video).isEmpty else {
            throw RenderError.missingCameraTrack
        }

        let canvasSize = try await outputSize(for: asset, manifest: session.loadManifest())
        let events = session.loadEvents() ?? ***REMOVED***()
        let project = session.loadProject()
        var style = project?.style.value ?? RecordingStudioStyle()
        // Selecting a camera means the default delivered recording includes
        // it. Hiding it remains an explicit Studio/manual-export choice.
        style.camera.isVisible = true
        let zoomEnabled = project?.zoomEnabled ?? true
        let zoomSegments = project?.zoomSegments
            ?? ***REMOVED***.segments(from: events, duration: duration)
        let zoomPath = zoomEnabled
            ? ***REMOVED***.build(segments: zoomSegments, events: events, duration: duration)
            : .identity
        let configuration = RecordingStudioExporter.Configuration(
            screenURL: session.screenURL,
            cameraURL: session.cameraURL,
            cameraOffset: session.loadManifest()?.***REMOVED*** ?? 0,
            style: style,
            zoomPath: zoomPath,
            canvasSize: canvasSize,
            trimSelection: nil,
            exportSettings: project?.exportSettings ?? VideoCompressionSettings()
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
        manifest: ***REMOVED***?
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
