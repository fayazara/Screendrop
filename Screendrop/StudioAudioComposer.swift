//
//  StudioAudioComposer.swift
//  Screendrop
//
//  Builds all the sound of a Studio project into a composition: each video
//  clip's own sound (the recording's audio, or the soundtrack standing in
//  for it, cut where the picture is cut) and every audio clip on its lane.
//  Playback, the video export and the audio-only export all go through
//  here, so they cannot disagree about what is heard.
//
//  The composition says *when* each sound plays; the mix says how loud.
//  They are built apart so a level or a fade changes without rebuilding
//  the player item.
//

import AVFoundation

/// The audio tracks a project's sound is read from, resolved ahead of time
/// so a composition can be built synchronously.
nonisolated struct StudioAudioSources: @unchecked Sendable {
    struct Track: @unchecked Sendable {
        let track: AVAssetTrack
        /// The part of its file that holds sound.
        let range: CMTimeRange
        /// Held because a track doesn't keep its asset alive, and a track
        /// whose asset is gone inserts nothing.
        let asset: AVAsset

        static func load(_ track: AVAssetTrack, of asset: AVAsset) async -> Track? {
            guard let range = try? await track.load(.timeRange), range.duration > .zero else { return nil }
            return Track(track: track, range: range, asset: asset)
        }

        static func loadAll(of asset: AVAsset) async -> [Track] {
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return [] }
            var result: [Track] = []
            for track in tracks {
                if let loaded = await load(track, of: asset) { result.append(loaded) }
            }
            return result
        }
    }

    /// The recording's own audio: system sound and microphone.
    var recording: [Track] = []
    /// The soundtrack standing in for it.
    var replacement: [Track] = []
    /// Imported audio, by its name in the media folder.
    var files: [String: [Track]] = [:]

    var replacementDuration: TimeInterval {
        replacement.map { $0.range.end.seconds }.max() ?? 0
    }

    func tracks(for clip: RecordingAudioClip) -> [Track] {
        switch clip.source {
        case .file: files[clip.fileName] ?? []
        case .recording: recording
        case .replacement: replacement
        }
    }

    /// Everything a project's export needs, read from disk.
    static func load(
        screenAsset: AVAsset,
        replacementURL: URL?,
        clips: [RecordingAudioClip],
        mediaDirectory: URL?
    ) async -> StudioAudioSources {
        var sources = StudioAudioSources()
        sources.recording = await Track.loadAll(of: screenAsset)
        if let replacementURL {
            sources.replacement = Array(await Track.loadAll(of: AVURLAsset(url: replacementURL)).prefix(1))
        }
        if let mediaDirectory {
            for name in Set(clips.filter { $0.source == .file }.map(\.fileName)) where !name.isEmpty {
                let asset = AVURLAsset(url: mediaDirectory.appendingPathComponent(name))
                let tracks = Array(await Track.loadAll(of: asset).prefix(1))
                if !tracks.isEmpty { sources.files[name] = tracks }
            }
        }
        return sources
    }
}

/// What should be heard: the cut, how an imported soundtrack lines up with
/// the recording, the audio clips, and the project's volume.
nonisolated struct StudioAudioPlan: Equatable, Sendable {
    var timeline: RecordingClipTimeline
    /// Nil plays the recording's own audio.
    var sync: RecordingAudioSync?
    var clips: [RecordingAudioClip] = []
    /// Applied to the video clips' own sound; audio clips carry their own.
    var volume: Double = 1

    /// The plan with everything that only changes loudness set aside. Two
    /// plans that agree here need the same composition.
    var placement: StudioAudioPlan {
        var plan = self
        plan.volume = 1
        plan.timeline.segments = plan.timeline.segments.map {
            var segment = $0
            segment.volume = 1
            segment.isMuted = false
            return segment
        }
        plan.clips = plan.clips.map {
            var clip = $0
            clip.volume = 1
            clip.isMuted = false
            clip.fadeIn = 0
            clip.fadeOut = 0
            clip.displayName = ""
            return clip
        }
        return plan
    }
}

/// Which composition track carries which sound, and when.
nonisolated struct StudioAudioLayout: Sendable {
    enum Owner: Equatable, Sendable {
        case segment(UUID)
        case clip(UUID)
    }

    struct Placement: Sendable {
        var trackID: CMPersistentTrackID
        var start: TimeInterval
        var end: TimeInterval
        var owner: Owner
    }

    var placements: [Placement] = []

    var isEmpty: Bool { placements.isEmpty }
}

nonisolated enum StudioAudioComposer {
    private static let timescale: CMTimeScale = 600

    private static func time(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: timescale)
    }

    /// Where each clip of a cut starts and how long it runs, on the same
    /// 600ths the video track is built from, so sound and picture share
    /// every cut exactly.
    static func editorRanges(for timeline: RecordingClipTimeline) -> [CMTimeRange] {
        var ranges: [CMTimeRange] = []
        var cursor = CMTime.zero
        for segment in timeline.segments {
            let duration = abs(segment.speed - 1) > 0.000_001
                ? time(segment.editorDuration)
                : time(segment.duration)
            ranges.append(CMTimeRange(start: cursor, duration: duration))
            cursor = cursor + duration
        }
        return ranges
    }

    // MARK: Composition

    /// A composition holding only the project's sound, for export.
    static func makeComposition(
        plan: StudioAudioPlan,
        sources: StudioAudioSources
    ) -> (composition: AVMutableComposition, layout: StudioAudioLayout) {
        let composition = AVMutableComposition()
        let layout = add(plan, sources: sources, to: composition)
        return (composition, layout)
    }

    /// Adds the project's sound to a composition that already holds its
    /// picture (or nothing).
    @discardableResult
    static func add(
        _ plan: StudioAudioPlan,
        sources: StudioAudioSources,
        to composition: AVMutableComposition
    ) -> StudioAudioLayout {
        var builder = Builder(composition: composition)
        let ranges = editorRanges(for: plan.timeline)
        let hasSoundtrack = plan.sync != nil && !sources.replacement.isEmpty

        for (segment, range) in zip(plan.timeline.segments, ranges) {
            let owner = StudioAudioLayout.Owner.segment(segment.id)
            let speed = max(segment.speed, RecordingClipSegment.minimumSpeed)
            let editorStart = range.start.seconds

            func insert(
                _ tracks: [StudioAudioSources.Track],
                group: String,
                sourceStart: TimeInterval,
                sourceEnd: TimeInterval,
                mediaStart: TimeInterval,
                mediaEnd: TimeInterval
            ) {
                let start = editorStart + (sourceStart - segment.sourceStart) / speed
                let end = min(range.end.seconds, editorStart + (sourceEnd - segment.sourceStart) / speed)
                builder.insert(
                    tracks, group: group,
                    mediaStart: mediaStart, mediaEnd: mediaEnd,
                    editorStart: start, editorEnd: end,
                    owner: owner
                )
            }

            guard hasSoundtrack, let sync = plan.sync else {
                insert(
                    sources.recording, group: "recording",
                    sourceStart: segment.sourceStart, sourceEnd: segment.sourceEnd,
                    mediaStart: segment.sourceStart, mediaEnd: segment.sourceEnd
                )
                continue
            }

            // The soundtrack wherever it covers this clip; the recording's
            // own audio fills anything it was never made for, such as video
            // brought back by opening up a trim.
            var cursor = segment.sourceStart
            let pieces = sync.pieces(
                from: segment.sourceStart,
                to: segment.sourceEnd,
                fileDuration: sources.replacementDuration
            )
            for piece in pieces {
                if piece.sourceStart - cursor > 0.01 {
                    insert(
                        sources.recording, group: "recording",
                        sourceStart: cursor, sourceEnd: piece.sourceStart,
                        mediaStart: cursor, mediaEnd: piece.sourceStart
                    )
                }
                insert(
                    sources.replacement, group: "soundtrack",
                    sourceStart: piece.sourceStart, sourceEnd: piece.sourceEnd,
                    mediaStart: piece.fileStart, mediaEnd: piece.fileEnd
                )
                cursor = piece.sourceEnd
            }
            if segment.sourceEnd - cursor > 0.01 {
                insert(
                    sources.recording, group: "recording",
                    sourceStart: cursor, sourceEnd: segment.sourceEnd,
                    mediaStart: cursor, mediaEnd: segment.sourceEnd
                )
            }
        }

        // Audio clips, a lane at a time, cut to the part inside the video.
        let videoDuration = ranges.last?.end.seconds ?? 0
        for clip in plan.clips.sorted(by: { ($0.lane, $0.start) < ($1.lane, $1.start) }) {
            let visibleStart = max(clip.start, 0)
            let visibleEnd = min(clip.end, videoDuration)
            guard visibleEnd - visibleStart >= 0.01 else { continue }
            let speed = max(clip.speed, 0.01)
            builder.insert(
                sources.tracks(for: clip),
                group: "lane\(clip.lane)",
                mediaStart: clip.trimStart + (visibleStart - clip.start) * speed,
                mediaEnd: clip.trimStart + (visibleEnd - clip.start) * speed,
                editorStart: visibleStart,
                editorEnd: visibleEnd,
                owner: .clip(clip.id)
            )
        }
        return builder.layout
    }

    /// Lays stretches of source tracks onto composition tracks. Sounds of
    /// one group share a composition track per source track, since they
    /// never overlap; AVFoundation mixes far fewer tracks more happily.
    private struct Builder {
        let composition: AVMutableComposition
        var layout = StudioAudioLayout()
        private var tracks: [String: AVMutableCompositionTrack] = [:]

        init(composition: AVMutableComposition) {
            self.composition = composition
        }

        mutating func insert(
            _ sources: [StudioAudioSources.Track],
            group: String,
            mediaStart: TimeInterval,
            mediaEnd: TimeInterval,
            editorStart: TimeInterval,
            editorEnd: TimeInterval,
            owner: StudioAudioLayout.Owner
        ) {
            guard mediaEnd - mediaStart > 0.005, editorEnd - editorStart > 0.005 else { return }
            let rate = (mediaEnd - mediaStart) / (editorEnd - editorStart)

            for (index, source) in sources.enumerated() {
                // Only the part of the file that holds sound can be placed;
                // what is cut from the head moves the start along.
                let wanted = CMTimeRange(start: time(mediaStart), end: time(mediaEnd))
                let available = CMTimeRangeGetIntersection(wanted, otherRange: source.range)
                guard available.duration.seconds > 0.005 else { continue }
                let headTrim = (available.start - wanted.start).seconds

                let key = "\(group)#\(index)"
                let track: AVMutableCompositionTrack
                if let existing = tracks[key] {
                    track = existing
                } else if let added = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) {
                    tracks[key] = added
                    track = added
                } else {
                    continue
                }

                // Never before what the track already holds: inserting
                // there would push later sound along.
                var at = time(editorStart + headTrim / rate)
                let trackEnd = track.timeRange.end
                if trackEnd.isValid, at < trackEnd { at = trackEnd }
                let target = time(available.duration.seconds / rate)
                do {
                    try track.insertTimeRange(available, of: source.track, at: at)
                    if abs(rate - 1) > 0.000_1, target > .zero {
                        track.scaleTimeRange(CMTimeRange(start: at, duration: available.duration), toDuration: target)
                    }
                } catch {
                    continue
                }
                let placedDuration = abs(rate - 1) > 0.000_1 ? target : available.duration
                layout.placements.append(StudioAudioLayout.Placement(
                    trackID: track.trackID,
                    start: at.seconds,
                    end: (at + placedDuration).seconds,
                    owner: owner
                ))
            }
        }
    }

    // MARK: Mix

    private struct Gain {
        var start: TimeInterval
        var end: TimeInterval
        var level: Double
        var fadeIn: TimeInterval = 0
        var fadeOut: TimeInterval = 0
    }

    /// How loud each placed sound plays: a video clip's own sound at its
    /// level times the project's, an audio clip at its level with its
    /// fades. Nil when everything plays as recorded.
    static func mix(for layout: StudioAudioLayout, plan: StudioAudioPlan) -> AVAudioMix? {
        let segments = Dictionary(plan.timeline.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let clips = Dictionary(plan.clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projectVolume = RecordingAudioGain.normalized(plan.volume)

        var gains: [CMPersistentTrackID: [Gain]] = [:]
        for placement in layout.placements {
            var gain = Gain(start: placement.start, end: placement.end, level: 1)
            switch placement.owner {
            case .segment(let id):
                gain.level = (segments[id]?.audibleVolume ?? 1) * projectVolume
            case .clip(let id):
                guard let clip = clips[id] else { continue }
                gain.level = clip.audibleVolume
                // Fades are squeezed into half the clip each, so they
                // never cross, and belong to the clip's own ends.
                let fadeIn = min(clip.fadeIn, clip.duration / 2)
                let fadeOut = min(clip.fadeOut, clip.duration / 2)
                gain.fadeIn = max(0, min(clip.start + fadeIn, placement.end) - placement.start)
                gain.fadeOut = max(0, placement.end - max(clip.end - fadeOut, placement.start))
                if clip.start + fadeIn <= placement.start { gain.fadeIn = 0 }
                if clip.end - fadeOut >= placement.end { gain.fadeOut = 0 }
            }
            gains[placement.trackID, default: []].append(gain)
        }

        var parameters: [AVMutableAudioMixInputParameters] = []
        for (trackID, trackGains) in gains {
            let changesNothing = trackGains.allSatisfy {
                abs($0.level - 1) < 0.000_1 && $0.fadeIn < 0.01 && $0.fadeOut < 0.01
            }
            if changesNothing { continue }

            let input = AVMutableAudioMixInputParameters()
            input.trackID = trackID
            // Levels are applied by a tap, exact to the sample: the mix's
            // own volume ramps smear a change over the sound around it,
            // and stop at 1.
            var spans: [RecordingAudioGain.EnvelopeSpan] = []
            for gain in trackGains.sorted(by: { $0.start < $1.start }) {
                let level = Float(gain.level)
                let fadeIn = gain.fadeIn >= 0.01 ? gain.fadeIn : 0
                let fadeOut = gain.fadeOut >= 0.01 ? gain.fadeOut : 0
                let holdStart = gain.start + fadeIn
                let holdEnd = max(holdStart, gain.end - fadeOut)
                if fadeIn > 0 {
                    spans.append(.init(start: gain.start, end: holdStart, startGain: 0, endGain: level))
                }
                if holdEnd > holdStart {
                    spans.append(.init(start: holdStart, end: holdEnd, startGain: level, endGain: level))
                }
                if fadeOut > 0 {
                    spans.append(.init(start: holdEnd, end: gain.end, startGain: level, endGain: 0))
                }
            }
            input.audioTapProcessor = RecordingAudioGain.makeEnvelopeTap(spans: spans)
            parameters.append(input)
        }
        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }
}
