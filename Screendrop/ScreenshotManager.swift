//
//  ScreenshotManager.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import SwiftUI
import CoreGraphics
import ImageIO

/// Manages all screenshot capture operations at native Retina resolution.
@Observable
final class ScreenshotManager {
    
    static let shared = ScreenshotManager()
    
    private init() {}
    
    // MARK: - Fullscreen Capture
    
    /// Captures the requested display at full native (Retina) resolution using
    /// the native `screencapture` tool.
    ///
    /// ScreenCaptureKit's display capture re-composites windows itself and drops
    /// the WindowServer's inter-window drop shadows, so windows over a light
    /// background lose their edges. `screencapture` captures the real on-screen
    /// composite (shadows included), matching the window/area capture paths.
    func captureFullscreen(displayID: CGDirectDisplayID?) async -> URL? {
        let displayIndex = Self.screencaptureDisplayIndex(for: displayID)
        guard let url = await runScreencapture(args: ["-D", "\(displayIndex)"]) else { return nil }

        // On notched Macs, a fullscreen capture with the menu bar hidden leaves a
        // solid black strip across the top. Trim it (no-op when it isn't black).
        trimEmptyMenuBarIfNeeded(at: url, displayID: displayID)
        return url
    }

    /// Maps a `CGDirectDisplayID` to the 1-based index `screencapture -D`
    /// expects (1 = main display, 2 = secondary, …). `CGGetActiveDisplayList`
    /// returns the main display first, matching that ordering.
    private static func screencaptureDisplayIndex(for displayID: CGDirectDisplayID?) -> Int {
        guard let displayID else { return 1 }

        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return 1 }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return 1 }

        if let index = displays.firstIndex(of: displayID) {
            return index + 1
        }
        return 1
    }
    
    // MARK: - Window Capture
    
    /// Uses the native macOS screencapture tool for interactive window selection.
    /// `-w` = click a window, `-o` = no shadow, `-t png` = lossless PNG.
    /// `delaySeconds` maps to screencapture's `-T`, which (like the system
    /// Screenshot app) fires *after* the window has been picked.
    func captureWindow(includeShadow: Bool = false, delaySeconds: Int = 0) async -> URL? {
        var args = ["-w"]
        if !includeShadow {
            args.append("-o")
        }
        args.append(contentsOf: delayArguments(delaySeconds))
        return await runScreencapture(args: args)
    }
    
    // MARK: - Area Capture
    
    /// Uses the native macOS screencapture tool for interactive area drag selection.
    /// `-s` = drag to select area, `-t png` = lossless PNG. `delaySeconds` maps
    /// to `-T`, firing after the area has been drawn.
    func captureArea(delaySeconds: Int = 0) async -> URL? {
        return await runScreencapture(args: ["-s"] + delayArguments(delaySeconds))
    }

    /// Builds the `-T <seconds>` delay arguments, or none when the timer is off.
    private func delayArguments(_ seconds: Int) -> [String] {
        seconds > 0 ? ["-T", "\(seconds)"] : []
    }
    
    // MARK: - screencapture CLI runner
    
    /// Runs `/usr/sbin/screencapture` silently off the main thread and returns the file URL on success.
    private func runScreencapture(args: [String]) async -> URL? {
        let filePath = generateTempPath(extension: "png")
        
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = args + ["-x", "-t", "png", filePath]
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    if process.terminationStatus == 0,
                       FileManager.default.fileExists(atPath: filePath) {
                        continuation.resume(returning: URL(fileURLWithPath: filePath))
                    } else {
                        // User cancelled the selection
                        continuation.resume(returning: nil)
                    }
                } catch {
                    print("screencapture failed: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    // MARK: - Notch trimming

    /// Loads the PNG at `url`, trims the empty black menu-bar strip left on
    /// notched displays, and rewrites the file in place when a trim happened.
    /// Preserves the original image properties (e.g. DPI) written by
    /// `screencapture`. A no-op when there's nothing to trim or the feature is
    /// disabled.
    private func trimEmptyMenuBarIfNeeded(at url: URL, displayID: CGDirectDisplayID?) {
        guard let displayID,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return
        }

        let trimmed = NotchBarTrimmer.trimmingEmptyMenuBar(image, displayID: displayID)
        // Same reference back means nothing was trimmed — leave the file as-is.
        guard trimmed !== image else { return }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return
        }

        CGImageDestinationAddImage(destination, trimmed, properties)
        CGImageDestinationFinalize(destination)
    }

    // MARK: - Helpers
    
    /// Generates a unique temp file path for screenshots.
    private func generateTempPath(extension ext: String) -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let initialURL = directory.appendingPathComponent(ScreenshotFileNaming.fileName(extension: ext))
        guard FileManager.default.fileExists(atPath: initialURL.path) else {
            return initialURL.path
        }

        let baseName = initialURL.deletingPathExtension().lastPathComponent
        for index in 1...10_000 {
            let candidateURL = directory
                .appendingPathComponent("\(baseName)-\(index)")
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL.path
            }
        }

        return directory
            .appendingPathComponent("Screendrop_\(UUID().uuidString)")
            .appendingPathExtension(ext)
            .path
    }
}
