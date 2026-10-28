//
//  ScreenshotManager.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import SwiftUI
import CoreGraphics
import ImageIO
import ScreenCaptureKit

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
    /// `-i` = interactive mode (starts in area selection mode and supports pressing Space to switch to window selection),
    /// `-o` = no shadow, `-t png` = lossless PNG. `delaySeconds` maps
    /// to `-T`, firing after the area/window has been chosen.
    func captureArea(includeShadow: Bool = false, delaySeconds: Int = 0) async -> URL? {
        var args = ["-i"]
        if !includeShadow {
            args.append("-o")
        }
        args.append(contentsOf: delayArguments(delaySeconds))
        return await runScreencapture(args: args)
    }

    /// Captures a rectangle the user drew, given in global screen points.
    /// ScreenCaptureKit is tried first because it maps the rectangle to the
    /// display that owns it and returns an error when capture is not
    /// available, instead of a transparent image. `screencapture -R` remains
    /// the fallback: it measures from the top-left of the main display, while
    /// AppKit's global space has its origin at the bottom-left.
    func captureRect(_ rect: CGRect) async -> URL? {
        if let url = await captureRectWithScreenCaptureKit(rect) {
            return url
        }

        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let x = Int(rect.minX.rounded())
        let y = Int((mainHeight - rect.maxY).rounded())
        let width = max(1, Int(rect.width.rounded()))
        let height = max(1, Int(rect.height.rounded()))
        return await runScreencapture(args: ["-R", "\(x),\(y),\(width),\(height)"])
    }

    /// Captures just the requested rectangle from the display that contains
    /// it. ScreenDrop's own windows are excluded unless the user opted into
    /// capturing the app's UI, matching the screenshot privacy preference.
    private func captureRectWithScreenCaptureKit(_ rect: CGRect) async -> URL? {
        guard rect.width >= 1, rect.height >= 1,
              let screen = NSScreen.screens.first(where: {
                  $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
              }) ?? NSScreen.screens.first(where: { $0.frame.intersects(rect) }),
              let displayID = ActiveDisplayResolver.displayID(for: screen)
        else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return nil
            }

            // Match the existing privacy preference: ScreenDrop's own panels
            // stay out of captures unless the user opts in. The selection,
            // border and HUD are already outside the captured rectangle; this
            // also covers any preview card or open window that overlaps it.
            let excludedIDs = PreviewWindowCaptureExclusion.shared.excludedWindowIDs
            let excludedWindows = content.windows.filter {
                excludedIDs.contains($0.windowID)
            }

            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(
                x: rect.minX - screen.frame.minX,
                y: screen.frame.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            let scale = screen.backingScaleFactor
            configuration.width = max(1, Int((rect.width * scale).rounded()))
            configuration.height = max(1, Int((rect.height * scale).rounded()))
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return writePNG(image, scale: scale)
        } catch {
            return nil
        }
    }

    private func writePNG(_ image: CGImage, scale: CGFloat = 2) -> URL? {
        let url = URL(fileURLWithPath: generateTempPath(extension: "png"))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }

        CGImageDestinationAddImage(
            destination,
            image,
            ImageDPI.properties(scale: scale) as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
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
        // Same reference back means nothing was trimmed - leave the file as-is.
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
