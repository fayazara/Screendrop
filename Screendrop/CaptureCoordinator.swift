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
    var onShowPreview: ((URL, CGDirectDisplayID?, CaptureSource?) -> URL)?
    
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

    /// Opens the tab picker: point at a browser window and click (or press
    /// Return for the frontmost one) to capture its page.
    func captureBrowserTab() {
        let picker = RecordingSourceTargetPresenter.shared
        if picker.isActive, picker.purpose == .screenshot {
            picker.cancel()
            return
        }
        picker.begin(.browserTab, purpose: .screenshot)
    }

    func captureBrowserTab(_ content: BrowserContent) {
        Task { await performCaptureBrowserTab(content) }
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
        guard let url = await ScreenshotManager.shared.captureFullscreen(displayID: displayID) else { return nil }
        return finishCapture(url: url, displayID: displayID, source: source)
    }

    @discardableResult
    private func performCaptureWindow() async -> URL? {
        // The self-timer is handled by screencapture's `-T` so the delay
        // happens *after* the window is picked, not before.
        let probe = CaptureSourceProbe(tracksPointer: true)
        let captured = await ScreenshotManager.shared.captureWindow(
            includeShadow: ScreendropPreferences.captureWindowShadow,
            delaySeconds: ScreendropPreferences.captureDelaySeconds
        )
        let source = probe.finish(.window)
        guard let url = captured else { return nil }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        return finishCapture(url: url, displayID: displayID, source: source)
    }

    @discardableResult
    private func performCaptureArea() async -> URL? {
        // The self-timer is handled by screencapture's `-T` so the delay
        // happens *after* the area is drawn, not before.
        let probe = CaptureSourceProbe(tracksPointer: true)
        let captured = await ScreenshotManager.shared.captureArea(
            includeShadow: ScreendropPreferences.captureWindowShadow,
            delaySeconds: ScreendropPreferences.captureDelaySeconds
        )
        let source = probe.finish(.area)
        guard let url = captured else { return nil }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        return finishCapture(url: url, displayID: displayID, source: source)
    }

    /// Captures the page picked in the tab picker. The self-timer runs after
    /// the pick, like screencapture's `-T`, so the page can be scrolled or
    /// hovered into place first.
    @discardableResult
    private func performCaptureBrowserTab(_ picked: BrowserContent) async -> URL? {
        let displayID = Self.displayID(containing: picked.contentFrame)
        CaptureShelfPresenter.shared.setTargetDisplay(displayID)

        let delaySeconds = ScreendropPreferences.captureDelaySeconds
        guard await CaptureCountdownPresenter.shared.runIfNeeded(
            seconds: delaySeconds,
            displayID: displayID
        ) else { return nil }
        // The page may have moved or resized since it was picked.
        let content = BrowserContentLocator.relocate(picked) ?? picked
        guard let url = await ScreenshotManager.shared.captureBrowserContent(content) else { return nil }

        // The self-timer exists so the page can be changed before the shot;
        // without one, a different page means something else changed it.
        let expected = delaySeconds > 0 ? content : picked
        let pageChanged = BrowserContentLocator.relocate(content).map { !$0.showsSamePage(as: expected) } ?? false
        let historyURL = finishCapture(url: url, displayID: displayID, source: content.captureSource)
        if pageChanged {
            CaptureTextFeedbackPresenter.shared.showBrowserPageChanged(
                appName: content.captureSource.appName,
                displayID: displayID
            ) { [weak self] in
                self?.captureBrowserTab()
            }
        }
        return historyURL
    }

    private static func displayID(containing rect: CGRect) -> CGDirectDisplayID? {
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard CGGetDisplaysWithPoint(center, 1, &displayID, &count) == .success, count > 0 else {
            return ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        }
        return displayID
    }

    /// Capture Text is the odd one out: it recognizes the text inside the drawn
    /// area, puts it on the clipboard, and throws the image away. It
    /// deliberately skips `finishCapture` - there is no file to import into
    /// history, no preview card to raise, and no after-capture action to run -
    /// so the toast and the capture sound are its only feedback.
    ///
    /// The self-timer is handled by screencapture's `-T`, so the delay happens
    /// after the area is drawn, matching Capture Area.
    @discardableResult
    private func performCaptureText() async -> CaptureTextOutcome {
        guard let url = await ScreenshotManager.shared.captureArea(
            delaySeconds: ScreendropPreferences.captureDelaySeconds
        ) else { return .cancelled }
        defer { try? FileManager.default.removeItem(at: url) }

        // Resolved before recognition runs, so the toast lands on the display
        // the user was just drawing on rather than wherever the pointer
        // drifted to while Vision worked.
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
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

    func recordBrowserTab(_ window: SCWindow) {
        Task {
            let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
            guard await CaptureCountdownPresenter.shared.runIfNeeded(
                seconds: ScreendropPreferences.recordingStartDelaySeconds,
                displayID: displayID
            ) else { return }
            ScreenRecordingManager.shared.startRecording(source: ScreenRecordingSource(kind: .browserTab(window)))
        }
    }

    /// - Parameter rect: global AppKit coordinates, picked with
    ///   RecordingAreaSelectionPresenter.
    func recordArea(_ display: SCDisplay, rect: CGRect) {
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
    
    // MARK: - Preview

    @discardableResult
    @MainActor
    private func finishCapture(url: URL, displayID: CGDirectDisplayID?, source: CaptureSource?) -> URL {
        if ScreendropPreferences.playSounds {
            CaptureFeedbackSound.play()
        }
        return showPreview(url: url, displayID: displayID, source: source)
    }

    @discardableResult
    private func showPreview(url: URL, displayID: CGDirectDisplayID?, source: CaptureSource?) -> URL {
        guard let onShowPreview else {
            let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url, source: source)
            CaptureShelf.shared.add(url: historyURL)
            if AfterCaptureActions.isEnabled(.showOverlay, for: .screenshot) {
                CaptureShelfPresenter.shared.show(displayID: displayID)
            }
            return historyURL
        }

        return onShowPreview(url, displayID, source)
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
