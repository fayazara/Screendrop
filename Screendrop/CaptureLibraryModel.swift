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

/// What the sidebar has selected: a kind of capture, a smart category, or
/// the app captures came from (by `CaptureSource.appKey`).
nonisolated enum CaptureLibraryScope: Hashable, Sendable {
    case kind(CaptureLibraryFilter)
    case category(CaptureCategory)
    case app(String)
}

/// One row of the sidebar's Apps section.
nonisolated struct CaptureLibraryAppFacet: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let count: Int
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
    let source: CaptureSource?
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
    let source: CaptureSource?

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
        source = item.source
    }
}

@MainActor
@Observable
final class CaptureLibraryModel {
    static let shared = CaptureLibraryModel()
    var scope: CaptureLibraryScope? = .kind(.all) { didSet { if scope != oldValue { updateVisibleItems() } } }
    var searchText = "" { didSet { scheduleSearch() } }
    var sortOrder: CaptureLibrarySort = .newest { didSet { updateVisibleItems() } }
    var selection: Set<String> = []
    private(set) var items: [CaptureLibraryItem] = []
    private(set) var visibleItems: [CaptureLibraryItem] = []
    private(set) var contentRevision = 0
    private(set) var screenshotCount = 0
    private(set) var categoryFacets: [(category: CaptureCategory, count: Int)] = []
    private(set) var appFacets: [CaptureLibraryAppFacet] = []
    /// The folded words of the active search, for highlighting text matches.
    private(set) var searchTokens: [String] = []
    private(set) var isLoading = false
    var operationTitle: String?
    var errorMessage: String?
    var renamingItem: CaptureLibraryItem?
    var renameText = ""
    var pendingTrash: [CaptureLibraryItem] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var visibleIndices: [String: Int] = [:]
    @ObservationIgnored private var itemsByID: [String: CaptureLibraryItem] = [:]
    /// Folded search text per capture, rebuilt off the main actor for the
    /// captures whose metadata or analysis changed.
    @ObservationIgnored private var corpus: [String: String] = [:]
    @ObservationIgnored private var corpusItems: [String: CaptureLibraryItem] = [:]
    @ObservationIgnored private var corpusTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCorpusIDs: Set<String> = []
    @ObservationIgnored var openWindow: (() -> Void)?
    @ObservationIgnored private var pendingOpen = false
    @ObservationIgnored private var isWindowOpen = false

    private init() {}

    var selectedItems: [CaptureLibraryItem] {
        let _ = contentRevision
        return selection.compactMap { visibleIndices[$0] }.sorted().map { visibleItems[$0] }
    }
    var isBusy: Bool { operationTitle != nil }

    func item(id: String) -> CaptureLibraryItem? { itemsByID[id] }

    /// Selects a capture, widening the browser first if the current scope
    /// or search hides it.
    func reveal(_ id: String) {
        guard itemsByID[id] != nil else { return }
        if visibleIndices[id] == nil {
            searchText = ""
            scope = .kind(.all)
            updateVisibleItems()
        }
        selection = [id]
    }

    func show(filter: CaptureLibraryFilter? = nil) {
        if let filter {
            scope = .kind(filter)
            searchText = ""
        }
        guard let openWindow else { pendingOpen = true; return }
        openWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Search text is only kept in memory while the Library is open.
    func windowDidOpen() {
        isWindowOpen = true
        CaptureLibraryIndex.shared.libraryDidOpen()
    }

    func windowDidClose() {
        isWindowOpen = false
        corpusTask?.cancel()
        corpus = [:]
        corpusItems = [:]
        pendingCorpusIDs = []
        CaptureLibraryIndex.shared.libraryDidClose()
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
            itemsByID = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            screenshotCount = result.lazy.filter { !$0.isVideo }.count
            updateFacets()
            updateVisibleItems()
            rebuildCorpus(changed: [])
            isLoading = false
            CaptureLibraryIndex.shared.sync(result)
        }
    }

    /// Called by the index after it publishes a batch of analyses.
    func indexDidChange(changed: Set<String>) {
        updateFacets()
        rebuildCorpus(changed: changed)
        if case .category = scope { updateVisibleItems() }
    }

    /// Re-folds search text for captures that are new, changed, or newly
    /// analyzed; everything else keeps its cached text.
    private func rebuildCorpus(changed: Set<String>) {
        // Opening the Library loads the index, which rebuilds it all.
        guard isWindowOpen, CaptureLibraryIndex.shared.isLoaded else { return }
        pendingCorpusIDs.formUnion(changed)
        corpusTask?.cancel()
        let analyses = CaptureLibraryIndex.shared.analyses
        let live = Set(items.map(\.id))
        let stale = items.filter { corpusItems[$0.id] != $0 || corpus[$0.id] == nil || pendingCorpusIDs.contains($0.id) }
        guard !stale.isEmpty || corpus.count != live.count else { return }
        corpusTask = Task {
            let built = await Task.detached(priority: .utility) {
                stale.map { ($0.id, CaptureLibrarySearch.document(for: $0, analysis: analyses[$0.id])) }
            }.value
            guard !Task.isCancelled else { return }
            corpus = corpus.filter { live.contains($0.key) }
            corpusItems = corpusItems.filter { live.contains($0.key) }
            for (item, entry) in zip(stale, built) {
                corpus[entry.0] = entry.1
                corpusItems[item.id] = item
            }
            pendingCorpusIDs.subtract(stale.map(\.id))
            if !searchText.isEmpty { updateVisibleItems() }
        }
    }

    /// Sidebar counts. Categories are listed by size with Other last; apps
    /// by size, then name.
    private func updateFacets() {
        let index = CaptureLibraryIndex.shared
        let analyses = index.analyses
        var categories: [CaptureCategory: Int] = [:]
        var apps: [String: (source: CaptureSource, count: Int)] = [:]
        for item in items {
            if let category = analyses[item.id]?.category { categories[category, default: 0] += 1 }
            if let source = item.source {
                apps[source.appKey, default: (source, 0)].count += 1
            }
        }
        let sortedCategories = categories.map { (category: $0.key, count: $0.value) }.sorted {
            if ($0.category == .other) != ($1.category == .other) { return $1.category == .other }
            return $0.count != $1.count ? $0.count > $1.count : $0.category.title < $1.category.title
        }
        // No categories are known until the index has loaded.
        if index.isLoaded, !sortedCategories.elementsEqual(categoryFacets, by: { $0 == $1 }) { categoryFacets = sortedCategories }
        let sortedApps = apps.map {
            CaptureLibraryAppFacet(id: $0.key, name: $0.value.source.appName,
                                   bundleIdentifier: $0.value.source.bundleIdentifier, count: $0.value.count)
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if sortedApps != appFacets { appFacets = sortedApps }
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
        searchTask?.cancel()
        let tokens = CaptureLibrarySearch.tokens(searchText)
        let analyses = CaptureLibraryIndex.shared.analyses
        let scoped = items.filter { item in
            switch scope ?? .kind(.all) {
            case .kind(let filter): filter == .all || (filter == .recordings ? item.isVideo : !item.isVideo)
            case .category(let category): analyses[item.id]?.category == category
            case .app(let key): item.source?.appKey == key
            }
        }
        guard !tokens.isEmpty else { return apply(scoped, tokens: tokens) }
        let corpus = corpus
        searchTask = Task {
            let matches = await Task.detached(priority: .userInitiated) {
                scoped.filter { item in
                    let text = corpus[item.id] ?? CaptureLibrarySearch.document(for: item, analysis: analyses[item.id])
                    return tokens.allSatisfy(text.contains)
                }
            }.value
            guard !Task.isCancelled else { return }
            apply(matches, tokens: tokens)
        }
    }

    private func apply(_ matches: [CaptureLibraryItem], tokens: [String]) {
        let visible = matches.sorted { lhs, rhs in
            switch sortOrder {
            case .newest where lhs.createdAt != rhs.createdAt: return lhs.createdAt > rhs.createdAt
            case .oldest where lhs.createdAt != rhs.createdAt: return lhs.createdAt < rhs.createdAt
            case .modified where lhs.modifiedAt != rhs.modifiedAt: return lhs.modifiedAt > rhs.modifiedAt
            case .name where lhs.name != rhs.name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            default: return lhs.id < rhs.id
            }
        }
        if visible != visibleItems || tokens != searchTokens {
            searchTokens = tokens
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
                .compactMap(modificationDate(of:))
                .max() ?? row?.modifiedAt ?? createdAt
            entries.append(CaptureLibraryItem(
                id: "recording:\(path)", historyIDs: Set(rows.map(\.id)), name: session.displayName,
                fileURL: fileURL, session: session, createdAt: createdAt, modifiedAt: modified,
                pixelWidth: manifest?.pixelWidth ?? row?.width ?? 0, pixelHeight: manifest?.pixelHeight ?? row?.height ?? 0,
                duration: manifest?.duration ?? row?.duration,
                isVideo: true, hasEdits: session.hasSavedProject, hasDraft: session.hasUnsavedDraft,
                cloudURL: rows.compactMap(\.cloudURL).first,
                source: manifest?.source ?? rows.compactMap(\.source).first,
                thumbnailKey: "\(fileURL.path):\(modified.timeIntervalSince1970)"
            ))
        }
        for row in history where row.sessionPath == nil {
            guard !Task.isCancelled else { return [] }
            let url = historyDirectory.appendingPathComponent(row.fileName)
            guard let modified = modificationDate(of: url) else { continue }
            entries.append(CaptureLibraryItem(
                id: row.id.uuidString, historyIDs: [row.id], name: row.name, fileURL: url, session: nil,
                createdAt: row.createdAt, modifiedAt: max(modified, row.modifiedAt), pixelWidth: row.width,
                pixelHeight: row.height, duration: row.duration, isVideo: row.isVideo,
                hasEdits: row.hasEdits, hasDraft: false, cloudURL: row.cloudURL, source: row.source,
                thumbnailKey: "\(url.path):\(modified.timeIntervalSince1970)"
            ))
        }
        return entries
    }

    /// The file's modification date, or nil when it's missing. Resource
    /// values would stay cached on the URL, which every item keeps; `stat`
    /// leaves nothing behind. The date is made as Foundation makes it, so
    /// thumbnail keys, and the index entries keyed by them, don't change.
    private static func modificationDate(of url: URL) -> Date? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: Double(info.st_mtimespec.tv_sec)
            - Date.timeIntervalBetween1970AndReferenceDate + 1.0e-9 * Double(info.st_mtimespec.tv_nsec))
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
