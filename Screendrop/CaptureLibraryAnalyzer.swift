//
//  CaptureLibraryAnalyzer.swift
//  Screendrop
//

@preconcurrency import AVFoundation
import CoreGraphics
import FoundationModels
import ImageIO
import Vision

/// Looks at captures entirely on device, in two steps the index schedules
/// separately. `read` is quick (~0.15s): Vision reads the text and makes a
/// feature print for Similar, and the rules in `CaptureCategoryRules` give a
/// first category. `sort` is slow (~1–2s): Apple's language model files the
/// capture into a category with a short title and keywords.
nonisolated enum CaptureLibraryAnalyzer {
    struct Result: Sendable {
        var analysis: CaptureAnalysis
        /// An archived `VNFeaturePrintObservation`.
        var featurePrint: Data?
    }

    /// Screenshots are read at up to this many pixels on the long side.
    /// Retina UI text stays legible well below full 5K, and Vision's time
    /// grows with the pixel count.
    private static let readingSize = 3200
    private static let promptTextLimit = 1800
    private static let promptTranscriptLimit = 600

    /// `previous` is the capture's last analysis, if any: a model's sorting
    /// carries over when an edit changes the pixels, rather than falling back
    /// to the rules until it's sorted again.
    static func read(_ item: CaptureLibraryItem, previous: CaptureAnalysis?) async -> Result? {
        let frames = await readFrames(item)
        guard let primary = frames.first else { return nil }
        guard !Task.isCancelled else { return nil }

        var lines = (try? recognizeText(in: primary)) ?? []
        // Later frames add searchable text; only the first frame matches the
        // thumbnail, so their lines carry no boxes.
        var seen = Set(lines.map(\.text))
        for frame in frames.dropFirst() {
            guard !Task.isCancelled else { return nil }
            for line in (try? recognizeText(in: frame)) ?? [] where seen.insert(line.text).inserted {
                lines.append(CaptureTextLine(text: line.text, box: nil))
            }
        }
        guard !Task.isCancelled else { return nil }

        let featurePrint = try? makeFeaturePrint(of: primary)
        var analysis = CaptureAnalysis(id: item.id, fingerprint: item.thumbnailKey)
        analysis.lines = CaptureTextLines(lines)
        analysis.transcript = item.session.flatMap(transcript)
        analysis.hasFeaturePrint = featurePrint != nil
        if let previous, previous.classifier == .model {
            analysis.category = previous.category
            analysis.title = previous.title
            analysis.keywords = previous.keywords
            analysis.classifier = .model
        } else {
            analysis.category = CaptureCategoryRules.category(source: item.source, text: analysis.text, isVideo: item.isVideo)
            analysis.classifier = .rules
        }
        return Result(analysis: analysis, featurePrint: featurePrint)
    }

    /// Asks the model to sort a capture that has already been read. Text and
    /// the feature print are kept.
    static func sort(_ analysis: CaptureAnalysis, item: CaptureLibraryItem) async -> CaptureAnalysis {
        var analysis = analysis
        let image = await readFrames(item, framesForVideo: 1).first
        await classify(&analysis, item: item, image: image)
        return analysis
    }

    static var isModelAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    // MARK: Frames

    private static func readFrames(_ item: CaptureLibraryItem, framesForVideo: Int = 3) async -> [CGImage] {
        if item.isVideo {
            let asset = AVURLAsset(url: item.fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1920, height: 1920)
            let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let duration = item.duration ?? 0
            // The first frame is what the thumbnail shows; the rest sample
            // the middle and the end for more text.
            let fractions = [0, 0.5, 0.9].prefix(duration > 2 ? framesForVideo : 1)
            var frames: [CGImage] = []
            for fraction in fractions {
                guard !Task.isCancelled else { break }
                let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
                if let image = try? await generator.image(at: time).image { frames.append(image) }
            }
            return frames
        }
        guard let source = CGImageSourceCreateWithURL(item.fileURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: readingSize
              ] as CFDictionary) else { return [] }
        return [image]
    }

    // MARK: Vision

    private static func recognizeText(in image: CGImage) throws -> [CaptureTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return ImageTextRecognizer.readingOrder(request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return CaptureTextLine(text: text, box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        }
    }

    private static func makeFeaturePrint(of image: CGImage) throws -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first else { return nil }
        return try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    /// The spoken words of a recording, from its saved or draft captions.
    private static func transcript(_ session: RecordingSession) -> String? {
        struct Captions: Decodable {
            struct Cue: Decodable { var text: String }
            var subtitleCues: [Cue]?
        }
        for url in [session.draftDocumentURL, session.editDocumentURL] {
            guard let data = try? Data(contentsOf: url),
                  let cues = (try? JSONDecoder().decode(Captions.self, from: data))?.subtitleCues,
                  !cues.isEmpty else { continue }
            return cues.map(\.text).joined(separator: " ")
        }
        return nil
    }

    // MARK: Classification

    @Generable
    struct Insight {
        @Guide(description: "The one category that best describes what the capture shows.")
        var category: Category
        @Guide(description: "A specific title of two to six words for what the capture shows, such as 'Stripe payout settings' or 'Swift build error in Xcode'. Plain words, no quotes or trailing period.")
        var title: String
        @Guide(description: "Lowercase search keywords for topics, products, people or document types the capture is about.", .maximumCount(5))
        var keywords: [String]
    }

    @Generable
    enum Category {
        case code, design, website, document, chat, email, data, error, receipt, social, media, settings, other
    }

    private static let instructions = """
        You file screenshots and screen recordings in a person's capture library so they can find them later. \
        You are given the app a capture came from, its window title and the text recognized in it. \
        Describe only what the details support; never invent names, numbers or products.
        """

    private static func classify(_ analysis: inout CaptureAnalysis, item: CaptureLibraryItem, image: CGImage?) async {
        let text = analysis.text
        let rules = CaptureCategoryRules.category(source: item.source, text: text, isVideo: item.isVideo)
        guard isModelAvailable, !Task.isCancelled else {
            analysis.category = rules
            analysis.classifier = .rules
            return
        }
        let prompt = promptText(analysis: analysis, item: item)
        let seenImage = visionCapable ? image : nil
        var insight = await respond(prompt: prompt, image: seenImage)
        // An image can overflow the context window; the text alone still works.
        if insight == nil, seenImage != nil { insight = await respond(prompt: prompt, image: nil) }
        if let insight {
            analysis.category = CaptureCategory(rawValue: String(describing: insight.category)) ?? rules
            let title = insight.title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            analysis.title = title.isEmpty ? nil : title
            analysis.keywords = Array(Set(insight.keywords.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })).sorted()
            analysis.classifier = .model
        } else {
            // Guardrails or an unsupported language: file it by the rules,
            // and don't ask again for this version of the pipeline.
            analysis.category = rules
            analysis.classifier = .rules
            analysis.modelDeclined = true
        }
    }

    private static func promptText(analysis: CaptureAnalysis, item: CaptureLibraryItem) -> String {
        var parts = ["Capture: \(item.isVideo ? "screen recording" : "screenshot")"]
        if let source = item.source {
            parts.append("App: \(source.appName)")
            if let window = source.windowTitle { parts.append("Window title: \(window)") }
        }
        let text = analysis.text
        parts.append(text.isEmpty
            ? "Text in the capture: none"
            : "Text in the capture, possibly partial:\n\(text.prefix(promptTextLimit))")
        if let transcript = analysis.transcript {
            parts.append("Narration: \(transcript.prefix(promptTranscriptLimit))")
        }
        parts.append("Categories:\n" + CaptureCategory.allCases.map { "- \($0.rawValue): \($0.guidance)" }.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    /// One fresh session per capture, so one capture never colors the next.
    private static func respond(prompt: String, image: CGImage?) async -> Insight? {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.2)
        do {
            if #available(macOS 27.0, *), let image {
                return try await session.respond(generating: Insight.self, options: options) {
                    prompt
                    Attachment(image).label("The capture")
                }.content
            }
            return try await session.respond(to: prompt, generating: Insight.self, options: options).content
        } catch {
            return nil
        }
    }

    /// Whether the system model accepts images (macOS 27 and later).
    private static var visionCapable: Bool {
        if #available(macOS 27.0, *) {
            return SystemLanguageModel.default.capabilities.contains(.vision)
        }
        return false
    }
}
