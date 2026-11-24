//
//  ImageResolutionMetadata.swift
//  Screendrop
//
//  Carries a source image's DPI onto images written from it. `screencapture`
//  tags Retina captures 144 DPI; an image written without it defaults to 72,
//  so Preview, Quick Look, Keynote and pasted copies show it at twice its
//  point size and it looks blurry even though every pixel is intact.
//

import Foundation
import ImageIO

nonisolated enum ImageResolutionMetadata {
    /// The DPI properties of the image at `url`, ready to pass as
    /// `CGImageDestinationAddImage` options. Empty when the file has none.
    static func properties(of url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        var result: [CFString: Any] = [:]
        if let dpiWidth = properties[kCGImagePropertyDPIWidth] { result[kCGImagePropertyDPIWidth] = dpiWidth }
        if let dpiHeight = properties[kCGImagePropertyDPIHeight] { result[kCGImagePropertyDPIHeight] = dpiHeight }
        return result
    }
}
