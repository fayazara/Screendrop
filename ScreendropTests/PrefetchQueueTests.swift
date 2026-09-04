import XCTest

/// `pumpVideo` decodes the next source frame inline, in the same loop that
/// composites the current one, so decoding and drawing never overlap. The
/// prefetch queue moves the blocking producer onto its own task while
/// keeping delivery order and bounding how many frames sit in flight.
final class PrefetchQueueTests: XCTestCase {
    /// Minimal synchronized box. The producer closure runs off the test's
    /// actor, so its state cannot be plain captured `var`s.
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) { storage = value }

        func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body(&storage)
        }
    }

    func testDeliversEveryElementInProductionOrderThenEndsTheStream() async {
        let remaining = LockedBox([1, 2, 3, 4, 5])
        let queue = PrefetchQueue<Int>(capacity: 2) {
            remaining.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }

        var received: [Int] = []
        while let value = await queue.next() {
            received.append(value)
        }

        XCTAssertEqual(
            received,
            [1, 2, 3, 4, 5],
            "Frames must reach the compositor in decode order, with no gaps."
        )
    }

    func testDecodesAheadOfTheConsumerUpToCapacity() async throws {
        let capacity = 3
        let produced = LockedBox(0)
        let queue = PrefetchQueue<Int>(capacity: capacity) {
            produced.withLock { count in
                guard count < 10 else { return nil }
                count += 1
                return count
            }
        }

        // Take one frame, then leave the consumer idle. A queue that only
        // decodes on demand stops at one; a prefetching one fills its buffer.
        _ = await queue.next()

        let target = capacity + 1
        let deadline = Date().addingTimeInterval(5)
        while produced.withLock({ $0 }) < target, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertGreaterThanOrEqual(
            produced.withLock { $0 },
            target,
            "The producer must decode ahead while the consumer is busy."
        )
    }

    func testStopsProducingOnceCapacityIsBuffered() async throws {
        let capacity = 2
        let produced = LockedBox(0)
        let queue = PrefetchQueue<Int>(capacity: capacity) {
            produced.withLock { count in
                guard count < 20 else { return nil }
                count += 1
                return count
            }
        }
        defer { queue.cancel() }

        // Nothing is consumed, so nothing can leave the buffer. An
        // unbounded producer would run the source dry; a bounded one parks
        // at exactly `capacity`.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            produced.withLock { $0 },
            capacity,
            "Decoded frames are full-size pixel buffers, so the queue must stop at capacity."
        )
    }
}
