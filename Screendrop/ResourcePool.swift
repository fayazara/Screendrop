//
//  ResourcePool.swift
//  Screendrop
//
//  A fixed set of reusable workers, lent one at a time. Used for objects
//  that are expensive to build and unsafe to share - the studio export's
//  per-frame compositors above all.
//

import Foundation

nonisolated final class ResourcePool<Resource>: @unchecked Sendable {
    private let lock = NSLock()
    private var available: [Resource]

    init(_ resources: [Resource]) {
        available = resources
    }

    /// Takes a resource out of the pool, or nil when all are lent out.
    func borrow() -> Resource? {
        lock.lock()
        defer { lock.unlock() }
        return available.isEmpty ? nil : available.removeLast()
    }

    /// Returns a borrowed resource. Callers must do this on every exit
    /// path, or the pool drains.
    func giveBack(_ resource: Resource) {
        lock.lock()
        defer { lock.unlock() }
        available.append(resource)
    }
}
