//
//  OpenShotPreferences.swift
//  OpenShot
//
//  Created by Codex on 26/04/26.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

enum OpenShotPreferences {
    static let autoSaveKey = "autoSaveScreenshots"
    static let autoCopyKey = "autoCopyScreenshotsToClipboard"
    static let autoCompressKey = "autoCompressScreenshots"
    static let compressionQualityKey = "compressionQuality"
    static let exportDirectoryPathKey = "exportDirectoryPath"
    
    private static let defaultCompressionQuality = 0.8
    
    static var autoSave: Bool {
        UserDefaults.standard.bool(forKey: autoSaveKey)
    }
    
    static var autoCopy: Bool {
        UserDefaults.standard.bool(forKey: autoCopyKey)
    }
    
    static var autoCompress: Bool {
        UserDefaults.standard.bool(forKey: autoCompressKey)
    }
    
    static var compressionQuality: Double {
        let value = UserDefaults.standard.object(forKey: compressionQualityKey) as? Double ?? defaultCompressionQuality
        return min(max(value, 0.1), 1)
    }
    
    static var exportDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: exportDirectoryPathKey),
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        
        return defaultExportDirectory
    }
    
    static var defaultExportDirectory: URL {
        let picturesDirectory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        return (picturesDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures"))
            .appendingPathComponent("OpenShot", isDirectory: true)
    }
}

enum ScreenshotFileActions {
    static func copyPNGToClipboard(from url: URL) throws {
        let pngData = try Data(contentsOf: url, options: .mappedIfSafe)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
    }
    
    @discardableResult
    static func saveToDefaultLocation(from url: URL) throws -> URL {
        let destinationDirectory = OpenShotPreferences.exportDirectory
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        
        let destinationURL = uniqueDestinationURL(
            for: exportFileName(for: url),
            in: destinationDirectory
        )
        try save(from: url, to: destinationURL)
        return destinationURL
    }
    
    static func save(from sourceURL: URL, to destinationURL: URL) throws {
        if OpenShotPreferences.autoCompress {
            try exportCompressedJPEG(from: sourceURL, to: destinationURL)
        } else {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
    }
    
    static func exportFileName(for sourceURL: URL) -> String {
        guard OpenShotPreferences.autoCompress else {
            return sourceURL.lastPathComponent
        }
        
        return sourceURL
            .deletingPathExtension()
            .appendingPathExtension("jpg")
            .lastPathComponent
    }
    
    static var exportContentType: UTType {
        OpenShotPreferences.autoCompress ? .jpeg : .png
    }
    
    private static func exportCompressedJPEG(from sourceURL: URL, to destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        
        guard let source = CGImageSourceCreateWithURL(
            sourceURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: OpenShotPreferences.compressionQuality
        ]
        
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    
    private static func uniqueDestinationURL(for fileName: String, in directory: URL) -> URL {
        let originalURL = directory.appendingPathComponent(fileName)
        
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            return originalURL
        }
        
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let pathExtension = originalURL.pathExtension
        
        for index in 1...10_000 {
            let numberedName = "\(baseName) \(index)"
            let candidateURL = directory
                .appendingPathComponent(numberedName)
                .appendingPathExtension(pathExtension)
            
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }
        
        return directory
            .appendingPathComponent("\(baseName) \(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }
}
