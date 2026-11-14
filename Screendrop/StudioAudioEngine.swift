//
//  StudioAudioEngine.swift
//  Screendrop
//
//  The rules that keep sound and picture together in Studio. Pure values:
//  no players, no files.
//
//  The video is a list of clips, each a range of the recording. Sound comes
//  in two kinds:
//
//  - A clip's own sound: the recording's audio, or a soundtrack imported to
//    stand in for it. Either way it is tied to the recording's clock, so it
//    is cut exactly where the picture is. `RecordingAudioSync` is what ties
//    an imported soundtrack to that clock.
//  - Audio clips on lanes under the video. `StudioAudioConform` carries
//    them through every change to the video's clips.
//

import Foundation

// MARK: - Soundtrack sync

/// Where an imported soundtrack lines up with the recording. A soundtrack
/// comes back from a cleanup tool matching the cut it was exported from, so
/// the cut at that moment is recorded here: each span says which stretch of
/// the file is the sound of which stretch of the recording. From then on
/// the soundtrack follows the picture through any later edit.
nonisolated struct RecordingAudioSync: Codable, Equatable, Sendable {
    struct Span: Codable, Equatable, Sendable {
        var sourceStart: TimeInterval
        var sourceEnd: TimeInterval
        /// The file time that plays at `sourceStart`.
        var fileStart: TimeInterval
        /// Recording seconds per file second: the clip's speed when the
        /// soundtrack was made.
        var rate: Double

        var fileEnd: TimeInterval { fileStart + (sourceEnd - sourceStart) / max(rate, 0.01) }
    }

    /// A stretch of the file standing in for a stretch of the recording.
    struct Piece: Equatable, Sendable {
        var sourceStart: TimeInterval
        var sourceEnd: TimeInterval
        var fileStart: TimeInterval
        var fileEnd: TimeInterval
    }

    /// Kept in recording order, which `pieces` relies on.
    var spans: [Span] {
        didSet { spans.sort { $0.sourceStart < $1.sourceStart } }
    }
    /// Shifts the soundtrack against the picture, in seconds: positive
    /// plays it later. For files that come back from a cleanup tool with a
    /// little latency added.
    var offset: TimeInterval = 0
    /// How far the soundtrack can be slid either way.
    static let offsetLimit: TimeInterval = 1

    init(spans: [Span], offset: TimeInterval = 0) {
        self.spans = spans.sorted { $0.sourceStart < $1.sourceStart }
        self.offset = offset
    }

    private enum CodingKeys: String, CodingKey {
        case spans
        case offset
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spans = try container.decode([Span].self, forKey: .spans).sorted { $0.sourceStart < $1.sourceStart }
        offset = try container.decodeIfPresent(TimeInterval.self, forKey: .offset) ?? 0
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(spans, forKey: .spans)
        if offset != 0 { try container.encode(offset, forKey: .offset) }
    }

    /// The soundtrack laid flat over a cut from its first frame, which is
    /// what an export of that cut's audio lines up with.
    static func flat(over timeline: RecordingClipTimeline) -> RecordingAudioSync {
        var spans: [Span] = []
        var editorStart: TimeInterval = 0
        for segment in timeline.segments {
            spans.append(Span(
                sourceStart: segment.sourceStart,
                sourceEnd: segment.sourceEnd,
                fileStart: editorStart,
                rate: max(segment.speed, RecordingClipSegment.minimumSpeed)
            ))
            editorStart += segment.editorDuration
        }
        return RecordingAudioSync(spans: spans)
    }

    /// How long a file has to be to cover every span.
    var coveredFileDuration: TimeInterval {
        spans.map(\.fileEnd).max() ?? 0
    }

    /// The file stretches that cover a range of the recording, in order,
    /// kept inside a file `fileDuration` long. Anything they leave
    /// uncovered has no soundtrack.
    func pieces(
        from sourceStart: TimeInterval,
        to sourceEnd: TimeInterval,
        fileDuration: TimeInterval
    ) -> [Piece] {
        guard sourceEnd > sourceStart else { return [] }
        var pieces: [Piece] = []
        for span in spans {
            let rate = max(span.rate, 0.01)
            // An offset moves the file under the recording: the file time
            // that plays at a moment is `offset` earlier.
            let fileStart = span.fileStart - offset
            var low = max(sourceStart, span.sourceStart, pieces.last?.sourceEnd ?? sourceStart)
            var high = min(sourceEnd, span.sourceEnd)
            // Only where the file has sound: an offset can push its start
            // past the span's, and the file may be shorter than the cut it
            // was made for.
            let firstCovered = span.sourceStart + max(0, -fileStart) * rate
            let lastCovered = span.sourceStart + max(0, fileDuration - fileStart) * rate
            low = max(low, firstCovered)
            high = min(high, lastCovered)
            guard high - low > 0.001 else { continue }
            pieces.append(Piece(
                sourceStart: low,
                sourceEnd: high,
                fileStart: fileStart + (low - span.sourceStart) / rate,
                fileEnd: fileStart + (high - span.sourceStart) / rate
            ))
        }
        return pieces
    }
}

// MARK: - Carrying audio through an edit

nonisolated enum StudioAudioConform {
    private static let epsilon: TimeInterval = 0.000_5

    /// The audio clips as they should be after the video's clips change
    /// from `old` to `new`.
    ///
    /// A linked clip is treated as part of the picture above it: each
    /// moment of it goes wherever that moment of the recording went, so
    /// video that was removed takes its sound with it and a clip that
    /// changed speed retimes the sound under it. An unlinked clip stays in
    /// one piece and keeps its starting moment.
    static func conform(
        _ clips: [RecordingAudioClip],
        from old: RecordingClipTimeline,
        to new: RecordingClipTimeline
    ) -> [RecordingAudioClip] {
        guard old != new else { return clips }
        var result: [RecordingAudioClip] = []
        for clip in clips {
            if clip.isLinked {
                result.append(contentsOf: conformLinked(clip, from: old, to: new))
            } else {
                var moved = clip
                moved.start = max(0, mapPoint(clip.start, from: old, to: new))
                result.append(moved)
            }
        }
        return resolvingLanes(healingExtensions(result, from: old, to: new))
    }

    /// Opening a clip's trim back up brings back the linked sound under
    /// it, as it brings back the clip's own sound. A linked piece whose
    /// edge sat on the clip's edge grows with it, as far as its file and
    /// its neighbours on the lane allow. Sound that was trimmed on its own
    /// ends somewhere else, so it is left alone.
    private static func healingExtensions(
        _ clips: [RecordingAudioClip],
        from old: RecordingClipTimeline,
        to new: RecordingClipTimeline
    ) -> [RecordingAudioClip] {
        let oldSegments = Dictionary(old.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = clips
        var editorStart: TimeInterval = 0
        for segment in new.segments {
            defer { editorStart += segment.editorDuration }
            guard let before = oldSegments[segment.id] else { continue }
            let speed = max(segment.speed, RecordingClipSegment.minimumSpeed)
            let grewAtEnd = segment.sourceEnd - before.sourceEnd
            let grewAtStart = before.sourceStart - segment.sourceStart
            guard grewAtEnd > 0.001 || grewAtStart > 0.001 else { continue }

            // Where the clip's old edges now sit in the new cut.
            let oldEndHere = editorStart + (before.sourceEnd - segment.sourceStart) / speed
            let oldStartHere = editorStart + (before.sourceStart - segment.sourceStart) / speed

            for index in result.indices where result[index].isLinked {
                var clip = result[index]
                let neighbours = result.enumerated()
                    .filter { $0.offset != index && $0.element.lane == clip.lane }
                    .map(\.element)
                if grewAtEnd > 0.001, abs(clip.end - oldEndHere) < 0.002, clip.trimEnd < clip.fileDuration - 0.001 {
                    let room = neighbours.map(\.start).filter { $0 >= clip.end - 0.002 }.min() ?? .infinity
                    let wanted = grewAtEnd / speed
                    let grow = min(wanted, room - clip.end, (clip.fileDuration - clip.trimEnd) / max(clip.speed, 0.01))
                    if grow > 0.001 {
                        clip.trimEnd += grow * clip.speed
                    }
                }
                if grewAtStart > 0.001, abs(clip.start - oldStartHere) < 0.002, clip.trimStart > 0.001 {
                    let room = neighbours.map(\.end).filter { $0 <= clip.start + 0.002 }.max() ?? -.infinity
                    let wanted = grewAtStart / speed
                    let grow = min(wanted, clip.start - max(room, editorStart), clip.trimStart / max(clip.speed, 0.01))
                    if grow > 0.001 {
                        clip.start -= grow
                        clip.trimStart -= grow * clip.speed
                    }
                }
                result[index] = clip
            }
        }
        return result
    }

    /// Where a moment of the old cut is in the new one. A moment whose
    /// video was removed lands on the cut that replaced it.
    static func mapPoint(
        _ time: TimeInterval,
        from old: RecordingClipTimeline,
        to new: RecordingClipTimeline
    ) -> TimeInterval {
        let oldDuration = old.duration
        guard time < oldDuration - epsilon, let location = old.location(at: time) else {
            return new.duration + max(0, time - oldDuration)
        }
        let source = location.sourceTime
        if let mapped = editorTime(forSourceTime: source, preferring: location.segmentID, in: new) {
            return mapped
        }
        // Removed: the next video that survives starts where it was.
        var editorStart: TimeInterval = 0
        var best: (source: TimeInterval, editor: TimeInterval)?
        for segment in new.segments {
            if segment.sourceStart >= source - epsilon, best == nil || segment.sourceStart < best!.source {
                best = (segment.sourceStart, editorStart)
            }
            editorStart += segment.editorDuration
        }
        return best?.editor ?? new.duration
    }

    private static func editorTime(
        forSourceTime source: TimeInterval,
        preferring id: UUID,
        in timeline: RecordingClipTimeline
    ) -> TimeInterval? {
        var editorStart: TimeInterval = 0
        var fallback: TimeInterval?
        for segment in timeline.segments {
            if source >= segment.sourceStart - epsilon, source <= segment.sourceEnd + epsilon {
                let offset = min(max(source - segment.sourceStart, 0), segment.duration) / segment.speed
                if segment.id == id { return editorStart + offset }
                if fallback == nil { fallback = editorStart + offset }
            }
            editorStart += segment.editorDuration
        }
        return fallback
    }

    private static func conformLinked(
        _ clip: RecordingAudioClip,
        from old: RecordingClipTimeline,
        to new: RecordingClipTimeline
    ) -> [RecordingAudioClip] {
        let clipSpeed = max(clip.speed, 0.01)
        var pieces: [RecordingAudioClip] = []

        func append(start: TimeInterval, fileStart: TimeInterval, fileEnd: TimeInterval, speed: Double) {
            guard fileEnd - fileStart > epsilon, speed > 0 else { return }
            var piece = clip
            piece.start = start
            piece.trimStart = fileStart
            piece.trimEnd = fileEnd
            piece.speed = speed
            // Joins what a cut didn't actually separate, so a split of the
            // video alone leaves the sound in one piece.
            if var last = pieces.last,
               abs(last.end - piece.start) < 0.002,
               abs(last.trimEnd - piece.trimStart) < 0.002,
               abs(last.speed - piece.speed) < 0.000_1 {
                last.trimEnd = piece.trimEnd
                pieces[pieces.count - 1] = last
            } else {
                pieces.append(piece)
            }
        }

        // Under the video: each stretch follows the recording it sat over.
        var oldEditorStart: TimeInterval = 0
        for segment in old.segments {
            let oldEditorEnd = oldEditorStart + segment.editorDuration
            defer { oldEditorStart = oldEditorEnd }
            let low = max(clip.start, oldEditorStart)
            let high = min(clip.end, oldEditorEnd)
            guard high - low > epsilon else { continue }
            let sourceLow = segment.sourceStart + (low - oldEditorStart) * segment.speed
            let sourceHigh = segment.sourceStart + (high - oldEditorStart) * segment.speed
            let fileLow = clip.trimStart + (low - clip.start) * clipSpeed
            // File seconds per recording second, which no retiming changes.
            let filePerSource = clipSpeed / segment.speed

            for slice in slices(of: new, overlapping: sourceLow, sourceHigh, preferring: segment.id) {
                let fileStart = fileLow + (slice.sourceStart - sourceLow) * filePerSource
                let fileEnd = fileLow + (slice.sourceEnd - sourceLow) * filePerSource
                append(
                    start: slice.editorStart,
                    fileStart: fileStart,
                    fileEnd: min(fileEnd, clip.trimEnd),
                    speed: filePerSource * slice.speed
                )
            }
        }

        // Past the end of the video: carried along behind it.
        let oldDuration = old.duration
        if clip.end > oldDuration + epsilon {
            let low = max(clip.start, oldDuration)
            append(
                start: new.duration + (low - oldDuration),
                fileStart: clip.trimStart + (low - clip.start) * clipSpeed,
                fileEnd: clip.trimEnd,
                speed: clipSpeed
            )
        }

        pieces = pieces.filter { $0.duration >= RecordingAudioClip.minimumDuration / 2 }
        for index in pieces.indices {
            if index > 0 { pieces[index].id = UUID() }
            // A fade belongs to the clip's own end, not to a cut inside it.
            if abs(pieces[index].trimStart - clip.trimStart) > 0.002 { pieces[index].fadeIn = 0 }
            if abs(pieces[index].trimEnd - clip.trimEnd) > 0.002 { pieces[index].fadeOut = 0 }
        }
        return pieces
    }

    private struct Slice {
        var sourceStart: TimeInterval
        var sourceEnd: TimeInterval
        var editorStart: TimeInterval
        var speed: Double
    }

    /// Where a range of the recording plays in a cut, in playing order.
    private static func slices(
        of timeline: RecordingClipTimeline,
        overlapping sourceStart: TimeInterval,
        _ sourceEnd: TimeInterval,
        preferring id: UUID
    ) -> [Slice] {
        var result: [Slice] = []
        var editorStart: TimeInterval = 0
        for segment in timeline.segments {
            let low = max(sourceStart, segment.sourceStart)
            let high = min(sourceEnd, segment.sourceEnd)
            if high - low > epsilon {
                result.append(Slice(
                    sourceStart: low,
                    sourceEnd: high,
                    editorStart: editorStart + (low - segment.sourceStart) / segment.speed,
                    speed: segment.speed
                ))
            }
            editorStart += segment.editorDuration
        }
        return result
    }

    // MARK: Lanes

    /// The most audio lanes the timeline shows. Past this, overlapping
    /// clips share the last lane (they still all play).
    static let maximumLanes = 8

    /// Clips on one lane never overlap: a clip that lands on another moves
    /// down to the first lane with room. Earlier clips keep their lane.
    /// `first` is placed before the others, so it gets the lane it asks
    /// for; `last` after them, so it is the one that gives way.
    static func resolvingLanes(
        _ clips: [RecordingAudioClip],
        first: UUID? = nil,
        last: UUID? = nil
    ) -> [RecordingAudioClip] {
        var occupied: [Int: [ClosedRange<TimeInterval>]] = [:]
        var result = clips
        func rank(_ clip: RecordingAudioClip) -> Int {
            clip.id == first ? 0 : clip.id == last ? 2 : 1
        }
        let order = clips.indices.sorted {
            let (a, b) = (clips[$0], clips[$1])
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.lane != b.lane { return a.lane < b.lane }
            return a.start < b.start
        }
        for index in order {
            let clip = clips[index]
            guard clip.end - clip.start > epsilon else { continue }
            var lane = min(max(0, clip.lane), maximumLanes - 1)
            while lane < maximumLanes - 1, (occupied[lane] ?? []).contains(where: {
                $0.lowerBound < clip.end - 0.001 && $0.upperBound > clip.start + 0.001
            }) {
                lane += 1
            }
            occupied[lane, default: []].append(clip.start...clip.end)
            result[index].lane = lane
        }
        return compactingLanes(result)
    }

    /// Closes up lanes nothing sits on, so there is never an empty lane
    /// between two used ones.
    private static func compactingLanes(_ clips: [RecordingAudioClip]) -> [RecordingAudioClip] {
        let used = Set(clips.map(\.lane)).sorted()
        guard used != Array(0..<used.count) else { return clips }
        let remap = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, $0) })
        return clips.map { clip in
            var clip = clip
            clip.lane = remap[clip.lane] ?? clip.lane
            return clip
        }
    }

    // MARK: Splitting

    /// Cuts a clip in two at a moment of the video. Nil when the moment is
    /// outside it or too close to an end.
    static func split(
        _ clip: RecordingAudioClip,
        at time: TimeInterval
    ) -> (leading: RecordingAudioClip, trailing: RecordingAudioClip)? {
        let minimum = RecordingAudioClip.minimumDuration
        guard time - clip.start >= minimum, clip.end - time >= minimum else { return nil }
        let fileTime = clip.trimStart + (time - clip.start) * max(clip.speed, 0.01)
        var leading = clip
        leading.trimEnd = fileTime
        leading.fadeOut = 0
        var trailing = clip
        trailing.id = UUID()
        trailing.start = time
        trailing.trimStart = fileTime
        trailing.fadeIn = 0
        return (leading, trailing)
    }

    // MARK: Snapping

    /// The moments worth snapping an audio edit to: the playhead, every
    /// cut of the video, and the ends of the other audio clips.
    static func snapPoints(
        timeline: RecordingClipTimeline,
        clips: [RecordingAudioClip],
        excluding id: UUID?,
        playhead: TimeInterval
    ) -> [TimeInterval] {
        var points = timeline.editPoints
        points.append(playhead)
        for clip in clips where clip.id != id {
            points.append(clip.start)
            points.append(clip.end)
        }
        return points
    }

    /// `time`, or the nearest snap point within `tolerance` of it.
    static func snapped(_ time: TimeInterval, to points: [TimeInterval], tolerance: TimeInterval) -> TimeInterval {
        var best = time
        var distance = tolerance
        for point in points where abs(point - time) <= distance {
            best = point
            distance = abs(point - time)
        }
        return best
    }
}
