import XCTest
@testable import CoherenceGraph

/// These two functions live in the core module precisely so this file can
/// exist. While they sat next to the SwiftUI view, nothing on Linux compiled
/// them and the sign bug below shipped untested.
final class DisplayTests: XCTestCase {

    func testMoneyFormatsOrdinaryAmounts() {
        XCTAssertEqual(Money.format(cents: 0), "$0.00")
        XCTAssertEqual(Money.format(cents: 5), "$0.05")
        XCTAssertEqual(Money.format(cents: 50), "$0.50")
        XCTAssertEqual(Money.format(cents: 2700), "$27.00")
        XCTAssertEqual(Money.format(cents: 2705), "$27.05")
    }

    func testMoneyKeepsTheSignOnNegativeAmounts() {
        // Int division truncates toward zero, so -50 / 100 == 0. A naive
        // implementation renders minus fifty cents as "$0.50".
        XCTAssertEqual(Money.format(cents: -50), "-$0.50")
        XCTAssertEqual(Money.format(cents: -5), "-$0.05")
        XCTAssertEqual(Money.format(cents: -2705), "-$27.05")
    }

    func testMoneyDoesNotTrapAtTheIntegerExtremes() {
        // `abs(Int.min)` traps and `Int.min % 100` is negative.
        XCTAssertTrue(Money.format(cents: Int.min).hasPrefix("-$"))
        XCTAssertTrue(Money.format(cents: Int.max).hasPrefix("$"))
        XCTAssertFalse(Money.format(cents: Int.min).contains("--"))
    }

    func testQuantityClampsToBounds() {
        let bounds = 0...99
        XCTAssertEqual(Quantity.fromSlider(-10, bounds: bounds), 0)
        XCTAssertEqual(Quantity.fromSlider(0, bounds: bounds), 0)
        XCTAssertEqual(Quantity.fromSlider(3.4, bounds: bounds), 3)
        XCTAssertEqual(Quantity.fromSlider(3.6, bounds: bounds), 4)
        XCTAssertEqual(Quantity.fromSlider(99, bounds: bounds), 99)
        XCTAssertEqual(Quantity.fromSlider(1000, bounds: bounds), 99)
    }

    func testQuantitySurvivesNaNAndInfinity() {
        // `Int(Double)` traps on every one of these.
        let bounds = 1...50
        XCTAssertEqual(Quantity.fromSlider(.nan, bounds: bounds), 1)
        XCTAssertEqual(Quantity.fromSlider(.infinity, bounds: bounds), 50)
        XCTAssertEqual(Quantity.fromSlider(-.infinity, bounds: bounds), 1)
        XCTAssertEqual(Quantity.fromSlider(.greatestFiniteMagnitude, bounds: bounds), 50)
    }
}
