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
    private var display: SCDisplay?
    private var keyMonitor: Any?

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
        panel.acceptsMouseMovedEvents = true

        let selectionView = RecordingAreaSelectionView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            pixelScale: CGSize(
                width: CGFloat(display.width) / max(screen.frame.width, 1),
                height: CGFloat(display.height) / max(screen.frame.height, 1)
            )
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
        panel.makeFirstResponder(selectionView)
        self.panel = panel
        installKeyMonitor()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func cancel() {
        finish(rect: nil)
    }

    private func finish(rect: CGRect?) {
        let completion = completion
        self.completion = nil
        display = nil
        removeKeyMonitor()
        panel?.orderOut(nil)
        panel = nil
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

    private enum DragMode {
        case none
        case drawing
        case moving
        case resizing(Handle)
    }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private let pixelScale: CGSize
    private let minimumSize: CGFloat = 16
    private let handleLength: CGFloat = 10
    private let handleHitPadding: CGFloat = 6

    private var selection: CGRect?
    private var drawStart: CGPoint?
    private var drawCurrent: CGPoint?
    private var dragMode: DragMode = .none
    private var moveOffset: CGSize = .zero
    private var resizeAnchor: CGRect = .zero

    override var acceptsFirstResponder: Bool {
        true
    }

    init(frame frameRect: NSRect, pixelScale: CGSize) {
        self.pixelScale = pixelScale
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    // MARK: - Active rect

    private var draftRect: CGRect? {
        guard let drawStart, let drawCurrent else { return nil }

        return CGRect(
            x: min(drawStart.x, drawCurrent.x),
            y: min(drawStart.y, drawCurrent.y),
            width: abs(drawStart.x - drawCurrent.x),
            height: abs(drawStart.y - drawCurrent.y)
        )
    }

    private var isDrawing: Bool {
        if case .drawing = dragMode { return true }
        return false
    }

    private var activeRect: CGRect? {
        isDrawing ? draftRect : selection
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        if let rect = activeRect {
            NSColor.clear.setFill()
            rect.fill(using: .clear)

            NSColor.white.withAlphaComponent(0.96).setStroke()
            let border = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            border.lineWidth = 2
            border.stroke()

            drawSelectionSize(for: rect)

            if !isDrawing, selection != nil {
                drawHandles(for: rect)
            }
        }

        if !isDrawing {
            drawHint()
        }
    }

    private func drawHint() {
        let text = selection == nil
            ? "Drag to select an area    Esc to cancel"
            : "Return to record    Drag to adjust    Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let attributedHint = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributedHint.size()
        let padding = CGSize(width: 14, height: 9)
        let badgeSize = CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        let badgeRect = CGRect(
            x: bounds.midX - badgeSize.width / 2,
            y: bounds.maxY - badgeSize.height - 28,
            width: badgeSize.width,
            height: badgeSize.height
        )

        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 9, yRadius: 9).fill()

        attributedHint.draw(
            at: CGPoint(
                x: badgeRect.minX + padding.width,
                y: badgeRect.minY + padding.height
            )
        )
    }

    private func drawHandles(for rect: CGRect) {
        for handle in Handle.allCases {
            let center = handlePoint(handle, in: rect)
            let square = CGRect(
                x: center.x - handleLength / 2,
                y: center.y - handleLength / 2,
                width: handleLength,
                height: handleLength
            )
            let path = NSBezierPath(roundedRect: square, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let selection {
            if event.clickCount >= 2, selection.contains(point) {
                commitSelection()
                return
            }
            if let handle = handle(at: point, in: selection) {
                dragMode = .resizing(handle)
                resizeAnchor = selection
                return
            }
            if selection.contains(point) {
                dragMode = .moving
                moveOffset = CGSize(width: point.x - selection.minX, height: point.y - selection.minY)
                NSCursor.closedHand.set()
                return
            }
        }

        dragMode = .drawing
        selection = nil
        drawStart = point
        drawCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch dragMode {
        case .drawing:
            drawCurrent = point
        case .moving:
            if let current = selection {
                var moved = current
                moved.origin = CGPoint(
                    x: point.x - moveOffset.width,
                    y: point.y - moveOffset.height
                )
                selection = clampToBounds(moved)
            }
        case .resizing(let handle):
            selection = resizedRect(anchor: resizeAnchor, handle: handle, to: point)
        case .none:
            break
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if case .drawing = dragMode {
            drawCurrent = point
            if let rect = draftRect, rect.width >= minimumSize, rect.height >= minimumSize {
                selection = clampToBounds(rect)
            } else {
                selection = nil
            }
            drawStart = nil
            drawCurrent = nil
        }

        dragMode = .none
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:            // Escape
            onCancel?()
        case 36, 76:        // Return / keypad Enter
            commitSelection()
        default:
            super.keyDown(with: event)
        }
    }

    private func commitSelection() {
        guard let selection else { return }
        onSelect?(selection)
    }

    // MARK: - Geometry

    private func handlePoint(_ handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.maxY)
        case .top:         return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func handleHitRect(_ handle: Handle, in rect: CGRect) -> CGRect {
        let center = handlePoint(handle, in: rect)
        let reach = handleLength / 2 + handleHitPadding
        return CGRect(
            x: center.x - reach,
            y: center.y - reach,
            width: reach * 2,
            height: reach * 2
        )
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        Handle.allCases.first { handleHitRect($0, in: rect).contains(point) }
    }

    private func resizedRect(anchor: CGRect, handle: Handle, to rawPoint: CGPoint) -> CGRect {
        var minX = anchor.minX
        var maxX = anchor.maxX
        var minY = anchor.minY
        var maxY = anchor.maxY

        let px = max(bounds.minX, min(rawPoint.x, bounds.maxX))
        let py = max(bounds.minY, min(rawPoint.y, bounds.maxY))

        switch handle {
        case .left, .topLeft, .bottomLeft:
            minX = min(px, anchor.maxX - minimumSize)
        case .right, .topRight, .bottomRight:
            maxX = max(px, anchor.minX + minimumSize)
        default:
            break
        }

        switch handle {
        case .bottom, .bottomLeft, .bottomRight:
            minY = min(py, anchor.maxY - minimumSize)
        case .top, .topLeft, .topRight:
            maxY = max(py, anchor.minY + minimumSize)
        default:
            break
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func clampToBounds(_ rect: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(result.size.width, bounds.width)
        result.size.height = min(result.size.height, bounds.height)
        result.origin.x = max(bounds.minX, min(result.origin.x, bounds.maxX - result.width))
        result.origin.y = max(bounds.minY, min(result.origin.y, bounds.maxY - result.height))
        return result
    }

    // MARK: - Cursor

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
        if window != nil {
            NSCursor.annotationPlus.set()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .annotationPlus)

        guard let selection, !isDrawing else { return }

        addCursorRect(selection, cursor: .openHand)
        for handle in Handle.allCases {
            addCursorRect(handleHitRect(handle, in: selection), cursor: cursor(for: handle))
        }
    }

    private func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return .crosshair
        }
    }

    // MARK: - Size badge

    private func drawSelectionSize(for rect: CGRect) {
        let pixelWidth = Int((rect.width * pixelScale.width).rounded())
        let pixelHeight = Int((rect.height * pixelScale.height).rounded())
        let label = "\(pixelWidth) x \(pixelHeight)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attributedLabel = NSAttributedString(string: label, attributes: attributes)
        let textSize = attributedLabel.size()
        let padding = CGSize(width: 10, height: 6)
        let badgeSize = CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        let badgeOrigin = badgeOrigin(for: rect, size: badgeSize)
        let badgeRect = CGRect(origin: badgeOrigin, size: badgeSize)

        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 7, yRadius: 7).fill()

        attributedLabel.draw(
            at: CGPoint(
                x: badgeRect.minX + padding.width,
                y: badgeRect.minY + padding.height
            )
        )
    }

    private func badgeOrigin(for rect: CGRect, size: CGSize) -> CGPoint {
        let preferred = CGPoint(x: rect.minX, y: rect.minY - size.height - 8)
        if bounds.contains(CGRect(origin: preferred, size: size)) {
            return preferred
        }

        let fallbackY = min(rect.maxY + 8, bounds.maxY - size.height - 8)
        return CGPoint(
            x: min(max(rect.minX, bounds.minX + 8), bounds.maxX - size.width - 8),
            y: max(fallbackY, bounds.minY + 8)
        )
    }
}
