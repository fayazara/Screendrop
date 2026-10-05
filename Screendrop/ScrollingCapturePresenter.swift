//
//  ScrollingCapturePresenter.swift
//  Screendrop
//

import AppKit
import ScreenCaptureKit
import SwiftUI

/// Runs a scrolling capture: the user draws a region, scrolls the content
/// under it, and clicks Done. Frames are sampled while they scroll and handed
/// to `ScrollingCaptureStitcher`, which keeps the rows that scrolled into view.
///
/// The region stays highlighted for the whole session, with a small bar below
/// it showing the stitched height and Done/Cancel. The app being scrolled
/// keeps the keyboard throughout, so the bar's buttons - or pressing the
/// shortcut again - are how a session ends.
@Observable
final class ScrollingCapturePresenter {
    static let shared = ScrollingCapturePresenter()

    struct Capture {
        let image: CGImage
        let displayID: CGDirectDisplayID
        /// Pixels per point of the captured display.
        let scale: CGFloat
    }

    /// ponytail: stops growing at 16,384 px, the GPU texture limit on Apple
    /// silicon, because the editor isn't verified with taller images. Raise
    /// once it is.
    private static let maximumHeight = 16_384
    /// Scrolling further than the region's height between two samples leaves
    /// no overlap to line frames up with, so sample often.
    private static let sampleInterval: Duration = .milliseconds(50)
    /// Right-edge strip left out of matching, where the overlay scroll bar
    /// appears while scrolling.
    private static let scrollBarWidth: CGFloat = 20

    private(set) var isRunning = false
    private(set) var stitchedHeight = 0
    /// The latest frame couldn't be lined up, usually from scrolling too far
    /// between samples. Scrolling back to where it left off recovers.
    private(set) var hasLostTrack = false
    /// The capture is as tall as it can get; only Done or Cancel are left.
    private(set) var hasReachedLimit = false

    @ObservationIgnored private var outcome: Outcome?
    @ObservationIgnored private var isSelectingArea = false
    @ObservationIgnored private var isCapturing = false
    @ObservationIgnored private var panel: NSPanel?

    private enum Outcome {
        case done
        case cancelled
    }

    private init() {}

    /// Returns the stitched capture, or nil if the user cancelled or nothing
    /// could be captured.
    func run() async -> Capture? {
        // An area recording is using the region highlight.
        guard !isRunning, !ScreenRecordingManager.shared.isActive else {
            NSSound.beep()
            return nil
        }
        isRunning = true
        outcome = nil
        defer { isRunning = false }

        guard ScreenRecordingManager.ensureScreenCapturePermission(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        let pointerDisplayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        guard let display = content.displays.first(where: { $0.displayID == pointerDisplayID }) ?? content.displays.first,
              outcome == nil,
              let rect = await selectArea(on: display),
              outcome != .cancelled else {
            return nil
        }

        // Screendrop's own windows are always left out, whatever the
        // app-windows preference says: the capture bar and highlight sit on
        // screen the whole time and must never end up in a frame.
        let filter = ScreenRecordingCapture.displayFilter(
            display: display,
            content: content,
            includesAppWindows: false
        )
        let screen = ActiveDisplayResolver.screen(for: display.displayID)
        // Whole points, so every frame maps 1:1 onto screen pixels with no
        // resampling. Stitching relies on rows matching exactly.
        let sourceRect = ScreenRecordingManager.sourceRect(
            forAppKitSelectionRect: rect,
            screenFrame: screen?.frame,
            contentRect: filter.contentRect
        ).integral.intersection(filter.contentRect)
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int((sourceRect.width * scale).rounded()))
        configuration.height = max(1, Int((sourceRect.height * scale).rounded()))
        configuration.showsCursor = false

        stitchedHeight = configuration.height
        hasLostTrack = false
        hasReachedLimit = false
        RecordingAreaHighlightPresenter.shared.show(display: display, rect: rect)
        showPanel(below: rect, on: screen)
        defer {
            hidePanel()
            RecordingAreaHighlightPresenter.shared.hide()
        }

        let stitcher: ScrollingCaptureStitcher
        do {
            let firstFrame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let firstStitcher = ScrollingCaptureStitcher(
                firstFrame: firstFrame,
                ignoredTrailingColumns: Int((Self.scrollBarWidth * scale).rounded())
            ) else { return nil }
            stitcher = firstStitcher
        } catch {
            FailureAlert.present(message: "Scrolling capture couldn't start", error: error)
            return nil
        }

        isCapturing = true
        defer { isCapturing = false }
        // ponytail: a sample that fails is skipped silently; a display that
        // keeps failing leaves the height still until the user ends the session.
        while outcome == nil {
            try? await Task.sleep(for: Self.sampleInterval)
            guard outcome == nil, !hasReachedLimit,
                  let frame = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
                continue
            }
            switch await stitcher.add(frame) {
            case .appended, .unchanged: hasLostTrack = false
            case .noMatch: hasLostTrack = true
            }
            // The image is cropped to the cap on Done, so never show more.
            stitchedHeight = min(await stitcher.stitchedHeight, Self.maximumHeight)
            hasReachedLimit = stitchedHeight >= Self.maximumHeight
        }

        guard outcome != .cancelled, let image = await stitcher.makeImage() else { return nil }
        let capped = image.height > Self.maximumHeight
            ? image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: Self.maximumHeight))
            : image
        return capped.map { Capture(image: $0, displayID: display.displayID, scale: scale) }
    }

    /// Ends the session, keeping what was captured. Until frames are being
    /// captured - the region still being drawn, or not yet on screen - there
    /// is nothing to keep, so it cancels instead.
    func finish() {
        if isCapturing {
            outcome = outcome ?? .done
        } else {
            cancel()
        }
    }

    func cancel() {
        outcome = .cancelled
        if isSelectingArea {
            RecordingAreaSelectionPresenter.shared.cancel()
        }
    }

    private func selectArea(on display: SCDisplay) async -> CGRect? {
        isSelectingArea = true
        defer { isSelectingArea = false }
        return await withCheckedContinuation { continuation in
            RecordingAreaSelectionPresenter.shared.selectArea(on: display) { rect in
                continuation.resume(returning: rect)
            }
        }
    }

    // MARK: - Bar

    private func showPanel(below rect: CGRect, on screen: NSScreen?) {
        let size = ScrollingCaptureBar.panelSize
        let panel = ScrollingCapturePanel(
            contentRect: CGRect(origin: Self.panelOrigin(size: size, below: rect, on: screen), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: ScrollingCaptureBar())
        hostingView.sizingOptions = []
        hostingView.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Centered under the region, else above it, else inside its bottom edge.
    private static func panelOrigin(size: CGSize, below rect: CGRect, on screen: NSScreen?) -> CGPoint {
        let visible = screen?.visibleFrame ?? rect
        let x = min(max(rect.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let below = rect.minY - size.height
        let above = rect.maxY
        let y = if below >= visible.minY {
            below
        } else if above + size.height <= visible.maxY {
            above
        } else {
            rect.minY
        }
        return CGPoint(x: x, y: y)
    }
}

private final class ScrollingCapturePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override func cancelOperation(_ sender: Any?) {
        ScrollingCapturePresenter.shared.cancel()
    }
}

private struct ScrollingCaptureBar: View {
    static let barSize = CGSize(width: 380, height: 52)
    /// Room around the bar for the glass shadow.
    static let margin: CGFloat = 12
    static let panelSize = CGSize(width: barSize.width + margin * 2, height: barSize.height + margin * 2)

    @State private var presenter = ScrollingCapturePresenter.shared

    /// The finish shortcut, when it registered, so the keyboard exit is
    /// discoverable while another app has the keyboard.
    private let finishShortcut: String? = HotkeyManager.shared.registrationErrors[.scrollingCapture] == nil
        ? CaptureHotkeyPreferences.shortcut(for: .scrollingCapture).displayString
        : nil

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(presenter.hasLostTrack ? .orange : .primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            Button("Cancel") {
                presenter.cancel()
            }
            Button("Done") {
                presenter.finish()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(width: Self.barSize.width, height: Self.barSize.height)
        .glassEffect(.regular, in: .capsule)
        .padding(Self.margin)
    }

    private var title: String {
        if presenter.hasReachedLimit {
            "Maximum height reached"
        } else if presenter.hasLostTrack {
            "Scroll back to where you left off"
        } else {
            "Scroll to capture"
        }
    }

    private var detail: String {
        if presenter.hasLostTrack && !presenter.hasReachedLimit {
            return "Couldn't line this view up"
        }
        let height = "\(presenter.stitchedHeight.formatted()) px tall"
        guard let finishShortcut else { return height }
        return "\(height) · \(finishShortcut) to finish"
    }
}
