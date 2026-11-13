//
//  RecordingClipTimeline.swift
//  Screendrop
//
//  Non-destructive edit map for the recording Studio. The source movie is
//  never modified: each clip keeps a range on the original recording, while
//  the editor/export timeline is the concatenation of the surviving ranges.
//

import Foundation

nonisolated struct RecordingClipSegment: Identifiable, Codable, Equatable, Sendable {
    static let minimumDuration: TimeInterval = 0.12
    static let minimumSpeed: Double = 1
    static let maximumSpeed: Double = 8
    /// Rates offered wherever a clip's speed is picked - the inspector and
    /// the timeline's context menu - so both list the same choices.
    static let speedPresets: [Double] = [1, 1.5, 2, 3, 4, 8]

    var id: UUID
    var sourceStart: TimeInterval
    var sourceEnd: TimeInterval
    /// Playback speed multiplier applied only to this clip (1...8). Baked
    /// into the composition via `AVMutableComposition.scaleTimeRange`, so
    /// video and audio speed up together and stay in sync.
    var speed: Double
    /// Level of this clip's own sound (the recording's audio, or the
    /// soundtrack standing in for it), 0...2, on top of the project volume.
    var volume: Double = 1
    /// Silences this clip's own sound without touching its level.
    var isMuted = false

    static let volumeRange: ClosedRange<Double> = 0...2

    init(
        id: UUID = UUID(),
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        speed: Double = 1
    ) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.speed = speed
    }

    /// This clip over another source range, keeping its speed and sound.
    func covering(_ start: TimeInterval, _ end: TimeInterval, id: UUID? = nil) -> RecordingClipSegment {
        var copy = self
        copy.id = id ?? self.id
        copy.sourceStart = start
        copy.sourceEnd = end
        return copy
    }

    /// What its sound plays at before the project volume: 0 when muted.
    var audibleVolume: Double {
        isMuted ? 0 : min(max(volume, Self.volumeRange.lowerBound), Self.volumeRange.upperBound)
    }

    /// Raw duration of the source range this clip covers.
    var duration: TimeInterval {
        max(0, sourceEnd - sourceStart)
    }

    /// How long this clip occupies on the edited/output timeline once its
    /// speed is applied.
    var editorDuration: TimeInterval {
        duration / max(speed, Self.minimumSpeed)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceStart
        case sourceEnd
        case speed
        case volume
        case isMuted
        // Accepted for migration from the first experimental split schema.
        case start
        case end
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceStart = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceStart)
            ?? container.decode(TimeInterval.self, forKey: .start)
        sourceEnd = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceEnd)
            ?? container.decode(TimeInterval.self, forKey: .end)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceStart, forKey: .sourceStart)
        try container.encode(sourceEnd, forKey: .sourceEnd)
        try container.encode(speed, forKey: .speed)
        // Written only when changed, so projects that never touch a clip's
        // sound stay byte-identical on disk.
        if volume != 1 { try container.encode(volume, forKey: .volume) }
        if isMuted { try container.encode(isMuted, forKey: .isMuted) }
    }
}

nonisolated struct RecordingClipTimeline: Codable, Equatable, Sendable {
    struct Location: Equatable, Sendable {
        var segmentIndex: Int
        var segmentID: UUID
        var editorStart: TimeInterval
        var offset: TimeInterval
        var sourceTime: TimeInterval
    }

    struct Slice: Identifiable, Equatable, Sendable {
        struct ID: Hashable, Sendable {
            var segmentID: UUID
            var sourceStart: TimeInterval
            var sourceEnd: TimeInterval
        }

        var segmentID: UUID
        var sourceStart: TimeInterval
        var sourceEnd: TimeInterval
        var editorStart: TimeInterval
        var editorEnd: TimeInterval

        var id: ID {
            ID(
                segmentID: segmentID,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd
            )
        }
    }

    var segments: [RecordingClipSegment]

    init(segments: [RecordingClipSegment]) {
        self.segments = segments
    }

    static func full(sourceDuration: TimeInterval) -> RecordingClipTimeline {
        let safeDuration = max(0, sourceDuration.isFinite ? sourceDuration : 0)
        guard safeDuration > 0 else { return RecordingClipTimeline(segments: []) }
        return RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: safeDuration)
        ])
    }

    static func legacyTrim(
        start: TimeInterval?,
        end: TimeInterval?,
        sourceDuration: TimeInterval
    ) -> RecordingClipTimeline {
        let safeDuration = max(0, sourceDuration.isFinite ? sourceDuration : 0)
        let safeStart = min(max(start ?? 0, 0), safeDuration)
        let safeEnd = min(max(end ?? safeDuration, safeStart), safeDuration)
        guard safeEnd - safeStart >= RecordingClipSegment.minimumDuration else {
            return full(sourceDuration: safeDuration)
        }
        return RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: safeStart, sourceEnd: safeEnd)
        ])
    }

    /// Total length of the edited/output timeline, honoring per-clip speed.
    var duration: TimeInterval {
        segments.reduce(0) { $0 + $1.editorDuration }
    }

    func normalized(to sourceDuration: TimeInterval) -> RecordingClipTimeline {
        let safeDuration = max(0, sourceDuration.isFinite ? sourceDuration : 0)
        var seenIDs = Set<UUID>()
        var normalized = segments.compactMap { segment -> RecordingClipSegment? in
            let start = min(max(segment.sourceStart, 0), safeDuration)
            let end = min(max(segment.sourceEnd, start), safeDuration)
            guard end - start >= RecordingClipSegment.minimumDuration else { return nil }
            let id = seenIDs.insert(segment.id).inserted ? segment.id : UUID()
            let speed = min(
                max(segment.speed.isFinite ? segment.speed : 1, RecordingClipSegment.minimumSpeed),
                RecordingClipSegment.maximumSpeed
            )
            var clip = segment.covering(start, end, id: id)
            clip.speed = speed
            clip.volume = min(
                max(segment.volume.isFinite ? segment.volume : 1, RecordingClipSegment.volumeRange.lowerBound),
                RecordingClipSegment.volumeRange.upperBound
            )
            return clip
        }
        .sorted {
            if abs($0.sourceStart - $1.sourceStart) > 0.000_001 {
                return $0.sourceStart < $1.sourceStart
            }
            return $0.sourceEnd < $1.sourceEnd
        }

        // A corrupt/old project should never produce overlapping source
        // ranges. Keep the first range and trim later ranges forward.
        var previousEnd: TimeInterval = 0
        normalized = normalized.compactMap { segment in
            var segment = segment
            segment.sourceStart = max(segment.sourceStart, previousEnd)
            guard segment.duration >= RecordingClipSegment.minimumDuration else { return nil }
            previousEnd = segment.sourceEnd
            return segment
        }

        if normalized.isEmpty, safeDuration > 0 {
            return .full(sourceDuration: safeDuration)
        }
        return RecordingClipTimeline(segments: normalized)
    }

    func location(at editorTime: TimeInterval) -> Location? {
        guard !segments.isEmpty, duration > 0 else { return nil }
        let clamped = min(max(editorTime, 0), duration)
        var editorStart: TimeInterval = 0

        for (index, segment) in segments.enumerated() {
            let editorEnd = editorStart + segment.editorDuration
            if clamped < editorEnd || index == segments.index(before: segments.endIndex) {
                // `offset` is in editor-space; a sped-up segment covers more
                // source seconds per editor second, so the source offset
                // scales up by the clip's speed.
                let offset = min(max(clamped - editorStart, 0), segment.editorDuration)
                let sourceOffset = min(offset * segment.speed, segment.duration)
                return Location(
                    segmentIndex: index,
                    segmentID: segment.id,
                    editorStart: editorStart,
                    offset: offset,
                    sourceTime: segment.sourceStart + sourceOffset
                )
            }
            editorStart = editorEnd
        }
        return nil
    }

    func sourceTime(at editorTime: TimeInterval) -> TimeInterval {
        location(at: editorTime)?.sourceTime ?? 0
    }

    func editorTime(forSourceTime sourceTime: TimeInterval) -> TimeInterval? {
        var editorStart: TimeInterval = 0
        for segment in segments {
            if sourceTime >= segment.sourceStart - 0.000_001,
               sourceTime <= segment.sourceEnd + 0.000_001 {
                let sourceOffset = min(max(sourceTime - segment.sourceStart, 0), segment.duration)
                return editorStart + sourceOffset / segment.speed
            }
            editorStart += segment.editorDuration
        }
        return nil
    }

    func editorRange(for segmentID: UUID) -> Range<TimeInterval>? {
        var editorStart: TimeInterval = 0
        for segment in segments {
            let editorEnd = editorStart + segment.editorDuration
            if segment.id == segmentID {
                return editorStart..<editorEnd
            }
            editorStart = editorEnd
        }
        return nil
    }

    func split(at editorTime: TimeInterval) -> (timeline: RecordingClipTimeline, selectedID: UUID)? {
        guard let location = location(at: editorTime) else { return nil }
        let segment = segments[location.segmentIndex]
        let sourceTime = location.sourceTime
        guard sourceTime - segment.sourceStart >= RecordingClipSegment.minimumDuration,
              segment.sourceEnd - sourceTime >= RecordingClipSegment.minimumDuration else {
            return nil
        }

        let trailingID = UUID()
        let leading = segment.covering(segment.sourceStart, sourceTime)
        let trailing = segment.covering(sourceTime, segment.sourceEnd, id: trailingID)
        var next = segments
        next.replaceSubrange(location.segmentIndex...location.segmentIndex, with: [leading, trailing])
        return (RecordingClipTimeline(segments: next), trailingID)
    }

    func deleting(segmentID: UUID) -> RecordingClipTimeline? {
        guard segments.count > 1, segments.contains(where: { $0.id == segmentID }) else {
            return nil
        }
        let next = segments.filter { $0.id != segmentID }
        guard next.reduce(0, { $0 + $1.duration }) >= RecordingClipSegment.minimumDuration else {
            return nil
        }
        return RecordingClipTimeline(segments: next)
    }

    func replacing(_ replacement: RecordingClipSegment) -> RecordingClipTimeline {
        guard let index = segments.firstIndex(where: { $0.id == replacement.id }) else {
            return self
        }
        var next = segments
        next[index] = replacement
        return RecordingClipTimeline(segments: next)
    }

    /// Cuts source-time ranges out of the timeline, splitting segments where
    /// a range lands inside one. Ranges may overlap segments partially, span
    /// several, or fall entirely in already-cut gaps (a no-op). Returns nil
    /// when nothing playable would survive.
    func removingSourceRanges(_ ranges: [ClosedRange<TimeInterval>]) -> RecordingClipTimeline? {
        let cuts = Self.mergedRanges(ranges)
        guard !cuts.isEmpty else { return self }

        var next: [RecordingClipSegment] = []
        for segment in segments {
            // Subtract every cut from this segment, keeping the surviving
            // sub-ranges in order. The leading survivor keeps the segment's
            // identity so selection and undo stay anchored.
            var pieces: [(start: TimeInterval, end: TimeInterval)] = []
            var cursor = segment.sourceStart
            for cut in cuts where cut.upperBound > segment.sourceStart && cut.lowerBound < segment.sourceEnd {
                if cut.lowerBound > cursor {
                    pieces.append((cursor, min(cut.lowerBound, segment.sourceEnd)))
                }
                cursor = max(cursor, cut.upperBound)
            }
            if cursor < segment.sourceEnd {
                pieces.append((cursor, segment.sourceEnd))
            }

            var keptSegmentID = false
            for piece in pieces where piece.end - piece.start >= RecordingClipSegment.minimumDuration {
                next.append(segment.covering(piece.start, piece.end, id: keptSegmentID ? UUID() : segment.id))
                keptSegmentID = true
            }
        }

        guard !next.isEmpty else { return nil }
        return RecordingClipTimeline(segments: next)
    }

    /// Overlapping/touching ranges collapsed into disjoint sorted ranges;
    /// empty and non-finite ranges are dropped.
    static func mergedRanges(_ ranges: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
        let sorted = ranges
            .filter { $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<TimeInterval>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    func slices(overlapping sourceStart: TimeInterval, sourceEnd: TimeInterval) -> [Slice] {
        guard sourceEnd > sourceStart else { return [] }
        var result: [Slice] = []
        var editorOffset: TimeInterval = 0

        for segment in segments {
            let overlapStart = max(sourceStart, segment.sourceStart)
            let overlapEnd = min(sourceEnd, segment.sourceEnd)
            if overlapEnd > overlapStart {
                let editorStart = editorOffset + (overlapStart - segment.sourceStart) / segment.speed
                let editorEnd = editorOffset + (overlapEnd - segment.sourceStart) / segment.speed
                result.append(Slice(
                    segmentID: segment.id,
                    sourceStart: overlapStart,
                    sourceEnd: overlapEnd,
                    editorStart: editorStart,
                    editorEnd: editorEnd
                ))
            }
            editorOffset += segment.editorDuration
        }
        return result
    }

    func isUnedited(sourceDuration: TimeInterval) -> Bool {
        guard segments.count == 1, let only = segments.first else { return false }
        return abs(only.sourceStart) < 0.000_001
            && abs(only.sourceEnd - sourceDuration) < 0.000_001
            && abs(only.speed - 1) < 0.000_001
            && only.volume == 1 && !only.isMuted
    }

    /// Every cut on the edited timeline: where each clip starts, and the end.
    var editPoints: [TimeInterval] {
        var points: [TimeInterval] = []
        var cursor: TimeInterval = 0
        for segment in segments {
            points.append(cursor)
            cursor += segment.editorDuration
        }
        points.append(cursor)
        return points
    }

    /// The clip playing at an editor time.
    func segment(at editorTime: TimeInterval) -> RecordingClipSegment? {
        location(at: editorTime).map { segments[$0.segmentIndex] }
    }
}

nonisolated extension RecordingClipSegment {
    /// "1.5×", "2×": trailing zeros dropped.
    static func speedTitle(_ speed: Double) -> String {
        let rounded = (speed * 100).rounded() / 100
        let text = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%g", rounded)
        return "\(text)×"
    }
}
