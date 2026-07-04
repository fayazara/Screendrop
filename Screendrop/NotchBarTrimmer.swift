//
//  NotchBarTrimmer.swift
//  Screendrop
//
//  On notched Macs, a fullscreen app with the menu bar hidden leaves a solid
//  black strip across the top of a fullscreen display capture (the menu-bar /
//  notch area the app doesn't draw into). This trims that strip off — but only
//  when it's actually empty black. If the menu bar is revealed (it shows menu
//  items) or the app draws content edge-to-edge behind the notch, the strip
//  contains non-black pixels and is preserved.
//
//  The strip height comes straight from `NSScreen.safeAreaInsets.top`, scaled to
//  the captured image's pixel height, so the crop is exact to the pixel.
//

import AppKit
import CoreGraphics

@MainActor
enum NotchBarTrimmer {
    /// Luminance below which a channel is considered "black" (tolerates encoding
    /// noise around the genuinely-black menu-bar strip).
    private static let blackChannelThreshold: UInt8 = 14
    /// Maximum fraction of non-black pixels for the strip to count as empty.
    private static let maxNonBlackFraction = 0.002

    /// Returns `image` with the empty black menu-bar strip removed, or the
    /// original image when there's nothing to trim.
    static func trimmingEmptyMenuBar(_ image: CGImage, displayID: CGDirectDisplayID) -> CGImage {
        guard ScreendropPreferences.trimFullscreenMenuBar else { return image }

        guard let screen = NSScreen.matching(displayID: displayID) else { return image }
        let topInset = screen.safeAreaInsets.top
        let screenHeight = screen.frame.height
        // Non-notched displays report a zero top inset.
        guard topInset > 0, screenHeight > 0 else { return image }

        // Map the inset (points) onto the captured image's pixel height. Using
        // the image's own height keeps this exact regardless of capture scale.
        let stripHeight = Int((CGFloat(image.height) * topInset / screenHeight).rounded())
        guard stripHeight > 0, stripHeight < image.height else { return image }

        guard topStripIsBlack(image, stripHeight: stripHeight) else { return image }

        // Hack: the captured black bar sits a hair taller than the safe-area
        // inset, leaving a thin (1–2px) black line after a pixel-exact crop.
        // Shave a couple of extra pixels to kill it. The black check above still
        // gates trimming, so a visible menu bar is never cropped.
        let trimHeight = min(stripHeight + Self.extraTrimPixels, image.height - 1)

        let cropRect = CGRect(
            x: 0,
            y: trimHeight,
            width: image.width,
            height: image.height - trimHeight
        )
        return image.cropping(to: cropRect) ?? image
    }

    /// Extra pixel rows shaved below the computed safe-area strip to remove the
    /// leftover thin black notch line.
    private static let extraTrimPixels = 2

    /// Whether the top `stripHeight` pixel rows of `image` are essentially solid
    /// black.
    private static func topStripIsBlack(_ image: CGImage, stripHeight: Int) -> Bool {
        guard let strip = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: stripHeight)) else {
            return false
        }

        let width = strip.width
        let height = strip.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let context = buffer.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else {
            return false
        }

        context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: height))

        let total = width * height
        guard total > 0 else { return false }

        var nonBlackCount = 0
        let allowedNonBlack = Int(Double(total) * maxNonBlackFraction)
        var index = 0
        while index < buffer.count {
            if buffer[index] > blackChannelThreshold
                || buffer[index + 1] > blackChannelThreshold
                || buffer[index + 2] > blackChannelThreshold {
                nonBlackCount += 1
                if nonBlackCount > allowedNonBlack {
                    return false
                }
            }
            index += bytesPerPixel
        }

        return true
    }
}

private extension NSScreen {
    /// Finds the screen backing the given Core Graphics display ID.
    static func matching(displayID: CGDirectDisplayID) -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return screens.first { screen in
            (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }
    }
}
