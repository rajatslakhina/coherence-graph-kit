import XCTest
@testable import CoherenceGraph

/// The demo UI reconstructs the glitch from `NaivePropagator.updateLog` rather
/// than from a callback. These tests cover that exact path, because a UI that
/// renders nothing interesting is a UI whose claim is false — and SwiftUI code
/// is not compiled by the Linux job that runs this suite.
final class UpdateLogTests: XCTestCase {

    private func buildNaiveDiamond() -> (
        graph: NaivePropagator, cart: Int, subtotal: Int, tax: Int, total: Int
    ) {
        let graph = NaivePropagator()
        let cart = graph.source(3)
        let subtotal = graph.derived([cart]) {
            Saturating.multiply($0.first ?? 0, GraphState.unitPrice)
        }
        let tax = graph.derived([cart]) {
            Saturating.multiply($0.first ?? 0, GraphState.unitTax)
        }
        let total = graph.derived([subtotal, tax]) { values in
            guard values.count == 2 else { return 0 }
            return Saturating.add(values[0], values[1])
        }
        return (graph, cart, subtotal, tax, total)
    }

    /// Calls the shared core function the view model uses, rather than a
    /// second copy of it. An earlier version re-implemented the
    /// reconstruction inline, which proved only that it could be written
    /// twice — gutting `statesObservedAtApex` left every test green.
    private func statesObservedAtApex(
        _ d: (graph: NaivePropagator, cart: Int, subtotal: Int, tax: Int, total: Int)
    ) -> [GraphState] {
        GraphState.statesObservedAtApex(
            in: d.graph.updateLog,
            cart: d.cart,
            subtotal: d.subtotal,
            tax: d.tax,
            apex: d.total
        )
    }

    func testUpdateLogSnapshotsPreserveTheIncoherentMoment() {
        let d = buildNaiveDiamond()
        d.graph.clearUpdateLog()
        d.graph.set(25, at: d.cart)

        let states = statesObservedAtApex(d)
        XCTAssertEqual(states.count, 2, "the demo panel must have two rows to compare")
        XCTAssertEqual(states.first, GraphState(cart: 25, subtotal: 2500, tax: 24, total: 2524))
        XCTAssertFalse(states[0].isCoherent, "the first row is the glitch the demo exists to show")
        XCTAssertTrue(states[1].isCoherent)
        XCTAssertEqual(states.last, GraphState(cart: 25, subtotal: 2500, tax: 200, total: 2700))
    }

    func testReadingCurrentValuesInsteadOfSnapshotsWouldHideTheGlitch() {
        // Non-vacuity for the design decision above: if the log stored only
        // (index, value) and the UI read the graph afterwards, every row would
        // show the settled state and the panel would show nothing at all.
        let d = buildNaiveDiamond()
        d.graph.clearUpdateLog()
        d.graph.set(25, at: d.cart)

        let settled = GraphState(
            cart: d.graph.value(at: d.cart) ?? 0,
            subtotal: d.graph.value(at: d.subtotal) ?? 0,
            tax: d.graph.value(at: d.tax) ?? 0,
            total: d.graph.value(at: d.total) ?? 0
        )
        XCTAssertTrue(settled.isCoherent, "after settling, nothing looks wrong — which is the whole problem")
    }

    func testClearUpdateLogResetsBetweenWrites() {
        let d = buildNaiveDiamond()
        d.graph.set(10, at: d.cart)
        XCTAssertFalse(d.graph.updateLog.isEmpty)
        d.graph.clearUpdateLog()
        XCTAssertTrue(d.graph.updateLog.isEmpty)
        d.graph.set(11, at: d.cart)
        XCTAssertEqual(statesObservedAtApex(d).count, 2)
    }

    func testUpdateLogIsBounded() {
        let d = buildNaiveDiamond()
        for value in 1...200 { d.graph.set(value, at: d.cart) }
        XCTAssertLessThanOrEqual(d.graph.updateLog.count, 256, "an unbounded log in a long-lived object is a leak")
        // And it kept the most recent writes, not the oldest.
        XCTAssertEqual(d.graph.updateLog.last?.value(at: d.cart), 200)
    }

    func testOutOfRangeSnapshotReadIsNil() {
        let d = buildNaiveDiamond()
        d.graph.set(5, at: d.cart)
        let update = d.graph.updateLog.last
        XCTAssertNil(update?.value(at: 999))
        XCTAssertNil(update?.value(at: -1))
    }

    func testNaivePropagatorRejectsOutOfRangeIndices() {
        let graph = NaivePropagator()
        let a = graph.source(1)
        XCTAssertNil(graph.value(at: 99))
        XCTAssertNil(graph.value(at: -1))
        graph.set(5, at: 99)          // must not crash
        XCTAssertEqual(graph.value(at: a), 1)
    }
}
