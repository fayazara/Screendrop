import Foundation

/// Stage every file before changing the editable screenshot. Keep backups until
/// the image, base, and document have all been installed successfully.
nonisolated enum ScreenshotEditFileTransaction {
    static func apply(replacements: [(source: URL, destination: URL)], removing: [URL] = []) throws {
        let manager = FileManager.default
        guard let directory = (replacements.first?.destination ?? removing.first)?.deletingLastPathComponent() else { return }
        let staging = directory.appendingPathComponent(".screendrop-save-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        var keepBackup = false
        defer { if !keepBackup { try? manager.removeItem(at: staging) } }

        let destinations = replacements.map(\.destination) + removing
        var backups: [URL: URL] = [:]
        var staged: [URL] = []
        for (index, replacement) in replacements.enumerated() {
            let copy = staging.appendingPathComponent("new-\(index)")
            try manager.copyItem(at: replacement.source, to: copy)
            staged.append(copy)
        }
        for (index, destination) in destinations.enumerated() where manager.fileExists(atPath: destination.path) {
            let backup = staging.appendingPathComponent("original-\(index)")
            try manager.copyItem(at: destination, to: backup)
            backups[destination] = backup
        }

        var attempted: [URL] = []
        do {
            for (index, replacement) in replacements.enumerated() {
                attempted.append(replacement.destination)
                try install(staged[index], at: replacement.destination)
            }
            for destination in removing where manager.fileExists(atPath: destination.path) {
                attempted.append(destination)
                try manager.removeItem(at: destination)
            }
        } catch {
            let saveError = error
            for destination in attempted.reversed() {
                do {
                    if let backup = backups[destination] {
                        try install(backup, at: destination)
                    } else if manager.fileExists(atPath: destination.path) {
                        try manager.removeItem(at: destination)
                    }
                } catch {
                    keepBackup = true
                }
            }
            if keepBackup {
                throw NSError(domain: "Screendrop.ScreenshotSave", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The screenshot could not be saved or fully restored. Recovery files are kept at \(staging.path).",
                    NSUnderlyingErrorKey: saveError
                ])
            }
            throw saveError
        }
    }

    private static func install(_ source: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }
}
