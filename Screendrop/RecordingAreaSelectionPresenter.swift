//
//  RecordingAreaSelectionPresenter.swift
//  Screendrop
//
//  Created by Codex on 01/05/26.
//

import AppKit
import ScreenCaptureKit

@MainActor
final class RecordingAreaSelectionPresenter {
    static let shared = RecordingAreaSelectionPresenter()

    private var panel: NSPanel?
    private var completion: ((CGRect?) -> Void)?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    private init() {}

    /// Area selection for screen recording, measured in the display's pixels.
    func selectArea(on display: SCDisplay, completion: @escaping (CGRect?) -> Void) {
        guard let screen = ActiveDisplayResolver.screen(for: display.displayID) ?? NSScreen.main else {
            completion(nil)
            return
        }
        selectArea(on: screen, completion: completion)
    }

    /// Area selection for screenshots. Returns the rectangle in global screen
    /// coordinates so the preview can sit exactly where it was drawn.
    func selectArea(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        SettingsWindowController.hideIfVisible()
        cancel()

        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication

        let panel = RecordingAreaSelectionPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true

        let selectionView = RecordingAreaSelectionView(
            frame: CGRect(origin: .zero, size: screen.frame.size)
        )
        selectionView.onCancel = { [weak self] in
            self?.finish(rect: nil)
        }
        selectionView.onSelect = { [weak self, weak panel] localRect in
            guard let self, let panel else {
                self?.finish(rect: nil)
                return
            }

            let globalRect = CGRect(
                x: panel.frame.minX + localRect.minX,
                y: panel.frame.minY + localRect.minY,
                width: localRect.width,
                height: localRect.height
            )
            self.finish(rect: globalRect)
        }

        panel.contentView = selectionView
        PreviewWindowCaptureExclusion.shared.register(window: panel)
        panel.makeFirstResponder(selectionView)
        self.panel = panel
        installKeyMonitor()
        // Activating matters for the cursor: an inactive app's tracking areas
        // do not own the pointer, so apps like OpenCode kept their I-beam.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        selectionView.beginSelectionCursorSession()
    }

    func cancel() {
        finish(rect: nil)
    }

    private func finish(rect: CGRect?) {
        let completion = completion
        self.completion = nil
        removeKeyMonitor()
        (panel?.contentView as? RecordingAreaSelectionView)?.endSelectionCursorSession()
        // Make sure the dimmed overlay is not part of the screenshot: alpha 0
        // is applied immediately, then the panel is ordered out.
        panel?.alphaValue = 0
        panel?.orderOut(nil)
        panel = nil

        if rect != nil {
            // Keep Screendrop active while the capture preview is up, so ⌘W
            // closes the preview instead of the window of the app behind it.
            CaptureShelfPresenter.shared.adoptPreviousApp(previousApp)
        } else {
            previousApp?.activate()
        }
        previousApp = nil
        completion?(rect)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }

            self?.finish(rect: nil)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

private final class RecordingAreaSelectionPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

private final class RecordingAreaSelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var didPushSelectionCursor = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        endSelectionCursorSession()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Light enough to keep the page readable underneath: CleanShot's
        // selector is a hint, not a blackout.
        NSColor.black.withAlphaComponent(0.14).setFill()
        bounds.fill()

        guard let selectionRect else { return }

        NSColor.clear.setFill()
        selectionRect.fill(using: .clear)

        NSColor.white.withAlphaComponent(0.96).setStroke()
        let border = NSBezierPath(roundedRect: selectionRect, xRadius: 4, yRadius: 4)
        border.lineWidth = 2
        border.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .annotationPlus)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
        if window != nil {
            beginSelectionCursorSession()
        } else {
            endSelectionCursorSession()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        beginSelectionCursorSession()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        currentPoint = point
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        beginSelectionCursorSession()
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        // Apps with aggressive cursor management (web views, remote desktops)
        // can steal the pointer; reassert ours on every move.
        beginSelectionCursorSession()
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let rect = selectionRect, rect.width >= 16, rect.height >= 16 else {
            onCancel?()
            return
        }

        onSelect?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    func beginSelectionCursorSession() {
        if didPushSelectionCursor {
            NSCursor.annotationPlus.set()
        } else {
            NSCursor.annotationPlus.push()
            didPushSelectionCursor = true
        }
    }

    func endSelectionCursorSession() {
        guard didPushSelectionCursor else { return }

        NSCursor.pop()
        didPushSelectionCursor = false
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }

        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(startPoint.x - currentPoint.x),
            height: abs(startPoint.y - currentPoint.y)
        )
    }
}
