//
//  ScreenshotFileNaming.swift
//  Screendrop
//

import Foundation

enum ScreenshotFileNaming {
    /// A fixed timestamp name for scratch files that never reach the user,
    /// such as the temp PNG `screencapture` writes before history import.
    static func fileName(date: Date = Date(), extension pathExtension: String = "png") -> String {
        "Screendrop_\(timestampFormatter.string(from: date)).\(pathExtension)"
    }

    /// The user-facing name for a capture, rendered from the template in
    /// Settings. Draws an auto-increment number when the template asks for
    /// one and the context does not already carry it.
    static func captureFileName(for context: CaptureNamingContext, extension pathExtension: String) -> String {
        let template = ScreendropPreferences.fileNameTemplate
        var context = context
        if context.sequenceNumber == nil, CaptureFileNameTemplate.usesSequenceNumber(template) {
            context.sequenceNumber = ScreendropPreferences.nextFileNameSequenceNumber()
        }
        let stem = CaptureFileNameTemplate.stem(
            template: template,
            context: context,
            timeZone: ScreendropPreferences.fileNameUsesUTC ? .gmt : .current
        )
        return "\(stem).\(pathExtension)"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter
    }()
}
