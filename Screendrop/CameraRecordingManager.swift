//
//  CameraRecordingManager.swift
//  Screendrop
//
//  Captures the webcam alongside a screen recording. The camera is written
//  to its own camera.mov inside the recording session (never burned into
//  the screen video) so the studio editor can restyle, reposition, or drop
//  the bubble in post. A floating circular preview shows the user what the
//  camera sees while recording; the preview panel is excluded from capture.
//
//  Sync: AVCaptureSession stamps buffers with the same host clock
//  ScreenCaptureKit uses, so the first camera frame's PTS minus the screen
//  writer's session start gives an exact timeline offset for the editor.
//

import AppKit
import AVFoundation
@preconcurrency import CoreMedia
import Observation

nonisolated enum RecordingDeviceCatalog {
    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func camera(withID uniqueID: String) -> AVCaptureDevice? {
        guard !uniqueID.isEmpty else { return nil }
        return cameras().first { $0.uniqueID == uniqueID }
    }

    static func microphone(withID uniqueID: String) -> AVCaptureDevice? {
        guard !uniqueID.isEmpty else { return nil }
        return microphones().first { $0.uniqueID == uniqueID }
    }
}

@MainActor
final class CameraRecordingManager {
    static let shared = CameraRecordingManager()

    private let engine = CameraCaptureEngine()
    private var previewPanel: NSPanel?
    private var activePreviewDisplayID: CGDirectDisplayID?
    private(set) var isRunning = false
    /// True once frames are actually being written to a `camera.mov`, as
    /// opposed to just warming the sensor for the floating preview.
    private(set) var isWriting = false
    private var activeDeviceID: String?

    private init() {}

    /// Starts the capture session and shows the floating preview, without
    /// writing anything to disk yet. Call this as soon as the camera is
    /// enabled in the pre-record picker (or whenever it's re-shown with the
    /// camera already on) so the sensor's exposure/white-balance ramp - the
    /// visible fade-in macOS shows whenever a capture session starts cold -
    /// finishes before "Start Recording", instead of showing up live and at
    /// the start of the recorded footage.
    @discardableResult
    func startPreview(deviceID: String, displayID: CGDirectDisplayID?) async -> Bool {
        guard !isWriting else { return true }
        if isRunning {
            if activeDeviceID == deviceID {
                showPreview(displayID: displayID)
                return true
            }
            await stopPreview()
        }
        guard let device = RecordingDeviceCatalog.camera(withID: deviceID) else { return false }

        let authorized = await AVCaptureDevice.requestAccess(for: .video)
        guard authorized else { return false }

        do {
            try await engine.startSession(device: device)
        } catch {
            print("Camera preview failed to start: \(error)")
            return false
        }

        isRunning = true
        activeDeviceID = deviceID
        showPreview(displayID: displayID)
        return true
    }

    /// Tears down a warm preview that never turned into a recording - the
    /// camera was toggled off, or the pre-record picker was dismissed
    /// without starting. No-op while an actual recording is using the camera.
    func stopPreview() async {
        guard isRunning, !isWriting else { return }
        isRunning = false
        activeDeviceID = nil
        hidePreview()
        await engine.stopSessionOnly()
    }

    /// Starts writing camera frames to `outputURL`. Reuses an already-warm
    /// preview session for the same device when one is running - so
    /// recording never re-triggers the startup ramp - otherwise it starts a
    /// fresh session (e.g. a recording started without the picker bar).
    /// Returns false (without throwing) when the camera can't start -
    /// a missing device or denied permission should never abort the
    /// screen recording itself.
    func start(outputURL: URL, deviceID: String, displayID: CGDirectDisplayID?) async -> Bool {
        guard !isWriting else { return true }

        if !isRunning || activeDeviceID != deviceID {
            guard await startPreview(deviceID: deviceID, displayID: displayID) else { return false }
        } else {
            showPreview(displayID: displayID)
        }

        do {
            try await engine.beginWriting(outputURL: outputURL)
        } catch {
            print("Camera recording failed to start: \(error)")
            isRunning = false
            activeDeviceID = nil
            hidePreview()
            await engine.stopSessionOnly()
            return false
        }

        isWriting = true
        return true
    }

    func pause() {
        guard isWriting else { return }
        engine.pause()
    }

    func resume() {
        guard isWriting else { return }
        engine.resume()
    }

    func stop() async -> CameraRecordingResult? {
        guard isWriting else { return nil }
        isRunning = false
        isWriting = false
        activeDeviceID = nil
        hidePreview()
        return await engine.finish()
    }

    func cancel() async {
        guard isRunning else { return }
        isRunning = false
        isWriting = false
        activeDeviceID = nil
        hidePreview()
        await engine.cancel()
    }

    private func showPreview(displayID: CGDirectDisplayID?) {
        // Already showing in the right place: the session (and its exposure)
        // is untouched, so recreating the panel here would only cost a
        // pointless layer swap.
        if previewPanel != nil, activePreviewDisplayID == displayID {
            return
        }
        hidePreview()

        let diameter: CGFloat = 160
        let screen = ActiveDisplayResolver.screen(for: displayID) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let origin = CGPoint(
            x: visibleFrame.maxX - diameter - 24,
            y: visibleFrame.minY + 24
        )

        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: CGSize(width: diameter, height: diameter)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        PreviewWindowCaptureExclusion.shared.register(window: panel)

        let container = NSView(frame: CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter)))
        container.wantsLayer = true
        container.layer?.cornerRadius = diameter / 2
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        container.layer?.borderWidth = 1

        let previewLayer = engine.makePreviewLayer()
        previewLayer.frame = container.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        previewLayer.videoGravity = .resizeAspectFill
        container.layer?.addSublayer(previewLayer)

        panel.contentView = container
        panel.orderFrontRegardless()
        previewPanel = panel
        activePreviewDisplayID = displayID
    }

    private func hidePreview() {
        previewPanel?.orderOut(nil)
        previewPanel = nil
        activePreviewDisplayID = nil
    }
}

// MARK: - Capture engine

nonisolated private final class CameraCaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.screendrop.camera.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.screendrop.camera.video", qos: .userInitiated)
    private let writer = CameraMovieWriter()
    private var input: AVCaptureDeviceInput?
    private var output: AVCaptureVideoDataOutput?
    private var activeDevice: AVCaptureDevice?

    /// Starts the capture session only - no movie is written yet. Frames
    /// reach `captureOutput` immediately (for the live preview layer), but
    /// `CameraMovieWriter.writeVideoSample` silently no-ops until
    /// `beginWriting` has run, since it has no asset writer to append to.
    func startSession(device: AVCaptureDevice) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    try configureSession(device: device)
                    activeDevice = device
                    session.startRunning()
                    continuation.resume()
                } catch {
                    teardownSession()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Sets up the movie writer for the already-running session so its
    /// frames start landing on disk.
    func beginWriting(outputURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                guard let activeDevice else {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                    return
                }
                do {
                    let dimensions = CMVideoFormatDescriptionGetDimensions(activeDevice.activeFormat.formatDescription)
                    try writer.setup(
                        outputURL: outputURL,
                        width: Int(dimensions.width),
                        height: Int(dimensions.height)
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func pause() {
        writer.pause()
    }

    func resume() {
        writer.resume()
    }

    func finish() async -> CameraRecordingResult? {
        await stopSession()
        return await writer.finish()
    }

    func cancel() async {
        await stopSession()
        await writer.cancel()
    }

    /// Tears the session down without ever having written a movie - the
    /// warm preview was toggled off or dismissed before recording began.
    func stopSessionOnly() async {
        await stopSession()
    }

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        return layer
    }

    private func configureSession(device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CocoaError(.featureUnsupported)
        }
        session.addInput(input)
        self.input = input

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            throw CocoaError(.featureUnsupported)
        }
        session.addOutput(output)
        self.output = output

        // Mirror the recorded video so it matches the on-screen preview -
        // the FaceTime convention users expect from a talking-head bubble.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    private func stopSession() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                teardownSession()
                continuation.resume()
            }
        }
    }

    private func teardownSession() {
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        if let input {
            session.removeInput(input)
        }
        if let output {
            session.removeOutput(output)
        }
        session.commitConfiguration()
        input = nil
        output = nil
        activeDevice = nil
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        writer.writeVideoSample(sampleBuffer)
    }
}
