import XCTest
@testable import CoherenceGraph

/// Every one of these inputs traps with the plain operator. That is the point:
/// a recompute closure runs on data the library does not control.
final class SaturatingTests: XCTestCase {

    func testAddClampsInsteadOfTrapping() {
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.add(2, 3), 5)
        XCTAssertEqual(Saturating.add(Int.max, Int.min), -1)
    }

    func testSubtractClampsInsteadOfTrapping() {
        XCTAssertEqual(Saturating.subtract(Int.min, 1), Int.min)
        XCTAssertEqual(Saturating.subtract(Int.max, -1), Int.max)
        XCTAssertEqual(Saturating.subtract(5, 3), 2)
    }

    func testMultiplyClampsToTheCorrectEnd() {
        XCTAssertEqual(Saturating.multiply(Int.max, 2), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.max, -2), Int.min)
        XCTAssertEqual(Saturating.multiply(Int.min, -1), Int.max)
        XCTAssertEqual(Saturating.multiply(6, 7), 42)
        XCTAssertEqual(Saturating.multiply(0, Int.max), 0)
    }

    func testDivideHandlesZeroAndTheOverflowingCase() {
        XCTAssertEqual(Saturating.divide(10, 0), 0)
        XCTAssertEqual(Saturating.divide(10, 0, fallback: -1), -1)
        XCTAssertEqual(Saturating.divide(Int.min, -1), Int.max)
        XCTAssertEqual(Saturating.divide(10, 3), 3)
    }

    func testRemainderHandlesZeroAndTheOverflowingCase() {
        XCTAssertEqual(Saturating.remainder(10, 0), 0)
        XCTAssertEqual(Saturating.remainder(10, 0, fallback: 7), 7)
        XCTAssertEqual(Saturating.remainder(Int.min, -1), 0)
        XCTAssertEqual(Saturating.remainder(10, 3), 1)
    }
}
