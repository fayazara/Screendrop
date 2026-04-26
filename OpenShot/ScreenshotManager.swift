//
//  ScreenshotManager.swift
//  OpenShot
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
    
    /// Captures the entire main display at full native (Retina) resolution
    /// using ScreenCaptureKit.
    func captureFullscreen() async -> URL? {
        do {
            let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            
            guard let mainDisplay = availableContent.displays.first else {
                print("No display found")
                return nil
            }
            
            let filter = SCContentFilter(display: mainDisplay, excludingWindows: [])
            let config = SCStreamConfiguration()
            // SCDisplay dimensions are points; SCStreamConfiguration expects pixels.
            let pixelScale = CGFloat(filter.pointPixelScale)
            config.width = Int(CGFloat(mainDisplay.width) * pixelScale)
            config.height = Int(CGFloat(mainDisplay.height) * pixelScale)
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
    func captureWindow() async -> URL? {
        return await runScreencapture(args: ["-w", "-o"])
    }
    
    // MARK: - Area Capture
    
    /// Uses the native macOS screencapture tool for interactive area drag selection.
    /// `-s` = drag to select area, `-o` = no shadow, `-t png` = lossless PNG.
    func captureArea() async -> URL? {
        return await runScreencapture(args: ["-s"])
    }
    
    // MARK: - screencapture CLI runner
    
    /// Runs `/usr/sbin/screencapture` off the main thread and returns the file URL on success.
    private func runScreencapture(args: [String]) async -> URL? {
        let filePath = generateTempPath(extension: "png")
        
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = args + ["-t", "png", filePath]
                
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
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return NSTemporaryDirectory().appending("OpenShot_\(timestamp)_\(UUID().uuidString.prefix(6)).\(ext)")
    }
}
