//
//  RecordingViewportTimeline.swift
//  Screendrop
//
//  Deterministic virtual-camera planning for screen recordings. Zoom cues
//  are editable project data; this file resolves those cues against the
//  separately recorded pointer capture, constrains the viewport to the
//  source, and integrates one damped spring at a fixed rate along the
//  *edited* (clip) timeline, so cuts never interrupt a zoom and per-clip
//  speed never changes how fast the camera itself moves. Preview and export
//  then interpolate the same immutable viewport timeline at editor time.
//

import CoreGraphics
import Foundation

nonisolated enum ZoomAnchorMode: String, Codable, CaseIterable, Sendable {
    /// Track the latest recorded pointer sample directly.
    case pointerAnchor
    /// Hold on stable regions of pointer activity instead of chasing every
    /// recorded sample. This remains available as an explicit editing choice.
    case smartAnchor
    /// Frame an explicit normalized point selected by the user.
    case pinnedAnchor

    /// Unknown and legacy experimental modes preserve the current project's
    /// pointer-follow behavior instead of silently changing saved edits.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ZoomAnchorMode(rawValue: raw) ?? .pointerAnchor
    }
}

nonisolated struct ZoomCue: Identifiable, Codable, Equatable, Sendable {
    /// Shortest cue the timeline will create or leave behind after a resize.
    static let minimumDuration: TimeInterval = 0.5

    var id: UUID
    var start: TimeInterval
    var end: TimeInterval
    /// Magnification while the cue is fully active (1 = no zoom).
    var zoom: Double
    var anchorMode: ZoomAnchorMode
    /// Normalized source coordinate, with a top-left origin.
    var pinnedPoint: CGPoint
    /// How strongly automatic targets retain their unzoomed screen position.
    var boundsBias: Double
    var isEnabled: Bool
    var isImplicit: Bool
    var skipsEasing: Bool

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        zoom: Double = 1.5,
        anchorMode: ZoomAnchorMode = .pointerAnchor,
        pinnedPoint: CGPoint = CGPoint(x: 0.5, y: 0.5),
        boundsBias: Double = 0.25,
        isEnabled: Bool = true,
        isImplicit: Bool = false,
        skipsEasing: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.zoom = zoom
        self.anchorMode = anchorMode
        self.pinnedPoint = Self.normalized(pinnedPoint)
        self.boundsBias = Self.unit(boundsBias)
        self.isEnabled = isEnabled
        self.isImplicit = isImplicit
        self.skipsEasing = skipsEasing
    }

    var duration: TimeInterval {
        max(0, end - start)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case start
        case end
        case zoom
        case anchorMode
        case pinnedPoint
        case boundsBias
        case isEnabled
        case isImplicit
        case skipsEasing
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 2
        anchorMode = try container.decodeIfPresent(ZoomAnchorMode.self, forKey: .anchorMode) ?? .pointerAnchor
        let decodedPoint = try container.decodeIfPresent(CGPoint.self, forKey: .pinnedPoint)
            ?? CGPoint(x: 0.5, y: 0.5)
        pinnedPoint = Self.normalized(decodedPoint)
        boundsBias = Self.unit(try container.decodeIfPresent(Double.self, forKey: .boundsBias) ?? 0.25)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isImplicit = try container.decodeIfPresent(Bool.self, forKey: .isImplicit) ?? false
        skipsEasing = try container.decodeIfPresent(Bool.self, forKey: .skipsEasing) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(anchorMode, forKey: .anchorMode)
        try container.encode(Self.normalized(pinnedPoint), forKey: .pinnedPoint)
        try container.encode(Self.unit(boundsBias), forKey: .boundsBias)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isImplicit, forKey: .isImplicit)
        try container.encode(skipsEasing, forKey: .skipsEasing)
    }

    private static func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: unit(point.x), y: unit(point.y))
    }

    private static func unit<T: BinaryFloatingPoint>(_ value: T) -> T {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}

/// How much of the recording a card shows at 1x along each axis. A
/// viewport at magnification m sees `fraction / m` of the recording, so its
/// half-extent on an axis is `fraction / (2m)`; the whole frame is (1, 1).
nonisolated struct VisibleFraction: Sendable {
    let width: Double
    let height: Double

    init(_ size: CGSize) {
        width = min(max(Double(size.width), 0.000_1), 1)
        height = min(max(Double(size.height), 0.000_1), 1)
    }

    func halfExtents(magnification: Double) -> (x: Double, y: Double) {
        let base = 1 / (2 * max(magnification, 1))
        return (base * width, base * height)
    }
}

/// One sampled state of the virtual camera.
nonisolated struct ViewportFrame: Sendable, Equatable {
    var magnification: Double
    /// Normalized (0...1, top-left origin) content point at the viewport center.
    var anchor: CGPoint

    static let identity = ViewportFrame(magnification: 1, anchor: CGPoint(x: 0.5, y: 0.5))
}

/// Original subject coordinates, before viewport bounds or camera clearance
/// change where that subject can appear on the output canvas.
nonisolated struct ViewportTarget: Sendable {
    let magnification: Double
    let point: CGPoint
    let boundsBias: Double
}

// MARK: - Auto-generation from recorded input

nonisolated enum ZoomCueSynthesizer {
    private static let preRoll: TimeInterval = 0.3
    private static let postRoll: TimeInterval = 2.5
    private static let joinTolerance: TimeInterval = 2.5
    private static let tailExclusion: TimeInterval = 1.0
    private static let trailingGuard: TimeInterval = 0.8
    private static let earliestStart: TimeInterval = 0.001
    private static let defaultMagnification = 1.5

    /// Builds editable Pointer cues around press events. A sorted one-pass merge
    /// is transitive, so cues connected by the allowed gap naturally become
    /// one continuous zoom.
    static func cues(from capture: PointerCaptureFile, duration: TimeInterval) -> [ZoomCue] {
        guard duration.isFinite, duration > 0 else { return [] }

        let latestEligiblePress = duration - tailExclusion
        let candidates = capture.presses
            .filter {
                $0.phase == .down
                    && $0.time.isFinite
                    && $0.time < latestEligiblePress
                    && (0...1).contains($0.x)
                    && (0...1).contains($0.y)
            }
            .sorted { $0.time < $1.time }
            .compactMap { press -> ZoomCue? in
                let start = max(press.time - preRoll, earliestStart)
                let end = min(press.time + postRoll, duration - trailingGuard)
                guard end > start else { return nil }
                return ZoomCue(
                    start: start,
                    end: end,
                    zoom: defaultMagnification,
                    anchorMode: .pointerAnchor,
                    pinnedPoint: CGPoint(x: press.x, y: press.y),
                    boundsBias: 0.25
                )
            }

        var merged: [ZoomCue] = []
        merged.reserveCapacity(candidates.count)
        for candidate in candidates {
            if var previous = merged.last, candidate.start <= previous.end + joinTolerance {
                previous.end = max(previous.end, candidate.end)
                merged[merged.count - 1] = previous
            } else {
                merged.append(candidate)
            }
        }
        return merged
    }
}

// MARK: - Precomputed viewport timeline

nonisolated struct ViewportTimeline: Sendable {
    /// Fixed integration cadence. Playback display cadence never advances the
    /// springs; it only interpolates this immutable source-time timeline.
    static let stepRate: Double = 120

    static let motionProfile = SpringConstant(tension: 125, friction: 12, inertia: 1.5, clampsOvershoot: true)
    private static let anticipationWindow: TimeInterval = 0.5

    private let frames: [ViewportFrame]
    /// Per frame, how far the zoom has travelled toward the magnification
    /// it is heading for (or, zooming out, the one it is leaving): 0 on the
    /// unzoomed screen, 1 once it lands. Things that react to zooms, like
    /// the corner camera stepping back, follow this so they arrive with the
    /// zoom rather than ahead of it.
    private let zoomProgress: [Double]
    private let duration: TimeInterval
    private var snapFrames: [Bool] = []
    private var targets: [ViewportTarget] = []

    static let identity = ViewportTimeline(frames: [.identity], zoomProgress: [0], duration: 0)

    /// Destination intent for the composed Studio track. A bounded viewport
    /// anchor is a camera center, and must never stand in for the subject.
    func target(at time: TimeInterval) -> ViewportTarget? {
        guard !targets.isEmpty else { return nil }
        let index = min(max(Int((time * Self.stepRate).rounded()), 0), targets.count - 1)
        return targets[index]
    }

    func snaps(at time: TimeInterval) -> Bool {
        guard !snapFrames.isEmpty else { return false }
        let index = min(max(Int((time * Self.stepRate).rounded()), 0), snapFrames.count - 1)
        return snapFrames[index]
    }

    private init(frames: [ViewportFrame], zoomProgress: [Double], duration: TimeInterval) {
        self.frames = frames
        self.zoomProgress = zoomProgress
        self.duration = duration
    }

    /// - Parameter time: Editor (edited-timeline) time, not raw source time.
    func zoomProgress(at time: TimeInterval) -> Double {
        guard zoomProgress.count > 1, duration > 0 else { return zoomProgress.first ?? 0 }
        let position = min(max(time, 0), duration) * Self.stepRate
        let index = Int(position)
        guard index < zoomProgress.count - 1 else { return zoomProgress[zoomProgress.count - 1] }
        let fraction = position - Double(index)
        return zoomProgress[index] + (zoomProgress[index + 1] - zoomProgress[index]) * fraction
    }

    /// - Parameter time: Editor (edited-timeline) time, not raw source time.
    func frame(at time: TimeInterval) -> ViewportFrame {
        guard frames.count > 1, duration > 0 else { return frames.first ?? .identity }

        let position = min(max(time, 0), duration) * Self.stepRate
        let index = Int(position)
        guard index < frames.count - 1 else { return frames[frames.count - 1] }

        let fraction = position - Double(index)
        let a = frames[index]
        let b = frames[index + 1]
        return ViewportFrame(
            magnification: a.magnification + (b.magnification - a.magnification) * fraction,
            anchor: CGPoint(
                x: a.anchor.x + (b.anchor.x - a.anchor.x) * fraction,
                y: a.anchor.y + (b.anchor.y - a.anchor.y) * fraction
            )
        )
    }

    /// Builds the camera's motion along the *edited* (clip) timeline rather
    /// than raw source time. Two things follow from that:
    ///
    /// - A cut never interrupts a zoom. The spring is only ever asked to
    ///   step across contiguous editor time, so when editor time crosses a
    ///   clip boundary it just keeps easing smoothly toward whatever target
    ///   applies after the cut, instead of jumping to wherever the
    ///   uncut-timeline curve would have been at that source instant.
    /// - Zoom motion is speed-independent. The spring's own step cadence is
    ///   fixed editor-time `dt`; only the *lookup* of which cue/pointer
    ///   target is active is resolved through the clip's speed (via
    ///   `clipTimeline.sourceTime(at:)`), so a sped-up clip plays its video
    ///   faster without the pan/zoom itself moving any faster.
    /// - Parameter visibleFraction: Source width and height visible at 1x.
    /// - Parameter sourceBounds: The selected source crop, in source units.
    /// - Parameter smoothsMotion: False supplies destination intent to the
    ///   Studio motion track, which integrates layout and zoom together.
    /// - Parameter visibleFractionAtTime: Destination card geometry when
    ///   the layout or output aspect changes the visible source fraction.
    static func build(
        cues: [ZoomCue],
        capture: PointerCaptureFile,
        clipTimeline: RecordingClipTimeline,
        visibleFraction: CGSize = CGSize(width: 1, height: 1),
        sourceBounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        smoothsMotion: Bool = true,
        visibleFractionAtTime: ((TimeInterval, Double) -> CGSize)? = nil
    ) -> ViewportTimeline {
        let visible = VisibleFraction(visibleFraction)
        let duration = clipTimeline.duration
        guard duration.isFinite, duration > 0 else { return .identity }

        // Cuts to footage from another moment: the camera lands on them
        // instead of easing across.
        let hardCutFrames = Set(clipTimeline.hardCuts.map { Int(($0 * stepRate).rounded(.up)) })
        let pointerSamples = mergedPointerSamples(from: capture)
        let activitySamples = pointerSamples.filter {
            isRetainedSourceEvent($0.time, in: clipTimeline)
        }
        let restingVisible = visibleFractionAtTime.map { VisibleFraction($0(0, 1)) } ?? visible
        let restingTargets = activityTargets(
            for: ZoomCue(start: 0, end: clipTimeline.segments.map(\.sourceEnd).max() ?? duration, zoom: 1),
            samples: activitySamples,
            visible: restingVisible,
            prefersPressGroups: false
        )
        var activityTargetsByCueID: [UUID: [ActivityTarget]] = [:]
        for cue in cues where cue.anchorMode == .smartAnchor
            && activityTargetsByCueID[cue.id] == nil {
            activityTargetsByCueID[cue.id] = activityTargets(
                for: cue,
                samples: activitySamples,
                visible: visible
            )
        }
        // Anticipation is in playback seconds, so speeding or cutting footage
        // cannot desynchronize the camera's lead-in from the displayed cursor.
        let pressEvents = activitySamples.filter { $0.kind == .press }.compactMap { sample -> PointerSample? in
            guard let time = clipTimeline.editorTime(forSourceTime: sample.time) else { return nil }
            return PointerSample(time: time, point: sample.point, kind: sample.kind)
        }.sorted { $0.time < $1.time }
        let frameCount = max(2, Int((duration * stepRate).rounded(.up)) + 1)
        let dt = 1.0 / stepRate

        // Spring the rendered rectangle's scale and translation. Springing
        // an inverse scale and then multiplying it by a separately sprung
        // anchor gives pan and zoom different trajectories.
        var scaleSpring = DampedSpring(position: 1)
        var translationXSpring = DampedSpring(position: 0.5 - sourceBounds.midX)
        var translationYSpring = DampedSpring(position: 0.5 - sourceBounds.midY)
        var previousActive: ZoomCue?
        var latestPressIndex = -1

        var frames: [ViewportFrame] = []
        frames.reserveCapacity(frameCount)
        var zoomProgress: [Double] = []
        zoomProgress.reserveCapacity(frameCount)
        var snapFrames: [Bool] = []
        snapFrames.reserveCapacity(frameCount)
        var targets: [ViewportTarget] = []
        if !smoothsMotion { targets.reserveCapacity(frameCount) }
        // The zoom the viewport is heading for, held through the zoom-out.
        var progressReference = 1.0

        for frameIndex in 0..<frameCount {
            let editorTime = min(Double(frameIndex) * dt, duration)
            let time = clipTimeline.sourceTime(at: editorTime)
            while latestPressIndex + 1 < pressEvents.count,
                  pressEvents[latestPressIndex + 1].time <= editorTime {
                latestPressIndex += 1
            }
            let active = activeCue(at: time, cues: cues)
            let targetMagnification = max(1, active?.zoom ?? 1)
            let visible = visibleFractionAtTime.map {
                VisibleFraction($0(editorTime, targetMagnification))
            } ?? visible
            let isCropped = visible.width < sourceBounds.width - 0.001
                || visible.height < sourceBounds.height - 0.001
            var rawTarget = active.map { cue in
                anchorPoint(
                    for: cue,
                    at: time,
                    samples: pointerSamples,
                    activityTargets: activityTargetsByCueID[cue.id] ?? []
                )
            } ?? (isCropped
                ? activityTarget(at: time, targets: restingTargets)
                    ?? trackedPointerPosition(at: time, samples: pointerSamples)
                    ?? CGPoint(x: sourceBounds.midX, y: sourceBounds.midY)
                : CGPoint(x: sourceBounds.midX, y: sourceBounds.midY))
            let upcomingIndex = latestPressIndex + 1
            if (active?.anchorMode == .pointerAnchor || (active == nil && isCropped)),
               upcomingIndex < pressEvents.count,
               pressEvents[upcomingIndex].time - editorTime <= anticipationWindow {
                rawTarget = pressEvents[upcomingIndex].point
            }
            if !smoothsMotion {
                targets.append(ViewportTarget(
                    magnification: targetMagnification,
                    point: normalized(rawTarget),
                    boundsBias: active?.anchorMode == .pinnedAnchor ? 0 : active?.boundsBias ?? 0
                ))
            }
            let targetAnchor = boundedAnchor(
                rawTarget,
                magnification: targetMagnification,
                anchorMode: active?.anchorMode ?? (isCropped ? .pointerAnchor : .pinnedAnchor),
                boundsBias: active?.boundsBias ?? 0,
                visible: visible,
                bounds: sourceBounds
            )
            let targetX = (0.5 - targetAnchor.x) * targetMagnification
            let targetY = (0.5 - targetAnchor.y) * targetMagnification

            let activeChanged = active?.id != previousActive?.id
            let shouldSnap = hardCutFrames.contains(frameIndex)
                || (activeChanged
                    && (active?.skipsEasing == true
                        || previousActive?.skipsEasing == true))

            if shouldSnap || !smoothsMotion {
                scaleSpring.snap(to: targetMagnification)
                translationXSpring.snap(to: targetX)
                translationYSpring.snap(to: targetY)
            } else if frameIndex > 0 {
                scaleSpring.step(toward: targetMagnification, using: motionProfile, dt: dt)
                translationXSpring.step(toward: targetX, using: motionProfile, dt: dt)
                translationYSpring.step(toward: targetY, using: motionProfile, dt: dt)
            }

            let magnification = max(1, scaleSpring.position)
            let anchor = clampToFrame(
                CGPoint(
                    x: 0.5 - translationXSpring.position / magnification,
                    y: 0.5 - translationYSpring.position / magnification
                ),
                magnification: magnification,
                visible: visible,
                bounds: sourceBounds
            )
            frames.append(ViewportFrame(magnification: magnification, anchor: anchor))
            snapFrames.append(shouldSnap)
            if targetMagnification > 1 {
                progressReference = targetMagnification
            }
            var progress = progressReference > 1
                ? min(max((magnification - 1) / (progressReference - 1), 0), 1)
                : 0
            // The spring only approaches its target; within half a percent
            // the zoom has landed, and reacting layers can hold still.
            if progress > 0.995 { progress = 1 } else if progress < 0.005 { progress = 0 }
            zoomProgress.append(progress)
            previousActive = active
        }

        var timeline = ViewportTimeline(frames: frames, zoomProgress: zoomProgress, duration: duration)
        timeline.snapFrames = snapFrames
        timeline.targets = targets
        return timeline
    }

    // MARK: Cue selection

    /// User-authored intent wins over generic behavior. Within the same class,
    /// the most recently started active cue wins deterministically.
    private static func activeCue(
        at time: TimeInterval,
        cues: [ZoomCue]
    ) -> ZoomCue? {
        var selected: ZoomCue?
        var selectedPrecedence = Int.min

        for cue in cues where cue.isEnabled
            && time >= cue.start
            && time <= cue.end {
            let precedence = cuePriority(cue)
            if selected == nil
                || precedence > selectedPrecedence
                || (precedence == selectedPrecedence && cue.start >= selected!.start) {
                selected = cue
                selectedPrecedence = precedence
            }
        }
        return selected
    }

    private static func cuePriority(_ cue: ZoomCue) -> Int {
        if cue.isImplicit { return 0 }
        switch cue.anchorMode {
        case .pointerAnchor: return 1
        case .smartAnchor: return 2
        case .pinnedAnchor: return 3
        }
    }

    // MARK: Target resolution

    private static func anchorPoint(
        for cue: ZoomCue,
        at time: TimeInterval,
        samples: [PointerSample],
        activityTargets: [ActivityTarget]
    ) -> CGPoint {
        switch cue.anchorMode {
        case .pinnedAnchor:
            return normalized(cue.pinnedPoint)
        case .pointerAnchor:
            return trackedPointerPosition(at: time, samples: samples) ?? normalized(cue.pinnedPoint)
        case .smartAnchor:
            return activityTarget(at: time, targets: activityTargets) ?? normalized(cue.pinnedPoint)
        }
    }

    /// Groups a cue's surviving input into viewport-sized activity regions.
    /// Each region has one immutable bounding-box center, so tiny pointer
    /// movement cannot make the camera continually revise its destination.
    private static func activityTargets(
        for cue: ZoomCue,
        samples: [PointerSample],
        visible: VisibleFraction,
        prefersPressGroups: Bool = true
    ) -> [ActivityTarget] {
        var cueSamples = samples.filter { $0.time >= cue.start && $0.time <= cue.end }
        if cueSamples.isEmpty {
            if let preceding = samples.last(where: { $0.time < cue.start }) {
                cueSamples = [preceding]
            } else if let following = samples.first(where: { $0.time > cue.start }) {
                cueSamples = [following]
            }
        }
        guard let first = cueSamples.first else { return [] }

        let magnification = max(cue.zoom, 1)
        let horizontalLimit = 0.5 * visible.width / magnification
        let verticalLimit = 0.7 * visible.height / magnification
        var group = ActivityGroup(sample: first)
        var groups: [ActivityGroup] = []

        for sample in cueSamples.dropFirst() {
            if group.canInclude(
                sample,
                horizontalLimit: horizontalLimit,
                verticalLimit: verticalLimit
            ) {
                group.include(sample)
            } else {
                groups.append(group)
                group = ActivityGroup(sample: sample)
            }
        }
        groups.append(group)

        // When this cue contains clicks, movement-only groups are just transit
        // between interaction targets. Ignoring them prevents the camera from
        // following the travel path it was introduced to smooth out. A Smart
        // cue without clicks still uses its movement regions.
        let focusedGroups = prefersPressGroups && groups.contains { $0.firstPressTime != nil }
            ? groups.filter { $0.firstPressTime != nil }
            : groups
        return focusedGroups.map { group in
            // When a region contains a click, begin the handoff during the
            // same 300 ms lead-in used by automatic zoom generation. This is
            // precomputed, so seeking and export remain deterministic.
            let activationTime = group.firstPressTime.map {
                max(cue.start, $0 - 0.3)
            } ?? group.firstTime
            return ActivityTarget(
                activationTime: activationTime,
                point: group.center
            )
        }
    }

    private static func activityTarget(
        at time: TimeInterval,
        targets: [ActivityTarget]
    ) -> CGPoint? {
        guard let first = targets.first else { return nil }
        // A manually extended Smart cue can begin long before its first click.
        // Hold its captured fallback point until the planned handoff instead
        // of revealing a future target early.
        guard time >= first.activationTime else { return nil }

        var low = 0
        var high = targets.count
        while low < high {
            let middle = (low + high) / 2
            if targets[middle].activationTime <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return targets[max(0, low - 1)].point
    }

    private static func trackedPointerPosition(
        at time: TimeInterval,
        samples: [PointerSample]
    ) -> CGPoint? {
        guard let first = samples.first else { return nil }
        guard time >= first.time else { return first.point }

        var low = 0
        var high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].time <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return samples[max(0, low - 1)].point
    }

    /// Match the pointer timeline's half-open event-boundary contract so an
    /// outgoing clip-end click cannot become a Smart target in the next clip.
    private static func isRetainedSourceEvent(
        _ time: TimeInterval,
        in clipTimeline: RecordingClipTimeline
    ) -> Bool {
        clipTimeline.segments.contains {
            time >= $0.sourceStart && time < $0.sourceEnd
        }
    }

    private static func mergedPointerSamples(from capture: PointerCaptureFile) -> [PointerSample] {
        var merged: [(sample: PointerSample, sourceOrder: Int, originalIndex: Int)] = []
        merged.reserveCapacity(capture.travel.count + capture.presses.count)

        for (index, travel) in capture.travel.enumerated()
            where travel.time.isFinite
                && travel.x.isFinite
                && travel.y.isFinite
                && (0...1).contains(travel.x)
                && (0...1).contains(travel.y) {
            merged.append((
                PointerSample(
                    time: travel.time,
                    point: normalized(CGPoint(x: travel.x, y: travel.y)),
                    kind: .travel
                ),
                0,
                index
            ))
        }
        for (index, press) in capture.presses.enumerated()
            where press.time.isFinite
                && press.x.isFinite
                && press.y.isFinite
                && (0...1).contains(press.x)
                && (0...1).contains(press.y) {
            merged.append((
                PointerSample(
                    time: press.time,
                    point: normalized(CGPoint(x: press.x, y: press.y)),
                    kind: press.phase == .down ? .press : .release
                ),
                1,
                index
            ))
        }

        return merged.sorted { lhs, rhs in
            if lhs.sample.time != rhs.sample.time { return lhs.sample.time < rhs.sample.time }
            if lhs.sourceOrder != rhs.sourceOrder { return lhs.sourceOrder < rhs.sourceOrder }
            return lhs.originalIndex < rhs.originalIndex
        }.map(\.sample)
    }

    // MARK: Viewport constraints

    private static func boundedAnchor(
        _ point: CGPoint,
        magnification: Double,
        anchorMode: ZoomAnchorMode,
        boundsBias: Double,
        visible: VisibleFraction,
        bounds: CGRect
    ) -> CGPoint {
        let rawCenteredTarget = normalized(point)
        guard anchorMode != .pinnedAnchor else {
            return clampToFrame(rawCenteredTarget, magnification: magnification, visible: visible, bounds: bounds)
        }

        let halfExtent = visible.halfExtents(magnification: magnification)
        // This anchor keeps the subject at its original unzoomed screen
        // position: screen = 0.5 + magnification * (subject - viewportAnchor).
        let screenPositionPreservingTarget = CGPoint(
            x: bounds.minX + halfExtent.x
                + (rawCenteredTarget.x - bounds.minX) / bounds.width * (bounds.width - 2 * halfExtent.x),
            y: bounds.minY + halfExtent.y
                + (rawCenteredTarget.y - bounds.minY) / bounds.height * (bounds.height - 2 * halfExtent.y)
        )
        let bias = unit(boundsBias)
        let blended = CGPoint(
            x: rawCenteredTarget.x
                + (screenPositionPreservingTarget.x - rawCenteredTarget.x) * bias,
            y: rawCenteredTarget.y
                + (screenPositionPreservingTarget.y - rawCenteredTarget.y) * bias
        )
        return clampToFrame(blended, magnification: magnification, visible: visible, bounds: bounds)
    }

    /// Final safety invariant: the viewport never exposes space beyond source.
    private static func clampToFrame(
        _ point: CGPoint,
        magnification: Double,
        visible: VisibleFraction,
        bounds: CGRect
    ) -> CGPoint {
        let halfExtent = visible.halfExtents(magnification: magnification)
        return CGPoint(
            x: min(max(point.x, bounds.minX + halfExtent.x), bounds.maxX - halfExtent.x),
            y: min(max(point.y, bounds.minY + halfExtent.y), bounds.maxY - halfExtent.y)
        )
    }

    private static func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: unit(point.x), y: unit(point.y))
    }

    private static func unit<T: BinaryFloatingPoint>(_ value: T) -> T {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}

// MARK: - Helpers

nonisolated private struct PointerSample: Sendable {
    var time: TimeInterval
    var point: CGPoint
    var kind: PointerSampleKind
}

nonisolated private enum PointerSampleKind: Sendable {
    case travel
    case press
    case release
}

nonisolated private struct ActivityTarget: Sendable {
    var activationTime: TimeInterval
    var point: CGPoint
}

nonisolated private struct ActivityGroup: Sendable {
    var minX: Double
    var maxX: Double
    var minY: Double
    var maxY: Double
    var firstTime: TimeInterval
    var firstPressTime: TimeInterval?

    init(sample: PointerSample) {
        minX = sample.point.x
        maxX = sample.point.x
        minY = sample.point.y
        maxY = sample.point.y
        firstTime = sample.time
        if case .press = sample.kind {
            firstPressTime = sample.time
        } else {
            firstPressTime = nil
        }
    }

    var center: CGPoint {
        CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    func canInclude(
        _ sample: PointerSample,
        horizontalLimit: Double,
        verticalLimit: Double
    ) -> Bool {
        let candidateMinX = min(minX, sample.point.x)
        let candidateMaxX = max(maxX, sample.point.x)
        let candidateMinY = min(minY, sample.point.y)
        let candidateMaxY = max(maxY, sample.point.y)
        return candidateMaxX - candidateMinX <= horizontalLimit
            && candidateMaxY - candidateMinY <= verticalLimit
    }

    mutating func include(_ sample: PointerSample) {
        minX = min(minX, sample.point.x)
        maxX = max(maxX, sample.point.x)
        minY = min(minY, sample.point.y)
        maxY = max(maxY, sample.point.y)
        if firstPressTime == nil, case .press = sample.kind {
            firstPressTime = sample.time
        }
    }
}
