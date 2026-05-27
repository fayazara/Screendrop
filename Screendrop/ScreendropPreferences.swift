//
//  ScreendropPreferences.swift
//  Screendrop
//
//  Created by Codex on 26/04/26.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ScreendropPreferences {
    static let autoSaveKey = "autoSaveScreenshots"
    static let autoCopyKey = "autoCopyScreenshotsToClipboard"
    static let autoCompressKey = "autoCompressScreenshots"
    static let exportFormatKey = "exportFormat"
    static let compressionQualityKey = "compressionQuality"
    static let exportDirectoryPathKey = "exportDirectoryPath"
    static let showRecordingMouseIndicatorsKey = "showRecordingMouseIndicators"
    static let showRecordingKeyPressCaptionsKey = "showRecordingKeyPressCaptions"
    static let recordingMouseIndicatorColorKey = "recordingMouseIndicatorColor"
    static let recordingMouseIndicatorSizeKey = "recordingMouseIndicatorSize"
    static let fullscreenHotkeyKey = "captureHotkey.fullscreen"
    static let windowHotkeyKey = "captureHotkey.window"
    static let areaHotkeyKey = "captureHotkey.area"
    static let screenRecordingHotkeyKey = "captureHotkey.screenRecording"
    
    private static let defaultCompressionQuality = 0.8
    static let defaultRecordingMouseIndicatorColor = "#007AFF"
    static let defaultRecordingMouseIndicatorSize = 44.0
    
    static var autoSave: Bool {
        UserDefaults.standard.bool(forKey: autoSaveKey)
    }
    
    static var autoCopy: Bool {
        UserDefaults.standard.bool(forKey: autoCopyKey)
    }
    
    static var autoCompress: Bool {
        UserDefaults.standard.bool(forKey: autoCompressKey)
    }

    static var exportFormat: ScreenshotExportFormat {
        if let rawValue = UserDefaults.standard.string(forKey: exportFormatKey),
           let format = ScreenshotExportFormat(rawValue: rawValue) {
            return format
        }

        return autoCompress ? .jpeg : .png
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
            .appendingPathComponent("Screendrop", isDirectory: true)
    }

    static var showRecordingMouseIndicators: Bool {
        if UserDefaults.standard.object(forKey: showRecordingMouseIndicatorsKey) == nil {
            return true
        }

        return UserDefaults.standard.bool(forKey: showRecordingMouseIndicatorsKey)
    }

    static var showRecordingKeyPressCaptions: Bool {
        UserDefaults.standard.bool(forKey: showRecordingKeyPressCaptionsKey)
    }

    static var recordingMouseIndicatorColor: String {
        let color = UserDefaults.standard.string(forKey: recordingMouseIndicatorColorKey) ?? defaultRecordingMouseIndicatorColor
        return color.isEmpty ? defaultRecordingMouseIndicatorColor : color
    }

    static var recordingMouseIndicatorSize: Double {
        let value = UserDefaults.standard.object(forKey: recordingMouseIndicatorSizeKey) as? Double
            ?? defaultRecordingMouseIndicatorSize
        return min(max(value, 24), 96)
    }
    
    // MARK: - Cloud
    
    static var cloudWorkerURL: String {
        CloudCredentialStore.shared.workerURL
    }
    
    static var cloudUploadToken: String {
        CloudCredentialStore.shared.uploadToken
    }
    
    /// Cloud upload is available when the worker URL and upload token are configured.
    static var isCloudConfigured: Bool {
        CloudCredentialStore.shared.isConfigured
    }
}

enum ScreenshotExportFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg
    case heic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png:
            "PNG"
        case .jpeg:
            "JPEG"
        case .heic:
            "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .png:
            "png"
        case .jpeg:
            "jpg"
        case .heic:
            "heic"
        }
    }

    var contentType: UTType {
        switch self {
        case .png:
            .png
        case .jpeg:
            .jpeg
        case .heic:
            .heic
        }
    }

    var usesLossyQuality: Bool {
        self != .png
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
        let destinationDirectory = ScreendropPreferences.exportDirectory
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
        if ScreendropPreferences.exportFormat == .png {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } else {
            try exportImage(from: sourceURL, to: destinationURL, contentType: ScreendropPreferences.exportFormat.contentType)
        }
    }
    
    static func exportFileName(for sourceURL: URL) -> String {
        return sourceURL
            .deletingPathExtension()
            .appendingPathExtension(ScreendropPreferences.exportFormat.fileExtension)
            .lastPathComponent
    }
    
    static var exportContentType: UTType {
        ScreendropPreferences.exportFormat.contentType
    }
    
    private static func exportImage(from sourceURL: URL, to destinationURL: URL, contentType: UTType) throws {
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
            contentType.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        
        let options: [CFString: Any] = contentType == .png ? [:] : [
            kCGImageDestinationLossyCompressionQuality: ScreendropPreferences.compressionQuality
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
