import AppKit
import Observation

nonisolated enum CaptureLibraryFilter: String, CaseIterable, Identifiable {
    case all, screenshots, recordings
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All Captures"
        case .screenshots: "Screenshots"
        case .recordings: "Recordings"
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .screenshots: "photo.on.rectangle"
        case .recordings: "video"
        }
    }
}

nonisolated enum CaptureLibrarySort: String, CaseIterable, Identifiable {
    case newest, oldest, name, modified
    var id: Self { self }
    var title: String {
        switch self {
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        case .name: "Name"
        case .modified: "Recently Modified"
        }
    }
}

nonisolated enum CaptureLibraryLayout: String, CaseIterable {
    case grid, list
}

/// Immutable, inexpensive row data. Resolving packages and reading file metadata
/// happens in the scanner, never in a cell's body or a selection update.
nonisolated struct CaptureLibraryItem: Identifiable, Equatable, Sendable {
    let id: String
    let historyIDs: Set<UUID>
    let name: String
    let fileURL: URL
    let session: RecordingSession?
    let createdAt: Date
    let modifiedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: Double?
    let isVideo: Bool
    let hasEdits: Bool
    let hasDraft: Bool
    let cloudURL: String?
    let thumbnailKey: String

    var ownedURL: URL { session?.directoryURL ?? fileURL }
    var dimensions: String {
        pixelWidth > 0 && pixelHeight > 0 ? "\(pixelWidth) × \(pixelHeight)" : "Unknown"
    }
    var kindTitle: String { session != nil ? "Recording Project" : isVideo ? "Video" : "Screenshot" }
    var subtitle: String {
        let date = createdAt.formatted(date: .abbreviated, time: .omitted)
        return isVideo ? "\(date) · \(durationText)" : "\(date) · \(dimensions)"
    }
    var durationText: String {
        guard let duration, duration.isFinite, duration >= 0 else { return "—" }
        let seconds = Int(min(duration.rounded(), Double(Int.max / 2)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

nonisolated struct CaptureLibraryHistorySnapshot: Sendable {
    let id: UUID
    let name: String
    let fileName: String
    let sessionPath: String?
    let createdAt: Date
    let modifiedAt: Date
    let width: Int
    let height: Int
    let duration: Double?
    let isVideo: Bool
    let hasEdits: Bool
    let cloudURL: String?

    @MainActor init(_ item: ScreenshotHistoryItem) {
        id = item.id
        name = item.displayName ?? item.fileName
        fileName = item.fileName
        sessionPath = item.recordingSessionPath
        createdAt = item.createdAt
        modifiedAt = item.updatedAt
        width = item.pixelWidth
        height = item.pixelHeight
        duration = item.duration
        isVideo = item.isVideo
        hasEdits = item.hasEdits
        cloudURL = item.cloudURL
    }
}

@MainActor
@Observable
final class CaptureLibraryModel {
    static let shared = CaptureLibraryModel()
    var filter: CaptureLibraryFilter? = .all { didSet { updateVisibleItems() } }
    var searchText = "" { didSet { scheduleSearch() } }
    var sortOrder: CaptureLibrarySort = .newest { didSet { updateVisibleItems() } }
    var selection: Set<String> = []
    private(set) var items: [CaptureLibraryItem] = []
    private(set) var visibleItems: [CaptureLibraryItem] = []
    private(set) var contentRevision = 0
    private(set) var screenshotCount = 0
    private(set) var isLoading = false
    var operationTitle: String?
    var errorMessage: String?
    var renamingItem: CaptureLibraryItem?
    var renameText = ""
    var pendingTrash: [CaptureLibraryItem] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var visibleIndices: [String: Int] = [:]
    @ObservationIgnored var openWindow: (() -> Void)?
    @ObservationIgnored private var pendingOpen = false

    private init() {}

    var selectedItems: [CaptureLibraryItem] {
        let _ = contentRevision
        return selection.compactMap { visibleIndices[$0] }.sorted().map { visibleItems[$0] }
    }
    var isBusy: Bool { operationTitle != nil }

    func show(filter: CaptureLibraryFilter? = nil) {
        if let filter {
            self.filter = filter
            searchText = ""
        }
        guard let openWindow else { pendingOpen = true; return }
        openWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func installOpener(_ opener: @escaping () -> Void) {
        openWindow = opener
        if pendingOpen {
            pendingOpen = false
            DispatchQueue.main.async { self.show() }
        }
    }

    func count(for filter: CaptureLibraryFilter) -> Int {
        switch filter {
        case .all: items.count
        case .screenshots: screenshotCount
        case .recordings: items.count - screenshotCount
        }
    }

    func refresh() {
        refreshTask?.cancel()
        let history = ScreenshotHistoryStore.shared.items.map(CaptureLibraryHistorySnapshot.init)
        let directory = ScreenshotHistoryStore.historyDirectory
        let activeSessionPath = ScreenRecordingManager.shared.activeSessionDirectoryURL?.standardizedFileURL.path
        isLoading = true
        refreshTask = Task {
            // Coalesce capture completion, project saves and window activation.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let scan = Task.detached(priority: .userInitiated) {
                CaptureLibraryScanner.scan(history: history, historyDirectory: directory, excludingSessionPath: activeSessionPath)
            }
            let result = await withTaskCancellationHandler {
                await scan.value
            } onCancel: { scan.cancel() }
            guard !Task.isCancelled else { return }
            items = result
            screenshotCount = result.lazy.filter { !$0.isVideo }.count
            updateVisibleItems()
            isLoading = false
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            updateVisibleItems()
        }
    }

    private func updateVisibleItems() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = filter ?? .all
        let visible = items.filter { item in
            let matchesKind = filter == .all || (filter == .recordings ? item.isVideo : !item.isVideo)
            return matchesKind && (query.isEmpty || item.name.localizedStandardContains(query)
                || item.fileURL.lastPathComponent.localizedStandardContains(query))
        }.sorted { lhs, rhs in
            switch sortOrder {
            case .newest where lhs.createdAt != rhs.createdAt: return lhs.createdAt > rhs.createdAt
            case .oldest where lhs.createdAt != rhs.createdAt: return lhs.createdAt < rhs.createdAt
            case .modified where lhs.modifiedAt != rhs.modifiedAt: return lhs.modifiedAt > rhs.modifiedAt
            case .name where lhs.name != rhs.name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            default: return lhs.id < rhs.id
            }
        }
        if visible != visibleItems {
            visibleItems = visible
            visibleIndices = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($0.element.id, $0.offset) })
            contentRevision &+= 1
        }
        selection.formIntersection(Set(visibleIndices.keys))
    }
}

nonisolated enum CaptureLibraryScanner {
    static func scan(history: [CaptureLibraryHistorySnapshot], historyDirectory: URL, excludingSessionPath: String?) -> [CaptureLibraryItem] {
        let grouped = Dictionary(grouping: history.filter { $0.sessionPath != nil }) {
            URL(fileURLWithPath: $0.sessionPath!, isDirectory: true).standardizedFileURL.path
        }
        var sessions = Dictionary(RecordingSessionStore.allSessions().map {
            ($0.directoryURL.standardizedFileURL.path, $0)
        }, uniquingKeysWith: { first, _ in first })
        for path in grouped.keys {
            let session = RecordingSession(directoryURL: URL(fileURLWithPath: path, isDirectory: true))
            if RecordingSession.isSessionDirectory(session.directoryURL) { sessions[path] = session }
        }
        var entries: [CaptureLibraryItem] = []
        for (path, session) in sessions {
            guard !Task.isCancelled else { return [] }
            guard path != excludingSessionPath else { continue }
            let manifest = session.loadCaptureManifest()
            let rows = grouped[path] ?? []
            let row = rows.first
            let createdAt = manifest?.createdAt ?? row?.createdAt
                ?? (try? session.directoryURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let fileURL = session.deliverableURL
            let modified = [session.editDocumentURL, session.draftDocumentURL, session.projectMetadataURL, fileURL]
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max() ?? row?.modifiedAt ?? createdAt
            entries.append(CaptureLibraryItem(
                id: "recording:\(path)", historyIDs: Set(rows.map(\.id)), name: session.displayName,
                fileURL: fileURL, session: session, createdAt: createdAt, modifiedAt: modified,
                pixelWidth: manifest?.pixelWidth ?? row?.width ?? 0, pixelHeight: manifest?.pixelHeight ?? row?.height ?? 0,
                duration: manifest?.duration ?? row?.duration,
                isVideo: true, hasEdits: session.hasSavedProject, hasDraft: session.hasUnsavedDraft,
                cloudURL: rows.compactMap(\.cloudURL).first,
                thumbnailKey: "\(fileURL.path):\(modified.timeIntervalSince1970)"
            ))
        }
        for row in history where row.sessionPath == nil {
            guard !Task.isCancelled else { return [] }
            let url = historyDirectory.appendingPathComponent(row.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? row.modifiedAt
            entries.append(CaptureLibraryItem(
                id: row.id.uuidString, historyIDs: [row.id], name: row.name, fileURL: url, session: nil,
                createdAt: row.createdAt, modifiedAt: max(modified, row.modifiedAt), pixelWidth: row.width,
                pixelHeight: row.height, duration: row.duration, isVideo: row.isVideo,
                hasEdits: row.hasEdits, hasDraft: false, cloudURL: row.cloudURL,
                thumbnailKey: "\(url.path):\(modified.timeIntervalSince1970)"
            ))
        }
        return entries
    }

    static func sizeOnDisk(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard !Task.isCancelled else { return total }
            let values = try? child.resourceValues(forKeys: keys)
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
