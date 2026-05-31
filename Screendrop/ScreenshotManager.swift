//
//  ScreenshotManager.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import SwiftUI
import ScreenCaptureKit
import CoreGraphics
import ImageIO

/// Manages all screenshot capture operations at native Retina resolution.
@Observable
final class ScreenshotManager {
    
    static let shared = ScreenshotManager()
    
    private init() {}
    
    // MARK: - Fullscreen Capture
    
    /// Captures the requested display at full native (Retina) resolution
    /// using ScreenCaptureKit.
    func captureFullscreen(displayID: CGDirectDisplayID?) async -> URL? {
        do {
            let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            
            guard let display = availableContent.displays.first(where: { $0.displayID == displayID }) ?? availableContent.displays.first else {
                print("No display found")
                return nil
            }
            
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // SCDisplay dimensions are points; SCStreamConfiguration expects pixels.
            let pixelScale = CGFloat(filter.pointPixelScale)
            config.width = Int(CGFloat(display.width) * pixelScale)
            config.height = Int(CGFloat(display.height) * pixelScale)
            config.scalesToFit = false
            config.showsCursor = false
            
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            
            return saveImage(image)
        } catch {
            print("Fullscreen capture failed: \(error)")
            return nil
        }
    }
    
    // MARK: - Window Capture
    
    /// Uses the native macOS screencapture tool for interactive window selection.
    /// `-w` = click a window, `-o` = no shadow, `-t png` = lossless PNG.
    func captureWindow(includeShadow: Bool = false) async -> URL? {
        var args = ["-w"]
        if !includeShadow {
            args.append("-o")
        }
        return await runScreencapture(args: args)
    }
    
    // MARK: - Area Capture
    
    /// Uses the native macOS screencapture tool for interactive area drag selection.
    /// `-s` = drag to select area, `-t png` = lossless PNG.
    func captureArea() async -> URL? {
        return await runScreencapture(args: ["-s"])
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
    
    // MARK: - Helpers
    
    /// Saves a CGImage as a lossless PNG to a temporary file.
    private func saveImage(_ cgImage: CGImage) -> URL? {
        let filePath = generateTempPath(extension: "png")
        let fileURL = URL(fileURLWithPath: filePath)
        
        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            print("Failed to create image destination")
            return nil
        }
        
        CGImageDestinationAddImage(destination, cgImage, nil)
        
        guard CGImageDestinationFinalize(destination) else {
            print("Failed to write image to disk")
            return nil
        }
        
        return fileURL
    }
    
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
