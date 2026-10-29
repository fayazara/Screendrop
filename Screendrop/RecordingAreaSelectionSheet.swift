//
//  RecordingAreaSelectionSheet.swift
//  Screendrop
//
//  One screen's share of the area picker: the dim, the selection cut out of
//  it with its handles, and the pointer handling that draws, moves and
//  resizes it. The Start Recording pill and the first-use hint are SwiftUI,
//  laid over the top; they only draw, and the sheet decides what a click on
//  them means.
//

import AppKit
import SwiftUI

final class RecordingAreaSelectionSheet: NSView {
    let displayID: CGDirectDisplayID
    /// Global AppKit coordinates.
    let screenFrame: CGRect
    let scale: CGFloat

    private enum Drag {
        /// Waits for the pointer to travel a few points before replacing
        /// the selection, so a stray click never throws one away.
        case drawing(anchor: CGPoint, previous: RecordingAreaSelectionPresenter.Selection?, hasStarted: Bool)
        case moving(start: CGPoint, original: CGRect)
        case resizing(RecordingAreaHandle, original: CGRect)
        case pill
    }

    private var drag: Drag?
    private var presenter: RecordingAreaSelectionPresenter { .shared }

    /// Sheet coordinates are top-left, the same as the SwiftUI overlay's,
    /// so the pill's reported frame can be hit-tested without converting.
    override var isFlipped: Bool { true }

    init(displayID: CGDirectDisplayID, screenFrame: CGRect, scale: CGFloat) {
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.scale = scale
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        wantsLayer = true

        let overlay = NSHostingView(rootView: RecordingAreaSheetOverlay(displayID: displayID, screenFrame: screenFrame))
        overlay.frame = bounds
        // Sized by the panel, never the other way round - see
        // RecordingBarPresenter.makePanel.
        overlay.sizingOptions = []
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func selectionDidChange() {
        needsDisplay = true
        if drag == nil {
            updateCursor()
        }
    }

    // MARK: Coordinates

    private func local(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// The selection on this screen, if that's where it is.
    private var selection: RecordingAreaSelectionPresenter.Selection? {
        guard let selection = presenter.selection, selection.displayID == displayID else { return nil }
        return selection
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()

        guard selection != nil, let visible = presenter.visibleRect else { return }
        let rect = local(visible)
        rect.fill(using: .clear)

        if presenter.isInteracting {
            drawThirds(in: rect)
        }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        shadow.set()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
        drawHandles(around: rect)
        NSGraphicsContext.restoreGraphicsState()

        if presenter.isInteracting {
            drawSizeBadge(for: rect)
        }
    }

    /// L-shaped brackets on the corners and short bars on the edges, set
    /// just outside the border so they frame the selection rather than
    /// covering what's in it.
    private func drawHandles(around rect: CGRect) {
        let thickness: CGFloat = 4
        let outset = thickness / 2 - 0.5
        let frame = rect.insetBy(dx: -outset, dy: -outset)
        let arm = min(18, rect.width / 3, rect.height / 3)

        NSColor.white.setStroke()
        let corners = NSBezierPath()
        corners.lineWidth = thickness
        corners.lineCapStyle = .round
        corners.lineJoinStyle = .round
        for (corner, dx, dy) in [
            (CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0),
            (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
            (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0),
            (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0)
        ] {
            corners.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
            corners.line(to: corner)
            corners.line(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
        }
        corners.stroke()

        // Edge grips only where there's room between the brackets for them
        // to read as separate handles.
        let grip: CGFloat = 20
        NSColor.white.setFill()
        if rect.width >= grip + arm * 2 + 24 {
            for y in [frame.minY, frame.maxY] {
                NSBezierPath(
                    roundedRect: CGRect(x: rect.midX - grip / 2, y: y - thickness / 2, width: grip, height: thickness),
                    xRadius: thickness / 2,
                    yRadius: thickness / 2
                ).fill()
            }
        }
        if rect.height >= grip + arm * 2 + 24 {
            for x in [frame.minX, frame.maxX] {
                NSBezierPath(
                    roundedRect: CGRect(x: x - thickness / 2, y: rect.midY - grip / 2, width: thickness, height: grip),
                    xRadius: thickness / 2,
                    yRadius: thickness / 2
                ).fill()
            }
        }
    }

    /// Thirds while adjusting, for lining a subject up.
    private func drawThirds(in rect: CGRect) {
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let guides = NSBezierPath()
        guides.lineWidth = 1 / max(scale, 1)
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            let x = rect.minX + rect.width * fraction
            let y = rect.minY + rect.height * fraction
            guides.move(to: CGPoint(x: x, y: rect.minY))
            guides.line(to: CGPoint(x: x, y: rect.maxY))
            guides.move(to: CGPoint(x: rect.minX, y: y))
            guides.line(to: CGPoint(x: rect.maxX, y: y))
        }
        guides.stroke()
    }

    /// The exact pixel size by the selection while it's being adjusted - the
    /// bar has it too, but the pointer is here.
    private func drawSizeBadge(for rect: CGRect) {
        guard let selection else { return }
        let size = selection.pixelSize
        let label = NSMutableAttributedString(
            string: "\(size.width) × \(size.height)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        if let aspect = presenter.aspect {
            label.append(NSAttributedString(
                string: "  \(aspect.title)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.6)
                ]
            ))
        }

        let textSize = label.size()
        let padding = CGSize(width: 8, height: 4)
        let badgeSize = CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        let gap: CGFloat = 8
        var origin = CGPoint(x: rect.minX, y: rect.minY - badgeSize.height - gap)
        if origin.y < gap {
            origin.y = rect.height > badgeSize.height + gap * 2 ? rect.minY + gap : rect.maxY + gap
            if origin.y == rect.minY + gap { origin.x += gap }
        }
        origin.x = min(max(origin.x, gap), bounds.width - badgeSize.width - gap)
        origin.y = min(max(origin.y, gap), bounds.height - badgeSize.height - gap)

        let badge = CGRect(origin: origin, size: badgeSize)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        label.draw(at: CGPoint(x: badge.minX + padding.width, y: badge.minY + padding.height))
    }

    // MARK: Hit testing

    /// Every click on this screen is the sheet's; the overlay only draws.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func isOnPill(_ event: NSEvent) -> Bool {
        guard let pill = presenter.pillFrames[displayID] else { return false }
        return pill.contains(convert(event.locationInWindow, from: nil))
    }

    /// Corners take priority and are generous; edges are grabbable along
    /// their whole length, not just at the grip.
    private func handle(at point: CGPoint, in rect: CGRect) -> RecordingAreaHandle? {
        let corner: CGFloat = 12
        let edge: CGFloat = 6
        if let hit = RecordingAreaHandle.allCases.first(where: { handle in
            handle.isCorner
                && abs(point.x - handle.point(in: rect).x) <= corner
                && abs(point.y - handle.point(in: rect).y) <= corner
        }) {
            return hit
        }
        let withinX = point.x >= rect.minX - edge && point.x <= rect.maxX + edge
        let withinY = point.y >= rect.minY - edge && point.y <= rect.maxY + edge
        if withinX && abs(point.y - rect.maxY) <= edge { return .top }
        if withinX && abs(point.y - rect.minY) <= edge { return .bottom }
        if withinY && abs(point.x - rect.minX) <= edge { return .left }
        if withinY && abs(point.x - rect.maxX) <= edge { return .right }
        return nil
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    /// The pointer says what a press will do: draw, move, or resize along
    /// which axis. Set from the tracking area, which this panel gets whether
    /// or not Screendrop is active, rather than from cursor rects, which it
    /// only gets while key.
    private func updateCursor() {
        guard let window, window.isVisible else { return }
        let point = NSEvent.mouseLocation
        guard NSMouseInRect(point, screenFrame, false) else { return }
        cursor(at: point).set()
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        guard let selection else { return .crosshair }
        if let pill = presenter.pillFrames[displayID],
           let window,
           pill.contains(convert(window.convertPoint(fromScreen: point), from: nil)) {
            return .arrow
        }
        if let handle = handle(at: point, in: selection.rect) {
            return .frameResize(position: handle.cursorPosition, directions: .all)
        }
        return selection.rect.contains(point) ? .openHand : .crosshair
    }

    override func mouseDown(with event: NSEvent) {
        let point = NSEvent.mouseLocation

        if let selection {
            if isOnPill(event) {
                drag = .pill
                presenter.setPillPressed(true)
                return
            }
            if let handle = handle(at: point, in: selection.rect) {
                drag = .resizing(handle, original: selection.rect)
                presenter.setInteracting(true)
                return
            }
            if selection.rect.contains(point) {
                if event.clickCount == 2 {
                    presenter.commit()
                    return
                }
                drag = .moving(start: point, original: selection.rect)
                NSCursor.closedHand.set()
                return
            }
        }
        drag = .drawing(anchor: point, previous: presenter.selection, hasStarted: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = NSEvent.mouseLocation
        let flags = event.modifierFlags

        switch drag {
        case let .drawing(anchor, previous, hasStarted):
            if !hasStarted {
                guard hypot(point.x - anchor.x, point.y - anchor.y) >= 3 else { return }
                self.drag = .drawing(anchor: anchor, previous: previous, hasStarted: true)
                presenter.setInteracting(true)
            }
            // Shift squares a freeform selection; a locked ratio wins.
            let ratio = presenter.ratio ?? (flags.contains(.shift) ? 1 : nil)
            presenter.update(
                rect: RecordingAreaGeometry.drawn(
                    from: anchor,
                    to: point,
                    ratio: ratio,
                    fromCenter: flags.contains(.option),
                    in: screenFrame
                ),
                on: self
            )
        case let .moving(start, original):
            presenter.update(
                rect: RecordingAreaGeometry.moved(
                    original,
                    by: CGSize(width: point.x - start.x, height: point.y - start.y),
                    in: screenFrame
                ),
                on: self
            )
        case let .resizing(handle, original):
            // Shift keeps a freeform selection's current shape.
            let ratio = presenter.ratio
                ?? (flags.contains(.shift) && original.height > 0 ? original.width / original.height : nil)
            presenter.update(
                rect: RecordingAreaGeometry.resized(original, handle: handle, to: point, ratio: ratio, in: screenFrame),
                on: self
            )
        case .pill:
            presenter.setPillPressed(isOnPill(event))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil

        switch drag {
        case let .drawing(_, previous, hasStarted):
            // Too small to be meant: put back whatever was there.
            if hasStarted, let rect = presenter.selection?.rect, !RecordingAreaGeometry.isLargeEnough(rect) {
                presenter.restore(previous)
            }
        case .pill:
            presenter.setPillPressed(false)
            if isOnPill(event) {
                presenter.commit()
                return
            }
        case .moving, .resizing:
            break
        }
        presenter.setInteracting(false)
        updateCursor()
    }

    override func rightMouseDown(with event: NSEvent) {
        presenter.cancel()
    }
}

private extension RecordingAreaHandle {
    var cursorPosition: NSCursor.FrameResizePosition {
        switch self {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .left: .left
        case .right: .right
        case .bottomLeft: .bottomLeft
        case .bottom: .bottom
        case .bottomRight: .bottomRight
        }
    }
}

// MARK: - Overlay

/// The Start Recording pill beside the selection, and the hint on the bar's
/// screen before there is one.
private struct RecordingAreaSheetOverlay: View {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect

    @State private var presenter = RecordingAreaSelectionPresenter.shared
    @State private var pillSize = CGSize(width: 170, height: 32)

    private static let pillGap: CGFloat = 14
    private static let margin: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            if presenter.selection?.displayID == displayID,
               !presenter.isInteracting,
               let visible = presenter.visibleRect {
                startPill
                    .position(pillCenter(for: local(visible), in: proxy.size))
                    .transition(.opacity)
            } else if presenter.selection == nil, presenter.isHome(displayID) {
                hint
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: presenter.isInteracting)
        .animation(.easeOut(duration: 0.15), value: presenter.selection == nil)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Solid rather than glass, like the Display and Window pickers' pill:
    /// glass in this never-active panel renders untinted, and the pill has to
    /// read over any content.
    private var startPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "record.circle")
                .font(.system(size: 13, weight: .semibold))
            Text("Start Recording")
                .font(.system(size: 13, weight: .semibold))
            Text("↩")
                .font(.system(size: 12, weight: .semibold))
                .opacity(0.7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Palette.record, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
        }
        .opacity(presenter.isPillPressed ? 0.75 : 1)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .fixedSize()
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: { frame in
            pillSize = frame.size
            presenter.pillFrames[displayID] = frame
        }
        .onDisappear {
            presenter.pillFrames[displayID] = nil
        }
        .accessibilityLabel("Start Recording")
    }

    private var hint: some View {
        VStack(spacing: 4) {
            Text(presenter.aspect.map { "Drag to select a \($0.title) area" } ?? "Drag to select an area")
                .font(.system(size: 13, weight: .semibold))
            Text(presenter.aspect == nil
                 ? "Shift for a square · Option to draw from the center"
                 : "Option to draw from the center · Esc to cancel")
                .font(.system(size: 11, weight: .medium))
                .opacity(0.65)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fixedSize()
    }

    /// Below the selection, where it doesn't cover what's being framed;
    /// above when there's no room below (or the bar or its area pill is there); inside along
    /// the bottom edge when the selection fills the screen.
    private func pillCenter(for rect: CGRect, in size: CGSize) -> CGPoint {
        let gap = Self.pillGap
        let margin = Self.margin
        let height = pillSize.height
        let x = min(max(rect.midX, pillSize.width / 2 + margin), size.width - pillSize.width / 2 - margin)
        let chrome = [RecordingBarPresenter.shared.barFrame, RecordingBarPresenter.shared.areaPillFrame]
            .compactMap { $0.map(local) }

        func isClear(_ y: CGFloat) -> Bool {
            let pill = CGRect(x: x - pillSize.width / 2, y: y - height / 2, width: pillSize.width, height: height)
            return pill.minY >= margin
                && pill.maxY <= size.height - margin
                && !chrome.contains { $0.insetBy(dx: -8, dy: -8).intersects(pill) }
        }

        let below = rect.maxY + gap + height / 2
        if isClear(below) { return CGPoint(x: x, y: below) }
        let above = rect.minY - gap - height / 2
        if isClear(above) { return CGPoint(x: x, y: above) }
        return CGPoint(x: x, y: max(rect.maxY - gap - height / 2, rect.minY + height / 2))
    }

    private func local(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
