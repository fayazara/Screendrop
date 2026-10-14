//
//  RecordingAreaHighlightPresenter.swift
//  Screendrop
//

import AppKit
import ScreenCaptureKit

/// Dims everything outside the selected region while an area recording is in
/// progress, so the recording boundary stays visible under whatever windows
/// the user brings to the front. Purely decorative and click-through. The panel
/// registers with PreviewWindowCaptureExclusion, which keeps it out of captures
/// unless the include-app-windows preference is enabled.
@MainActor
final class RecordingAreaHighlightPresenter {
    static let shared = RecordingAreaHighlightPresenter()

    private var panel: NSPanel?

    private init() {}

    /// - Parameter rect: the recorded area in AppKit/global screen
    ///   coordinates, matching `ScreenRecordingSource.Kind.area`'s rect.
    func show(display: SCDisplay, rect: CGRect) {
        hide()

        guard let screen = ActiveDisplayResolver.screen(for: display.displayID) ?? NSScreen.main else {
            return
        }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let localRect = CGRect(
            x: rect.minX - screen.frame.minX,
            y: rect.minY - screen.frame.minY,
            width: rect.width,
            height: rect.height
        )
        panel.contentView = RecordingAreaHighlightView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            highlightRect: localRect
        )

        PreviewWindowCaptureExclusion.shared.register(window: panel)
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class RecordingAreaHighlightView: NSView {
    private let highlightRect: CGRect

    init(frame frameRect: NSRect, highlightRect: CGRect) {
        self.highlightRect = highlightRect
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    // The same dim as the area selection, so the region looks the same while
    // capturing as while drawing it. A light tint in dark mode was invisible
    // over light content. Leave a one-point gap so the centered two-point
    // stroke's antialiasing stays clear of fractional selection edges.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        NSColor.clear.setFill()
        highlightRect.fill(using: .clear)

        NSColor.white.withAlphaComponent(0.96).setStroke()
        let border = NSBezierPath(rect: highlightRect.insetBy(dx: -2, dy: -2))
        border.lineWidth = 2
        border.stroke()
    }
}
