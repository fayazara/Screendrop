import XCTest

/// Compositors carry caches that are not thread-safe, so parallel frame
/// workers each need their own. They are too expensive to build per frame -
/// a cold compositor re-decodes the pointer artwork - so a fixed set is
/// built once and lent out.
final class ResourcePoolTests: XCTestCase {
    private final class Worker {}

    func testNeverLendsOneResourceToTwoBorrowersAtOnce() {
        let pool = ResourcePool([Worker(), Worker()])

        let first = pool.borrow()
        let second = pool.borrow()

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertFalse(
            first === second,
            "Two frame workers sharing one compositor would race on its caches."
        )
    }

    func testReportsExhaustionRatherThanLendingBeyondItsSize() {
        let pool = ResourcePool([Worker()])

        _ = pool.borrow()

        XCTAssertNil(
            pool.borrow(),
            "An exhausted pool must say so, so the caller fails loudly."
        )
    }

    func testLendsAResourceAgainOnceItIsReturned() {
        let only = Worker()
        let pool = ResourcePool([only])

        guard let borrowed = pool.borrow() else {
            return XCTFail("The pool lent nothing on its first borrow.")
        }
        pool.giveBack(borrowed)

        XCTAssertTrue(
            pool.borrow() === only,
            "A returned worker must go back into circulation."
        )
    }
}
