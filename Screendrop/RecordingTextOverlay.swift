//
//  RecordingTextOverlay.swift
//  Screendrop
//
//  Text placed over a Studio recording: titles, callouts and labels, with
//  the web editor's enter and exit animations (fade, slide, mask, grow,
//  shrink, blur), played on the whole text, word by word or letter by
//  letter. Each text lives on the recording's own clock, like zoom and
//  layout cues, so it stays with the footage it describes through cuts.
//
//  Position and size are fractions of the canvas, so one Core Text routine
//  draws it identically in the live preview and the offline export.
//

import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - Color

/// An sRGB color that survives the project file.
nonisolated struct RecordingOverlayColor: Codable, Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let white = RecordingOverlayColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = RecordingOverlayColor(red: 0, green: 0, blue: 0, alpha: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? .white
        red = Double(srgb.redComponent)
        green = Double(srgb.greenComponent)
        blue = Double(srgb.blueComponent)
        alpha = Double(srgb.alphaComponent)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

// MARK: - Font

nonisolated enum RecordingTextFont: String, Codable, CaseIterable, Identifiable, Sendable {
    case sans
    case rounded
    case serif
    case mono
    case condensed
    case marker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sans: "Sans"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .mono: "Mono"
        case .condensed: "Condensed"
        case .marker: "Marker"
        }
    }

    func font(size: CGFloat, isBold: Bool) -> CTFont {
        let weight: NSFont.Weight = isBold ? .bold : .regular
        let nsFont: NSFont
        switch self {
        case .sans:
            nsFont = .systemFont(ofSize: size, weight: weight)
        case .rounded, .serif, .mono:
            let base = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            let design: NSFontDescriptor.SystemDesign = switch self {
            case .rounded: .rounded
            case .serif: .serif
            default: .monospaced
            }
            let descriptor = base.withDesign(design) ?? base
            nsFont = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
        case .condensed:
            nsFont = .systemFont(ofSize: size, weight: isBold ? .heavy : .semibold, width: .compressed)
        case .marker:
            nsFont = NSFont(name: isBold ? "MarkerFelt-Wide" : "MarkerFelt-Thin", size: size)
                ?? .systemFont(ofSize: size, weight: weight)
        }
        return nsFont as CTFont
    }
}

// MARK: - Animation

/// An enter or exit animation. `.none` is a hard cut, or a typewriter when
/// split into words or letters.
nonisolated struct RecordingTextAnimation: Codable, Equatable, Hashable, Sendable {
    enum Effect: String, Codable, CaseIterable, Identifiable, Sendable {
        case none
        case fade
        case slideUp
        case slideDown
        case slideLeft
        case slideRight
        case maskUp
        case maskDown
        case grow
        case shrink
        case blur

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: "Appear"
            case .fade: "Fade"
            case .slideUp: "Slide Up"
            case .slideDown: "Slide Down"
            case .slideLeft: "Slide Left"
            case .slideRight: "Slide Right"
            case .maskUp: "Mask Up"
            case .maskDown: "Mask Down"
            case .grow: "Grow"
            case .shrink: "Shrink"
            case .blur: "Blur"
            }
        }
    }

    /// What animates independently.
    enum Unit: String, Codable, CaseIterable, Identifiable, Sendable {
        case all
        case words
        case letters

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .words: "Words"
            case .letters: "Letters"
            }
        }
    }

    enum Order: String, Codable, CaseIterable, Identifiable, Sendable {
        case forward
        case backward
        case center
        case random

        var id: String { rawValue }

        var title: String {
            switch self {
            case .forward: "Forward"
            case .backward: "Backward"
            case .center: "Center"
            case .random: "Random"
            }
        }
    }

    enum Ease: String, Codable, CaseIterable, Identifiable, Sendable {
        case linear
        case out
        case inOut
        case spring

        var id: String { rawValue }

        var title: String {
            switch self {
            case .linear: "Linear"
            case .out: "Ease Out"
            case .inOut: "Ease In Out"
            case .spring: "Spring"
            }
        }
    }

    var effect: Effect = .none
    /// Seconds each unit takes to animate.
    var duration: TimeInterval = 0.5
    var unit: Unit = .all
    var order: Order = .forward
    /// Seconds between one unit starting and the next.
    var delay: TimeInterval = 0.05
    var ease: Ease = .spring

    static let durationRange: ClosedRange<TimeInterval> = 0.05...3
    static let delayRange: ClosedRange<TimeInterval> = 0...0.5

    init(
        effect: Effect = .none,
        duration: TimeInterval = 0.5,
        unit: Unit = .all,
        order: Order = .forward,
        delay: TimeInterval = 0.05,
        ease: Ease = .spring
    ) {
        self.effect = effect
        self.duration = duration
        self.unit = unit
        self.order = order
        self.delay = delay
        self.ease = ease
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        effect = try container.decodeIfPresent(Effect.self, forKey: .effect) ?? .none
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0.5
        unit = try container.decodeIfPresent(Unit.self, forKey: .unit) ?? .all
        order = try container.decodeIfPresent(Order.self, forKey: .order) ?? .forward
        delay = try container.decodeIfPresent(TimeInterval.self, forKey: .delay) ?? 0.05
        ease = try container.decodeIfPresent(Ease.self, forKey: .ease) ?? .spring
    }

    /// Seconds from the first of `count` units starting to the last finishing.
    func span(units count: Int) -> TimeInterval {
        Double(max(0, count - 1)) * (count > 1 ? delay : 0) + (effect == .none ? 0 : duration)
    }

    /// Eased progress for `u` in 0...1. Spring overshoots on the way in and
    /// winds up slightly on the way out, so the overshoot never hides an
    /// exit early.
    func eased(_ u: Double, isExit: Bool) -> Double {
        switch ease {
        case .linear:
            return u
        case .out:
            return 1 - pow(1 - u, 3)
        case .inOut:
            return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
        case .spring:
            if isExit {
                let c1 = 1.70158
                return (c1 + 1) * u * u * u - c1 * u * u
            }
            return u >= 1 ? 1 : 1 - exp(-5 * u) * cos(3 * .pi * u)
        }
    }
}

// MARK: - Text overlay

nonisolated struct RecordingTextOverlay: Identifiable, Codable, Equatable, Hashable, Sendable {
    static let minimumDuration: TimeInterval = 0.1
    static let defaultDuration: TimeInterval = 3
    static let fontSizeRange: ClosedRange<Double> = 0.02...0.3

    var id = UUID()
    /// Recording (source) time.
    var start: TimeInterval
    var end: TimeInterval
    var text = "Your text"
    /// The text block's centre, as a fraction of the canvas.
    var center = CGPoint(x: 0.5, y: 0.5)
    /// Font size as a fraction of the canvas height.
    var fontSize: Double = 0.08
    var font: RecordingTextFont = .sans
    var color: RecordingOverlayColor = .white
    var isBold = true
    var hasBackground = false
    var backgroundColor: RecordingOverlayColor = .black
    var animationIn = RecordingTextAnimation()
    var animationOut = RecordingTextAnimation()

    var duration: TimeInterval { end - start }

    init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        center = try container.decodeIfPresent(CGPoint.self, forKey: .center) ?? CGPoint(x: 0.5, y: 0.5)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 0.08
        font = try container.decodeIfPresent(RecordingTextFont.self, forKey: .font) ?? .sans
        color = try container.decodeIfPresent(RecordingOverlayColor.self, forKey: .color) ?? .white
        isBold = try container.decodeIfPresent(Bool.self, forKey: .isBold) ?? true
        hasBackground = try container.decodeIfPresent(Bool.self, forKey: .hasBackground) ?? false
        backgroundColor = try container.decodeIfPresent(RecordingOverlayColor.self, forKey: .backgroundColor) ?? .black
        animationIn = try container.decodeIfPresent(RecordingTextAnimation.self, forKey: .animationIn) ?? .init()
        animationOut = try container.decodeIfPresent(RecordingTextAnimation.self, forKey: .animationOut) ?? .init()
    }

    func isActive(atSourceTime time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

/// Where a text or effect sits on the edited timeline: its source range
/// mapped through the cut. A cut inside it removes editor time between its
/// slices, so they always merge into one block.
nonisolated struct RecordingOverlayTimelineBlock<Item: Identifiable & Sendable>: Identifiable, Sendable {
    let item: Item
    let editorStart: TimeInterval
    let editorEnd: TimeInterval

    var id: Item.ID { item.id }

    static func blocks(
        for items: [Item],
        clipTimeline: RecordingClipTimeline,
        range: (Item) -> (start: TimeInterval, end: TimeInterval)
    ) -> [RecordingOverlayTimelineBlock<Item>] {
        items.compactMap { item in
            let source = range(item)
            guard let span = clipTimeline.editorSpan(overlapping: source.start, sourceEnd: source.end) else { return nil }
            return RecordingOverlayTimelineBlock(
                item: item,
                editorStart: span.lowerBound,
                editorEnd: span.upperBound
            )
        }
    }
}

// MARK: - Rendering

/// Lays out and draws text overlays. Shared by the preview's Canvas and the
/// exporter, both of which hand it a context whose user space is the
/// canvas with a top-left origin, y growing down.
nonisolated enum RecordingTextOverlayRenderer {
    struct Layout {
        /// The static box around the text (and its background), in canvas
        /// space; what the preview selects and drags.
        let rect: CGRect
    }

    private struct Unit {
        let text: String
        let x: CGFloat
        let width: CGFloat
        let line: Int
        /// The word this piece belongs to, across all lines.
        let word: Int
    }

    private struct Pose {
        var alpha: CGFloat = 1
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var scale: CGFloat = 1
        var blur: CGFloat = 0
        var masks = false
    }

    private struct UnitState {
        /// 0 hidden, 1 shown; springs may overshoot.
        var value: Double
        /// nil once fully in and not yet leaving.
        var isExit: Bool?
    }

    private static let lineHeightFactor: CGFloat = 1.2
    private static let paddingFactor: CGFloat = 0.35

    static func layout(_ overlay: RecordingTextOverlay, canvasSize: CGSize) -> Layout {
        let metrics = measure(overlay, canvasSize: canvasSize)
        return Layout(rect: metrics.rect)
    }

    private struct Metrics {
        let font: CTFont
        let fontSize: CGFloat
        let lines: [String]
        let lineWidths: [CGFloat]
        let lineHeight: CGFloat
        let top: CGFloat
        let center: CGPoint
        let rect: CGRect
    }

    private static func measure(_ overlay: RecordingTextOverlay, canvasSize: CGSize) -> Metrics {
        let fontSize = max(1, CGFloat(overlay.fontSize) * canvasSize.height)
        let font = overlay.font.font(size: fontSize, isBold: overlay.isBold)
        let lines = overlay.text.components(separatedBy: "\n")
        let lineWidths = lines.map { width(of: $0, font: font) }
        let lineHeight = fontSize * lineHeightFactor
        let textWidth = max(lineWidths.max() ?? 0, fontSize * 0.5)
        let textHeight = lineHeight * CGFloat(lines.count)
        let padding = fontSize * paddingFactor
        let center = CGPoint(x: overlay.center.x * canvasSize.width, y: overlay.center.y * canvasSize.height)
        let top = center.y - textHeight / 2
        let rect = CGRect(
            x: center.x - textWidth / 2 - padding,
            y: top - padding,
            width: textWidth + padding * 2,
            height: textHeight + padding * 2
        )
        return Metrics(
            font: font, fontSize: fontSize, lines: lines, lineWidths: lineWidths,
            lineHeight: lineHeight, top: top, center: center, rect: rect
        )
    }

    private static func line(_ text: String, font: CTFont, color: CGColor? = nil) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let color { attributes[.foregroundColor] = color }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func width(of text: String, font: CTFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return CGFloat(CTLineGetTypographicBounds(line(text, font: font), nil, nil, nil))
    }

    /// The smallest pieces either animation needs. A coarser animation
    /// groups pieces back together by word.
    private static func units(for overlay: RecordingTextOverlay, metrics: Metrics) -> [Unit] {
        let letters = overlay.animationIn.unit == .letters || overlay.animationOut.unit == .letters
        let words = letters || overlay.animationIn.unit == .words || overlay.animationOut.unit == .words
        var units: [Unit] = []
        var word = 0
        for (lineIndex, text) in metrics.lines.enumerated() {
            let left = metrics.center.x - metrics.lineWidths[lineIndex] / 2
            guard words else {
                units.append(Unit(text: text, x: left, width: metrics.lineWidths[lineIndex], line: lineIndex, word: word))
                word += 1
                continue
            }
            var index = text.startIndex
            while index < text.endIndex {
                guard !text[index].isWhitespace else {
                    index = text.index(after: index)
                    continue
                }
                var wordEnd = index
                while wordEnd < text.endIndex, !text[wordEnd].isWhitespace {
                    wordEnd = text.index(after: wordEnd)
                }
                let parts: [Range<String.Index>] = letters
                    ? text[index..<wordEnd].indices.map { $0..<text.index(after: $0) }
                    : [index..<wordEnd]
                for part in parts {
                    // Measure through this piece and step back by its own
                    // width, so kerning with the piece before it lands it
                    // where a whole-line draw would.
                    let piece = String(text[part])
                    let pieceWidth = width(of: piece, font: metrics.font)
                    let before = width(of: String(text[..<part.upperBound]), font: metrics.font) - pieceWidth
                    units.append(Unit(text: piece, x: left + before, width: pieceWidth, line: lineIndex, word: word))
                }
                word += 1
                index = wordEnd
            }
        }
        return units
    }

    /// The start slot of each of `count` units; units sharing a slot animate
    /// together.
    private static func ranks(count: Int, order: RecordingTextAnimation.Order, seed: UUID) -> [Int] {
        let indices = Array(0..<count)
        switch order {
        case .forward:
            return indices
        case .backward:
            return indices.map { count - 1 - $0 }
        case .center:
            let raw = indices.map { Int((abs(Double($0) - Double(count - 1) / 2) + 0.5).rounded(.down)) }
            let low = raw.min() ?? 0
            return raw.map { $0 - low }
        case .random:
            let seedText = seed.uuidString
            let sorted = indices.sorted { hash(seedText, $0) < hash(seedText, $1) }
            var ranks = Array(repeating: 0, count: count)
            for (rank, unit) in sorted.enumerated() { ranks[unit] = rank }
            return ranks
        }
    }

    private static func hash(_ seed: String, _ index: Int) -> UInt32 {
        var value = UInt32(2_166_136_261) ^ UInt32(truncatingIfNeeded: index)
        for byte in seed.utf8 {
            value = (value ^ UInt32(byte)) &* 16_777_619
        }
        value ^= value >> 15
        value = value &* 2_246_822_507
        value ^= value >> 13
        return value
    }

    /// How shown a unit in slot `rank` of `slots` is, `local` seconds into a
    /// text of `length` seconds. Each side is squeezed into half the text so
    /// the two can never overlap.
    private static func state(
        local: TimeInterval,
        length: TimeInterval,
        animation: RecordingTextAnimation,
        isExit: Bool,
        rank: Int,
        slots: Int
    ) -> Double {
        let half = length / 2
        let span = animation.span(units: slots)
        let squeeze = span > half && span > 0 ? half / span : 1
        let unitStart = Double(rank) * animation.delay * squeeze
        if animation.effect == .none { return local >= unitStart ? 1 : 0 }
        let u = min(max((local - unitStart) / max(animation.duration * squeeze, 0.0001), 0), 1)
        return animation.eased(u, isExit: isExit)
    }

    private static func pose(_ effect: RecordingTextAnimation.Effect, value: Double, isExit: Bool, lineHeight: CGFloat, fontSize: CGFloat) -> Pose {
        let v = CGFloat(value)
        let sign: CGFloat = isExit ? -1 : 1
        let distance = lineHeight * 1.2
        var pose = Pose()
        switch effect {
        case .none:
            pose.alpha = v
        case .fade:
            pose.alpha = v
        case .slideUp:
            pose.dy = sign * (1 - v) * distance
            pose.alpha = v * 2
        case .slideDown:
            pose.dy = -sign * (1 - v) * distance
            pose.alpha = v * 2
        case .slideLeft:
            pose.dx = sign * (1 - v) * distance
            pose.alpha = v * 2
        case .slideRight:
            pose.dx = -sign * (1 - v) * distance
            pose.alpha = v * 2
        case .maskUp:
            pose.dy = sign * (1 - v) * lineHeight * 1.1
            pose.masks = true
        case .maskDown:
            pose.dy = -sign * (1 - v) * lineHeight * 1.1
            pose.masks = true
        case .grow:
            pose.scale = 0.5 + 0.5 * v
            pose.alpha = v * 1.5
        case .shrink:
            pose.scale = 1.5 - 0.5 * v
            pose.alpha = v * 1.5
        case .blur:
            pose.blur = max(0, 1 - v) * fontSize * 0.4
            pose.alpha = v * 1.5
        }
        pose.alpha = min(max(pose.alpha, 0), 1)
        return pose
    }

    /// Draws `overlay` at `sourceTime`, with its animations, into `context`
    /// (canvas space, top-left origin). `opacity` multiplies everything.
    static func draw(
        _ overlay: RecordingTextOverlay,
        atSourceTime sourceTime: TimeInterval,
        canvasSize: CGSize,
        in context: CGContext,
        opacity: CGFloat = 1
    ) {
        guard !overlay.text.isEmpty, overlay.isActive(atSourceTime: sourceTime) else { return }
        draw(overlay, local: sourceTime - overlay.start, length: overlay.duration, canvasSize: canvasSize, in: context, opacity: opacity)
    }

    /// Draws `overlay` `local` seconds into a run of `length` seconds; the
    /// inspector's effect previews pretend to be a long text this way.
    static func draw(
        _ overlay: RecordingTextOverlay,
        local: TimeInterval,
        length: TimeInterval,
        canvasSize: CGSize,
        in context: CGContext,
        opacity: CGFloat = 1,
        castsShadow: Bool = true
    ) {
        let metrics = measure(overlay, canvasSize: canvasSize)
        let units = units(for: overlay, metrics: metrics)
        let wordCount = (units.last?.word ?? -1) + 1

        func slots(for animation: RecordingTextAnimation) -> (ranks: [Int], count: Int) {
            switch animation.unit {
            case .all:
                return (units.map { _ in 0 }, 1)
            case .words:
                let byWord = ranks(count: wordCount, order: animation.order, seed: overlay.id)
                return (units.map { byWord[$0.word] }, wordCount)
            case .letters:
                return (ranks(count: units.count, order: animation.order, seed: overlay.id), units.count)
            }
        }
        let enter = slots(for: overlay.animationIn)
        let exit = slots(for: overlay.animationOut)
        let exitSpan = overlay.animationOut.span(units: exit.count)
        let half = length / 2
        let exitSqueeze = exitSpan > half && exitSpan > 0 ? half / exitSpan : 1
        let exitLocal = local - (length - exitSpan * exitSqueeze)
        let enterSpan = overlay.animationIn.span(units: enter.count)

        let states: [UnitState] = units.indices.map { index in
            if exitSpan > 0, exitLocal > 0 {
                let value = 1 - state(
                    local: exitLocal, length: length, animation: overlay.animationOut,
                    isExit: true, rank: exit.ranks[index], slots: exit.count
                )
                if value < 1 { return UnitState(value: value, isExit: true) }
            }
            let value = state(
                local: local, length: length, animation: overlay.animationIn,
                isExit: false, rank: enter.ranks[index], slots: enter.count
            )
            return UnitState(value: value, isExit: local < enterSpan ? false : nil)
        }

        func effect(of state: UnitState) -> RecordingTextAnimation.Effect {
            state.isExit == true ? overlay.animationOut.effect : overlay.animationIn.effect
        }
        func pose(for state: UnitState) -> Pose {
            Self.pose(effect(of: state), value: state.value, isExit: state.isExit == true,
                      lineHeight: metrics.lineHeight, fontSize: metrics.fontSize)
        }
        func apply(_ pose: Pose, around origin: CGPoint) {
            context.translateBy(x: origin.x + pose.dx, y: origin.y + pose.dy)
            if pose.scale != 1 { context.scaleBy(x: pose.scale, y: pose.scale) }
            context.translateBy(x: -origin.x, y: -origin.y)
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }

        if overlay.hasBackground {
            // The box travels with the text when the whole block animates;
            // otherwise it just fades.
            let whole = overlay.animationIn.unit == .all && overlay.animationOut.unit == .all
            let lead = states.first ?? UnitState(value: 1, isExit: nil)
            let leadPose = pose(for: lead)
            let boxPose: Pose = if whole, !leadPose.masks, !states.isEmpty {
                leadPose
            } else {
                Self.pose(.fade, value: states.map(\.value).max() ?? 1, isExit: false,
                          lineHeight: metrics.lineHeight, fontSize: metrics.fontSize)
            }
            context.saveGState()
            context.setAlpha(opacity * boxPose.alpha)
            apply(boxPose, around: metrics.center)
            let radius = metrics.fontSize * 0.2
            context.addPath(CGPath(roundedRect: metrics.rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(overlay.backgroundColor.cgColor)
            context.fillPath()
            context.restoreGState()
        }

        // Text without a box gets a soft shadow so it reads over any frame.
        // Shadows are measured in device units, so the blur is converted
        // to keep the same look at the preview's size and the export's.
        let shadowBlur = castsShadow && !overlay.hasBackground
            ? deviceLength(metrics.fontSize * 0.15, in: context)
            : 0
        let color = overlay.color.cgColor

        for (index, unit) in units.enumerated() {
            let unitState = states[index]
            let unitPose = pose(for: unitState)
            guard unitPose.alpha > 0.001 else { continue }
            let baselineCenter = metrics.top + metrics.lineHeight * (CGFloat(unit.line) + 0.5)
            context.saveGState()
            context.setAlpha(opacity * unitPose.alpha)
            if unitPose.masks {
                context.clip(to: CGRect(
                    x: metrics.rect.minX,
                    y: baselineCenter - metrics.lineHeight / 2,
                    width: metrics.rect.width,
                    height: metrics.lineHeight
                ))
            }
            let whole = (unitState.isExit == true ? overlay.animationOut.unit : overlay.animationIn.unit) == .all
            apply(unitPose, around: whole ? metrics.center : CGPoint(x: unit.x + unit.width / 2, y: baselineCenter))
            let ctLine = line(unit.text, font: metrics.font, color: color)
            // Centre the glyphs' em box on the line's middle.
            let ascent = CTFontGetAscent(metrics.font)
            let descent = CTFontGetDescent(metrics.font)
            let baseline = baselineCenter + (ascent - descent) / 2
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            if unitPose.blur > 0.3 {
                // Core Graphics has no per-draw blur, so a blurred unit is
                // drawn far off to the side and only its shadow, blurred,
                // is cast back into place.
                let away: CGFloat = 100_000
                let offset = deviceVector(CGSize(width: away, height: 0), in: context)
                context.setShadow(offset: offset, blur: deviceLength(unitPose.blur, in: context), color: color)
                context.textPosition = CGPoint(x: unit.x - away, y: baseline)
            } else {
                if shadowBlur > 0 {
                    context.setShadow(offset: .zero, blur: shadowBlur, color: CGColor(gray: 0, alpha: 0.45))
                }
                context.textPosition = CGPoint(x: unit.x, y: baseline)
            }
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }

    private static func deviceLength(_ length: CGFloat, in context: CGContext) -> CGFloat {
        let size = context.convertToDeviceSpace(CGSize(width: length, height: 0))
        return hypot(size.width, size.height)
    }

    private static func deviceVector(_ size: CGSize, in context: CGContext) -> CGSize {
        context.convertToDeviceSpace(size)
    }
}
