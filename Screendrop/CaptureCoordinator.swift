//
//  CaptureCoordinator.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit
import ScreenCaptureKit
import SwiftUI

/// What a Capture Text run produced. `cancelled` and `noTextFound` look the
/// same to a caller handed a plain optional, but a Shortcut needs to tell the
/// user which one happened.
enum CaptureTextOutcome {
    case cancelled
    case noTextFound
    case copied(String)
}

/// Single long-lived coordinator that manages the capture → preview flow.
@Observable
final class CaptureCoordinator {
    
    static let shared = CaptureCoordinator()
    
    /// Set by the App to open the preview window. Returns the URL the
    /// capture was imported to in history, so awaitable capture callers
    /// (App Intents) can hand the finished file to their result.
    var onShowPreview: ((URL, CGDirectDisplayID?, CaptureSource?, CGRect?) -> URL)?
    
    private init() {}
    
    // MARK: - Capture Actions

    func captureFullscreen() {
        Task { await performCaptureFullscreen() }
    }

    func captureWindow() {
        Task { await performCaptureWindow() }
    }

    func captureArea() {
        Task { await performCaptureArea() }
    }

    func captureText() {
        Task { await performCaptureText() }
    }

    // MARK: - Awaitable Capture Actions

    /// Awaitable variants for callers (App Intents / Shortcuts) that need the
    /// resulting file back to hand off to a following action. Both routes
    /// funnel through the same finish-capture path as the hotkey/menu bar
    /// triggers, so history import, sound, and preview behavior stay
    /// identical either way.
    @discardableResult
    func captureFullscreenAwaiting() async -> URL? {
        await performCaptureFullscreen()
    }

    @discardableResult
    func captureWindowAwaiting() async -> URL? {
        await performCaptureWindow()
    }

    @discardableResult
    func captureAreaAwaiting() async -> URL? {
        await performCaptureArea()
    }

    /// Returns the recognized text rather than a URL - Capture Text produces
    /// no file, and a Shortcuts action that hands back a string is what makes
    /// it composable with the rest of a workflow. The outcome distinguishes a
    /// cancelled selection from a region that simply had no text in it, which
    /// a Shortcut needs to report accurately.
    @discardableResult
    func captureTextAwaiting() async -> CaptureTextOutcome {
        await performCaptureText()
    }

    @discardableResult
    private func performCaptureFullscreen() async -> URL? {
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        CaptureShelfPresenter.shared.setTargetDisplay(displayID)

        guard await CaptureCountdownPresenter.shared.runIfNeeded(
            seconds: ScreendropPreferences.captureDelaySeconds,
            displayID: displayID
        ) else { return nil }
        let probe = CaptureSourceProbe(tracksPointer: false)
        let source = probe.finish(.display(displayID))
        hideFloatingCaptures()
        let url = await ScreenshotManager.shared.captureFullscreen(displayID: displayID)
        restoreFloatingCaptures()
        guard let url else { return nil }
        return finishCapture(url: url, displayID: displayID, source: source)
    }

    @discardableResult
    private func performCaptureWindow() async -> URL? {
        // The self-timer is handled by screencapture's `-T` so the delay
        // happens *after* the window is picked, not before.
        let probe = CaptureSourceProbe(tracksPointer: true)
        hideFloatingCaptures()
        let captured = await ScreenshotManager.shared.captureWindow(
            includeShadow: ScreendropPreferences.captureWindowShadow,
            delaySeconds: ScreendropPreferences.captureDelaySeconds
        )
        restoreFloatingCaptures()
        let source = probe.finish(.window)
        guard let url = captured else { return nil }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        return finishCapture(url: url, displayID: displayID, source: source)
    }

    @discardableResult
    private func performCaptureArea() async -> URL? {
        guard let screen = ActiveDisplayResolver.activeScreen(preferPointer: true) ?? NSScreen.main else {
            return nil
        }
        let displayID = ActiveDisplayResolver.displayID(for: screen)
            ?? ActiveDisplayResolver.activeDisplayID()
        CaptureShelfPresenter.shared.setTargetDisplay(displayID)

        let probe = CaptureSourceProbe(tracksPointer: true)
        // Screendrop draws the selection itself rather than handing over to
        // macOS's UI, so it knows exactly which rectangle was captured and can
        // put the preview on it.
        let selection = await withCheckedContinuation { (continuation: CheckedContinuation<CGRect?, Never>) in
            RecordingAreaSelectionPresenter.shared.selectArea(on: screen) { rect in
                continuation.resume(returning: rect)
            }
        }
        guard let selection, selection.width >= 1, selection.height >= 1 else { return nil }

        // Let the selection overlay leave the screen before capturing it.
        try? await Task.sleep(for: .milliseconds(140))

        // The self-timer now runs after the area is drawn, as it did with
        // screencapture's `-T`.
        guard await CaptureCountdownPresenter.shared.runIfNeeded(
            seconds: ScreendropPreferences.captureDelaySeconds,
            displayID: displayID
        ) else { return nil }

        let source = probe.finish(.area)
        hideFloatingCaptures()
        let url = await ScreenshotManager.shared.captureRect(selection)
        restoreFloatingCaptures()
        guard let url else { return nil }
        return finishCapture(url: url, displayID: displayID, source: source, selection: selection)
    }

    /// Capture Text is the odd one out: it recognizes the text inside the drawn
    /// area, puts it on the clipboard, and throws the image away. It
    /// deliberately skips `finishCapture` - there is no file to import into
    /// history, no preview card to raise, and no after-capture action to run -
    /// so the toast and the capture sound are its only feedback.
    ///
    /// It uses the same in-app selector as Capture Area. Handing this to
    /// `screencapture -i` left the macOS screenshot toolbar at the bottom of
    /// the display, which is the system's UI rather than Screendrop's.
    @discardableResult
    private func performCaptureText() async -> CaptureTextOutcome {
        guard let screen = ActiveDisplayResolver.activeScreen(preferPointer: true) ?? NSScreen.main else {
            return .cancelled
        }
        let displayID = ActiveDisplayResolver.displayID(for: screen)
            ?? ActiveDisplayResolver.activeDisplayID()

        let selection = await withCheckedContinuation { (continuation: CheckedContinuation<CGRect?, Never>) in
            RecordingAreaSelectionPresenter.shared.selectArea(on: screen) { rect in
                continuation.resume(returning: rect)
            }
        }
        guard let selection, selection.width >= 1, selection.height >= 1 else { return .cancelled }

        // Let the dimmed selector leave the screen before capturing through it.
        try? await Task.sleep(for: .milliseconds(140))
        guard await CaptureCountdownPresenter.shared.runIfNeeded(
            seconds: ScreendropPreferences.captureDelaySeconds,
            displayID: displayID
        ) else {
            CaptureShelfPresenter.shared.restoreAdoptedAppIfNeeded()
            return .cancelled
        }

        guard let url = await ScreenshotManager.shared.captureRect(selection) else {
            CaptureShelfPresenter.shared.restoreAdoptedAppIfNeeded()
            return .cancelled
        }
        defer {
            try? FileManager.default.removeItem(at: url)
            CaptureShelfPresenter.shared.restoreAdoptedAppIfNeeded()
        }

        // `displayID` was resolved before the selector opened, so the toast
        // lands on the display the user was just drawing on rather than
        // wherever the pointer drifted while Vision worked.
        let text = await ImageTextRecognizer.recognizeText(at: url)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            CaptureTextFeedbackPresenter.shared.showNoTextFound(displayID: displayID)
            if ScreendropPreferences.playSounds {
                NSSound.beep()
            }
            return .noTextFound
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        CaptureTextFeedbackPresenter.shared.showCopied(text: text, displayID: displayID)
        if ScreendropPreferences.playSounds {
            CaptureFeedbackSound.play()
        }
        return .copied(text)
    }

    func recordFullscreen(_ display: SCDisplay) {
        Task {
            guard await CaptureCountdownPresenter.shared.runIfNeeded(
                seconds: ScreendropPreferences.recordingStartDelaySeconds,
                displayID: display.displayID
            ) else { return }
            ScreenRecordingManager.shared.startRecording(source: ScreenRecordingSource(kind: .fullscreen(display)))
        }
    }

    func recordWindow(_ window: SCWindow) {
        Task {
            let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
            guard await CaptureCountdownPresenter.shared.runIfNeeded(
                seconds: ScreendropPreferences.recordingStartDelaySeconds,
                displayID: displayID
            ) else { return }
            ScreenRecordingManager.shared.startRecording(source: ScreenRecordingSource(kind: .window(window)))
        }
    }

    func recordArea(_ display: SCDisplay) {
        RecordingAreaSelectionPresenter.shared.selectArea(on: display) { rect in
            guard let rect else { return }
            Task {
                guard await CaptureCountdownPresenter.shared.runIfNeeded(
                    seconds: ScreendropPreferences.recordingStartDelaySeconds,
                    displayID: display.displayID
                ) else { return }
                ScreenRecordingManager.shared.startRecording(
                    source: ScreenRecordingSource(kind: .area(display: display, rect: rect))
                )
            }
        }
    }
    
    /// A finished scrolling capture: import it like any other screenshot and
    /// raise the normal preview tile (no capture rectangle, so it is not
    /// auto-pinned at the selected area).
    @discardableResult
    func presentScrollingCapture(url: URL, displayID: CGDirectDisplayID?) -> URL? {
        defer { try? FileManager.default.removeItem(at: url) }
        // A long capture always goes to the Screenshots folder, even if the
        // automatic Save after-capture action is off. If the configured
        // folder is unavailable (an offline cloud drive, for example), fall
        // back to the app's default folder rather than silently losing the
        // capture.
        let savedURL: URL
        do {
            savedURL = try ScreenshotFileActions.saveToDefaultLocation(from: url)
        } catch {
            do {
                let fallback = ScreendropPreferences.defaultExportDirectory
                savedURL = try ScreenshotFileActions.saveToDirectory(fallback, from: url)
                FailureAlert.present(
                    message: "Saved to the default Screenshots folder.",
                    error: error,
                    detail: "The configured export folder could not be used, so the capture was saved to \(fallback.path)."
                )
            } catch let fallbackError {
                FailureAlert.present(
                    message: "The scrolling capture could not be saved.",
                    error: fallbackError,
                    detail: "Check the export folder in Settings → General."
                )
                return nil
            }
        }

        let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: savedURL)
        CaptureShelfPresenter.shared.prepareCapture(displayID: displayID, selection: nil)
        CaptureShelf.shared.add(url: historyURL, preSavedURL: savedURL)
        if AfterCaptureActions.isEnabled(.showOverlay, for: .screenshot) {
            CaptureShelfPresenter.shared.show(displayID: displayID, selection: nil)
        }
        return historyURL
    }

    private func hideFloatingCaptures() {
        CaptureShelfPresenter.shared.hidePreviewForCapture()
        PinnedScreenshotPresenter.shared.hideAllForCapture()
    }

    private func restoreFloatingCaptures() {
        CaptureShelfPresenter.shared.restorePreviewAfterCapture()
        PinnedScreenshotPresenter.shared.restoreAfterCapture()
    }

    // MARK: - Preview

    @discardableResult
    @MainActor
    private func finishCapture(
        url: URL,
        displayID: CGDirectDisplayID?,
        source: CaptureSource?,
        selection: CGRect? = nil
    ) -> URL {
        if ScreendropPreferences.playSounds {
            CaptureFeedbackSound.play()
        }
        return showPreview(url: url, displayID: displayID, source: source, selection: selection)
    }

    @discardableResult
    private func showPreview(
        url: URL,
        displayID: CGDirectDisplayID?,
        source: CaptureSource?,
        selection: CGRect? = nil
    ) -> URL {
        guard let onShowPreview else {
            let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url, source: source)
            CaptureShelf.shared.add(url: historyURL)
            if AfterCaptureActions.isEnabled(.showOverlay, for: .screenshot) {
                CaptureShelfPresenter.shared.show(displayID: displayID, selection: selection)
            }
            return historyURL
        }

        return onShowPreview(url, displayID, source, selection)
    }
}

@MainActor
private enum CaptureFeedbackSound {
    private static let sound: NSSound? = {
        let url = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif")
        return NSSound(contentsOf: url, byReference: true)
    }()

    static func play() {
        guard let sound else { return }

        sound.stop()
        sound.currentTime = 0
        sound.play()
    }
}
