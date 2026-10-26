//
//  CaptureLibraryIndex.swift
//  Screendrop
//

import Accelerate
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
/// Application Support. Similarity lookups read the prints from a pack
/// rather than from each capture's file.
actor CaptureLibraryIndexStore {
    private let directory: URL
    private var pack: CaptureFeaturePrintPack
    /// Prints that couldn't be packed this session, so they aren't re-read
    /// on every lookup.
    private var unpackable: Set<CaptureFeaturePrintPack.Key> = []

    init(directory: URL) {
        self.directory = directory
        pack = CaptureFeaturePrintPack(url: directory.appendingPathComponent("Feature Prints.pack"))
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
                // The pack's last record for a capture wins, so a re-read
                // capture's new print replaces its old one.
                let key = CaptureFeaturePrintPack.key(analysis.id)
                unpackable.remove(key)
                if let elements = Self.elements(ofArchive: featurePrint) {
                    pack.open()
                    pack.append([(key, elements)])
                }
            }
        } catch {
            NSLog("[Screendrop] Failed to save Library index entry: \(error)")
        }
    }

    func forgetFeaturePrints() {
        pack.close()
    }

    func remove(ids: [String]) {
        for id in ids {
            try? FileManager.default.removeItem(at: url(id, "json"))
            try? FileManager.default.removeItem(at: url(id, "print"))
        }
    }

    func nearest(to id: String, among candidates: [String], limit: Int) -> [String] {
        pack.open()
        let target = CaptureFeaturePrintPack.key(id)
        let keyed = candidates.map { ($0, CaptureFeaturePrintPack.key($0)) }
        // Prints made before the pack existed are packed on first use.
        var missing: [(CaptureFeaturePrintPack.Key, [Float])] = []
        for (candidate, key) in [(id, target)] + keyed where !pack.contains(key) && !unpackable.contains(key) {
            if let data = try? Data(contentsOf: url(candidate, "print")),
               let elements = Self.elements(ofArchive: data) {
                missing.append((key, elements))
            } else {
                unpackable.insert(key)
            }
        }
        pack.append(missing)
        return pack.nearest(to: target, among: keyed, limit: limit)
    }

    private static func elements(ofArchive data: Data) -> [Float]? {
        guard let observation = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data),
              observation.elementType == .float else { return nil }
        return observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Item IDs include file paths, so files are named by a hash of the ID.
    private func url(_ id: String, _ pathExtension: String) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension(pathExtension)
    }
}

/// Every capture's feature print in one memory-mapped file: a header, then
/// records of a capture's key and its elements. Lookups leave nothing on the
/// heap, since mapped pages are file-backed and the system drops them freely,
/// and the per-capture archives stay the source of truth. Vision's distance
/// between two prints is the Euclidean distance between their elements, so
/// they're compared here directly. The file is only appended to; the last
/// record for a key wins, and it's compacted when old records pile up.
nonisolated struct CaptureFeaturePrintPack {
    struct Key: Hashable {
        var high: UInt64
        var low: UInt64
    }

    private static let magic: UInt32 = 0x5046_4453
    private static let headerSize = 8
    private static let keySize = 16

    let url: URL
    private var data: Data?
    private var dimension = 0
    /// Byte offset of each key's elements.
    private var offsets: [Key: Int] = [:]
    private var recordCount = 0
    private var isOpen = false

    init(url: URL) {
        self.url = url
    }

    static func key(_ id: String) -> Key {
        SHA256.hash(data: Data(id.utf8)).withUnsafeBytes {
            Key(high: $0.loadUnaligned(as: UInt64.self), low: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
    }

    private var recordSize: Int { Self.keySize + dimension * MemoryLayout<Float>.size }

    func contains(_ key: Key) -> Bool { offsets[key] != nil }

    mutating func open() {
        guard !isOpen else { return }
        isOpen = true
        guard let mapped = try? Data(contentsOf: url, options: .alwaysMapped),
              mapped.count >= Self.headerSize else { return }
        let (magic, dimension) = mapped.withUnsafeBytes {
            ($0.loadUnaligned(as: UInt32.self), Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
        }
        guard magic == Self.magic, dimension > 0 else { return }
        self.dimension = dimension
        let size = recordSize
        mapped.withUnsafeBytes { bytes in
            var offset = Self.headerSize
            while offset + size <= bytes.count {
                let key = Key(high: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self),
                              low: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self))
                offsets[key] = offset + Self.keySize
                offset += size
                recordCount += 1
            }
        }
        data = mapped
        if recordCount > offsets.count * 2 + 256 { compact() }
    }

    mutating func close() {
        data = nil
        dimension = 0
        offsets = [:]
        recordCount = 0
        isOpen = false
    }

    /// Writes the prints in one go and maps the file again. Prints of another
    /// size than the pack's are left out.
    mutating func append(_ entries: [(Key, [Float])]) {
        if dimension == 0, let first = entries.first { dimension = first.1.count }
        let entries = entries.filter { $0.1.count == dimension }
        guard !entries.isEmpty else { return }
        var bytes = Data()
        bytes.reserveCapacity((data == nil ? Self.headerSize : 0) + entries.count * recordSize)
        if data == nil {
            withUnsafeBytes(of: Self.magic) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(dimension)) { bytes.append(contentsOf: $0) }
        }
        for (key, elements) in entries {
            withUnsafeBytes(of: key.high) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: key.low) { bytes.append(contentsOf: $0) }
            elements.withUnsafeBytes { bytes.append(contentsOf: $0) }
        }
        do {
            if data == nil {
                try bytes.write(to: url, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: bytes)
            }
        } catch {
            // A half-written pack is rebuilt from the archives.
            try? FileManager.default.removeItem(at: url)
        }
        close()
        open()
    }

    func nearest(to targetKey: Key, among candidates: [(id: String, key: Key)], limit: Int) -> [String] {
        guard let data, let targetOffset = offsets[targetKey] else { return [] }
        let dimension = dimension
        return data.withUnsafeBytes { bytes -> [String] in
            func elements(at offset: Int) -> UnsafePointer<Float> {
                UnsafePointer((bytes.baseAddress! + offset).assumingMemoryBound(to: Float.self))
            }
            let target = elements(at: targetOffset)
            var scored: [(id: String, distance: Float)] = []
            scored.reserveCapacity(candidates.count)
            for candidate in candidates where candidate.key != targetKey {
                guard let offset = offsets[candidate.key] else { continue }
                var distance: Float = 0
                vDSP_distancesq(target, 1, elements(at: offset), 1, &distance, vDSP_Length(dimension))
                scored.append((candidate.id, distance))
            }
            return scored.sorted { $0.distance < $1.distance }.prefix(limit).map(\.id)
        }
    }

    /// Rewrites the pack with only each key's latest record.
    private mutating func compact() {
        guard let data else { return }
        var bytes = Data(data.prefix(Self.headerSize))
        bytes.reserveCapacity(Self.headerSize + offsets.count * recordSize)
        for offset in offsets.values {
            bytes.append(data[(offset - Self.keySize)..<(offset + recordSize - Self.keySize)])
        }
        try? bytes.write(to: url, options: .atomic)
        close()
        open()
    }
}
