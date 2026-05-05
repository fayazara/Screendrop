//
//  RecordingAreaSelectionPresenter.swift
//  OpenShot
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
    private var display: SCDisplay?

    private init() {}

    func selectArea(on display: SCDisplay, completion: @escaping (CGRect?) -> Void) {
        cancel()

        guard let screen = ActiveDisplayResolver.screen(for: display.displayID) ?? NSScreen.main else {
            completion(nil)
            return
        }

        self.display = display
        self.completion = completion

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

        let selectionView = RecordingAreaSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        selectionView.onCancel = { [weak self] in
            self?.finish(rect: nil)
        }
        selectionView.onSelect = { [weak self, weak panel] localRect in
            guard let self, let panel, let display = self.display else {
                self?.finish(rect: nil)
                return
            }

            let globalRect = CGRect(
                x: panel.frame.minX + localRect.minX,
                y: panel.frame.minY + localRect.minY,
                width: localRect.width,
                height: localRect.height
            )
            let sourceRect = CGRect(
                x: globalRect.minX - display.frame.minX,
                y: globalRect.minY - display.frame.minY,
                width: globalRect.width,
                height: globalRect.height
            )
            self.finish(rect: sourceRect)
        }

        panel.contentView = selectionView
        panel.makeFirstResponder(selectionView)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func cancel() {
        finish(rect: nil)
    }

    private func finish(rect: CGRect?) {
        let completion = completion
        self.completion = nil
        display = nil
        panel?.orderOut(nil)
        panel = nil
        completion?(rect)
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

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard let selectionRect else { return }

        NSColor.clear.setFill()
        selectionRect.fill(using: .clear)

        NSColor.white.withAlphaComponent(0.96).setStroke()
        let border = NSBezierPath(roundedRect: selectionRect, xRadius: 4, yRadius: 4)
        border.lineWidth = 2
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        currentPoint = point
        needsDisplay = true
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

