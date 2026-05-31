//
//  ColorPickerService.swift
//  Screendrop
//

import AppKit

/// Presents the system magnifier loupe to sample a pixel color anywhere on
/// screen and copies the result to the clipboard as a hex string.
@MainActor
enum ColorPickerService {
    static func pickColor() {
        NSColorSampler().show { color in
            guard let color else { return }
            let hex = color.usingColorSpace(.sRGB)?.hexRGBString
                ?? color.hexRGBString
                ?? "#000000"

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)

            if ScreendropPreferences.playSounds {
                NSSound(named: "Pop")?.play()
            }
        }
    }
}
