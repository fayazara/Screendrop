//
//  RecordingAreaSelectionPresenter.swift
//  Screendrop
//
//  Created by Codex on 01/05/26.
//

import AppKit
import ScreenCaptureKit
import SwiftUI

// MARK: - Presenter

@MainActor
final class RecordingAreaSelectionPresenter {
    static let shared = RecordingAreaSelectionPresenter()

    private var panel: NSPanel?
    private var toolbarPanel: NSPanel?
    private var selectionView: RecordingAreaSelectionView?
    private var model: RecordingSetupModel?
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

        self.display   = display
        self.completion = completion

        let pixelScale = CGSize(
            width:  CGFloat(display.width)  / max(screen.frame.width,  1),
            height: CGFloat(display.height) / max(screen.frame.height, 1)
        )

        // Shared observable model
        let setupModel = RecordingSetupModel(pixelScale: pixelScale)
        self.model = setupModel

        // ── Overlay panel ──────────────────────────────────────────────────
        let overlayPanel = RecordingAreaSelectionPanel(
            contentRect: screen.frame,
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        overlayPanel.backgroundColor          = .clear
        overlayPanel.isOpaque                 = false
        overlayPanel.hasShadow                = false
        overlayPanel.level                    = .screenSaver
        overlayPanel.collectionBehavior       = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlayPanel.isReleasedWhenClosed     = false
        overlayPanel.acceptsMouseMovedEvents  = true

        let selView = RecordingAreaSelectionView(
            frame:      CGRect(origin: .zero, size: screen.frame.size),
            pixelScale: pixelScale
        )

        // Cancel from overlay
        selView.onCancel = { [weak self] in
            self?.finish(rect: nil)
        }

        // Confirm from Return key or double-click — passes local rect directly
        selView.onSelect = { [weak self, weak overlayPanel] localRect in
            guard let self, let overlayPanel else { self?.finish(rect: nil); return }
            self.finish(rect: self.toGlobal(localRect, panel: overlayPanel))
        }

        // Keep model.selection in sync for the toolbar's size readout + Start enable state
        selView.onSelectionChanged = { [weak setupModel] rect in
            setupModel?.selection = rect
        }

        overlayPanel.contentView        = selView
        overlayPanel.makeFirstResponder(selView)
        self.panel         = overlayPanel
        self.selectionView = selView

        // ── Toolbar panel ──────────────────────────────────────────────────
        toolbarPanel = makeToolbarPanel(screen: screen, model: setupModel)

        installKeyMonitor()
        overlayPanel.makeKeyAndOrderFront(nil)
        overlayPanel.orderFrontRegardless()
        // Attach toolbar as a child window so the window server keeps it above
        // the overlay regardless of subsequent mouse interactions on the overlay.
        if let tp = toolbarPanel {
            overlayPanel.addChildWindow(tp, ordered: .above)
        }
    }

    func cancel() {
        finish(rect: nil)
    }

    // MARK: Private

    private func finish(rect: CGRect?) {
        let completion  = completion
        self.completion  = nil
        display          = nil
        model            = nil
        selectionView    = nil
        removeKeyMonitor()
        if let tp = toolbarPanel {
            panel?.removeChildWindow(tp)
            tp.orderOut(nil)
        }
        toolbarPanel = nil
        panel?.orderOut(nil)
        panel = nil
        completion?(rect)
    }

    /// Convert a panel-local rect to global screen coordinates.
    private func toGlobal(_ localRect: CGRect, panel: NSPanel) -> CGRect {
        CGRect(
            x:      panel.frame.minX + localRect.minX,
            y:      panel.frame.minY + localRect.minY,
            width:  localRect.width,
            height: localRect.height
        )
    }

    /// Called by the toolbar's Start button — reads the committed selection
    /// from the model and converts it to global coordinates.
    private func finishWithModelSelection() {
        guard let model, let panel else { return }
        guard let localRect = model.selection   else { return }
        finish(rect: toGlobal(localRect, panel: panel))
    }

    private func makeToolbarPanel(screen: NSScreen, model: RecordingSetupModel) -> NSPanel {
        let toolbarView = RecordingSetupToolbarView(
            model:          model,
            onStart:        { [weak self] in self?.finishWithModelSelection() },
            onCancel:       { [weak self] in self?.cancel() },
            onAspectChange: { [weak self] aspect in self?.selectionView?.applyAspect(aspect) },
            onModeChange:   { _ in }   // mode switching handled by RecordingSetupPresenter (PR 3)
        )

        let hosting     = NSHostingView(rootView: toolbarView)
        let idealSize   = hosting.fittingSize
        let panelWidth  = max(idealSize.width,  480)
        let panelHeight = idealSize.height > 0 ? idealSize.height : 72

        let panel = NSPanel(
            contentRect: CGRect(
                x: screen.frame.midX - panelWidth / 2,
                y: screen.frame.minY + 32,
                width:  panelWidth,
                height: panelHeight
            ),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.backgroundColor          = .clear
        panel.isOpaque                 = false
        panel.hasShadow                = false
        panel.level                    = .screenSaver
        panel.collectionBehavior       = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed     = false
        panel.sharingType              = .none   // excluded from recordings
        panel.contentView              = hosting
        return panel
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
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

// MARK: - Panel subclass

private final class RecordingAreaSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Selection view

private final class RecordingAreaSelectionView: NSView {

    // Callbacks
    var onSelect:           ((CGRect) -> Void)?
    var onCancel:           (() -> Void)?
    var onSelectionChanged: ((CGRect?) -> Void)?

    /// Active aspect constraint.  Updated by the presenter when the user picks
    /// a chip; the view re-fits the existing selection and locks future drags.
    var aspect: CropAspectRatio = .freeform

    // MARK: Internal state

    private enum DragMode {
        case none
        case drawing
        case moving
        case resizing(Handle)
    }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private let pixelScale:     CGSize
    private let minimumSize:    CGFloat = 16
    private let handleLength:   CGFloat = 10
    private let handleHitPad:   CGFloat = 6

    private var selection:    CGRect?
    private var drawStart:    CGPoint?
    private var drawCurrent:  CGPoint?
    private var dragMode:     DragMode = .none
    private var moveOffset:   CGSize   = .zero
    private var resizeAnchor: CGRect   = .zero

    override var acceptsFirstResponder: Bool { true }

    init(frame frameRect: NSRect, pixelScale: CGSize) {
        self.pixelScale = pixelScale
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Aspect

    /// Apply a new aspect constraint and re-fit the existing selection (if any).
    func applyAspect(_ newAspect: CropAspectRatio) {
        aspect = newAspect
        guard let current = selection,
              let ratio   = newAspect.pixelRatio(imageSize: .zero) else {
            needsDisplay = true
            return
        }
        let cw = current.width
        let ch = current.height
        var w: CGFloat
        var h: CGFloat
        if cw / max(ch, 0.001) > ratio { h = ch; w = h * ratio }
        else                           { w = cw; h = w / ratio }
        // Clamp to screen bounds
        if w > bounds.width  { w = bounds.width;  h = w / ratio }
        if h > bounds.height { h = bounds.height; w = h * ratio }
        selection = CGRect(
            x: min(max(current.midX - w / 2, bounds.minX), bounds.maxX - w),
            y: min(max(current.midY - h / 2, bounds.minY), bounds.maxY - h),
            width: w, height: h
        )
        onSelectionChanged?(selection)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Active rect

    private var isDrawing: Bool {
        if case .drawing = dragMode { return true }
        return false
    }

    private var draftRect: CGRect? {
        guard let drawStart, let drawCurrent else { return nil }
        let dx = drawCurrent.x - drawStart.x
        let dy = drawCurrent.y - drawStart.y

        guard let ratio = aspect.pixelRatio(imageSize: .zero) else {
            // Freeform
            return CGRect(
                x: min(drawStart.x, drawCurrent.x),
                y: min(drawStart.y, drawCurrent.y),
                width:  abs(dx),
                height: abs(dy)
            )
        }

        // Aspect-locked: shrink the over-constrained dimension so the rect
        // always fits within the drag extent.
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

    private var activeRect: CGRect? { isDrawing ? draftRect : selection }

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

        // Hint: only before the first selection; toolbar handles the rest.
        if !isDrawing, selection == nil {
            drawHint("Drag to select an area")
        }
    }

    private func drawHandles(for rect: CGRect) {
        for handle in Handle.allCases {
            let center = handlePoint(handle, in: rect)
            let sq = CGRect(
                x: center.x - handleLength / 2,
                y: center.y - handleLength / 2,
                width:  handleLength,
                height: handleLength
            )
            let path = NSBezierPath(roundedRect: sq, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
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
        let badgeSize = CGSize(
            width:  textSize.width  + pad.width  * 2,
            height: textSize.height + pad.height * 2
        )
        let badgeRect = CGRect(
            x: bounds.midX - badgeSize.width / 2,
            y: bounds.maxY - badgeSize.height - 28,
            width:  badgeSize.width,
            height: badgeSize.height
        )
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 9, yRadius: 9).fill()
        str.draw(at: CGPoint(
            x: badgeRect.minX + pad.width,
            y: badgeRect.minY + pad.height
        ))
    }

    // MARK: - Mouse events

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let sel = selection {
            // Double-click inside → commit
            if event.clickCount >= 2, sel.contains(point) {
                commitSelection(); return
            }
            // Hit-test a resize handle
            if let handle = handle(at: point, in: sel) {
                dragMode     = .resizing(handle)
                resizeAnchor = sel
                return
            }
            // Inside body → move
            if sel.contains(point) {
                dragMode   = .moving
                moveOffset = CGSize(
                    width:  point.x - sel.minX,
                    height: point.y - sel.minY
                )
                NSCursor.closedHand.set()
                return
            }
        }

        // Outside (or no selection) → start a new draw
        dragMode  = .drawing
        selection = nil
        onSelectionChanged?(nil)
        drawStart   = point
        drawCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .drawing:
            drawCurrent = point
        case .moving:
            guard let cur = selection else { break }
            var moved = cur
            moved.origin = CGPoint(
                x: point.x - moveOffset.width,
                y: point.y - moveOffset.height
            )
            selection = clampToBounds(moved)
            onSelectionChanged?(selection)
        case .resizing(let handle):
            selection = resizedRect(anchor: resizeAnchor, handle: handle, to: point)
            onSelectionChanged?(selection)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if case .drawing = dragMode {
            drawCurrent = point
            if let rect = draftRect,
               rect.width >= minimumSize, rect.height >= minimumSize {
                selection = clampToBounds(rect)
            } else {
                selection = nil
            }
            drawStart   = nil
            drawCurrent = nil
            onSelectionChanged?(selection)
        }
        dragMode = .none
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:       onCancel?()        // Esc
        case 36, 76:   commitSelection()  // Return / keypad Enter
        default:       super.keyDown(with: event)
        }
    }

    private func commitSelection() {
        guard let selection else { return }
        onSelect?(selection)
    }

    // MARK: - Geometry helpers

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
        let c     = handlePoint(handle, in: rect)
        let reach = handleLength / 2 + handleHitPad
        return CGRect(x: c.x - reach, y: c.y - reach, width: reach * 2, height: reach * 2)
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        Handle.allCases.first { handleHitRect($0, in: rect).contains(point) }
    }

    private func resizedRect(anchor: CGRect, handle: Handle, to raw: CGPoint) -> CGRect {
        let ratio = aspect.pixelRatio(imageSize: .zero)
        let px = max(bounds.minX, min(raw.x, bounds.maxX))
        let py = max(bounds.minY, min(raw.y, bounds.maxY))
        let p  = CGPoint(x: px, y: py)

        // Corner handles: aspect-locked when a preset is active.
        switch handle {
        case .topLeft:
            if let r = ratio {
                return aspectLockedCorner(
                    anchorX: anchor.maxX, anchorY: anchor.minY,
                    signX: -1, signY: +1, to: p, ratio: r)
            }
        case .topRight:
            if let r = ratio {
                return aspectLockedCorner(
                    anchorX: anchor.minX, anchorY: anchor.minY,
                    signX: +1, signY: +1, to: p, ratio: r)
            }
        case .bottomLeft:
            if let r = ratio {
                return aspectLockedCorner(
                    anchorX: anchor.maxX, anchorY: anchor.maxY,
                    signX: -1, signY: -1, to: p, ratio: r)
            }
        case .bottomRight:
            if let r = ratio {
                return aspectLockedCorner(
                    anchorX: anchor.minX, anchorY: anchor.maxY,
                    signX: +1, signY: -1, to: p, ratio: r)
            }
        default:
            break
        }

        // Edge handles (or freeform corners): unconstrained.
        var minX = anchor.minX, maxX = anchor.maxX
        var minY = anchor.minY, maxY = anchor.maxY

        switch handle {
        case .left,        .topLeft,     .bottomLeft:  minX = min(px, anchor.maxX - minimumSize)
        case .right,       .topRight,    .bottomRight: maxX = max(px, anchor.minX + minimumSize)
        default: break
        }
        switch handle {
        case .bottom,      .bottomLeft,  .bottomRight: minY = min(py, anchor.maxY - minimumSize)
        case .top,         .topLeft,     .topRight:    maxY = max(py, anchor.minY + minimumSize)
        default: break
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Resize a corner handle while locking to `ratio` (width ÷ height).
    ///
    /// - Parameters:
    ///   - anchorX/Y: The fixed opposite corner (NSView y-up coordinates).
    ///   - signX:     +1 = drag grows rightward, −1 = leftward.
    ///   - signY:     +1 = drag grows upward,    −1 = downward.
    private func aspectLockedCorner(
        anchorX: CGFloat, anchorY: CGFloat,
        signX: CGFloat,   signY: CGFloat,
        to point: CGPoint,
        ratio: CGFloat
    ) -> CGRect {
        let cw = max((point.x - anchorX) * signX, minimumSize)
        let ch = max((point.y - anchorY) * signY, minimumSize)

        var w: CGFloat
        var h: CGFloat
        if cw / max(ch, 0.001) > ratio { h = ch; w = h * ratio }
        else                           { w = cw; h = w / ratio }

        // Clamp to screen bounds while preserving ratio
        let maxW = signX > 0 ? bounds.maxX - anchorX : anchorX - bounds.minX
        let maxH = signY > 0 ? bounds.maxY - anchorY : anchorY - bounds.minY
        if w > maxW { w = maxW; h = w / ratio }
        if h > maxH { h = maxH; w = h * ratio }
        w = max(w, minimumSize)
        h = max(h, minimumSize)

        return CGRect(
            x:      signX > 0 ? anchorX      : anchorX - w,
            y:      signY > 0 ? anchorY      : anchorY - h,
            width:  w,
            height: h
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

    // MARK: - Cursor

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
        if window != nil { NSCursor.annotationPlus.set() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .annotationPlus)
        guard let selection, !isDrawing else { return }
        addCursorRect(selection, cursor: .openHand)
        for handle in Handle.allCases {
            addCursorRect(handleHitRect(handle, in: selection), cursor: cursorFor(handle))
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
        let label = "\(pw) x \(ph)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let str      = NSAttributedString(string: label, attributes: attrs)
        let textSize = str.size()
        let pad      = CGSize(width: 10, height: 6)
        let badgeSize = CGSize(
            width:  textSize.width  + pad.width  * 2,
            height: textSize.height + pad.height * 2
        )
        let origin    = badgeOrigin(for: rect, size: badgeSize)
        let badgeRect = CGRect(origin: origin, size: badgeSize)

        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 7, yRadius: 7).fill()
        str.draw(at: CGPoint(x: badgeRect.minX + pad.width, y: badgeRect.minY + pad.height))
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
