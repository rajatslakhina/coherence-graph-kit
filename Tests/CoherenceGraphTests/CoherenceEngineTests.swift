import XCTest
@testable import CoherenceGraph

final class CoherenceEngineTests: XCTestCase {

    private func buildDiamond(_ engine: CoherenceEngine)
        -> (cart: Node<Int>, subtotal: Node<Int>, tax: Node<Int>, total: Node<Int>) {
        let cart = engine.source(10, label: "cart")
        let subtotal = engine.derived(cart, label: "subtotal") { Saturating.multiply($0, 100) }
        let tax = engine.derived(cart, label: "tax") { Saturating.multiply($0, 8) }
        let total = engine.derived(subtotal, tax, label: "total") { Saturating.add($0, $1) }
        return (cart, subtotal, tax, total)
    }

    func testDerivedNodesAreSeededBeforeAnyWrite() {
        let engine = CoherenceEngine()
        let graph = buildDiamond(engine)
        XCTAssertEqual(engine.value(of: graph.subtotal), 1000)
        XCTAssertEqual(engine.value(of: graph.tax), 80)
        XCTAssertEqual(engine.value(of: graph.total), 1080)
    }

    func testWritePropagatesToTheApex() throws {
        let engine = CoherenceEngine()
        let graph = buildDiamond(engine)
        let snapshot = try engine.write(25, to: graph.cart)
        XCTAssertEqual(engine.value(of: graph.total), 2700)
        XCTAssertEqual(snapshot?.version, 1)
        XCTAssertEqual(snapshot?.cascadeDepth, 1)
    }

    func testApexIsRecomputedExactlyOnce() throws {
        let engine = CoherenceEngine()
        let graph = buildDiamond(engine)
        try engine.write(25, to: graph.cart)
        XCTAssertEqual(engine.lastRecomputeCounts[graph.total.id], 1)
        XCTAssertEqual(engine.lastRecomputeCounts[graph.subtotal.id], 1)
        XCTAssertEqual(engine.lastRecomputeCounts[graph.tax.id], 1)
        XCTAssertEqual(engine.lastRecomputeCounts.values.reduce(0, +), 3)
    }

    func testNaivePropagatorRecomputesTheApexTwice() {
        // The counterpart to the test above. Three recomputes is only a
        // meaningful number because the obvious implementation does four.
        let graph = NaivePropagator()
        let cart = graph.source(10)
        let subtotal = graph.derived([cart]) { Saturating.multiply($0.first ?? 0, 100) }
        let tax = graph.derived([cart]) { Saturating.multiply($0.first ?? 0, 8) }
        let total = graph.derived([subtotal, tax]) { values in
            guard values.count == 2 else { return 0 }
            return Saturating.add(values[0], values[1])
        }
        var updatesPerNode: [Int: Int] = [:]
        graph.onNodeUpdated = { index, _ in updatesPerNode[index, default: 0] += 1 }
        graph.set(25, at: cart)
        XCTAssertEqual(updatesPerNode[total], 2, "the apex of a diamond is recomputed twice by depth-first push")
        XCTAssertEqual(updatesPerNode.values.reduce(0, +), 5, "cart + subtotal + tax + total twice")
    }

    func testStagedWritesCoalesceIntoOneTransaction() throws {
        let engine = CoherenceEngine()
        let a = engine.source(1, label: "a")
        let b = engine.source(2, label: "b")
        let sum = engine.derived(a, b, label: "sum") { Saturating.add($0, $1) }

        final class Counter: CoherenceSink {
            var commits = 0
            func coherenceDidCommit(_ snapshot: CoherenceSnapshot) { commits += 1 }
        }
        let counter = Counter()
        engine.addSink(counter)

        try engine.set(10, for: a)
        try engine.set(20, for: b)
        let snapshot = try engine.commit()

        XCTAssertEqual(counter.commits, 1, "two staged writes must publish once, not twice")
        XCTAssertEqual(engine.value(of: sum), 30)
        XCTAssertEqual(snapshot?.recomputedCount, 1)
    }

    func testWritingTheSameValuePublishesNothing() throws {
        let engine = CoherenceEngine()
        let graph = buildDiamond(engine)
        final class Counter: CoherenceSink {
            var commits = 0
            func coherenceDidCommit(_ snapshot: CoherenceSnapshot) { commits += 1 }
        }
        let counter = Counter()
        engine.addSink(counter)
        let snapshot = try engine.write(10, to: graph.cart)
        XCTAssertNil(snapshot)
        XCTAssertEqual(counter.commits, 0)
    }

    func testUnchangedBranchIsNotRecomputed() throws {
        let engine = CoherenceEngine()
        let a = engine.source(4, label: "a")
        // `parity` collapses many inputs onto the same output, so a change to
        // `a` that preserves parity must not dirty anything downstream of it.
        let parity = engine.derived(a, label: "parity") { Saturating.remainder($0, 2) }
        let label = engine.derived(parity, label: "label") { $0 == 0 ? "even" : "odd" }
        _ = label

        try engine.write(6, to: a)   // 4 -> 6, parity stays 0
        XCTAssertEqual(engine.lastRecomputeCounts[parity.id], 1, "parity depends on a, so it is recomputed")
        XCTAssertNil(engine.lastRecomputeCounts[label.id], "parity did not change, so label must not be recomputed")

        try engine.write(7, to: a)   // 6 -> 7, parity flips
        XCTAssertEqual(engine.lastRecomputeCounts[label.id], 1, "parity changed, so label must be recomputed")
        XCTAssertEqual(engine.value(of: label), "odd")
    }

    func testSnapshotReportsOnlyNodesThatActuallyChanged() throws {
        let engine = CoherenceEngine()
        let a = engine.source(4, label: "a")
        let parity = engine.derived(a, label: "parity") { Saturating.remainder($0, 2) }
        let snapshot = try engine.write(6, to: a)
        XCTAssertEqual(snapshot?.changed, [a.id])
        XCTAssertFalse(snapshot?.changed.contains(parity.id) ?? true)
    }

    func testForeignHandleIsRejectedRatherThanCrashing() throws {
        let engineA = CoherenceEngine()
        let engineB = CoherenceEngine()
        _ = engineB.source(0, label: "filler")
        _ = engineB.source(0, label: "filler2")
        let foreign = engineB.source(99, label: "foreign")

        // Out of range for engineA, which has no nodes at all.
        XCTAssertNil(engineA.value(of: foreign))
        XCTAssertEqual(engineA.value(of: foreign, default: -1), -1)
        XCTAssertThrowsError(try engineA.set(1, for: foreign)) { error in
            XCTAssertEqual(error as? CoherenceError, .unknownNode(foreign.id))
        }
    }

    func testSinksAreHeldWeakly() throws {
        let engine = CoherenceEngine()
        let a = engine.source(0, label: "a")
        final class Counter: CoherenceSink {
            var commits = 0
            func coherenceDidCommit(_ snapshot: CoherenceSnapshot) { commits += 1 }
        }
        var counter: Counter? = Counter()
        weak var weakCounter = counter
        if let counter { engine.addSink(counter) }
        try engine.write(1, to: a)
        XCTAssertEqual(counter?.commits, 1)

        counter = nil
        XCTAssertNil(weakCounter, "the engine must not keep the sink alive")
        try engine.write(2, to: a)   // must not crash on the dead sink
        XCTAssertEqual(engine.value(of: a), 2)
    }

    func testVersionIncrementsOncePerCommittedTransaction() throws {
        let engine = CoherenceEngine()
        let a = engine.source(0, label: "a")
        XCTAssertEqual(try engine.write(1, to: a)?.version, 1)
        XCTAssertEqual(try engine.write(1, to: a)?.version, nil)   // no-op
        XCTAssertEqual(try engine.write(2, to: a)?.version, 2)
    }
}
