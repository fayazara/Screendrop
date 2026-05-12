//
//  RecordingMouseIndicators.swift
//  Screendrop
//
//  Created by Codex on 09/05/26.
//

import AppKit
import CoreVideo
import Foundation

final class RecordingMouseIndicatorController {
    static let shared = RecordingMouseIndicatorController()

    private let store = RecordingMouseIndicatorStore()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var appearance = RecordingMouseIndicatorAppearance.current
    private var controlGestureButtons = Set<Int>()

    private init() {}

    func start(mapping: RecordingMouseIndicatorMapping) -> RecordingMouseIndicatorStore {
        stop()
        let appearance = RecordingMouseIndicatorAppearance.current
        self.appearance = appearance
        store.start(mapping: mapping, appearance: appearance)
        RecordingMouseIndicatorOverlayPresenter.shared.show(mapping: mapping, appearance: appearance)

        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseDragged,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseDragged,
            .otherMouseUp
        ]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }

        return store
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        globalMonitor = nil
        localMonitor = nil
        controlGestureButtons = []
        store.stop()
        RecordingMouseIndicatorOverlayPresenter.shared.hide()
    }

    func pause() {
        store.pause(at: ProcessInfo.processInfo.systemUptime)
        RecordingMouseIndicatorOverlayPresenter.shared.clear()
    }

    func resume() {
        store.resume(at: ProcessInfo.processInfo.systemUptime)
    }

    private func handle(_ event: NSEvent) {
        let screenPoint = NSEvent.mouseLocation
        let button = Self.buttonNumber(for: event)
        let uptime = event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime

        if shouldSuppressControlGesture(event.type, button: button, screenPoint: screenPoint) {
            RecordingMouseIndicatorOverlayPresenter.shared.endDrag(button: button)
            return
        }

        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            store.recordMouseDown(button: button, screenPoint: screenPoint, uptime: uptime)
            RecordingMouseIndicatorOverlayPresenter.shared.showClick(
                screenPoint: screenPoint,
                button: button,
                appearance: appearance
            )
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            store.recordMouseDragged(button: button, screenPoint: screenPoint, uptime: uptime)
            RecordingMouseIndicatorOverlayPresenter.shared.updateDrag(
                screenPoint: screenPoint,
                button: button,
                appearance: appearance
            )
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            store.recordMouseUp(button: button, screenPoint: screenPoint, uptime: uptime)
            RecordingMouseIndicatorOverlayPresenter.shared.endDrag(button: button)
        default:
            break
        }
    }

    private func shouldSuppressControlGesture(
        _ type: NSEvent.EventType,
        button: Int,
        screenPoint: CGPoint
    ) -> Bool {
        if Self.isMouseDown(type) {
            if RecordingControlPresenter.shared.containsScreenPoint(screenPoint) {
                controlGestureButtons.insert(button)
                return true
            }

            controlGestureButtons.remove(button)
            return false
        }

        guard controlGestureButtons.contains(button) else {
            return false
        }

        if Self.isMouseUp(type) {
            controlGestureButtons.remove(button)
        }

        return true
    }

    private static func buttonNumber(for event: NSEvent) -> Int {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            0
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
            1
        default:
            max(2, event.buttonNumber)
        }
    }

    private static func isMouseDown(_ type: NSEvent.EventType) -> Bool {
        type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }

    private static func isMouseUp(_ type: NSEvent.EventType) -> Bool {
        type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp
    }
}

nonisolated struct RecordingMouseIndicatorAppearance: Sendable {
    let color: RecordingMouseIndicatorColor
    let size: Double

    static let `default` = RecordingMouseIndicatorAppearance(
        color: .macBlue,
        size: ScreendropPreferences.defaultRecordingMouseIndicatorSize
    )

    static var current: RecordingMouseIndicatorAppearance {
        RecordingMouseIndicatorAppearance(
            color: RecordingMouseIndicatorColor(hexString: ScreendropPreferences.recordingMouseIndicatorColor) ?? .macBlue,
            size: ScreendropPreferences.recordingMouseIndicatorSize
        )
    }
}

private final class RecordingMouseIndicatorOverlayPresenter {
    static let shared = RecordingMouseIndicatorOverlayPresenter()

    private var panel: NSPanel?
    private var overlayView: RecordingMouseIndicatorOverlayView?
    private var timer: Timer?
    private var mapping: RecordingMouseIndicatorMapping?

    private init() {}

    func show(mapping: RecordingMouseIndicatorMapping, appearance: RecordingMouseIndicatorAppearance) {
        hide()

        guard mapping.captureRect.width > 0,
              mapping.captureRect.height > 0 else {
            return
        }

        self.mapping = mapping

        let panel = NSPanel(
            contentRect: mapping.captureRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none

        let overlayView = RecordingMouseIndicatorOverlayView(frame: CGRect(origin: .zero, size: mapping.captureRect.size))
        panel.contentView = overlayView
        panel.orderFrontRegardless()

        self.panel = panel
        self.overlayView = overlayView
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.overlayView?.tick()
            }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        overlayView?.clear()
        overlayView = nil
        panel?.orderOut(nil)
        panel = nil
        mapping = nil
    }

    func clear() {
        overlayView?.clear()
    }

    func showClick(screenPoint: CGPoint, button: Int, appearance: RecordingMouseIndicatorAppearance) {
        guard let point = mapping?.overlayPoint(for: screenPoint) else {
            return
        }

        overlayView?.addClick(point: point, appearance: appearance)
        overlayView?.updateDrag(point: point, button: button, appearance: appearance)
    }

    func updateDrag(screenPoint: CGPoint, button: Int, appearance: RecordingMouseIndicatorAppearance) {
        guard let point = mapping?.overlayPoint(for: screenPoint) else {
            endDrag(button: button)
            return
        }

        overlayView?.updateDrag(point: point, button: button, appearance: appearance)
    }

    func endDrag(button: Int) {
        overlayView?.endDrag(button: button)
    }
}

private final class RecordingMouseIndicatorOverlayView: NSView {
    private var clicks: [RecordingMouseOverlayClick] = []
    private var activeDrags: [Int: RecordingMouseOverlayDrag] = [:]

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    func addClick(point: CGPoint, appearance: RecordingMouseIndicatorAppearance) {
        clicks.append(RecordingMouseOverlayClick(
            point: point,
            time: ProcessInfo.processInfo.systemUptime,
            appearance: appearance
        ))
        needsDisplay = true
    }

    func updateDrag(point: CGPoint, button: Int, appearance: RecordingMouseIndicatorAppearance) {
        activeDrags[button] = RecordingMouseOverlayDrag(point: point, appearance: appearance)
        needsDisplay = true
    }

    func endDrag(button: Int) {
        activeDrags.removeValue(forKey: button)
        needsDisplay = true
    }

    func clear() {
        clicks = []
        activeDrags = [:]
        needsDisplay = true
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        clicks.removeAll { now - $0.time > RecordingMouseIndicatorStyle.clickDuration }
        if !clicks.isEmpty || !activeDrags.isEmpty {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let now = ProcessInfo.processInfo.systemUptime
        for drag in activeDrags.values {
            drawDrag(at: drag.point, appearance: drag.appearance)
        }

        for click in clicks {
            drawClick(click, now: now)
        }
    }

    private func drawClick(_ click: RecordingMouseOverlayClick, now: TimeInterval) {
        let age = max(0, now - click.time)
        guard age <= RecordingMouseIndicatorStyle.clickDuration else { return }

        let progress = age / RecordingMouseIndicatorStyle.clickDuration
        let fade = max(0, 1 - progress)
        let radius = CGFloat(click.appearance.size / 2)
        let ringRadius = radius * CGFloat(0.42 + 0.58 * progress)
        let lineWidth = max(2, radius * 0.10)
        let color = click.appearance.color.nsColor

        drawRing(
            center: click.point,
            radius: ringRadius,
            lineWidth: lineWidth,
            color: color.withAlphaComponent(0.76 * fade)
        )
        drawFilledCircle(
            center: click.point,
            radius: radius * 0.20 * CGFloat(1 + 0.25 * (1 - progress)),
            color: color.withAlphaComponent(0.20 * fade)
        )
    }

    private func drawDrag(at point: CGPoint, appearance: RecordingMouseIndicatorAppearance) {
        let radius = CGFloat(appearance.size * 0.26)
        let color = appearance.color.nsColor
        drawFilledCircle(
            center: point,
            radius: radius * 0.68,
            color: color.withAlphaComponent(0.24)
        )
        drawRing(
            center: point,
            radius: radius,
            lineWidth: max(2, radius * 0.18),
            color: color.withAlphaComponent(0.70)
        )
    }

    private func drawFilledCircle(center: CGPoint, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )).fill()
    }

    private func drawRing(center: CGPoint, radius: CGFloat, lineWidth: CGFloat, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath(ovalIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        path.lineWidth = lineWidth
        path.stroke()
    }
}

private struct RecordingMouseOverlayClick {
    let point: CGPoint
    let time: TimeInterval
    let appearance: RecordingMouseIndicatorAppearance
}

private struct RecordingMouseOverlayDrag {
    let point: CGPoint
    let appearance: RecordingMouseIndicatorAppearance
}

nonisolated final class RecordingMouseIndicatorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var mapping: RecordingMouseIndicatorMapping?
    private var appearance = RecordingMouseIndicatorAppearance.default
    private var pixelScale = 1.0
    private var startUptime: TimeInterval = 0
    private var pauseStartedUptime: TimeInterval?
    private var accumulatedPauseDuration: TimeInterval = 0
    private var clicks: [RecordingMouseClick] = []
    private var activeDrags: [Int: RecordingMouseDrag] = [:]

    func start(mapping: RecordingMouseIndicatorMapping, appearance: RecordingMouseIndicatorAppearance) {
        lock.withLock {
            self.mapping = mapping
            self.appearance = appearance
            pixelScale = mapping.pointPixelScale
            startUptime = ProcessInfo.processInfo.systemUptime
            pauseStartedUptime = nil
            accumulatedPauseDuration = 0
            clicks = []
            activeDrags = [:]
        }
    }

    func stop() {
        lock.withLock {
            mapping = nil
            appearance = .default
            pixelScale = 1
            pauseStartedUptime = nil
            accumulatedPauseDuration = 0
            clicks = []
            activeDrags = [:]
        }
    }

    func pause(at uptime: TimeInterval) {
        lock.withLock {
            guard pauseStartedUptime == nil else { return }
            pauseStartedUptime = uptime
            activeDrags = [:]
        }
    }

    func resume(at uptime: TimeInterval) {
        lock.withLock {
            guard let pauseStartedUptime else { return }
            accumulatedPauseDuration += max(0, uptime - pauseStartedUptime)
            self.pauseStartedUptime = nil
        }
    }

    func recordMouseDown(button: Int, screenPoint: CGPoint, uptime: TimeInterval) {
        lock.withLock {
            guard pauseStartedUptime == nil,
                  let time = relativeTime(for: uptime),
                  let point = mapping?.pixelPoint(for: screenPoint) else {
                return
            }

            clicks.append(RecordingMouseClick(point: point, time: time))
            activeDrags[button] = RecordingMouseDrag(
                button: button,
                startedAt: time,
                points: [RecordingMouseTimedPoint(point: point, time: time)]
            )
            prune(before: time)
        }
    }

    func recordMouseDragged(button: Int, screenPoint: CGPoint, uptime: TimeInterval) {
        lock.withLock {
            guard pauseStartedUptime == nil,
                  let time = relativeTime(for: uptime),
                  let point = mapping?.pixelPoint(for: screenPoint),
                  var drag = activeDrags[button] else {
                return
            }

            if let last = drag.points.last,
               last.point.distance(to: point) < 4,
               time - last.time < 0.05 {
                return
            }

            drag.points.append(RecordingMouseTimedPoint(point: point, time: time))
            if drag.points.count > 180 {
                drag.points.removeFirst(drag.points.count - 180)
            }
            activeDrags[button] = drag
        }
    }

    func recordMouseUp(button: Int, screenPoint: CGPoint, uptime: TimeInterval) {
        lock.withLock {
            guard activeDrags.removeValue(forKey: button) != nil,
                  let time = relativeTime(for: uptime) else {
                return
            }
            prune(before: time)
        }
    }

    func snapshot(at time: TimeInterval) -> RecordingMouseIndicatorSnapshot? {
        lock.withLock {
            prune(before: time)

            let visibleClicks = clicks.filter {
                time >= $0.time - 0.05 && time - $0.time <= RecordingMouseIndicatorStyle.clickDuration
            }
            let visibleActiveDrags = activeDrags.values.filter { time >= $0.startedAt - 0.05 }

            guard !visibleClicks.isEmpty || !visibleActiveDrags.isEmpty else {
                return nil
            }

            return RecordingMouseIndicatorSnapshot(
                time: time,
                appearance: appearance,
                pixelScale: pixelScale,
                clicks: visibleClicks,
                activeDrags: Array(visibleActiveDrags)
            )
        }
    }

    private func relativeTime(for uptime: TimeInterval) -> TimeInterval? {
        guard mapping != nil, pauseStartedUptime == nil else { return nil }

        return max(0, uptime - startUptime - accumulatedPauseDuration)
    }

    private func prune(before time: TimeInterval) {
        clicks.removeAll { time - $0.time > RecordingMouseIndicatorStyle.clickDuration }
    }
}

nonisolated struct RecordingMouseIndicatorMapping: Sendable {
    let captureRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    var pointPixelScale: Double {
        guard captureRect.width > 0 else { return 1 }
        return max(1, Double(CGFloat(pixelWidth) / captureRect.width))
    }

    func pixelPoint(for screenPoint: CGPoint) -> RecordingMouseIndicatorPoint? {
        guard captureRect.width > 0,
              captureRect.height > 0,
              captureRect.contains(screenPoint) else {
            return nil
        }

        let scaleX = CGFloat(pixelWidth) / captureRect.width
        let scaleY = CGFloat(pixelHeight) / captureRect.height
        let x = (screenPoint.x - captureRect.minX) * scaleX
        let y = (captureRect.maxY - screenPoint.y) * scaleY

        return RecordingMouseIndicatorPoint(
            x: min(max(Double(x), 0), Double(pixelWidth - 1)),
            y: min(max(Double(y), 0), Double(pixelHeight - 1))
        )
    }

    func overlayPoint(for screenPoint: CGPoint) -> CGPoint? {
        guard captureRect.width > 0,
              captureRect.height > 0,
              captureRect.contains(screenPoint) else {
            return nil
        }

        return CGPoint(
            x: screenPoint.x - captureRect.minX,
            y: captureRect.maxY - screenPoint.y
        )
    }
}

nonisolated struct RecordingMouseIndicatorSnapshot: Sendable {
    let time: TimeInterval
    let appearance: RecordingMouseIndicatorAppearance
    let pixelScale: Double
    let clicks: [RecordingMouseClick]
    let activeDrags: [RecordingMouseDrag]

    var videoRadius: Double {
        max(8, appearance.size * pixelScale / 2)
    }
}

nonisolated struct RecordingMouseClick: Sendable {
    let point: RecordingMouseIndicatorPoint
    let time: TimeInterval
}

nonisolated struct RecordingMouseDrag: Sendable {
    let button: Int
    let startedAt: TimeInterval
    var points: [RecordingMouseTimedPoint]
}

nonisolated struct RecordingMouseTimedPoint: Sendable {
    let point: RecordingMouseIndicatorPoint
    let time: TimeInterval
}

nonisolated struct RecordingMouseIndicatorPoint: Sendable {
    let x: Double
    let y: Double

    func distance(to other: RecordingMouseIndicatorPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

nonisolated enum RecordingMouseIndicatorRenderer {
    static func render(snapshot: RecordingMouseIndicatorSnapshot, into pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return }

        let lockFlags = CVPixelBufferLockFlags(rawValue: 0)
        guard CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) == kCVReturnSuccess else { return }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, lockFlags)
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        var canvas = RecordingMouseIndicatorCanvas(
            baseAddress: baseAddress.assumingMemoryBound(to: UInt8.self),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )

        for drag in snapshot.activeDrags {
            drawDrag(drag, snapshot: snapshot, canvas: &canvas)
        }

        for click in snapshot.clicks {
            drawClick(click, snapshot: snapshot, canvas: &canvas)
        }
    }

    private static func drawClick(
        _ click: RecordingMouseClick,
        snapshot: RecordingMouseIndicatorSnapshot,
        canvas: inout RecordingMouseIndicatorCanvas
    ) {
        let age = max(0, snapshot.time - click.time)
        guard age <= RecordingMouseIndicatorStyle.clickDuration else { return }

        let progress = age / RecordingMouseIndicatorStyle.clickDuration
        let fade = max(0, 1 - progress)
        let accent = snapshot.appearance.color
        let maxRadius = snapshot.videoRadius
        let ringRadius = maxRadius * (0.42 + 0.58 * progress)
        let lineWidth = max(2, maxRadius * 0.10)
        let ringAlpha = 0.76 * fade
        let fillAlpha = 0.20 * fade

        canvas.drawRing(
            center: click.point,
            radius: ringRadius,
            lineWidth: lineWidth,
            color: accent.withAlphaMultiplier(ringAlpha)
        )
        canvas.drawFilledCircle(
            center: click.point,
            radius: maxRadius * 0.20 * (1 + 0.25 * (1 - progress)),
            color: accent.withAlphaMultiplier(fillAlpha)
        )
    }

    private static func drawDrag(
        _ drag: RecordingMouseDrag,
        snapshot: RecordingMouseIndicatorSnapshot,
        canvas: inout RecordingMouseIndicatorCanvas
    ) {
        guard let currentPoint = drag.points.last?.point else { return }

        let accent = snapshot.appearance.color
        let radius = snapshot.videoRadius * 0.52
        canvas.drawFilledCircle(
            center: currentPoint,
            radius: radius * 0.68,
            color: accent.withAlphaMultiplier(0.24)
        )
        canvas.drawRing(
            center: currentPoint,
            radius: radius,
            lineWidth: max(2, radius * 0.18),
            color: accent.withAlphaMultiplier(0.70)
        )
    }
}

private enum RecordingMouseIndicatorStyle {
    static let clickDuration: TimeInterval = 0.55
}

private struct RecordingMouseIndicatorCanvas {
    let baseAddress: UnsafeMutablePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

    mutating func drawFilledCircle(
        center: RecordingMouseIndicatorPoint,
        radius: Double,
        color: RecordingMouseIndicatorColor
    ) {
        let minX = max(0, Int(floor(center.x - radius)))
        let maxX = min(width - 1, Int(ceil(center.x + radius)))
        let minY = max(0, Int(floor(center.y - radius)))
        let maxY = min(height - 1, Int(ceil(center.y + radius)))
        let radiusSquared = radius * radius

        guard minX <= maxX, minY <= maxY else { return }

        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x) + 0.5 - center.x
                let dy = Double(y) + 0.5 - center.y
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared <= radiusSquared else { continue }

                let distance = sqrt(distanceSquared)
                let coverage = min(1, max(0, radius - distance + 0.75))
                blendPixel(x: x, y: y, color: color.withAlphaMultiplier(coverage))
            }
        }
    }

    mutating func drawRing(
        center: RecordingMouseIndicatorPoint,
        radius: Double,
        lineWidth: Double,
        color: RecordingMouseIndicatorColor
    ) {
        let outerRadius = radius + lineWidth / 2
        let innerRadius = max(0, radius - lineWidth / 2)
        let minX = max(0, Int(floor(center.x - outerRadius)))
        let maxX = min(width - 1, Int(ceil(center.x + outerRadius)))
        let minY = max(0, Int(floor(center.y - outerRadius)))
        let maxY = min(height - 1, Int(ceil(center.y + outerRadius)))

        guard minX <= maxX, minY <= maxY else { return }

        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x) + 0.5 - center.x
                let dy = Double(y) + 0.5 - center.y
                let distance = hypot(dx, dy)
                guard distance >= innerRadius, distance <= outerRadius else { continue }

                let edgeDistance = min(distance - innerRadius, outerRadius - distance)
                let coverage = min(1, max(0, edgeDistance + 0.75))
                blendPixel(x: x, y: y, color: color.withAlphaMultiplier(coverage))
            }
        }
    }

    private mutating func blendPixel(x: Int, y: Int, color: RecordingMouseIndicatorColor) {
        guard color.alpha > 0 else { return }

        let offset = y * bytesPerRow + x * 4
        let alpha = Double(color.alpha) / 255
        let inverseAlpha = 1 - alpha

        baseAddress[offset] = UInt8(min(255, Double(color.blue) * alpha + Double(baseAddress[offset]) * inverseAlpha))
        baseAddress[offset + 1] = UInt8(min(255, Double(color.green) * alpha + Double(baseAddress[offset + 1]) * inverseAlpha))
        baseAddress[offset + 2] = UInt8(min(255, Double(color.red) * alpha + Double(baseAddress[offset + 2]) * inverseAlpha))
        baseAddress[offset + 3] = max(baseAddress[offset + 3], color.alpha)
    }
}

nonisolated struct RecordingMouseIndicatorColor: Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }

    static let macBlue = RecordingMouseIndicatorColor(red: 0, green: 122, blue: 255, alpha: 255)

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(hexString: String) {
        let value = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6,
              let integer = Int(value, radix: 16) else {
            return nil
        }

        self.init(
            red: UInt8((integer >> 16) & 0xFF),
            green: UInt8((integer >> 8) & 0xFF),
            blue: UInt8(integer & 0xFF),
            alpha: 255
        )
    }

    func withAlphaMultiplier(_ multiplier: Double) -> RecordingMouseIndicatorColor {
        let boundedMultiplier = min(max(multiplier, 0), 1)
        return RecordingMouseIndicatorColor(
            red: red,
            green: green,
            blue: blue,
            alpha: UInt8(Double(alpha) * boundedMultiplier)
        )
    }
}
