//
//  RecordingRedaction.swift
//  Screendrop
//
//  Regions of the recording that must never be published: an API key, a
//  customer name, an inbox in the sidebar. Regions live in *source* space —
//  normalized against the recorded frame, on the source clock — which is the
//  one space the virtual camera has not touched yet. Studio and the exporter
//  then obscure those pixels before anything else looks at the frame, so the
//  zoom, pan, reframe, card clip, and motion blur downstream all inherit the
//  redaction for free instead of each needing to know about it.
//

import CoreGraphics
import CoreImage
import Foundation

nonisolated enum RedactionStyle: String, Codable, CaseIterable, Sendable {
    case blur
    case pixelate
    case solid

    var inspectorTitle: String {
        switch self {
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .solid: "Solid"
        }
    }

    var inspectorSymbol: String {
        switch self {
        case .blur: "drop.halffull"
        case .pixelate: "squareshape.split.3x3"
        case .solid: "square.fill"
        }
    }

    /// An unknown style from a newer project still has to hide something, so
    /// it decodes to the most opaque option rather than to nothing at all.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RedactionStyle(rawValue: raw) ?? .solid
    }
}

/// One placement of a region, on the source clock. A region with a single
/// keyframe never moves; more than one lets it travel with a window that was
/// dragged or a panel that slid, without any frame-to-frame tracking.
nonisolated struct RedactionKeyframe: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    /// Seconds on the source timeline.
    var time: TimeInterval
    /// Normalized (0...1, top-left origin) rectangle in the recorded frame.
    var rect: CGRect

    init(id: UUID = UUID(), time: TimeInterval, rect: CGRect) {
        self.id = id
        self.time = max(0, time)
        self.rect = RedactionRegion.normalized(rect)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case time
        case rect
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        time = max(0, try container.decodeIfPresent(TimeInterval.self, forKey: .time) ?? 0)
        rect = RedactionRegion.normalized(try container.decode(CGRect.self, forKey: .rect))
    }
}

nonisolated struct RedactionRegion: Identifiable, Codable, Equatable, Sendable {
    /// Smallest region the canvas will create or leave behind after a resize,
    /// as a fraction of the frame. Anything smaller is a stray click.
    static let minimumSize: CGFloat = 0.01

    var id: UUID
    /// Sorted by time, never empty. The first keyframe's rectangle applies to
    /// everything before it and the last one's to everything after, so a
    /// region can never blink off part-way through and expose what it covers.
    var keyframes: [RedactionKeyframe]
    var style: RedactionStyle
    /// 0...1, scaled into a blur radius or pixel size against the region's own
    /// size so the same setting reads the same on a small badge and a full
    /// sidebar.
    var intensity: Double
    /// Source-time window. Nil covers the whole recording, which is what most
    /// redactions want: the thing being hidden is usually on screen the whole
    /// time.
    var start: TimeInterval?
    var end: TimeInterval?
    var isEnabled: Bool
    /// Shown in the inspector list so a project with six regions stays legible.
    var label: String?

    init(
        id: UUID = UUID(),
        keyframes: [RedactionKeyframe],
        style: RedactionStyle = .blur,
        intensity: Double = 0.6,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil,
        isEnabled: Bool = true,
        label: String? = nil
    ) {
        self.id = id
        self.keyframes = Self.sortedNonEmpty(keyframes)
        self.style = style
        self.intensity = Self.unit(intensity)
        self.start = start
        self.end = end
        self.isEnabled = isEnabled
        self.label = label
    }

    init(
        id: UUID = UUID(),
        rect: CGRect,
        style: RedactionStyle = .blur,
        intensity: Double = 0.6
    ) {
        self.init(
            id: id,
            keyframes: [RedactionKeyframe(time: 0, rect: rect)],
            style: style,
            intensity: intensity
        )
    }

    var isTracking: Bool { keyframes.count > 1 }

    /// The rectangle to obscure at a source time, or nil when the region is
    /// switched off or outside its window.
    func rect(atSourceTime time: TimeInterval) -> CGRect? {
        guard isEnabled else { return nil }
        if let start, time < start { return nil }
        if let end, time > end { return nil }
        return interpolatedRect(atSourceTime: time)
    }

    /// Placement alone, ignoring the enabled flag and the time window. The
    /// canvas needs this to keep drawing a region's handles while the playhead
    /// sits outside the range the user is still setting up.
    func interpolatedRect(atSourceTime time: TimeInterval) -> CGRect {
        guard let first = keyframes.first else {
            return CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        }
        guard let last = keyframes.last, keyframes.count > 1 else { return first.rect }
        if time <= first.time { return first.rect }
        if time >= last.time { return last.rect }

        // Sorted and short: a linear scan beats the bookkeeping of a search,
        // and regions rarely carry more than a handful of keyframes.
        for index in 1..<keyframes.count {
            let leading = keyframes[index - 1]
            let trailing = keyframes[index]
            guard time <= trailing.time else { continue }
            let span = trailing.time - leading.time
            guard span > 0 else { return trailing.rect }
            let progress = (time - leading.time) / span
            return Self.interpolate(leading.rect, trailing.rect, progress)
        }
        return last.rect
    }

    /// The keyframe a canvas drag should edit: the one governing what is on
    /// screen right now.
    func nearestKeyframeID(toSourceTime time: TimeInterval) -> UUID? {
        keyframes.min { lhs, rhs in
            abs(lhs.time - time) < abs(rhs.time - time)
        }?.id
    }

    /// Moves or resizes the region at a source time. With one keyframe that is
    /// a plain edit; with several it retargets whichever keyframe governs this
    /// moment, so dragging never silently flattens a tracked region.
    mutating func setRect(_ rect: CGRect, atSourceTime time: TimeInterval) {
        let normalized = Self.normalized(rect)
        guard let targetID = nearestKeyframeID(toSourceTime: time),
              let index = keyframes.firstIndex(where: { $0.id == targetID }) else {
            keyframes = [RedactionKeyframe(time: max(0, time), rect: normalized)]
            return
        }
        keyframes[index].rect = normalized
    }

    /// Pins the region's current placement at a source time so it can be moved
    /// from there on without disturbing where it already sat.
    mutating func addKeyframe(atSourceTime time: TimeInterval) {
        let time = max(0, time)
        let rect = interpolatedRect(atSourceTime: time)
        if let index = keyframes.firstIndex(where: { abs($0.time - time) < 0.001 }) {
            keyframes[index].rect = rect
            return
        }
        keyframes.append(RedactionKeyframe(time: time, rect: rect))
        keyframes = Self.sortedNonEmpty(keyframes)
    }

    /// Collapses back to a single, unmoving rectangle at the current placement.
    mutating func clearTracking(atSourceTime time: TimeInterval) {
        let rect = interpolatedRect(atSourceTime: time)
        keyframes = [RedactionKeyframe(time: 0, rect: rect)]
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case keyframes
        case style
        case intensity
        case start
        case end
        case isEnabled
        case label
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        keyframes = Self.sortedNonEmpty(
            try container.decodeIfPresent([RedactionKeyframe].self, forKey: .keyframes) ?? []
        )
        style = try container.decodeIfPresent(RedactionStyle.self, forKey: .style) ?? .blur
        intensity = Self.unit(try container.decodeIfPresent(Double.self, forKey: .intensity) ?? 0.6)
        start = try container.decodeIfPresent(TimeInterval.self, forKey: .start)
        end = try container.decodeIfPresent(TimeInterval.self, forKey: .end)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        label = try container.decodeIfPresent(String.self, forKey: .label)
    }

    // MARK: - Geometry helpers

    /// Clamped into the frame and never smaller than `minimumSize`, so no edit
    /// path can produce a region that is invisible but still saved.
    static func normalized(_ rect: CGRect) -> CGRect {
        let standardized = rect.standardized
        let width = min(max(standardized.width, minimumSize), 1)
        let height = min(max(standardized.height, minimumSize), 1)
        let x = min(max(standardized.minX, 0), 1 - width)
        let y = min(max(standardized.minY, 0), 1 - height)
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            return CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func interpolate(_ from: CGRect, _ to: CGRect, _ progress: Double) -> CGRect {
        let t = CGFloat(min(max(progress, 0), 1))
        return CGRect(
            x: from.minX + (to.minX - from.minX) * t,
            y: from.minY + (to.minY - from.minY) * t,
            width: from.width + (to.width - from.width) * t,
            height: from.height + (to.height - from.height) * t
        )
    }

    private static func sortedNonEmpty(_ keyframes: [RedactionKeyframe]) -> [RedactionKeyframe] {
        guard !keyframes.isEmpty else {
            return [RedactionKeyframe(time: 0, rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))]
        }
        return keyframes.sorted { $0.time < $1.time }
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0.6 }
        return min(max(value, 0), 1)
    }
}

/// A region resolved to one moment: what to cover and how.
nonisolated struct ResolvedRedaction: Equatable, Sendable {
    let rect: CGRect
    let style: RedactionStyle
    let intensity: Double
}

/// The project's regions, resolved against source time. Held by value so the
/// exporter can carry it across to its own actor without sharing state.
nonisolated struct RedactionTrack: Equatable, Sendable {
    let regions: [RedactionRegion]

    init(regions: [RedactionRegion]) {
        self.regions = regions
    }

    var isEmpty: Bool {
        regions.allSatisfy { !$0.isEnabled }
    }

    func resolved(atSourceTime time: TimeInterval) -> [ResolvedRedaction] {
        regions.compactMap { region in
            guard let rect = region.rect(atSourceTime: time) else { return nil }
            return ResolvedRedaction(
                rect: rect,
                style: region.style,
                intensity: region.intensity
            )
        }
    }
}

/// Obscures resolved regions inside a frame. One instance is shared by every
/// frame of a render so the Metal-backed `CIContext` and its pipeline caches
/// are built once, and only the regions themselves are ever filtered — the
/// rest of the frame is passed through untouched.
nonisolated final class RedactionRenderer: @unchecked Sendable {
    private let context: CIContext

    init() {
        context = CIContext(options: [.cacheIntermediates: false])
    }

    /// Core Image's y axis runs up from the bottom of the extent; region
    /// rectangles are stored top-left like everything else in the project.
    static func imageRect(for normalized: CGRect, in extent: CGRect) -> CGRect {
        CGRect(
            x: extent.minX + normalized.minX * extent.width,
            y: extent.minY + (1 - normalized.minY - normalized.height) * extent.height,
            width: normalized.width * extent.width,
            height: normalized.height * extent.height
        )
    }

    func apply(_ redactions: [ResolvedRedaction], to image: CIImage) -> CIImage {
        guard !redactions.isEmpty else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return image }

        var output = image
        for redaction in redactions {
            let rect = Self.imageRect(for: redaction.rect, in: extent).intersection(extent)
            guard rect.width >= 1, rect.height >= 1 else { continue }
            guard let tile = tile(for: redaction, from: image, in: rect) else { continue }
            output = tile.composited(over: output)
        }
        return output
    }

    /// A redacted frame ready for the exporter's `CGContext`, or nil when
    /// there is nothing to hide — the caller then keeps its cheaper path.
    func redactedImage(
        from pixelBuffer: CVPixelBuffer,
        redactions: [ResolvedRedaction],
        colorSpace: CGColorSpace
    ) -> CGImage? {
        guard !redactions.isEmpty else { return nil }
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let output = apply(redactions, to: source)
        return context.createCGImage(
            output,
            from: source.extent,
            format: .BGRA8,
            colorSpace: colorSpace
        )
    }

    private func tile(
        for redaction: ResolvedRedaction,
        from image: CIImage,
        in rect: CGRect
    ) -> CIImage? {
        let shortEdge = min(rect.width, rect.height)
        switch redaction.style {
        case .blur:
            // Clamping first stops the blur from pulling in the transparent
            // space outside the crop, which would otherwise fade the region's
            // edges back towards legible.
            let radius = min(max(shortEdge * (0.06 + 0.18 * redaction.intensity), 4), 160)
            return image
                .cropped(to: rect)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: Double(radius))
                .cropped(to: rect)
        case .pixelate:
            let scale = min(max(shortEdge * (0.08 + 0.22 * redaction.intensity), 4), 200)
            let center = CIVector(x: rect.midX, y: rect.midY)
            return image
                .cropped(to: rect)
                .clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: center,
                    kCIInputScaleKey: scale
                ])
                .cropped(to: rect)
        case .solid:
            return CIImage(color: CIColor(red: 0.07, green: 0.07, blue: 0.08))
                .cropped(to: rect)
        }
    }
}
