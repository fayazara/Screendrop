//
//  OpenShotPreferences.swift
//  OpenShot
//
//  Created by Codex on 26/04/26.
//

import AppKit

enum OpenShotPreferences {
    static let autoSaveKey = "autoSaveScreenshots"
    static let autoCopyKey = "autoCopyScreenshotsToClipboard"
    
    static var autoSave: Bool {
        UserDefaults.standard.bool(forKey: autoSaveKey)
    }
    
    static var autoCopy: Bool {
        UserDefaults.standard.bool(forKey: autoCopyKey)
    }
    
    static var exportDirectory: URL {
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
            for: url.lastPathComponent,
            in: destinationDirectory
        )
        try FileManager.default.copyItem(at: url, to: destinationURL)
        return destinationURL
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
