//
//  ImageTextRecognizer.swift
//  Screendrop
//

import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Extracts text from a captured image using the Vision framework so users can
/// "Copy text from image" (OCR).
enum ImageTextRecognizer {
    /// Recognises text in the image at `url`, returning the recognised lines
    /// joined by newlines in reading order. Returns an empty string when
    /// nothing is found.
    static func recognizeText(at url: URL) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    continuation.resume(returning: "")
                    return
                }

                let request = VNRecognizeTextRequest()
                // Vision is the on-device engine CleanShot X and the system's
                // Live Text use. These are its highest-accuracy settings.
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.revision = VNRecognizeTextRequestRevision3
                request.automaticallyDetectsLanguage = true
                request.recognitionLanguages = Self.recognitionLanguages

                let handler = VNImageRequestHandler(cgImage: Self.preparedImage(cgImage), options: [:])
                do {
                    try handler.perform([request])
                    let observations = request.results ?? []
                    let lines = readingOrder(observations)
                        .compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    /// The user's languages first, filtered to what Vision supports, so a
    /// non-English screen is recognised in its own language rather than being
    /// forced through the English model.
    private static var recognitionLanguages: [String] {
        let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate,
            revision: VNRecognizeTextRequestRevision3
        )) ?? []
        let preferred = Locale.preferredLanguages
        let matching = preferred.filter { language in
            supported.contains { $0.caseInsensitiveCompare(language) == .orderedSame }
                || supported.contains { $0.hasPrefix(language) }
        }
        return matching.isEmpty ? ["en-US"] : Array(matching.prefix(3))
    }

    /// Screenshots of small text (menu items, code at 1x) recognise poorly.
    /// Upscaling them before Vision runs gives the recogniser more pixels per
    /// glyph; larger images are left untouched.
    private static func preparedImage(_ image: CGImage) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge < 1400 else { return image }
        let scale = 2
        let width = image.width * scale
        let height = image.height * scale
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Vision returns observations in no documented order, which scrambles
    /// anything laid out in columns. Groups them into visual lines top to
    /// bottom, then orders each line left to right.
    ///
    /// Done as an explicit grouping pass rather than one clever comparator:
    /// a tolerance-based comparator is not a strict weak ordering, and
    /// `sorted(by:)` gives undefined results when handed one.
    /// Shared with the Library's indexer, which runs off the main actor.
    nonisolated static func readingOrder(
        _ observations: [VNRecognizedTextObservation]
    ) -> [VNRecognizedTextObservation] {
        // Vision's normalized origin is bottom-left, so a larger midY sits
        // higher on the page.
        let topDown = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var ordered: [VNRecognizedTextObservation] = []
        var line: [VNRecognizedTextObservation] = []
        var lineMidY: CGFloat = 0

        func flushLine() {
            ordered.append(contentsOf: line.sorted { $0.boundingBox.minX < $1.boundingBox.minX })
            line.removeAll()
        }

        for observation in topDown {
            let box = observation.boundingBox
            // Two fragments belong to the same visual line when their centres
            // sit within half a line height of each other.
            if !line.isEmpty, abs(box.midY - lineMidY) > box.height / 2 {
                flushLine()
            }
            if line.isEmpty {
                lineMidY = box.midY
            }
            line.append(observation)
        }
        flushLine()

        return ordered
    }
}
