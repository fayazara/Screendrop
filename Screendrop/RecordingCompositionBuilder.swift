//
//  RecordingCompositionBuilder.swift
//  Screendrop
//
//  Shared gap-closing composition used by Studio playback and export.
//

import AVFoundation

nonisolated enum RecordingCompositionBuilder {
    static func makeAsset(
        from sourceAsset: AVAsset,
        timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval
    ) throws -> AVAsset {
        let normalized = timeline.normalized(to: sourceDuration)
        if normalized.isUnedited(sourceDuration: sourceDuration) {
            return sourceAsset
        }

        let composition = AVMutableComposition()
        var insertionTime = CMTime.zero
        for clip in normalized.segments {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
            )
            try composition.insertTimeRange(range, of: sourceAsset, at: insertionTime)

            // Retiming here scales every track inserted above together
            // (video and audio alike), so a sped-up clip never drifts out
            // of sync the way independently retiming each track would.
            if abs(clip.speed - 1) > 0.000_001 {
                let insertedRange = CMTimeRange(start: insertionTime, duration: range.duration)
                let scaledDuration = CMTime(seconds: clip.editorDuration, preferredTimescale: 600)
                composition.scaleTimeRange(insertedRange, toDuration: scaledDuration)
                insertionTime = insertionTime + scaledDuration
            } else {
                insertionTime = insertionTime + range.duration
            }
        }
        return composition
    }

    /// The cut's picture alone, from a video track resolved ahead of time
    /// so Studio can rebuild its player item synchronously on every edit.
    /// `StudioAudioComposer` adds the sound.
    static func makeVideoComposition(
        videoTrack: AVAssetTrack,
        timeline: RecordingClipTimeline
    ) throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecordingStudioExporter.ExportError.noVideoTrack
        }

        // The same ranges the sound is laid on, so both share every cut.
        let ranges = StudioAudioComposer.editorRanges(for: timeline)
        for (clip, editorRange) in zip(timeline.segments, ranges) {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
            )
            try video.insertTimeRange(range, of: videoTrack, at: editorRange.start)
            if abs(clip.speed - 1) > 0.000_001 {
                video.scaleTimeRange(
                    CMTimeRange(start: editorRange.start, duration: range.duration),
                    toDuration: editorRange.duration
                )
            }
        }
        return composition
    }
}
