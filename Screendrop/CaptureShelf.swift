//
//  CaptureShelf.swift
//  Screendrop
//
//  The shelf of recent captures that floats at the edge of the screen after a
//  screenshot or recording. Cards enter and leave through the screen edge
//  they are docked to. Tucking the shelf slides every card out through that
//  same edge, leaving a slim handle in the middle of the edge, well away from
//  the bottom corner where editors keep their footers.
//
//  This model owns the cards and everything done to them. The panel, its
//  placement and input live in `CaptureShelfPresenter`; the views only read
//  this state and call back into it.
//

import AppKit
import Observation
import SwiftUI

enum PreviewMediaKind: String, Equatable, Codable {
    case image
    case video
}

/// Work a card is busy with. The card shows it in place of its actions.
enum ShelfActivity: Equatable {
    case compressing
    /// A recording being flattened into a shareable file before Save/Copy.
    case preparing
}

/// A short-lived result shown over a card, then cleared.
enum ShelfFlash: Equatable {
    case linkCopied
    case uploadFailed
    case compressed(summary: String)
}

struct ShelfItem: Identifiable {
    let id = UUID()
    var url: URL
    var thumbnail: NSImage
    var kind: PreviewMediaKind = .image
    /// Where the capture was saved on the user's disk, if anywhere. Without
    /// one it lives only in the temporary directory.
    var savedURL: URL?
    var activity: ShelfActivity?
    var flash: ShelfFlash?
    /// Opened, previewed or worked on. Engaged cards never auto-close.
    var isEngaged = false
}

@MainActor
@Observable
final class CaptureShelf {
    static let shared = CaptureShelf()

    /// Why the shelf is tucked. It shows again only once every reason is
    /// gone, so closing Quick Look can't pop it open over an editor.
    enum TuckReason: Hashable {
        /// Tucked by hand, from the header or with a swipe.
        case user
        /// An editor opened from a card is on screen.
        case editor
    }

    /// Newest first.
    private(set) var items: [ShelfItem] = []
    private(set) var tuckReasons: Set<TuckReason> = []
    var hoveredID: ShelfItem.ID?
    private(set) var draggingID: ShelfItem.ID?
    /// True while cards slide in, out, or along the column. Cards hold
    /// their hover state until it settles: a card sliding under a resting
    /// pointer would otherwise flash its controls on and off.
    private(set) var isMoving = false

    /// The most cards the screen fits, set by the view as it lays out.
    @ObservationIgnored var capacity = 6 {
        didSet { trimToCapacity() }
    }

    @ObservationIgnored private var autoCloseTasks: [ShelfItem.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var flashTasks: [ShelfItem.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var compressionTasks: [ShelfItem.ID: Task<Void, Never>] = [:]

    private init() {}

    var isTucked: Bool { !tuckReasons.isEmpty }

    var hoveredItem: ShelfItem? {
        hoveredID.flatMap(item(id:))
    }

    /// Captures that exist only in the temporary directory and are lost
    /// when the app quits.
    var unsavedItems: [ShelfItem] {
        items.filter { $0.savedURL == nil }
    }

    func item(id: ShelfItem.ID) -> ShelfItem? {
        items.first { $0.id == id }
    }

    // MARK: - Tucking

    func tuck(_ reason: TuckReason) {
        guard !tuckReasons.contains(reason) else { return }
        noteMotion()
        withAnimation(Self.slideIfAllowed) {
            _ = tuckReasons.insert(reason)
            hoveredID = nil
        }
    }

    func untuck(_ reason: TuckReason) {
        guard tuckReasons.contains(reason) else { return }
        noteMotion()
        withAnimation(Self.slideIfAllowed) {
            _ = tuckReasons.remove(reason)
        }
    }

    /// Brings the shelf out whatever tucked it: the user asked for it.
    func open() {
        guard isTucked else { return }
        noteMotion()
        withAnimation(Self.slideIfAllowed) {
            tuckReasons.removeAll()
        }
    }

    // MARK: - Adding

    /// A fresh screenshot. Runs the after-capture actions whether or not the
    /// shelf is set to show it.
    func add(url: URL) {
        let showsCard = AfterCaptureActions.isEnabled(.showOverlay, for: .screenshot)
        let savedURL = AfterCaptureActions.isEnabled(.save, for: .screenshot)
            ? saveToDefaultLocation(from: url)
            : nil

        guard showsCard,
              let thumbnail = ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: Self.thumbnailPixelSize)
        else {
            runAfterCaptureActions(type: .screenshot, url: url, itemID: nil)
            return
        }

        let item = ShelfItem(url: url, thumbnail: thumbnail, savedURL: savedURL)
        insert(item)
        runAfterCaptureActions(type: .screenshot, url: url, itemID: item.id)
        scheduleAutoClose(id: item.id)
    }

    /// A finished recording. The card shows at once; saving and the real
    /// thumbnail land when they are ready.
    func addVideo(url: URL) {
        guard AfterCaptureActions.isEnabled(.showOverlay, for: .recording) else {
            if AfterCaptureActions.isEnabled(.save, for: .recording) {
                Task { _ = await saveVideoToDefaultLocation(from: url, itemID: nil) }
            }
            runAfterCaptureActions(type: .recording, url: url, itemID: nil)
            return
        }

        let item = ShelfItem(url: url, thumbnail: VideoPreviewImageLoader.placeholderImage(), kind: .video)
        let id = item.id
        insert(item)
        loadVideoThumbnail(for: id, from: url)
        runAfterCaptureActions(type: .recording, url: url, itemID: id)
        scheduleAutoClose(id: id)

        if AfterCaptureActions.isEnabled(.save, for: .recording) {
            Task {
                let savedURL = await saveVideoToDefaultLocation(from: url, itemID: id)
                update(id) { $0.savedURL = savedURL }
            }
        }
    }

    /// Brings back a capture from history, from the menu bar's recents. It
    /// moves to the front if it is already on the shelf.
    func show(existing url: URL, kind: PreviewMediaKind) {
        if let index = items.firstIndex(where: { $0.url == url && $0.kind == kind }) {
            noteMotion()
        withAnimation(Self.slideIfAllowed) {
                let item = items.remove(at: index)
                items.insert(item, at: 0)
                tuckReasons.removeAll()
            }
            return
        }

        switch kind {
        case .image:
            guard let thumbnail = ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: Self.thumbnailPixelSize) else { return }
            insert(ShelfItem(url: url, thumbnail: thumbnail))
        case .video:
            let item = ShelfItem(url: url, thumbnail: VideoPreviewImageLoader.placeholderImage(), kind: .video)
            insert(item)
            loadVideoThumbnail(for: item.id, from: url)
        }
    }

    /// Swaps in an annotated version of a screenshot, then keeps the
    /// clipboard and any saved copy in step with it. A screenshot that isn't
    /// on the shelf gets a card only when `addsIfMissing` (finishing an
    /// edit); a mid-edit save must not drop a card, and with it the whole
    /// shelf, over the editor. Returns whether the capture was on the shelf.
    @discardableResult
    func applyAnnotation(originalURL: URL, historyURL: URL, addsIfMissing: Bool = false) -> Bool {
        if let existing = items.first(where: { $0.url == originalURL }) {
            guard let thumbnail = ScreenshotImageLoader.downsampledImage(at: historyURL, maxPixelSize: Self.thumbnailPixelSize) else {
                return true
            }
            CloudUploader.shared.clearUploadState(for: existing.id)
            update(existing.id) {
                $0.url = historyURL
                $0.thumbnail = thumbnail
            }
            republish(existing.id)
            return true
        }

        guard addsIfMissing,
              let thumbnail = ScreenshotImageLoader.downsampledImage(at: historyURL, maxPixelSize: Self.thumbnailPixelSize)
        else {
            if ScreendropPreferences.autoCopy {
                _ = copyImageToClipboard(historyURL)
            }
            return false
        }
        let item = ShelfItem(url: historyURL, thumbnail: thumbnail)
        insert(item)
        republish(item.id)
        return false
    }

    // MARK: - Removing

    func dismiss(id: ShelfItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if QuickLookPreviewPresenter.currentURL == items[index].url {
            QuickLookPreviewPresenter.dismiss()
        }
        cancelTasks(for: id)

        noteMotion()
        withAnimation(Self.slideIfAllowed) {
            items.remove(at: index)
            if hoveredID == id { hoveredID = nil }
            if draggingID == id { draggingID = nil }
            if items.isEmpty { tuckReasons.removeAll() }
        } completion: {
            CaptureShelfPresenter.shared.closeIfEmpty()
        }
    }

    func dismissAll() {
        QuickLookPreviewPresenter.dismiss()
        for id in items.map(\.id) { cancelTasks(for: id) }

        noteMotion()
        withAnimation(Self.slideIfAllowed) {
            items.removeAll()
            tuckReasons.removeAll()
            hoveredID = nil
            draggingID = nil
        } completion: {
            CaptureShelfPresenter.shared.closeIfEmpty()
        }
    }

    /// Removes the cards for one recording, whichever file of its package
    /// they point at. Library keeps the recording itself.
    func dismissVideo(for url: URL) {
        if RecordingSession.isSessionDirectory(url) {
            dismissRecordingSession(url)
        } else if let session = RecordingDeliverable.session(for: url) {
            dismissRecordingSession(session.directoryURL)
        } else {
            let standardizedURL = url.standardizedFileURL
            for item in items where item.kind == .video && item.url.standardizedFileURL == standardizedURL {
                dismiss(id: item.id)
            }
        }
    }

    func dismissRecordingSession(_ directoryURL: URL) {
        let packagePath = directoryURL.standardizedFileURL.path
        // The trailing separator keeps a sibling package with a longer name
        // from matching.
        let prefix = packagePath.hasSuffix("/") ? packagePath : packagePath + "/"
        for item in items where item.kind == .video && item.url.standardizedFileURL.path.hasPrefix(prefix) {
            dismiss(id: item.id)
        }
    }

    // MARK: - Hover and drag

    func setHovered(_ id: ShelfItem.ID, _ isHovered: Bool) {
        if isHovered {
            hoveredID = id
        } else if hoveredID == id {
            hoveredID = nil
        }
    }

    func beginDrag(id: ShelfItem.ID) {
        QuickLookPreviewPresenter.dismiss()
        draggingID = id
    }

    func endDrag(id: ShelfItem.ID) {
        if ScreendropPreferences.previewCloseAfterDragging {
            dismiss(id: id)
        } else {
            withAnimation(.morphQuickIfAllowed) { draggingID = nil }
        }
    }

    // MARK: - Actions

    func openEditor(id: ShelfItem.ID) {
        guard let item = item(id: id) else { return }
        engage(id)
        QuickLookPreviewPresenter.dismiss()
        switch item.kind {
        case .image: CaptureShelfPresenter.shared.onAnnotate?(item.url)
        case .video: CaptureShelfPresenter.shared.onEditVideo?(item.url)
        }
    }

    func quickLook(id: ShelfItem.ID) {
        guard let item = item(id: id) else { return }
        engage(id)
        QuickLookPreviewPresenter.show(url: item.url)
    }

    func copy(id: ShelfItem.ID) {
        guard let item = item(id: id) else { return }
        switch item.kind {
        case .image:
            guard copyImageToClipboard(item.url) else { return }
            dismiss(id: id)
        case .video:
            // Flattening can take a moment, so the card stays up showing
            // progress and leaves once the copy has happened.
            Task {
                guard await copyVideoToClipboard(item.url, itemID: id) else { return }
                dismiss(id: id)
            }
        }
    }

    func pin(id: ShelfItem.ID) {
        guard let item = item(id: id), item.kind == .image else { return }
        QuickLookPreviewPresenter.dismiss()
        PinnedScreenshotPresenter.shared.pin(url: item.url)
        dismiss(id: id)
    }

    /// Whether an editor has this capture open. It can't be deleted then,
    /// or the editor would be left saving into a file that is gone.
    func isOpenInEditor(id: ShelfItem.ID) -> Bool {
        guard let item = item(id: id) else { return false }
        return CaptureLibraryOpenEditors.isEditing(item.url)
    }

    func delete(id: ShelfItem.ID) {
        guard let item = item(id: id), !isOpenInEditor(id: id) else { return }
        if !ScreenshotHistoryStore.shared.delete(url: item.url) {
            deleteFile(at: item.url)
        }
        if let savedURL = item.savedURL, savedURL != item.url {
            deleteFile(at: savedURL)
        }
        dismiss(id: id)
    }

    /// Recognizes the text in a screenshot and copies it.
    func copyText(id: ShelfItem.ID) {
        guard let item = item(id: id), item.kind == .image else { return }
        let url = item.url
        Task {
            let text = await ImageTextRecognizer.recognizeText(at: url)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func upload(id: ShelfItem.ID) {
        guard let item = item(id: id), CloudUploader.shared.isConfigured else { return }
        if item.kind == .video { engage(id) }
        let url = item.url
        Task {
            do {
                // The card can leave on its own, so it is no anchor for a
                // popover: the remembered default stands in for asking.
                let result = try await CloudUploader.shared.upload(
                    itemID: id,
                    fileURL: url,
                    socialEnabled: CloudUploadPreferences.lastSocialEnabled
                )
                copyString(result.url)
                ScreenshotHistoryStore.shared.setCloudURL(for: url, cloudURL: result.url)
                flash(.linkCopied, on: id)
            } catch is CancellationError {
                return
            } catch {
                CloudUploader.shared.clearFailed(for: id)
                flash(.uploadFailed, on: id)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "The capture could not be uploaded"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    func copyLink(id: ShelfItem.ID) {
        guard let link = CloudUploader.shared.uploadedURLs[id] else { return }
        copyString(link)
        flash(.linkCopied, on: id)
    }

    func save(id: ShelfItem.ID, choosingLocation: Bool = false) {
        guard let item = item(id: id) else { return }
        // A save dialog, a cancel or a failure must not expire the card.
        engage(id)

        if !choosingLocation && ScreendropPreferences.saveButtonUsesConfiguredFolder {
            guard item.savedURL == nil else {
                dismiss(id: id)
                return
            }
            switch item.kind {
            case .video:
                Task {
                    guard let savedURL = await saveVideoToDefaultLocation(from: item.url, itemID: id) else { return }
                    update(id) { $0.savedURL = savedURL }
                    dismiss(id: id)
                }
            case .image:
                do {
                    let savedURL = try ScreenshotFileActions.saveToDefaultLocation(from: item.url)
                    update(id) { $0.savedURL = savedURL }
                    dismiss(id: id)
                } catch {
                    presentSaveFailure(error, id: id)
                }
            }
            return
        }

        let panel = NSSavePanel()
        // Recordings offer every container; the panel's format popup picks
        // one and `VideoFileActions.save` converts to it.
        panel.allowedContentTypes = item.kind == .video
            ? VideoExportContainer.allCases.map(\.contentType)
            : [ScreenshotFileActions.exportContentType]
        panel.nameFieldStringValue = item.kind == .video
            ? VideoFileActions.exportFileName(for: item.url)
            : ScreenshotFileActions.exportFileName(for: item.url)
        panel.canCreateDirectories = true
        panel.title = item.kind == .video ? "Save Recording" : "Save Screenshot"

        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                do {
                    if item.kind == .video {
                        let deliverable = try await self.prepareDeliverable(from: item.url, itemID: id)
                        try await VideoFileActions.save(from: deliverable, to: destination)
                    } else {
                        try ScreenshotFileActions.save(from: item.url, to: destination)
                    }
                    self.update(id) { $0.savedURL = destination }
                    self.dismiss(id: id)
                } catch {
                    FailureAlert.present(message: "The capture could not be saved", error: error)
                }
            }
        }
    }

    /// Copies a smaller JPG and adds it to the shelf beside the original.
    func compress(id: ShelfItem.ID) {
        guard let item = item(id: id), item.kind == .image, item.activity == nil else { return }
        engage(id)
        QuickLookPreviewPresenter.dismiss()
        update(id) { $0.activity = .compressing }

        let sourceURL = item.url
        let quality = ScreenshotCompressionService.defaultJPEGQuality
        compressionTasks[id] = Task {
            defer {
                compressionTasks[id] = nil
                update(id) { $0.activity = nil }
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ScreenshotCompressionService.compressToTemporaryJPEG(sourceURL: sourceURL, quality: quality)
                }.value
                try Task.checkCancellation()
                insertCompressed(result, beside: id)
            } catch is CancellationError {
                return
            } catch {
                print("Failed to compress screenshot: \(error)")
            }
        }
    }

    // MARK: - Internals

    /// How cards travel through the screen edge: smooth, with no overshoot.
    /// The app's bouncy `morph` would carry them past their dock and back.
    static let slide = Animation.smooth(duration: 0.38)

    static var slideIfAllowed: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : slide
    }

    @ObservationIgnored private var motionEndTask: Task<Void, Never>?

    /// Marks the shelf as moving until the slide has had time to finish.
    func noteMotion() {
        isMoving = true
        motionEndTask?.cancel()
        motionEndTask = Task {
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            isMoving = false
        }
    }

    /// Long edge of a card's thumbnail, in pixels.
    private static let thumbnailPixelSize: CGFloat = 520

    private func insert(_ item: ShelfItem, at index: Int = 0) {
        QuickLookPreviewPresenter.dismiss()
        makeRoom(keeping: items.indices.contains(index) ? items[index].id : nil)
        noteMotion()
        withAnimation(Self.slideIfAllowed) {
            items.insert(item, at: min(index, items.count))
            // A new capture always shows, even over an editor.
            tuckReasons.removeAll()
        }
    }

    /// Drops the oldest idle cards so one more fits on screen.
    private func makeRoom(keeping keptID: ShelfItem.ID?) {
        let overflow = items.count + 1 - capacity
        guard overflow > 0 else { return }
        let removable = items.reversed().filter { $0.id != keptID }.prefix(overflow)
        for item in removable { dismiss(id: item.id) }
    }

    private func trimToCapacity() {
        let overflow = items.count - capacity
        guard overflow > 0 else { return }
        for item in items.suffix(overflow) { dismiss(id: item.id) }
    }

    private func update(_ id: ShelfItem.ID, _ change: (inout ShelfItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func engage(_ id: ShelfItem.ID) {
        update(id) { $0.isEngaged = true }
        autoCloseTasks[id]?.cancel()
        autoCloseTasks[id] = nil
    }

    private func flash(_ flash: ShelfFlash, on id: ShelfItem.ID) {
        withAnimation(.morphQuickIfAllowed) { update(id) { $0.flash = flash } }
        flashTasks[id]?.cancel()
        flashTasks[id] = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.morphQuickIfAllowed) { update(id) { $0.flash = nil } }
            flashTasks[id] = nil
        }
    }

    private func cancelTasks(for id: ShelfItem.ID) {
        autoCloseTasks.removeValue(forKey: id)?.cancel()
        flashTasks.removeValue(forKey: id)?.cancel()
        compressionTasks.removeValue(forKey: id)?.cancel()
    }

    private func scheduleAutoClose(id: ShelfItem.ID, after delay: Duration? = nil) {
        let seconds = ScreendropPreferences.previewAutoCloseSeconds
        guard seconds > 0 else { return }
        autoCloseTasks[id]?.cancel()
        autoCloseTasks[id] = Task {
            try? await Task.sleep(for: delay ?? .seconds(seconds))
            guard !Task.isCancelled else { return }
            autoCloseIfIdle(id: id)
        }
    }

    /// Closes a card whose time is up, unless someone is using it; then it
    /// checks again shortly.
    private func autoCloseIfIdle(id: ShelfItem.ID) {
        guard let item = item(id: id), !item.isEngaged else { return }
        let isBusy = hoveredID == id
            || draggingID == id
            || item.activity != nil
            || CloudUploader.shared.uploadingItems.contains(id)
            || QuickLookPreviewPresenter.isShown
        if isBusy {
            scheduleAutoClose(id: id, after: .seconds(2))
        } else {
            dismiss(id: id)
        }
    }

    private func loadVideoThumbnail(for id: ShelfItem.ID, from url: URL) {
        Task {
            guard let thumbnail = await VideoPreviewImageLoader.thumbnail(at: url, maxPixelSize: Self.thumbnailPixelSize) else { return }
            update(id) { $0.thumbnail = thumbnail }
        }
    }

    private func insertCompressed(_ result: ScreenshotCompressionResult, beside sourceID: ShelfItem.ID) {
        guard let thumbnail = ScreenshotImageLoader.downsampledImage(at: result.outputURL, maxPixelSize: Self.thumbnailPixelSize) else { return }
        let item = ShelfItem(url: result.outputURL, thumbnail: thumbnail)
        insert(item, at: items.firstIndex { $0.id == sourceID } ?? 0)
        flash(.compressed(summary: result.displaySummary), on: item.id)
    }

    /// Runs the after-capture actions other than Save, which the caller does
    /// so it can keep the saved URL on the card.
    private func runAfterCaptureActions(type: AfterCaptureType, url: URL, itemID: ShelfItem.ID?) {
        if AfterCaptureActions.isEnabled(.copy, for: type) {
            switch type {
            case .screenshot: _ = copyImageToClipboard(url)
            case .recording: Task { _ = await copyVideoToClipboard(url, itemID: itemID) }
            }
        }

        if AfterCaptureActions.isEnabled(.upload, for: type) {
            if let itemID {
                upload(id: itemID)
            } else {
                uploadUnattended(url)
            }
        }

        switch type {
        case .screenshot:
            if AfterCaptureActions.isEnabled(.annotate, for: type) {
                if let itemID { engage(itemID) }
                CaptureShelfPresenter.shared.onAnnotate?(url)
            }
            if AfterCaptureActions.isEnabled(.pin, for: type) {
                PinnedScreenshotPresenter.shared.pin(url: url)
            }
        case .recording:
            if AfterCaptureActions.isEnabled(.openVideoEditor, for: type) {
                if let itemID { engage(itemID) }
                CaptureShelfPresenter.shared.onEditVideo?(url)
            }
        }
    }

    /// Uploads a capture that has no card to show the result on.
    private func uploadUnattended(_ url: URL) {
        guard CloudUploader.shared.isConfigured else { return }
        Task {
            do {
                let result = try await CloudUploader.shared.upload(
                    itemID: UUID(),
                    fileURL: url,
                    socialEnabled: CloudUploadPreferences.lastSocialEnabled
                )
                copyString(result.url)
                ScreenshotHistoryStore.shared.setCloudURL(for: url, cloudURL: result.url)
            } catch {
                print("Auto cloud upload failed: \(error)")
            }
        }
    }

    /// After an edit: overwrites an earlier saved copy in place (or saves a
    /// first one when Auto Save is on) and re-copies when Auto Copy is on, so
    /// no stale version is left anywhere.
    private func republish(_ id: ShelfItem.ID) {
        guard let item = item(id: id) else { return }
        if let savedURL = item.savedURL {
            do {
                try ScreenshotFileActions.replaceExistingExport(from: item.url, at: savedURL)
            } catch {
                print("Failed to update saved screenshot: \(error)")
            }
        } else if ScreendropPreferences.autoSave {
            let savedURL = saveToDefaultLocation(from: item.url)
            update(id) { $0.savedURL = savedURL }
        }

        if ScreendropPreferences.autoCopy {
            _ = copyImageToClipboard(item.url)
        }
    }

    private func presentSaveFailure(_ error: Error, id: ShelfItem.ID) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The screenshot could not be saved"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Choose Another Location…")
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[2].keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(id: id, choosingLocation: true)
        case .alertSecondButtonReturn: save(id: id)
        default: break
        }
    }

    private func copyString(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func copyImageToClipboard(_ url: URL) -> Bool {
        do {
            try ScreenshotFileActions.copyImageToClipboard(from: url)
            return true
        } catch {
            print("Failed to copy screenshot: \(error)")
            return false
        }
    }

    private func saveToDefaultLocation(from url: URL) -> URL? {
        do {
            return try ScreenshotFileActions.saveToDefaultLocation(from: url)
        } catch {
            print("Failed to auto save: \(error)")
            return nil
        }
    }

    private func deleteFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("Failed to delete capture: \(error)")
        }
    }

    // MARK: Recordings

    /// Copying and saving hand the user a file, so both resolve the
    /// session's deliverable first: the raw screen master has no cursor.
    private func copyVideoToClipboard(_ url: URL, itemID: ShelfItem.ID?) async -> Bool {
        do {
            let deliverable = try await prepareDeliverable(from: url, itemID: itemID)
            try VideoFileActions.copyToClipboard(from: deliverable)
            return true
        } catch {
            presentRecordingFailure("The recording could not be copied", error: error)
            return false
        }
    }

    private func saveVideoToDefaultLocation(from url: URL, itemID: ShelfItem.ID?) async -> URL? {
        do {
            let deliverable = try await prepareDeliverable(from: url, itemID: itemID)
            return try await VideoFileActions.saveToDefaultLocation(from: deliverable)
        } catch {
            presentRecordingFailure("The recording could not be saved", error: error)
            return nil
        }
    }

    /// Flattens the session behind `url`, showing the card's progress while
    /// a render is actually needed.
    private func prepareDeliverable(from url: URL, itemID: ShelfItem.ID?) async throws -> URL {
        guard RecordingDeliverable.needsRender(for: url), let itemID else {
            return try await RecordingDeliverable.resolve(for: url)
        }
        // A long render must not race the auto-close timer out from under
        // the progress it shows.
        engage(itemID)
        update(itemID) { $0.activity = .preparing }
        defer { update(itemID) { $0.activity = nil } }
        return try await RecordingDeliverable.resolve(for: url)
    }

    private func presentRecordingFailure(_ message: String, error: Error) {
        FailureAlert.present(message: message, error: error, detail: "Your recording is safe in its project.")
    }
}
