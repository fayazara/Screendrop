//
//  OrderedConcurrentRenderer.swift
//  Screendrop
//
//  Runs an independent per-item transform over an ordered stream and
//  delivers the results in submission order.
//
//  Compositing one export frame depends only on its own timestamps, so
//  frames can be drawn on as many cores as are free. `AVAssetWriter` still
//  requires appends in presentation order, which is what this type
//  reconciles.
//
//  The design is a FIFO of in-flight tasks. Awaiting the oldest one first
//  gives submission order for free, and refusing to start a new task until
//  the queue is under its cap gives the concurrency bound for free.
//
//  Single-producer: `submit` and `finish` are meant to be called from one
//  task, which is how the export's frame loop drives it.
//

import Foundation

nonisolated final class OrderedConcurrentRenderer<Input: Sendable, Output: Sendable> {
    private let concurrency: Int
    private let render: @Sendable (Input) async throws -> Output
    private let emit: (Output) async throws -> Void
    private var inFlight: [Task<Output, Error>] = []

    /// - Parameters:
    ///   - concurrency: how many items may render at once. Each in-flight
    ///     item holds a full-size destination buffer, so this bounds peak
    ///     memory as much as it bounds CPU.
    ///   - render: the independent per-item work.
    ///   - emit: receives outputs in submission order, one at a time.
    init(
        concurrency: Int,
        render: @escaping @Sendable (Input) async throws -> Output,
        emit: @escaping (Output) async throws -> Void
    ) {
        self.concurrency = max(1, concurrency)
        self.render = render
        self.emit = emit
    }

    func submit(_ input: Input) async throws {
        if inFlight.count >= concurrency {
            try await emitOldest()
        }
        let render = self.render
        inFlight.append(Task { try await render(input) })
    }

    /// Drains everything still rendering, in order.
    func finish() async throws {
        while !inFlight.isEmpty {
            try await emitOldest()
        }
    }

    /// Cancels every in-flight item and drops it undelivered.
    func cancel() {
        for task in inFlight {
            task.cancel()
        }
        inFlight.removeAll()
    }

    private func emitOldest() async throws {
        let oldest = inFlight.removeFirst()
        do {
            try await emit(oldest.value)
        } catch {
            // One failed frame makes the rest pointless, and leaving them
            // running would outlive the writer they were drawing for.
            cancel()
            throw error
        }
    }
}
