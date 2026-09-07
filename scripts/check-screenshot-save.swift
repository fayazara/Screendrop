import Foundation

// Exercises the production file transaction without launching Screendrop.
// xcrun swiftc -module-cache-path /tmp/screendrop-save-module-cache \
//   Screendrop/ScreenshotEditFileTransaction.swift scripts/check-screenshot-save.swift \
//   -o /tmp/screendrop-save-check && /tmp/screendrop-save-check
@main
struct ScreenshotSaveChecks {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("screendrop-save-check-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        func file(_ name: String, _ contents: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }
        func expect(_ url: URL, _ contents: String) throws {
            let actual = try String(contentsOf: url, encoding: .utf8)
            precondition(actual == contents, "Incorrect contents for \(url.lastPathComponent)")
        }
        func expectFailure(_ operation: () throws -> Void) {
            do {
                try operation()
                preconditionFailure("Expected transaction failure")
            } catch {}
        }
        func expectNoStagingFiles() throws {
            let files = try manager.contentsOfDirectory(atPath: root.path)
            precondition(!files.contains(where: { $0.hasPrefix(".screendrop-save-") }))
        }

        let display = try file("display.png", "original pixels")
        let render = try file("render.png", "edited pixels")
        let base = root.appendingPathComponent("base.png")
        let document = root.appendingPathComponent("edit.json")
        let newDocument = try file("new.json", "new document")
        try ScreenshotEditFileTransaction.apply(replacements: [
            (display, base), (render, display), (newDocument, document)
        ])
        try expect(base, "original pixels")
        try expect(display, "edited pixels")
        try expect(document, "new document")
        try expect(render, "edited pixels")
        try expectNoStagingFiles()

        // A later destination is invalid, after display has been replaced.
        let nextRender = try file("next.png", "later edits")
        let invalidDestination = root.appendingPathComponent("missing-parent/edit.json")
        expectFailure {
            try ScreenshotEditFileTransaction.apply(replacements: [
                (nextRender, display), (newDocument, invalidDestination)
            ])
        }
        try expect(display, "edited pixels")
        try expect(base, "original pixels")
        try expect(document, "new document")
        try expectNoStagingFiles()

        // Files newly created before a later failure must disappear again.
        let newBase = root.appendingPathComponent("new-base.png")
        expectFailure {
            try ScreenshotEditFileTransaction.apply(replacements: [
                (render, newBase), (newDocument, invalidDestination)
            ])
        }
        precondition(!manager.fileExists(atPath: newBase.path))
        try expectNoStagingFiles()

        // Staging failure must leave every existing file alone.
        expectFailure {
            try ScreenshotEditFileTransaction.apply(replacements: [
                (nextRender, display), (root.appendingPathComponent("missing-source"), document)
            ])
        }
        try expect(display, "edited pixels")
        try expect(document, "new document")
        try expectNoStagingFiles()

        // Clear annotations: restore original pixels and remove editable files.
        try ScreenshotEditFileTransaction.apply(replacements: [(base, display)], removing: [base, document])
        try expect(display, "original pixels")
        precondition(!manager.fileExists(atPath: base.path))
        precondition(!manager.fileExists(atPath: document.path))
        try expectNoStagingFiles()
        print("Screenshot save checks passed: commit, rollback, new-file cleanup, staging failure, and annotation removal.")
    }
}
