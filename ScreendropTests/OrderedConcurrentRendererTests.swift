import XCTest

/// Compositing a frame is a pure function of its time, so frames can be
/// drawn concurrently. `AVAssetWriter` still needs them appended in
/// presentation order, so the renderer has to reorder completions.
final class OrderedConcurrentRendererTests: XCTestCase {
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

    func testEmitsInSubmissionOrderWhenWorkersFinishOutOfOrder() async throws {
        let emitted = LockedBox([Int]())
        // Earlier inputs sleep longest, so completion order is the exact
        // reverse of submission order.
        let renderer = OrderedConcurrentRenderer<Int, Int>(
            concurrency: 4,
            render: { input in
                try await Task.sleep(nanoseconds: UInt64(4 - input) * 30_000_000)
                return input
            },
            emit: { output in
                emitted.withLock { $0.append(output) }
            }
        )

        for input in 0..<4 {
            try await renderer.submit(input)
        }
        try await renderer.finish()

        XCTAssertEqual(
            emitted.withLock { $0 },
            [0, 1, 2, 3],
            "Frames must be appended in presentation order, not completion order."
        )
    }

    func testRendersConcurrentlyWithoutExceedingTheConcurrencyCap() async throws {
        struct Activity { var current = 0; var peak = 0 }
        let concurrency = 3
        let activity = LockedBox(Activity())

        let renderer = OrderedConcurrentRenderer<Int, Int>(
            concurrency: concurrency,
            render: { input in
                activity.withLock {
                    $0.current += 1
                    $0.peak = max($0.peak, $0.current)
                }
                try await Task.sleep(nanoseconds: 50_000_000)
                activity.withLock { $0.current -= 1 }
                return input
            },
            emit: { _ in }
        )

        for input in 0..<9 {
            try await renderer.submit(input)
        }
        try await renderer.finish()

        let peak = activity.withLock { $0.peak }
        XCTAssertGreaterThan(
            peak,
            1,
            "Frames must composite in parallel; one at a time wastes every other core."
        )
        XCTAssertLessThanOrEqual(
            peak,
            concurrency,
            "Each in-flight frame holds a full-size pixel buffer, so the cap must hold."
        )
    }

    func testSurfacesARenderFailureInsteadOfTruncatingTheOutput() async {
        struct RenderFailure: Error {}

        let renderer = OrderedConcurrentRenderer<Int, Int>(
            concurrency: 2,
            render: { input in
                if input == 0 { throw RenderFailure() }
                try await Task.sleep(nanoseconds: 20_000_000)
                return input
            },
            emit: { _ in }
        )

        do {
            for input in 0..<6 {
                try await renderer.submit(input)
            }
            try await renderer.finish()
            XCTFail("A failed frame must throw, not end the movie early and silently.")
        } catch is RenderFailure {
            // Expected: the failure reaches the caller.
        } catch {
            XCTFail("Expected RenderFailure, got \(error).")
        }
    }
}
