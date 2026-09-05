import AppKit
import SwiftUI

extension CaptureLibraryModel {
    func perform(_ action: CaptureLibraryAction) {
        guard !isBusy else { return }
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        switch action {
        case .preview:
            guard selected.count == 1, let item = selected.first else { return }
            if QuickLookPreviewPresenter.isShown, let current = QuickLookPreviewPresenter.currentURL {
                let isSameCapture = current.standardizedFileURL == item.fileURL.standardizedFileURL
                    || (item.session != nil && current.deletingLastPathComponent().standardizedFileURL.path == item.ownedURL.standardizedFileURL.path)
                if isSameCapture { QuickLookPreviewPresenter.dismiss(); return }
            }
            run("Preparing preview…") {
                StudioProjectRegistry.shared.flushDrafts()
                let url = item.isVideo ? try await RecordingDeliverable.resolve(for: item.fileURL) : item.fileURL
                QuickLookPreviewPresenter.show(url: url)
            }
        case .edit:
            guard selected.count == 1, let item = selected.first else { return }
            QuickLookPreviewPresenter.dismiss()
            if item.isVideo { PreviewPanelPresenter.shared.onEditVideo?(item.session?.directoryURL ?? item.fileURL) }
            else { PreviewPanelPresenter.shared.onAnnotate?(item.fileURL) }
        case .rename:
            guard selected.count == 1, let item = selected.first else { return }
            renamingItem = item
            renameText = item.name
        case .copy:
            run("Copying \(selected.count == 1 ? "capture" : "captures")…") {
                StudioProjectRegistry.shared.flushDrafts()
                if selected.count == 1, let item = selected.first, !item.isVideo {
                    try ScreenshotFileActions.copyImageToClipboard(from: item.fileURL)
                } else {
                    var urls: [NSURL] = []
                    for item in selected {
                        let url = item.isVideo ? try await RecordingDeliverable.resolve(for: item.fileURL) : item.fileURL
                        urls.append(url as NSURL)
                    }
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.writeObjects(urls) else { throw CocoaError(.fileWriteUnknown) }
                }
            }
        case .export:
            export(selected)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.ownedURL))
        case .trash:
            pendingTrash = selected
        }
    }

    func rename() {
        guard let item = renamingItem else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let session = item.session {
            session.updateProjectMetadata { $0.displayName = name }
            RecordingProjectStore.shared.reload()
        } else if let id = item.historyIDs.first {
            ScreenshotHistoryStore.shared.rename(id: id, to: name)
        }
        renamingItem = nil
        refresh()
    }

    func movePendingItemsToTrash() {
        let targets = pendingTrash
        pendingTrash = []
        guard !targets.isEmpty else { return }
        run("Moving to Trash…") {
            QuickLookPreviewPresenter.dismiss()
            var removedIDs: Set<UUID> = []
            var removedEntries: Set<String> = []
            var failures: [String] = []
            for item in targets {
                guard !CaptureLibraryOpenEditors.contains(item.ownedURL) else {
                    failures.append("\(item.name): close its editor before moving it to Trash.")
                    continue
                }
                do {
                    try await Task.detached(priority: .userInitiated) { try CaptureLibraryFiles.trash(item) }.value
                    removedIDs.formUnion(item.historyIDs)
                    removedEntries.insert(item.id)
                    if let session = item.session {
                        ScreenshotPreviewStack.shared.dismissRecordingSession(session.directoryURL)
                    } else {
                        let cards = ScreenshotPreviewStack.shared.items.filter { $0.url.standardizedFileURL == item.fileURL.standardizedFileURL }
                        for card in cards { ScreenshotPreviewStack.shared.dismiss(id: card.id) }
                    }
                } catch { failures.append("\(item.name): \(error.localizedDescription)") }
            }
            ScreenshotHistoryStore.shared.removeTrashedItems(ids: removedIDs)
            self.selection.subtract(removedEntries)
            RecordingProjectStore.shared.reload()
            self.refresh()
            if !failures.isEmpty { self.errorMessage = failures.joined(separator: "\n\n") }
        }
    }

    func copyLink(_ item: CaptureLibraryItem) {
        guard let link = item.cloudURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    func upload(_ item: CaptureLibraryItem, options: CloudUploadOptions) {
        guard !isBusy else { return }
        run("Uploading…") {
            StudioProjectRegistry.shared.flushDrafts()
            if let session = item.session, item.historyIDs.isEmpty {
                _ = await ScreenshotHistoryStore.shared.importRecordingSession(session)
            }
            let id = item.historyIDs.first ?? ScreenshotHistoryStore.shared.items.first {
                $0.recordingSessionPath == item.session?.directoryURL.standardizedFileURL.path
            }?.id ?? UUID()
            let result = try await CloudUploader.shared.upload(itemID: id, fileURL: item.fileURL,
                title: options.trimmedTitleOrNil, socialEnabled: options.socialEnabled)
            ScreenshotHistoryStore.shared.setLibraryCloudURL(id: id, cloudURL: result.url)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.url, forType: .string)
            self.refresh()
        }
    }

    func deleteCloudCopy(_ item: CaptureLibraryItem) {
        guard let link = item.cloudURL, let uploadID = URL(string: link)?.lastPathComponent, !isBusy else { return }
        run("Deleting cloud copy…") {
            try await CloudUploader.shared.deleteFromCloud(uploadID: uploadID)
            for id in item.historyIDs { ScreenshotHistoryStore.shared.setLibraryCloudURL(id: id, cloudURL: nil) }
            self.refresh()
        }
    }

    private func export(_ items: [CaptureLibraryItem]) {
        let panel = NSOpenPanel()
        panel.title = "Export Captures"
        panel.message = "Choose a folder for \(items.count == 1 ? "this capture" : "these \(items.count) captures")."
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            self.run("Exporting…") {
                StudioProjectRegistry.shared.flushDrafts()
                var exported: [URL] = []
                var failures: [String] = []
                for item in items {
                    do {
                        let source = item.isVideo ? try await RecordingDeliverable.resolve(for: item.fileURL) : item.fileURL
                        let destination = try await Task.detached(priority: .userInitiated) {
                            try CaptureLibraryFiles.export(source, name: item.name, to: directory)
                        }.value
                        exported.append(destination)
                    } catch { failures.append("\(item.name): \(error.localizedDescription)") }
                }
                if !exported.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(exported) }
                if !failures.isEmpty { self.errorMessage = failures.joined(separator: "\n\n") }
                self.refresh()
            }
        }
    }

    private func run(_ title: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        operationTitle = title
        Task {
            defer { operationTitle = nil }
            do { try await operation() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

nonisolated enum CaptureLibraryFiles {
    static func export(_ source: URL, name: String, to directory: URL) throws -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let ext = source.pathExtension
        let stem = (safe as NSString).pathExtension.lowercased() == ext.lowercased()
            ? (safe as NSString).deletingPathExtension : safe
        let base = stem.isEmpty ? "Capture" : stem
        for suffix in 0..<10_000 {
            let name = suffix == 0 ? base : "\(base) \(suffix)"
            let destination = directory.appendingPathComponent(name).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func trash(_ item: CaptureLibraryItem) throws {
        var urls = [item.ownedURL]
        if item.session == nil && !item.isVideo {
            let url = item.fileURL
            let baseName = url.deletingPathExtension().lastPathComponent + ".base." + url.pathExtension
            urls += [url.appendingPathExtension("screendrop"), url.deletingLastPathComponent().appendingPathComponent(baseName)]
        }
        // Roll back earlier moves if any sidecar can't be moved. Keep the row
        // until every existing part of the capture is safely in Trash.
        var moved: [(URL, URL)] = []
        do {
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                var destination: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                if let destination { moved.append((url, destination as URL)) }
            }
        } catch {
            for (original, trashed) in moved.reversed() { try? FileManager.default.moveItem(at: trashed, to: original) }
            throw error
        }
    }
}

/// A Library action must not move a package out from under an editor that can
/// autosave into it. Reference counts also cover multiple windows for one file.
@MainActor
enum CaptureLibraryOpenEditors {
    private static var urls: [URL: Int] = [:]
    static func add(_ url: URL) { urls[url.standardizedFileURL, default: 0] += 1 }
    static func remove(_ url: URL) {
        let key = url.standardizedFileURL
        let count = (urls[key] ?? 0) - 1
        if count <= 0 { urls.removeValue(forKey: key) } else { urls[key] = count }
    }
    static func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return urls.keys.contains { $0.path == path || $0.path.hasPrefix(path + "/") }
    }
}

struct CaptureLibraryEditorRegistration: ViewModifier {
    let url: URL?
    @State private var registered: URL?
    func body(content: Content) -> some View {
        content
            .onAppear { update(url) }
            .onChange(of: url) { _, new in update(new) }
            .onDisappear { update(nil) }
    }
    private func update(_ new: URL?) {
        guard registered != new else { return }
        if let registered { CaptureLibraryOpenEditors.remove(registered) }
        registered = new
        if let new { CaptureLibraryOpenEditors.add(new) }
    }
}
