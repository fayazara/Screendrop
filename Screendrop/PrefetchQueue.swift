//
//  PrefetchQueue.swift
//  Screendrop
//
//  Hands the results of a blocking producer to an async consumer in
//  production order, so decoding a movie can overlap with the work that
//  consumes each decoded frame.
//
//  The producer runs on its own thread because the calls it wraps -
//  `AVAssetReaderOutput.copyNextSampleBuffer()` above all - block. Keeping
//  that off the cooperative pool is the point of the type.
//
//  Single-consumer: `next()` is meant to be called from one task at a
//  time, which is how the export's frame loop uses it.
//

import Foundation

nonisolated final class PrefetchQueue<Element: Sendable>: @unchecked Sendable {
    private let capacity: Int
    private let produce: @Sendable () -> Element?

    private let lock = NSCondition()
    private var buffer: [Element] = []
    private var waiting: [CheckedContinuation<Element?, Never>] = []
    private var isFinished = false
    private var isCancelled = false

    /// - Parameters:
    ///   - capacity: how many produced elements may sit undelivered before
    ///     the producer is made to wait. Bounds memory: each buffered
    ///     screen frame is a full-size pixel buffer.
    ///   - produce: returns the next element, or nil at end of stream.
    init(capacity: Int, produce: @escaping @Sendable () -> Element?) {
        self.capacity = max(1, capacity)
        self.produce = produce
        startProducer()
    }

    /// The next element in production order, or nil once the producer has
    /// reached end of stream or the queue was cancelled.
    func next() async -> Element? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !buffer.isEmpty {
                let element = buffer.removeFirst()
                lock.signal()
                lock.unlock()
                continuation.resume(returning: element)
            } else if isFinished || isCancelled {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Stops production and releases any consumer waiting on `next()`.
    /// Callers must invoke this on every exit path, including errors, or
    /// the producer thread keeps the queue alive.
    func cancel() {
        lock.lock()
        isCancelled = true
        let pending = waiting
        waiting.removeAll()
        buffer.removeAll()
        lock.broadcast()
        lock.unlock()
        pending.forEach { $0.resume(returning: nil) }
    }

    private func startProducer() {
        let thread = Thread { [self] in runProducer() }
        thread.name = "com.fayazahmed.Screendrop.PrefetchQueue"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func runProducer() {
        while true {
            lock.lock()
            while buffer.count >= capacity, !isCancelled, waiting.isEmpty {
                lock.wait()
            }
            if isCancelled {
                lock.unlock()
                return
            }
            lock.unlock()

            let element = produce()

            lock.lock()
            if isCancelled {
                lock.unlock()
                return
            }
            guard let element else {
                isFinished = true
                let pending = waiting
                waiting.removeAll()
                lock.unlock()
                pending.forEach { $0.resume(returning: nil) }
                return
            }
            if waiting.isEmpty {
                buffer.append(element)
                lock.unlock()
            } else {
                let consumer = waiting.removeFirst()
                lock.unlock()
                consumer.resume(returning: element)
            }
        }
    }
}
