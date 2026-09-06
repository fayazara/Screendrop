import CoreGraphics
import Foundation

/// A byte-bounded LRU shared by active consumers. The last lease releases
/// every image; a generation check rejects work started before that release.
nonisolated final class BoundedCGImageCache: @unchecked Sendable {
    nonisolated final class Lease: Sendable {
        private let cache: BoundedCGImageCache
        fileprivate init(cache: BoundedCGImageCache) { self.cache = cache }
        deinit { cache.endUse() }
    }

    private struct Entry {
        let image: CGImage
        let cost: Int
        var access: UInt64
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private let countLimit: Int
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private var users = 0
    private var epoch: UInt64 = 0
    private var access: UInt64 = 0

    init(byteLimit: Int, countLimit: Int) {
        self.byteLimit = byteLimit
        self.countLimit = countLimit
    }

    var generation: UInt64 { lock.withLock { epoch } }
    var retainedBytes: Int { lock.withLock { bytes } }

    func beginUse() -> Lease {
        lock.withLock { users += 1 }
        return Lease(cache: self)
    }

    private func endUse() {
        lock.withLock {
            users -= 1
            if users == 0 { clearLocked() }
        }
    }

    func removeAll() { lock.withLock { clearLocked() } }

    private func clearLocked() {
        entries.removeAll()
        bytes = 0
        epoch &+= 1
    }

    func image(for key: String) -> CGImage? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            access &+= 1
            entry.access = access
            entries[key] = entry
            return entry.image
        }
    }

    func insert(_ image: CGImage, for key: String, generation: UInt64) {
        let cost = image.bytesPerRow * image.height
        lock.withLock {
            guard users > 0, epoch == generation, cost <= byteLimit, countLimit > 0 else { return }
            if let previous = entries.removeValue(forKey: key) { bytes -= previous.cost }
            while bytes + cost > byteLimit || entries.count >= countLimit {
                guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key,
                      let removed = entries.removeValue(forKey: oldest) else { break }
                bytes -= removed.cost
            }
            access &+= 1
            entries[key] = Entry(image: image, cost: cost, access: access)
            bytes += cost
        }
    }
}
