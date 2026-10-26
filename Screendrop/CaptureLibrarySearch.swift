//
//  CaptureLibrarySearch.swift
//  Screendrop
//

import CoreGraphics
import Foundation

/// Library search: every word of the query has to appear somewhere in a
/// capture's name, app, window title, category, the model's title and
/// keywords, its month and weekday, or the text inside it. Matching ignores
/// case, accents and width, so "cafe" finds "Café".
nonisolated enum CaptureLibrarySearch {
    private static let folding: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    static func fold(_ text: String) -> String {
        text.folding(options: folding, locale: nil)
    }

    static func tokens(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The folded text a capture is searched by.
    static func document(for item: CaptureLibraryItem, analysis: CaptureAnalysis?) -> String {
        var fields = [item.name, item.fileURL.lastPathComponent, item.kindTitle]
        if let source = item.source {
            fields.append(source.appName)
            if let window = source.windowTitle { fields.append(window) }
        }
        // "october", "friday" or "2026" narrow by when.
        fields.append(item.createdAt.formatted(.dateTime.month(.wide).year().weekday(.wide)))
        if let analysis {
            if let category = analysis.category { fields.append(category.title) }
            if let title = analysis.title { fields.append(title) }
            fields.append(contentsOf: analysis.keywords)
            fields.append(analysis.text)
            if let transcript = analysis.transcript { fields.append(transcript) }
        }
        return fold(fields.joined(separator: "\n"))
    }

    /// Where the query's words sit in the capture, normalized to the image
    /// with a top-left origin. Vision reports whole lines, so a match's span
    /// is estimated from its share of the line's characters.
    static func highlights(in lines: CaptureTextLines, tokens: [String], limit: Int = 24) -> [CGRect] {
        guard !tokens.isEmpty else { return [] }
        var rects: [CGRect] = []
        for line in lines {
            guard let box = line.box else { continue }
            let text = fold(line.text)
            let length = CGFloat(text.count)
            guard length > 0 else { continue }
            for token in tokens {
                var searchRange = text.startIndex..<text.endIndex
                while let range = text.range(of: token, range: searchRange) {
                    let start: Int = text.distance(from: text.startIndex, to: range.lowerBound)
                    let count: Int = text.distance(from: range.lowerBound, to: range.upperBound)
                    let x: CGFloat = box.minX + box.width * CGFloat(start) / length
                    let width: CGFloat = box.width * CGFloat(count) / length
                    rects.append(CGRect(x: x, y: box.minY, width: width, height: box.height))
                    if rects.count >= limit { return rects }
                    searchRange = range.upperBound..<text.endIndex
                }
            }
        }
        return rects
    }
}

/// Turns Vision's lines into something readable for the inspector. Vision
/// reports each visual line on its own and orders them row by row, which
/// interleaves columns and breaks prose mid-sentence. Here a line joins the
/// paragraph whose last line sits directly above it, at the same left edge
/// and text size, so wrapped prose reads as one paragraph and a sidebar
/// stays apart from the content beside it. Stray fragments ("G", a lone
/// line number) are left out; search still sees every line.
nonisolated enum CaptureReadableText {
    static func paragraphs(from lines: CaptureTextLines) -> [String] {
        struct Paragraph {
            var lines: [String]
            var lastBox: CGRect?
        }
        var paragraphs: [Paragraph] = []
        for line in lines where isMeaningful(line.text) {
            if let box = line.box,
               let index = paragraphs.lastIndex(where: { continues($0.lastBox, with: box) }) {
                paragraphs[index].lines.append(line.text)
                paragraphs[index].lastBox = box
            } else {
                paragraphs.append(Paragraph(lines: [line.text], lastBox: line.box))
            }
        }
        return paragraphs.map { joined($0.lines) }
    }

    /// Prose rejoins into flowing text; code keeps its lines.
    private static func joined(_ lines: [String]) -> String {
        guard lines.count > 1 else { return lines.first ?? "" }
        let codeMarks = ["{", "}", "()", "=>", "->", ";", "//", "let ", "var ", "func ", "const ", "return ", "import ", "def "]
        let codeLines = lines.filter { line in codeMarks.contains { line.contains($0) } }.count
        if codeLines * 3 >= lines.count { return lines.joined(separator: "\n") }
        return lines.dropFirst().reduce(lines[0]) { text, line in
            text.hasSuffix("-") ? String(text.dropLast()) + line : text + " " + line
        }
    }

    /// `box` is the next line of the paragraph ending in `previous`.
    private static func continues(_ previous: CGRect?, with box: CGRect) -> Bool {
        guard let previous, previous.height > 0 else { return false }
        let lineHeight = previous.height
        return abs(box.minX - previous.minX) < 0.015
            && abs(box.height - lineHeight) < lineHeight * 0.35
            && box.minY > previous.minY + lineHeight * 0.5
            && box.minY - previous.maxY < lineHeight * 0.9
    }

    /// At least two letters or digits, and a letter unless it's a longer
    /// run such as a date or an amount.
    private static func isMeaningful(_ text: String) -> Bool {
        let alphanumerics = text.unicodeScalars.filter(CharacterSet.alphanumerics.contains)
        guard alphanumerics.count >= 2 else { return false }
        return alphanumerics.contains(where: CharacterSet.letters.contains) || text.count >= 5
    }
}
