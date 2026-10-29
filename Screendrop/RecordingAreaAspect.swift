//
//  RecordingAreaAspect.swift
//  Screendrop
//
//  The aspect ratio an area recording's selection is locked to. Stored as a
//  whole-number width:height pair rather than a preset enum, so a ratio the
//  user arrived at by hand ("Lock Current Ratio") is as much a ratio as 16:9,
//  and swapping orientation is just swapping the two numbers.
//

import CoreGraphics
import Foundation

nonisolated struct RecordingAreaAspect: Equatable, Hashable, Sendable {
    let width: Int
    let height: Int

    init(_ width: Int, _ height: Int) {
        let divisor = Self.gcd(max(width, 1), max(height, 1))
        self.width = max(width, 1) / divisor
        self.height = max(height, 1) / divisor
    }

    /// Width divided by height.
    var ratio: CGFloat { CGFloat(width) / CGFloat(height) }

    var swapped: RecordingAreaAspect { RecordingAreaAspect(height, width) }

    var isPortrait: Bool { height > width }

    /// "16:9" for anything that reads as a ratio; a hand-made selection whose
    /// reduced terms are unreadable (1847:1036) is shown as "1.78:1".
    var title: String {
        if width <= 32 && height <= 32 {
            return "\(width):\(height)"
        }
        if isPortrait {
            return "1:\(Self.format(CGFloat(height) / CGFloat(width)))"
        }
        return "\(Self.format(ratio)):1"
    }

    /// What a preset is for, shown under its ratio in the menu.
    var purpose: String? {
        switch (width, height) {
        case (16, 9): "YouTube, presentations"
        case (16, 10): "Mac displays"
        case (4, 3): "Classic"
        case (1, 1): "Square posts"
        case (4, 5): "Instagram feed"
        case (9, 16): "Reels, Shorts, TikTok"
        default: nil
        }
    }

    static let landscapePresets = [RecordingAreaAspect(16, 9), RecordingAreaAspect(16, 10), RecordingAreaAspect(4, 3)]
    static let square = RecordingAreaAspect(1, 1)
    static let portraitPresets = [RecordingAreaAspect(4, 5), RecordingAreaAspect(9, 16)]

    static var allPresets: [RecordingAreaAspect] {
        landscapePresets + [square] + portraitPresets
    }

    /// The ratio of a selection measured in pixels, reduced, for "Lock
    /// Current Ratio". Snaps to a preset when it is within a pixel or so of one so
    /// a selection made at 16:9 by eye locks as 16:9.
    static func of(pixelWidth: Int, pixelHeight: Int) -> RecordingAreaAspect {
        let measured = CGFloat(pixelWidth) / CGFloat(max(pixelHeight, 1))
        let tolerance = 1.5 / CGFloat(max(min(pixelWidth, pixelHeight), 1))
        if let preset = allPresets.first(where: { abs($0.ratio - measured) <= measured * tolerance }) {
            return preset
        }
        return RecordingAreaAspect(pixelWidth, pixelHeight)
    }

    // MARK: Persistence

    var storageValue: String { "\(width):\(height)" }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        self.init(parts[0], parts[1])
    }

    // MARK: Helpers

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }

    private static func format(_ value: CGFloat) -> String {
        var text = String(format: "%.2f", Double(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
