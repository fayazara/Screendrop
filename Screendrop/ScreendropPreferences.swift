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
    static let saveButtonUsesFolderKey = "saveButtonUsesConfiguredFolder"
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
    static let playSoundsKey = "playSounds"
    static let showMenuBarIconKey = "showMenuBarIcon"
    static let captureWindowShadowKey = "captureWindowShadow"
    static let captureDelaySecondsKey = "captureDelaySeconds"
    static let previewPositionKey = "previewPosition"
    static let previewAutoCloseSecondsKey = "previewAutoCloseSeconds"
    static let previewCloseAfterDraggingKey = "previewCloseAfterDragging"
    static let overlayCardLayoutKey = "overlayCardLayout"
    static let lowResolutionEditorPreviewKey = "lowResolutionEditorPreview"
    static let trimFullscreenMenuBarKey = "trimFullscreenMenuBar"

    private static let defaultCompressionQuality = 0.8
    static let defaultRecordingMouseIndicatorColor = "#007AFF"
    static let defaultRecordingMouseIndicatorSize = 44.0
    
    static var autoSave: Bool {
        UserDefaults.standard.bool(forKey: autoSaveKey)
    }

    static var saveButtonUsesConfiguredFolder: Bool {
        if UserDefaults.standard.object(forKey: saveButtonUsesFolderKey) == nil {
            return autoSave
        }
        return UserDefaults.standard.bool(forKey: saveButtonUsesFolderKey)
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

    /// Whether to play the shutter sound after a screenshot. Defaults to on.
    static var playSounds: Bool {
        if UserDefaults.standard.object(forKey: playSoundsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: playSoundsKey)
    }

    /// Whether the menu bar icon is shown. Defaults to on.
    static var showMenuBarIcon: Bool {
        if UserDefaults.standard.object(forKey: showMenuBarIconKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: showMenuBarIconKey)
    }

    /// Whether captured windows include their drop shadow. Defaults to off
    /// (tighter, shadow-free crops).
    static var captureWindowShadow: Bool {
        UserDefaults.standard.bool(forKey: captureWindowShadowKey)
    }

    /// Countdown delay (in seconds) before a capture is taken. 0 means off.
    static var captureDelaySeconds: Int {
        max(0, UserDefaults.standard.integer(forKey: captureDelaySecondsKey))
    }

    /// Which screen corner the preview overlay docks to.
    static var previewPosition: PreviewOverlayPosition {
        guard let raw = UserDefaults.standard.string(forKey: previewPositionKey),
              let position = PreviewOverlayPosition(rawValue: raw) else {
            return .right
        }
        return position
    }

    /// Seconds before the preview overlay auto-dismisses. 0 means never.
    static var previewAutoCloseSeconds: Int {
        max(0, UserDefaults.standard.integer(forKey: previewAutoCloseSecondsKey))
    }

    /// Whether dragging a preview card out dismisses it. Defaults to on.
    static var previewCloseAfterDragging: Bool {
        if UserDefaults.standard.object(forKey: previewCloseAfterDraggingKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: previewCloseAfterDraggingKey)
    }

    /// Whether the annotation editor displays a downscaled preview of the
    /// screenshot to reduce memory usage. This only affects the on-screen
    /// editing preview — exported images are always rendered at full
    /// resolution. Defaults to on.
    static var lowResolutionEditorPreview: Bool {
        if UserDefaults.standard.object(forKey: lowResolutionEditorPreviewKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: lowResolutionEditorPreviewKey)
    }
    
    /// Whether fullscreen captures on notched displays trim the empty black
    /// menu-bar strip at the top. The strip is only removed when it's solid
    /// black (menu bar hidden); a revealed menu bar is preserved. Defaults to on.
    static var trimFullscreenMenuBar: Bool {
        if UserDefaults.standard.object(forKey: trimFullscreenMenuBarKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: trimFullscreenMenuBarKey)
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

enum PreviewOverlayPosition: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: "Bottom left"
        case .right: "Bottom right"
        }
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
    static func copyImageToClipboard(from url: URL) throws {
        let contentType = UTType(filenameExtension: url.pathExtension)
        let dataType: NSPasteboard.PasteboardType = if contentType?.conforms(to: .jpeg) == true {
            NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        } else {
            .png
        }

        try copyImageToClipboard(from: url, dataType: dataType)
    }

    static func copyPNGToClipboard(from url: URL) throws {
        try copyImageToClipboard(from: url, dataType: .png)
    }

    private static func copyImageToClipboard(from url: URL, dataType: NSPasteboard.PasteboardType) throws {
        let imageData = try Data(contentsOf: url, options: .mappedIfSafe)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Write several representations on a single pasteboard item so that
        // every kind of paste target can find a flavor it understands:
        //
        // - `.fileURL`: terminals and apps that "paste a file" (e.g. opencode's
        //   terminal, editors, Slack) read the file reference from disk.
        // - image data / `.tiff`: rich-text and web targets (Gmail, Notes, Mail,
        //   image editors) read raw pixels directly.
        //
        // Only providing image data is why pasting worked in Gmail but not in
        // terminal apps — those read the file URL flavor instead.
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(imageData, forType: dataType)
        if let tiffData = NSBitmapImageRep(data: imageData)?.tiffRepresentation
            ?? NSImage(data: imageData)?.tiffRepresentation {
            item.setData(tiffData, forType: .tiff)
        }

        pasteboard.writeObjects([item])
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
