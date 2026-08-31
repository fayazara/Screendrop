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
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
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

    /// Vision returns observations in no documented order, which scrambles
    /// anything laid out in columns. Groups them into visual lines top to
    /// bottom, then orders each line left to right.
    ///
    /// Done as an explicit grouping pass rather than one clever comparator:
    /// a tolerance-based comparator is not a strict weak ordering, and
    /// `sorted(by:)` gives undefined results when handed one.
    private static func readingOrder(
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
