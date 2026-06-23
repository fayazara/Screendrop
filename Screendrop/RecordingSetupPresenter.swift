//
//  RecordingSetupPresenter.swift
//  Screendrop
//
//  Unified entry point for the recording setup HUD (Full Screen / Area).
//  Shows a full-screen selection overlay and a floating toolbar,
//  then hands a resolved ScreenRecordingSource to ScreenRecordingManager.
//
//  Area mode geometry (drag, 8 handles, aspect lock) mirrors the logic in
//  RecordingAreaSelectionView from RecordingAreaSelectionPresenter.  The
//  duplication is intentional: RecordingAreaSelectionPresenter will be
//  retired in a follow-up cleanup PR once all entry points route here.
//

import AppKit
import ScreenCaptureKit
import SwiftUI

// MARK: - Presenter

@MainActor
final class RecordingSetupPresenter {
    static let shared = RecordingSetupPresenter()

    private var overlayPanel: RecordingSetupKeyPanel?
    private var toolbarPanel: NSPanel?
    private var overlayView:  RecordingSetupOverlayView?
    private var model:        RecordingSetupModel?
    private var display:      SCDisplay?
    private var keyMonitor:   Any?

    private init() {}

    /// Resolve the active display and present the HUD.
    func begin() {
        // Don't interrupt an in-flight recording.
        guard ScreenRecordingManager.shared.state == .idle else { return }

        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        Task {
            do {
                let content  = try await ScreenRecordingCapture.availableContent()
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                                 ?? content.displays.first else { return }
                guard let screen = ActiveDisplayResolver.screen(for: display.displayID)
                                ?? NSScreen.main else { return }
                show(display: display, screen: screen)
            } catch {
                // Screen recording permission denied or SCK unavailable — fail silently.
            }
        }
    }

    func cancel() { dismiss() }

    // MARK: Private — lifecycle

    private func show(display: SCDisplay, screen: NSScreen) {
        dismiss()   // tear down any previous HUD

        self.display = display

        let pixelScale = CGSize(
            width:  CGFloat(display.width)  / max(screen.frame.width,  1),
            height: CGFloat(display.height) / max(screen.frame.height, 1)
        )

        let setupModel = RecordingSetupModel(pixelScale: pixelScale)
        self.model = setupModel

        // ── Overlay ────────────────────────────────────────────────────────
        let panel = RecordingSetupKeyPanel(
            contentRect: screen.frame,
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.backgroundColor         = .clear
        panel.isOpaque                = false
        panel.hasShadow               = false
        panel.level                   = .screenSaver
        panel.collectionBehavior      = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed    = false
        panel.acceptsMouseMovedEvents = true
        panel.sharingType             = .none

        let ov = RecordingSetupOverlayView(
            frame:      CGRect(origin: .zero, size: screen.frame.size),
            pixelScale: pixelScale
        )
        ov.onConfirm          = { [weak self] in self?.confirm() }
        ov.onCancel           = { [weak self] in self?.dismiss() }
        ov.onSelectionChanged = { [weak setupModel] rect in setupModel?.selection = rect }

        panel.contentView = ov
        panel.makeFirstResponder(ov)
        overlayPanel = panel
        overlayView  = ov

        // ── Toolbar ────────────────────────────────────────────────────────
        toolbarPanel = makeToolbarPanel(screen: screen, model: setupModel)

        installKeyMonitor()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // Child window relationship guarantees the toolbar is always above the
        // overlay regardless of subsequent mouse interactions on the overlay.
        if let tp = toolbarPanel {
            panel.addChildWindow(tp, ordered: .above)
        }
    }

    private func confirm() {
        guard let source = resolveSource() else { return }
        let mgr = ScreenRecordingManager.shared
        dismiss()
        mgr.startRecording(source: source)
    }

    private func dismiss() {
        removeKeyMonitor()
        if let tp = toolbarPanel {
            overlayPanel?.removeChildWindow(tp)
            tp.orderOut(nil)
        }
        toolbarPanel = nil
        overlayPanel?.orderOut(nil); overlayPanel = nil
        overlayView = nil
        model       = nil
        display     = nil
    }

    private func resolveSource() -> ScreenRecordingSource? {
        guard let display, let model else { return nil }
        switch model.mode {
        case .fullscreen:
            return ScreenRecordingSource(kind: .fullscreen(display))
        case .area:
            guard let rect = model.selection else { return nil }
            return ScreenRecordingSource(kind: .area(display: display, rect: rect))
        }
    }

    // MARK: Private — toolbar panel

    private func makeToolbarPanel(screen: NSScreen, model: RecordingSetupModel) -> NSPanel {
        let view = RecordingSetupToolbarView(
            model:          model,
            onStart:        { [weak self] in self?.confirm() },
            onCancel:       { [weak self] in self?.dismiss() },
            onAspectChange: { [weak self] aspect in self?.overlayView?.applyAspect(aspect) },
            onModeChange:   { [weak self] mode  in self?.overlayView?.applyMode(mode) }
        )

        let hosting    = NSHostingView(rootView: view)
        let idealSize  = hosting.fittingSize
        let panelWidth = max(idealSize.width, 480)
        let panelH     = idealSize.height > 0 ? idealSize.height : 72

        let panel = NSPanel(
            contentRect: CGRect(
                x: screen.frame.midX - panelWidth / 2,
                y: screen.frame.minY + 32,
                width: panelWidth, height: panelH
            ),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.backgroundColor         = .clear
        panel.isOpaque                = false
        panel.hasShadow               = false
        panel.level                   = .screenSaver
        panel.collectionBehavior      = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed    = false
        panel.sharingType             = .none
        panel.contentView             = hosting
        return panel
    }

    // MARK: Private — key monitor

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            self?.dismiss()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let km = keyMonitor { NSEvent.removeMonitor(km); keyMonitor = nil }
    }
}

// MARK: - Key panel subclass

private final class RecordingSetupKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Overlay view

/// Full-screen overlay that handles the setup HUD's recording modes.
///
/// Area mode geometry (drag, 8 handles, aspect-lock) is intentionally
/// duplicated from `RecordingAreaSelectionView` and will be consolidated
/// when `RecordingAreaSelectionPresenter` is retired.
private final class RecordingSetupOverlayView: NSView {

    // Callbacks
    var onConfirm:          (() -> Void)?
    var onCancel:           (() -> Void)?
    var onSelectionChanged: ((CGRect?) -> Void)?

    // MARK: State

    private(set) var mode: RecordingSetupMode = .area

    // Area mode
    var aspect: CropAspectRatio = .freeform

    private enum DragMode { case none, drawing, moving, resizing(Handle) }
    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private let pixelScale:   CGSize
    private let minimumSize:  CGFloat = 16
    private let handleLength: CGFloat = 10
    private let handleHitPad: CGFloat = 6

    private var selection:    CGRect?
    private var drawStart:    CGPoint?
    private var drawCurrent:  CGPoint?
    private var dragMode:     DragMode = .none
    private var moveOffset:   CGSize   = .zero
    private var resizeAnchor: CGRect   = .zero
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, pixelScale: CGSize) {
        self.pixelScale = pixelScale
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Mode + aspect switching

    func applyMode(_ newMode: RecordingSetupMode) {
        mode          = newMode
        selection     = nil
        drawStart     = nil
        drawCurrent   = nil
        dragMode      = .none
        onSelectionChanged?(nil)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func applyAspect(_ newAspect: CropAspectRatio) {
        aspect = newAspect
        guard let cur = selection, let ratio = newAspect.pixelRatio(imageSize: .zero) else {
            needsDisplay = true; return
        }
        let cw = cur.width, ch = cur.height
        var w: CGFloat
        var h: CGFloat
        if cw / max(ch, 0.001) > ratio { h = ch; w = h * ratio }
        else                           { w = cw; h = w / ratio }
        if w > bounds.width  { w = bounds.width;  h = w / ratio }
        if h > bounds.height { h = bounds.height; w = h * ratio }
        selection = CGRect(
            x: min(max(cur.midX - w / 2, bounds.minX), bounds.maxX - w),
            y: min(max(cur.midY - h / 2, bounds.minY), bounds.maxY - h),
            width: w, height: h
        )
        onSelectionChanged?(selection)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        switch mode {
        case .fullscreen: drawFullscreenMode()
        case .area:       drawAreaMode()
        }
    }

    private func drawFullscreenMode() {
        let inset = bounds.insetBy(dx: 4, dy: 4)
        NSColor.clear.setFill()
        inset.fill(using: .clear)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        path.lineWidth = 2.5
        path.stroke()
        drawHint("Click anywhere or press Return to record full screen")
    }

    private func drawAreaMode() {
        let isDrawing: Bool = { if case .drawing = dragMode { return true }; return false }()
        let rect = isDrawing ? draftRect : selection

        if let rect {
            NSColor.clear.setFill()
            rect.fill(using: .clear)
            NSColor.white.withAlphaComponent(0.96).setStroke()
            let border = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            border.lineWidth = 2
            border.stroke()
            drawSelectionSize(for: rect)
            if !isDrawing, selection != nil { drawHandles(for: rect) }
        }

        if !isDrawing, selection == nil {
            drawHint("Drag to select an area")
        }
    }

    /// Corners only when an aspect preset is active — edge handles would
    /// silently break the ratio lock.
    private var activeHandles: [Handle] {
        aspect.locksAspect
            ? [.topLeft, .topRight, .bottomLeft, .bottomRight]
            : Handle.allCases
    }

    private func drawHandles(for rect: CGRect) {
        for handle in activeHandles {
            let center = handlePoint(handle, in: rect)
            let sq = CGRect(
                x: center.x - handleLength / 2, y: center.y - handleLength / 2,
                width: handleLength, height: handleLength
            )
            let path = NSBezierPath(roundedRect: sq, xRadius: 2, yRadius: 2)
            NSColor.white.setFill(); path.fill()
            NSColor.black.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1; path.stroke()
        }
    }

    private func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str      = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.size()
        let pad      = CGSize(width: 14, height: 9)
        let bSize    = CGSize(width: textSize.width + pad.width * 2, height: textSize.height + pad.height * 2)
        let bRect    = CGRect(
            x: bounds.midX - bSize.width / 2,
            y: bounds.maxY - bSize.height - 28,
            width: bSize.width, height: bSize.height
        )
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: bRect, xRadius: 9, yRadius: 9).fill()
        str.draw(at: CGPoint(x: bRect.minX + pad.width, y: bRect.minY + pad.height))
    }

    // MARK: - Mouse events

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch mode {
        case .fullscreen:
            confirm()
        case .area:
            areaMouseDown(at: point, clickCount: event.clickCount)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        areaMouseDragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch mode {
        case .area:
            areaMouseUp(at: point)
        case .fullscreen:
            break
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:     onCancel?()  // Esc (also caught by presenter's key monitor)
        case 36, 76: confirm()   // Return / keypad Enter
        default:     super.keyDown(with: event)
        }
    }

    private func confirm() {
        switch mode {
        case .fullscreen:            onConfirm?()
        case .area   where selection != nil: onConfirm?()
        default: break
        }
    }

    // MARK: - Area mode helpers

    private var isDrawing: Bool { if case .drawing = dragMode { return true }; return false }

    private var draftRect: CGRect? {
        guard let drawStart, let drawCurrent else { return nil }
        let dx = drawCurrent.x - drawStart.x
        let dy = drawCurrent.y - drawStart.y

        guard let ratio = aspect.pixelRatio(imageSize: .zero) else {
            return CGRect(
                x: min(drawStart.x, drawCurrent.x),
                y: min(drawStart.y, drawCurrent.y),
                width: abs(dx), height: abs(dy)
            )
        }
        let cw = abs(dx), ch = abs(dy)
        let w: CGFloat
        let h: CGFloat
        if cw / max(ch, 0.001) > ratio { h = ch; w = h * ratio }
        else                           { w = cw; h = w / ratio }
        return CGRect(
            x: dx >= 0 ? drawStart.x : drawStart.x - w,
            y: dy >= 0 ? drawStart.y : drawStart.y - h,
            width: w, height: h
        )
    }

    private func areaMouseDown(at point: CGPoint, clickCount: Int) {
        if let sel = selection {
            if clickCount >= 2, sel.contains(point) { confirm(); return }
            if let h = handle(at: point, in: sel) { dragMode = .resizing(h); resizeAnchor = sel; return }
            if sel.contains(point) {
                dragMode   = .moving
                moveOffset = CGSize(width: point.x - sel.minX, height: point.y - sel.minY)
                NSCursor.closedHand.set()
                return
            }
        }
        dragMode  = .drawing
        selection = nil
        onSelectionChanged?(nil)
        drawStart = point; drawCurrent = point
        needsDisplay = true
    }

    private func areaMouseDragged(to point: CGPoint) {
        switch dragMode {
        case .drawing:
            drawCurrent = point
        case .moving:
            guard let cur = selection else { break }
            var moved = cur
            moved.origin = CGPoint(x: point.x - moveOffset.width, y: point.y - moveOffset.height)
            selection = clampToBounds(moved)
            onSelectionChanged?(selection)
        case .resizing(let h):
            selection = resizedRect(anchor: resizeAnchor, handle: h, to: point)
            onSelectionChanged?(selection)
        case .none: break
        }
        needsDisplay = true
    }

    private func areaMouseUp(at point: CGPoint) {
        if case .drawing = dragMode {
            drawCurrent = point
            if let rect = draftRect, rect.width >= minimumSize, rect.height >= minimumSize {
                selection = clampToBounds(rect)
            } else {
                selection = nil
            }
            drawStart = nil; drawCurrent = nil
            onSelectionChanged?(selection)
        }
        dragMode = .none
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Area geometry

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
        let c = handlePoint(handle, in: rect)
        let r = handleLength / 2 + handleHitPad
        return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        activeHandles.first { handleHitRect($0, in: rect).contains(point) }
    }

    private func resizedRect(anchor: CGRect, handle: Handle, to raw: CGPoint) -> CGRect {
        let ratio = aspect.pixelRatio(imageSize: .zero)
        let px = max(bounds.minX, min(raw.x, bounds.maxX))
        let py = max(bounds.minY, min(raw.y, bounds.maxY))
        let p  = CGPoint(x: px, y: py)

        switch handle {
        case .topLeft:
            if let r = ratio { return aspectLockedCorner(anchorX: anchor.maxX, anchorY: anchor.minY, signX: -1, signY: +1, to: p, ratio: r) }
        case .topRight:
            if let r = ratio { return aspectLockedCorner(anchorX: anchor.minX, anchorY: anchor.minY, signX: +1, signY: +1, to: p, ratio: r) }
        case .bottomLeft:
            if let r = ratio { return aspectLockedCorner(anchorX: anchor.maxX, anchorY: anchor.maxY, signX: -1, signY: -1, to: p, ratio: r) }
        case .bottomRight:
            if let r = ratio { return aspectLockedCorner(anchorX: anchor.minX, anchorY: anchor.maxY, signX: +1, signY: -1, to: p, ratio: r) }
        default: break
        }

        var minX = anchor.minX, maxX = anchor.maxX
        var minY = anchor.minY, maxY = anchor.maxY
        switch handle {
        case .left,   .topLeft,     .bottomLeft:  minX = min(px, anchor.maxX - minimumSize)
        case .right,  .topRight,    .bottomRight: maxX = max(px, anchor.minX + minimumSize)
        default: break
        }
        switch handle {
        case .bottom, .bottomLeft,  .bottomRight: minY = min(py, anchor.maxY - minimumSize)
        case .top,    .topLeft,     .topRight:    maxY = max(py, anchor.minY + minimumSize)
        default: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func aspectLockedCorner(
        anchorX: CGFloat, anchorY: CGFloat,
        signX: CGFloat, signY: CGFloat,
        to point: CGPoint, ratio: CGFloat
    ) -> CGRect {
        let cw = max((point.x - anchorX) * signX, minimumSize)
        let ch = max((point.y - anchorY) * signY, minimumSize)
        var w: CGFloat
        var h: CGFloat
        if cw / max(ch, 0.001) > ratio { h = ch; w = h * ratio }
        else                           { w = cw; h = w / ratio }
        let maxW = signX > 0 ? bounds.maxX - anchorX : anchorX - bounds.minX
        let maxH = signY > 0 ? bounds.maxY - anchorY : anchorY - bounds.minY
        if w > maxW { w = maxW; h = w / ratio }
        if h > maxH { h = maxH; w = h * ratio }
        w = max(w, minimumSize); h = max(h, minimumSize)
        return CGRect(
            x: signX > 0 ? anchorX : anchorX - w,
            y: signY > 0 ? anchorY : anchorY - h,
            width: w, height: h
        )
    }

    private func clampToBounds(_ rect: CGRect) -> CGRect {
        var r = rect
        r.size.width  = min(r.size.width,  bounds.width)
        r.size.height = min(r.size.height, bounds.height)
        r.origin.x    = max(bounds.minX, min(r.origin.x, bounds.maxX - r.width))
        r.origin.y    = max(bounds.minY, min(r.origin.y, bounds.maxY - r.height))
        return r
    }

    // MARK: - Tracking / key

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        // Re-key the overlay whenever the cursor returns to it (e.g. after
        // clicking the toolbar's mode picker), so the next click is a normal
        // mouseDown instead of a swallowed first-mouse activation click.
        window?.makeKey()
    }

    // MARK: - Cursor

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
        if window != nil { NSCursor.annotationPlus.set() }
    }

    override func resetCursorRects() {
        switch mode {
        case .fullscreen:
            addCursorRect(bounds, cursor: .arrow)
        case .area:
            addCursorRect(bounds, cursor: .annotationPlus)
            guard let sel = selection, !isDrawing else { return }
            addCursorRect(sel, cursor: .openHand)
            for h in activeHandles {
                addCursorRect(handleHitRect(h, in: sel), cursor: cursorFor(h))
            }
        }
    }

    private func cursorFor(_ handle: Handle) -> NSCursor {
        switch handle {
        case .left, .right:  return .resizeLeftRight
        case .top, .bottom:  return .resizeUpDown
        default:             return .crosshair
        }
    }

    // MARK: - Size badge

    private func drawSelectionSize(for rect: CGRect) {
        let pw = Int((rect.width  * pixelScale.width).rounded())
        let ph = Int((rect.height * pixelScale.height).rounded())
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let str      = NSAttributedString(string: "\(pw) x \(ph)", attributes: attrs)
        let textSize = str.size()
        let pad      = CGSize(width: 10, height: 6)
        let bSize    = CGSize(width: textSize.width + pad.width * 2, height: textSize.height + pad.height * 2)
        let origin   = badgeOrigin(for: rect, size: bSize)
        let bRect    = CGRect(origin: origin, size: bSize)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: bRect, xRadius: 7, yRadius: 7).fill()
        str.draw(at: CGPoint(x: bRect.minX + pad.width, y: bRect.minY + pad.height))
    }

    private func badgeOrigin(for rect: CGRect, size: CGSize) -> CGPoint {
        let preferred = CGPoint(x: rect.minX, y: rect.minY - size.height - 8)
        if bounds.contains(CGRect(origin: preferred, size: size)) { return preferred }
        let fallbackY = min(rect.maxY + 8, bounds.maxY - size.height - 8)
        return CGPoint(
            x: min(max(rect.minX, bounds.minX + 8), bounds.maxX - size.width - 8),
            y: max(fallbackY, bounds.minY + 8)
        )
    }
}
