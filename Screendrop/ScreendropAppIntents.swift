//
//  ScreendropAppIntents.swift
//  Screendrop
//
//  Exposes capture and recording actions to Shortcuts, Siri, and Spotlight
//  via the App Intents framework. Every intent funnels through the same
//  coordinators the menu bar and global hotkeys already drive, so behavior
//  (history import, sounds, the preview overlay) is identical no matter how
//  the action was triggered.
//
//  These types are deliberately `nonisolated`: AppIntents' static metadata
//  (title, description, the shortcuts list) must be readable without a
//  MainActor hop, since the framework can index it from a background
//  context. Only `perform()` - which touches the app's MainActor-isolated
//  capture/recording state - is annotated `@MainActor`.
//

import AppIntents
import ScreenCaptureKit

// MARK: - Errors

nonisolated enum ScreendropIntentError: Error, CustomLocalizedStringResourceConvertible {
    case captureCancelled
    case noTextRecognized
    case recordingAlreadyActive
    case noActiveRecording
    case noDisplayAvailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .captureCancelled:
            "The screenshot was cancelled before it could be captured."
        case .noTextRecognized:
            "No text was recognized in the captured area."
        case .recordingAlreadyActive:
            "Screendrop is already recording."
        case .noActiveRecording:
            "Screendrop isn't currently recording."
        case .noDisplayAvailable:
            "No display was available to record."
        }
    }
}

// MARK: - Screenshots

nonisolated struct TakeFullScreenScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Take Full Screen Screenshot"
    static var description = IntentDescription(
        "Captures the entire screen and adds it to Screendrop's history."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let url = await CaptureCoordinator.shared.captureFullscreenAwaiting() else {
            throw ScreendropIntentError.captureCancelled
        }
        return .result(value: IntentFile(fileURL: url))
    }
}

nonisolated struct TakeWindowScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Take Window Screenshot"
    static var description = IntentDescription(
        "Captures a window you click and adds it to Screendrop's history."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let url = await CaptureCoordinator.shared.captureWindowAwaiting() else {
            throw ScreendropIntentError.captureCancelled
        }
        return .result(value: IntentFile(fileURL: url))
    }
}

nonisolated struct TakeAreaScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Take Area Screenshot"
    static var description = IntentDescription(
        "Captures a region you drag out and adds it to Screendrop's history."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let url = await CaptureCoordinator.shared.captureAreaAwaiting() else {
            throw ScreendropIntentError.captureCancelled
        }
        return .result(value: IntentFile(fileURL: url))
    }
}

nonisolated struct CaptureTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Text"
    static var description = IntentDescription(
        "Recognizes the text inside a region you drag out, copies it to the clipboard, and returns it."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        switch await CaptureCoordinator.shared.captureTextAwaiting() {
        case .cancelled:
            throw ScreendropIntentError.captureCancelled
        case .noTextFound:
            throw ScreendropIntentError.noTextRecognized
        case .copied(let text):
            return .result(value: text)
        }
    }
}

// MARK: - Screen Recording

/// Shared by the recording intents: resolves the active display to an
/// `SCDisplay` and starts a fullscreen recording, bypassing the interactive
/// source-picker bar so automation stays deterministic.
@MainActor
private func startFullScreenRecording() async throws {
    guard !ScreenRecordingManager.shared.isActive else {
        throw ScreendropIntentError.recordingAlreadyActive
    }
    let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
    guard let content = try? await ScreenRecordingCapture.availableContent(),
          let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first else {
        throw ScreendropIntentError.noDisplayAvailable
    }
    CaptureCoordinator.shared.recordFullscreen(display)
}

nonisolated struct StartScreenRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Screen Recording"
    static var description = IntentDescription(
        "Starts recording the active display in Screendrop."
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        try await startFullScreenRecording()
        return .result()
    }
}

nonisolated struct StopScreenRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Screen Recording"
    static var description = IntentDescription(
        "Stops the current Screendrop screen recording."
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        guard ScreenRecordingManager.shared.isActive else {
            throw ScreendropIntentError.noActiveRecording
        }
        ScreenRecordingManager.shared.stopRecording()
        return .result()
    }
}

nonisolated struct ToggleScreenRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Screen Recording"
    static var description = IntentDescription(
        "Starts a full screen recording if Screendrop is idle, or stops the current one."
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        if ScreenRecordingManager.shared.isActive {
            ScreenRecordingManager.shared.stopRecording()
        } else {
            try await startFullScreenRecording()
        }
        return .result()
    }
}

// MARK: - Shortcuts

nonisolated struct ScreendropShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TakeFullScreenScreenshotIntent(),
            phrases: [
                "Take a screenshot with \(.applicationName)",
                "Capture the screen with \(.applicationName)"
            ],
            shortTitle: "Take Full Screen Screenshot",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: TakeWindowScreenshotIntent(),
            phrases: [
                "Take a window screenshot with \(.applicationName)"
            ],
            shortTitle: "Take Window Screenshot",
            systemImageName: "macwindow"
        )
        AppShortcut(
            intent: TakeAreaScreenshotIntent(),
            phrases: [
                "Take an area screenshot with \(.applicationName)"
            ],
            shortTitle: "Take Area Screenshot",
            systemImageName: "crop"
        )
        AppShortcut(
            intent: CaptureTextIntent(),
            phrases: [
                "Capture text with \(.applicationName)",
                "Copy text from the screen with \(.applicationName)"
            ],
            shortTitle: "Capture Text",
            systemImageName: "text.viewfinder"
        )
        AppShortcut(
            intent: StartScreenRecordingIntent(),
            phrases: [
                "Start recording with \(.applicationName)",
                "Start a screen recording with \(.applicationName)"
            ],
            shortTitle: "Start Screen Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopScreenRecordingIntent(),
            phrases: [
                "Stop recording with \(.applicationName)",
                "Stop the screen recording with \(.applicationName)"
            ],
            shortTitle: "Stop Screen Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: ToggleScreenRecordingIntent(),
            phrases: [
                "Toggle screen recording with \(.applicationName)"
            ],
            shortTitle: "Toggle Screen Recording",
            systemImageName: "record.circle.fill"
        )
    }
}
