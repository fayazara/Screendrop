//
//  RecordingInputAuthorization.swift
//  Screendrop
//
//  Resolves camera and microphone authorization before a recording input is
//  persisted. Denied access is surfaced with a direct route to System Settings
//  instead of failing later while the recording stream is starting.
//

import AppKit
import AVFoundation

@MainActor
enum RecordingInputAuthorization {
    enum Input {
        case camera
        case microphone

        fileprivate var mediaType: AVMediaType {
            switch self {
            case .camera:
                .video
            case .microphone:
                .audio
            }
        }

        // Whole sentences per input, so each reads naturally once translated.
        fileprivate var accessNeededTitle: String {
            switch self {
            case .camera:
                String(localized: "Camera access needed")
            case .microphone:
                String(localized: "Microphone access needed")
            }
        }

        fileprivate var restrictedMessage: String {
            switch self {
            case .camera:
                String(localized: "Screendrop can't use the camera because access is restricted on this Mac.")
            case .microphone:
                String(localized: "Screendrop can't use the microphone because access is restricted on this Mac.")
            }
        }

        fileprivate var deniedMessage: String {
            switch self {
            case .camera:
                String(localized: "Allow Screendrop to use the camera in Privacy & Security, then select it again.")
            case .microphone:
                String(localized: "Allow Screendrop to use the microphone in Privacy & Security, then select it again.")
            }
        }

        fileprivate var settingsURL: URL? {
            let pane: String
            switch self {
            case .camera:
                pane = "Privacy_Camera"
            case .microphone:
                pane = "Privacy_Microphone"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        }
    }

    static func status(for input: Input) -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: input.mediaType)
    }

    /// Requests access when it has not been decided yet. Denied or restricted
    /// access is explained immediately so callers never persist an unusable
    /// recording-device selection.
    static func ensureAccess(for input: Input) async -> Bool {
        let currentStatus = status(for: input)
        let granted = await requestAccess(for: input)
        guard !granted else { return true }

        presentDeniedAlert(for: input, isRestricted: currentStatus == .restricted)
        return false
    }

    /// Resolves access without presenting UI. Recording startup uses this to
    /// collect all unavailable optional inputs into one downgrade warning.
    static func requestAccess(for input: Input) async -> Bool {
        switch status(for: input) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: input.mediaType)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func presentDeniedAlert(for input: Input, isRestricted: Bool) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = input.accessNeededTitle

        if isRestricted {
            alert.informativeText = input.restrictedMessage
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            return
        }

        alert.informativeText = input.deniedMessage
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        if alert.runModal() == .alertFirstButtonReturn,
           let settingsURL = input.settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}
