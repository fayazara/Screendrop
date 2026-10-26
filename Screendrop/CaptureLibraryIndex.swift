//
//  CaptureLibraryIndex.swift
//  Screendrop
//

import AppKit
import CryptoKit
import Observation
import Vision

/// Keeps an analysis for every capture: the text inside it, a category and
/// a feature print for similarity. Work runs one capture at a time at
/// background priority and pauses while recording, in Low Power Mode, or
/// when the Mac runs hot. It runs in two passes, newest first: every capture
/// is read (quick) before any is sorted by the model (slow), so search works
/// across the whole Library within minutes. Captures made before the feature
/// arrived are sorted only once the user opts in. Results land in small
/// batches so the Library re-filters a few times a second at most.
@MainActor
@Observable
final class CaptureLibraryIndex {
    static let shared = CaptureLibraryIndex()

    private(set) var analyses: [String: CaptureAnalysis] = [:]
    /// Bumped once per published batch.
    private(set) var revision = 0
    /// Captures waiting to be read, then to be sorted, for the status bar.
    private(set) var readingCount = 0
    private(set) var sortingCount = 0
    /// Older captures the model could sort if the user opts in.
    private(set) var unsortedExistingCount = 0

    var pendingCount: Int { readingCount + sortingCount }

    @ObservationIgnored private let store = CaptureLibraryIndexStore(
        directory: ScreenshotHistoryStore.applicationSupportDirectory.appendingPathComponent("Library Index", isDirectory: true)
    )
    /// Whether `analyses` holds the saved index; it's empty while unloaded.
    @ObservationIgnored private(set) var isLoaded = false
    @ObservationIgnored private var latestItems: [CaptureLibraryItem]?
    @ObservationIgnored private var readQueue: [CaptureLibraryItem] = []
    @ObservationIgnored private var sortQueue: [CaptureLibraryItem] = []
    /// The capture being worked on right now, kept out of re-syncs meanwhile.
    @ObservationIgnored private var inFlight: CaptureLibraryItem?
    /// Fingerprints that couldn't be read this session, so an unreadable
    /// file isn't retried on every refresh.
    @ObservationIgnored private var unreadable: Set<String> = []
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var unpublished: [String: CaptureAnalysis] = [:]
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var isLibraryOpen = false

    private init() {}

    /// Keeps the index in step with History from now on, whether or not the
    /// Library window is open.
    func start() {
        guard !started else { return }
        started = true
        observeHistory()
        load()
    }

    /// The saved index stays in memory while the Library is open or there is
    /// work to do, and is read back from disk when either comes round again.
    func libraryDidOpen() {
        isLibraryOpen = true
        load()
    }

    func libraryDidClose() {
        isLibraryOpen = false
        unloadIfIdle()
    }

    private func load() {
        guard started, !isLoaded, loadTask == nil else { return }
        loadTask = Task {
            let loaded = await store.loadAll()
            loadTask = nil
            analyses = loaded
            isLoaded = true
            revision &+= 1
            CaptureLibraryModel.shared.indexDidChange(changed: Set(loaded.keys))
            if let latestItems { sync(latestItems) } else { CaptureLibraryModel.shared.refresh() }
        }
    }

    private func unloadIfIdle() {
        guard !isLibraryOpen, isLoaded, runner == nil, publishTask == nil, unpublished.isEmpty else { return }
        analyses = [:]
        isLoaded = false
        revision &+= 1
        Task { await store.forgetFeaturePrints() }
    }

    /// Re-plans the work after the Library settings change.
    func settingsDidChange() {
        if let latestItems { sync(latestItems) }
    }

    /// Opts older captures in to sorting by the model.
    func sortExistingCaptures() {
        UserDefaults.standard.set(true, forKey: ScreendropPreferences.librarySortExistingKey)
        settingsDidChange()
    }

    /// Queues every capture whose reading is missing or stale, then every
    /// capture due for the model, and forgets captures that are gone.
    func sync(_ items: [CaptureLibraryItem]) {
        latestItems = items
        guard isLoaded else { load(); return }
        let live = Set(items.lazy.map(\.id))
        // An empty scan more likely means History failed to load than that
        // every capture was deleted; keep the index rather than wipe it.
        if !items.isEmpty {
            let gone = analyses.keys.filter { !live.contains($0) }
            if !gone.isEmpty {
                for id in gone { analyses[id] = nil }
                revision &+= 1
                Task { await store.remove(ids: gone) }
            }
        }
        guard ScreendropPreferences.libraryAnalyzeCaptures else {
            readQueue = []
            sortQueue = []
            unsortedExistingCount = 0
            updateCounts()
            return
        }
        let modelAvailable = CaptureLibraryAnalyzer.isModelAvailable
        let sortExisting = ScreendropPreferences.librarySortExisting
        let autoSortSince = ScreendropPreferences.libraryAutoSortSince
        var reads: [CaptureLibraryItem] = []
        var sorts: [CaptureLibraryItem] = []
        var unsortedExisting = 0
        for item in items where item != inFlight && !unreadable.contains(item.thumbnailKey) {
            let analysis = analyses[item.id] ?? unpublished[item.id]
            guard let analysis,
                  analysis.version == CaptureAnalysis.currentVersion,
                  analysis.fingerprint == item.thumbnailKey else {
                reads.append(item)
                continue
            }
            guard modelAvailable, analysis.classifier != .model, !analysis.modelDeclined else { continue }
            if sortExisting || item.createdAt >= autoSortSince {
                sorts.append(item)
            } else {
                unsortedExisting += 1
            }
        }
        readQueue = reads.sorted { $0.createdAt > $1.createdAt }
        sortQueue = sorts.sorted { $0.createdAt > $1.createdAt }
        unsortedExistingCount = unsortedExisting
        updateCounts()
        if pendingCount > 0, runner == nil {
            runner = Task {
                await drain()
                unloadIfIdle()
            }
        }
        unloadIfIdle()
    }

    /// Captures that look most like `id`, nearest first.
    func similar(to id: String, among candidates: [String], limit: Int) async -> [String] {
        guard analyses[id]?.hasFeaturePrint == true else { return [] }
        let withPrints = candidates.filter { $0 != id && analyses[$0]?.hasFeaturePrint == true }
        return await store.nearest(to: id, among: withPrints, limit: limit)
    }

    // MARK: Work queue

    private func drain() async {
        defer { runner = nil }
        while ScreendropPreferences.libraryAnalyzeCaptures {
            if shouldPause {
                try? await Task.sleep(for: .seconds(10))
                continue
            }
            // Every capture is read before any is sorted.
            let isReading = !readQueue.isEmpty
            guard let item = isReading ? readQueue.first : sortQueue.first else { break }
            if isReading { readQueue.removeFirst() } else { sortQueue.removeFirst() }
            inFlight = item
            defer { inFlight = nil }
            let previous = analyses[item.id] ?? unpublished[item.id]
            let work = Task.detached(priority: .background) { () -> CaptureLibraryAnalyzer.Result? in
                if !isReading, let previous {
                    return .init(analysis: await CaptureLibraryAnalyzer.sort(previous, item: item), featurePrint: nil)
                }
                return await CaptureLibraryAnalyzer.read(item, previous: previous)
            }
            if let result = await work.value {
                await store.save(result.analysis, featurePrint: result.featurePrint)
                unpublished[item.id] = result.analysis
                schedulePublish()
                // A freshly read capture may be due for sorting next.
                if isReading, result.analysis.classifier != .model, CaptureLibraryAnalyzer.isModelAvailable {
                    if isDueForSorting(item) { sortQueue.append(item) } else { unsortedExistingCount += 1 }
                }
            } else {
                unreadable.insert(item.thumbnailKey)
            }
            updateCounts()
        }
        publish()
    }

    private func isDueForSorting(_ item: CaptureLibraryItem) -> Bool {
        ScreendropPreferences.librarySortExisting || item.createdAt >= ScreendropPreferences.libraryAutoSortSince
    }

    private func updateCounts() {
        if readingCount != readQueue.count { readingCount = readQueue.count }
        if sortingCount != sortQueue.count { sortingCount = sortQueue.count }
    }

    /// Recording, Low Power Mode and a hot Mac all come before indexing.
    private var shouldPause: Bool {
        ScreenRecordingManager.shared.isActive
            || ProcessInfo.processInfo.isLowPowerModeEnabled
            || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            publish()
        }
    }

    private func publish() {
        publishTask?.cancel()
        publishTask = nil
        guard !unpublished.isEmpty else { return }
        let changed = Set(unpublished.keys)
        analyses.merge(unpublished) { _, new in new }
        unpublished = [:]
        revision &+= 1
        CaptureLibraryModel.shared.indexDidChange(changed: changed)
    }

    /// Refreshes the Library model when History or the project list changes,
    /// so new captures are read even while the window is closed.
    private func observeHistory() {
        withObservationTracking {
            _ = ScreenshotHistoryStore.shared.items
            _ = RecordingProjectStore.shared.projects
        } onChange: {
            Task { @MainActor in
                CaptureLibraryModel.shared.refresh()
                CaptureLibraryIndex.shared.observeHistory()
            }
        }
    }
}

/// The index on disk: one JSON file per capture, plus its feature print, in
/// Application Support. Feature prints stay out of memory until the first
/// similarity lookup needs them.
actor CaptureLibraryIndexStore {
    private let directory: URL
    private var prints: [String: VNFeaturePrintObservation] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func loadAll() -> [String: CaptureAnalysis] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var result: [String: CaptureAnalysis] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let analysis = try? decoder.decode(CaptureAnalysis.self, from: data) else { continue }
            result[analysis.id] = analysis
        }
        return result
    }

    func save(_ analysis: CaptureAnalysis, featurePrint: Data?) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(analysis).write(to: url(analysis.id, "json"), options: .atomic)
            if let featurePrint {
                try featurePrint.write(to: url(analysis.id, "print"), options: .atomic)
                prints[analysis.id] = nil
            }
        } catch {
            NSLog("[Screendrop] Failed to save Library index entry: \(error)")
        }
    }

    func forgetFeaturePrints() {
        prints = [:]
    }

    func remove(ids: [String]) {
        for id in ids {
            prints[id] = nil
            try? FileManager.default.removeItem(at: url(id, "json"))
            try? FileManager.default.removeItem(at: url(id, "print"))
        }
    }

    func nearest(to id: String, among candidates: [String], limit: Int) -> [String] {
        guard let target = featurePrint(id) else { return [] }
        var scored: [(id: String, distance: Float)] = []
        scored.reserveCapacity(candidates.count)
        for candidate in candidates {
            var distance: Float = 0
            guard let other = featurePrint(candidate),
                  (try? target.computeDistance(&distance, to: other)) != nil else { continue }
            scored.append((candidate, distance))
        }
        return scored.sorted { $0.distance < $1.distance }.prefix(limit).map(\.id)
    }

    private func featurePrint(_ id: String) -> VNFeaturePrintObservation? {
        if let cached = prints[id] { return cached }
        guard let data = try? Data(contentsOf: url(id, "print")),
              let observation = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
        else { return nil }
        prints[id] = observation
        return observation
    }

    /// Item IDs include file paths, so files are named by a hash of the ID.
    private func url(_ id: String, _ pathExtension: String) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension(pathExtension)
    }
}
