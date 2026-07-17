//
//  RecordingTranscription.swift
//  Screendrop
//
//  Narration subtitles for the recording studio: SpeechAnalyzer (the
//  macOS 26 on-device transcription engine) turns the recorded microphone
//  track into timed subtitle cues on the source timeline. The timeline and
//  bar metrics are shared verbatim by the live preview and the offline
//  exporter, exactly like the keystroke caption.
//

import AVFoundation
import CoreGraphics
import Foundation
import Speech

/// One subtitle on the source (unedited) timeline, in seconds.
nonisolated struct RecordingSubtitleCue: Codable, Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

// MARK: - Subtitle timeline

/// Deterministic subtitle playback: the cue covering a source time, if any.
nonisolated struct SubtitleTimeline: Sendable, Equatable {
    private let cues: [RecordingSubtitleCue]

    static let empty = SubtitleTimeline(cues: [])

    init(cues: [RecordingSubtitleCue]) {
        self.cues = cues
            .filter { $0.start.isFinite && $0.end > $0.start && !$0.text.isEmpty }
            .sorted { $0.start < $1.start }
    }

    var isEmpty: Bool {
        cues.isEmpty
    }

    var count: Int {
        cues.count
    }

    func text(at time: TimeInterval) -> String? {
        guard !cues.isEmpty, time.isFinite else { return nil }

        // Last cue that has already started.
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = low - 1
        guard index >= 0 else { return nil }

        let cue = cues[index]
        return time < cue.end ? cue.text : nil
    }
}

// MARK: - Subtitle bar metrics

/// Geometry shared verbatim by the SwiftUI preview and the CoreGraphics
/// exporter: a rounded black bar with white text, pinned to the bottom
/// center of the recording card. Everything derives from the card's height
/// so the bar is identical at any render resolution.
nonisolated struct SubtitleBarMetrics: Sendable {
    let fontSize: CGFloat
    let paddingHorizontal: CGFloat
    let paddingVertical: CGFloat
    let cornerRadius: CGFloat
    let margin: CGFloat

    static let backgroundAlpha: Double = 0.78

    init(cardHeight: CGFloat) {
        fontSize = max(12, cardHeight * 0.034)
        paddingHorizontal = fontSize * 0.85
        paddingVertical = fontSize * 0.5
        cornerRadius = fontSize * 0.6
        margin = cardHeight * 0.045
    }
}

// MARK: - Transcription service

nonisolated enum RecordingTranscriptionService {
    enum TranscriptionError: LocalizedError {
        case noNarrationTrack
        case unsupportedLocale
        case narrationUnreadable
        case noSpeechDetected

        var errorDescription: String? {
            switch self {
            case .noNarrationTrack:
                "This recording has no microphone audio to transcribe."
            case .unsupportedLocale:
                "On-device transcription isn't available for your language yet."
            case .narrationUnreadable:
                "The narration audio could not be read."
            case .noSpeechDetected:
                "No speech was detected in the narration."
            }
        }
    }

    /// A subtitle should stay readable at a glance, so speech is chunked
    /// into short cues at natural pauses rather than whole sentences.
    private static let maximumCueCharacters = 42
    private static let maximumCueDuration: TimeInterval = 4
    private static let cueGapThreshold: TimeInterval = 0.9
    private static let minimumCueDuration: TimeInterval = 0.8

    static func transcribe(screenMovieURL: URL) async throws -> [RecordingSubtitleCue] {
        let narrationURL = try await extractNarrationAudio(from: screenMovieURL)
        defer { try? FileManager.default.removeItem(at: narrationURL) }

        let locale = try await resolveLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        let audioFile = try AVAudioFile(forReading: narrationURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Result collection must be consuming before audio is fed in, or the
        // analyzer's early results are dropped on the floor.
        async let collectedWords = collectWords(from: transcriber)
        if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let cues = makeCues(from: try await collectedWords)
        guard !cues.isEmpty else { throw TranscriptionError.noSpeechDetected }
        return cues
    }

    /// Best transcription locale for the user's language; on-device models
    /// are per-locale, so an unsupported language has to fail loudly rather
    /// than produce gibberish English cues.
    private static func resolveLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if let exact = supported.first(where: {
            $0.identifier(.bcp47) == current.identifier(.bcp47)
        }) {
            return exact
        }
        if let sameLanguage = supported.first(where: {
            $0.language.languageCode == current.language.languageCode
        }) {
            return sameLanguage
        }
        if let english = supported.first(where: { $0.language.languageCode?.identifier == "en" }) {
            return english
        }
        throw TranscriptionError.unsupportedLocale
    }

    /// Pulls the narration out of the screen movie into a standalone audio
    /// file. The recorder writes system audio as stereo and the microphone
    /// as mono, so the mono track is the narration whenever both exist.
    /// Track timing is preserved so cue timestamps stay on the movie's
    /// timeline.
    private static func extractNarrationAudio(from movieURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: movieURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard var narrationTrack = audioTracks.last else {
            throw TranscriptionError.noNarrationTrack
        }
        if audioTracks.count > 1 {
            for track in audioTracks {
                let descriptions = try await track.load(.formatDescriptions)
                let channels = descriptions
                    .compactMap { $0.audioStreamBasicDescription?.mChannelsPerFrame }
                    .max() ?? 0
                if channels == 1 {
                    narrationTrack = track
                    break
                }
            }
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TranscriptionError.narrationUnreadable
        }
        let timeRange = try await narrationTrack.load(.timeRange)
        try compositionTrack.insertTimeRange(timeRange, of: narrationTrack, at: timeRange.start)

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw TranscriptionError.narrationUnreadable
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("screendrop-narration-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try await exportSession.export(to: outputURL, as: .m4a)
        return outputURL
    }

    private struct TimedWord {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    private static func collectWords(from transcriber: SpeechTranscriber) async throws -> [TimedWord] {
        var words: [TimedWord] = []
        for try await result in transcriber.results where result.isFinal {
            for run in result.text.runs {
                let runText = String(result.text[run.range].characters)
                guard let timeRange = run.audioTimeRange else {
                    // Punctuation and whitespace runs carry no audio range;
                    // glue them onto the previous word so cues keep them.
                    if !words.isEmpty {
                        words[words.count - 1].text += runText
                    }
                    continue
                }
                let start = timeRange.start.seconds
                let end = timeRange.end.seconds
                guard start.isFinite, end.isFinite else { continue }
                words.append(TimedWord(text: runText, start: start, end: max(start, end)))
            }
        }
        return words
    }

    private static func makeCues(from words: [TimedWord]) -> [RecordingSubtitleCue] {
        var cues: [RecordingSubtitleCue] = []
        var text = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            guard !trimmed.isEmpty else { return }
            cues.append(RecordingSubtitleCue(
                start: start,
                end: max(end, start + minimumCueDuration),
                text: trimmed
            ))
        }

        for word in words {
            let wordLength = word.text.trimmingCharacters(in: .whitespaces).count
            if !text.isEmpty {
                let breaksOnLength = text.count + wordLength > maximumCueCharacters
                let breaksOnSilence = word.start - end > cueGapThreshold
                let breaksOnDuration = word.end - start > maximumCueDuration
                if breaksOnLength || breaksOnSilence || breaksOnDuration {
                    flush()
                }
            }
            if text.isEmpty {
                start = word.start
                end = word.end
            }
            // Runs keep the transcript's original spacing, so plain
            // concatenation reconstructs the text exactly.
            text += word.text
            end = max(end, word.end)
        }
        flush()
        return cues
    }
}
