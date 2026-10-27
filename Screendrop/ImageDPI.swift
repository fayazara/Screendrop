//
//  ImageDPI.swift
//  Screendrop
//  Contributed by Rochak Agrawal (Screenshot X).
//
//  Screen captures are stored at the display's native pixels: a 2x Retina
//  display means one point is two pixels. Without an explicit resolution the
//  PNG and JPEG writers fall back to 72 dpi, so every viewer that honours DPI
//  (Preview at Actual Size, Pages, Word, Mail) draws the capture at twice its
//  intended size — the "magnified" look. Tagging the file with the display's
//  scale keeps it at the same physical size as the content that was captured.
//

import CoreGraphics
import Foundation
import ImageIO

enum ImageDPI {
    /// Dots per inch for a capture taken at `scale` screen pixels per point.
    static func dotsPerInch(scale: CGFloat) -> Double {
        72.0 * Double(max(scale, 1))
    }

    /// Image properties carrying the resolution for a freshly written file.
    static func properties(scale: CGFloat) -> [CFString: Any] {
        let dpi = dotsPerInch(scale: scale)
        return [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
    }

    /// The source file's resolution, so a re-encode or an edit keeps it.
    /// Falls back to `scale` when the file carries none.
    static func preserving(_ sourceURL: URL, scale: CGFloat = 2) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyDPIWidth] as? Double,
              width > 0
        else {
            return properties(scale: scale)
        }
        let height = properties[kCGImagePropertyDPIHeight] as? Double ?? width
        return [
            kCGImagePropertyDPIWidth: width,
            kCGImagePropertyDPIHeight: height
        ]
    }
}
