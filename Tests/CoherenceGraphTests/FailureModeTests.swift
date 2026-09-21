import XCTest
@testable import CoherenceGraph

/// The paths that turn into a hang, a stack overflow, or silent corruption in
/// the naive implementation.
final class FailureModeTests: XCTestCase {

    func testCycleIsDetectedAndTheTransactionRollsBack() {
        let engine = CoherenceEngine()
        let a = engine.source(1, label: "a")
        let b = engine.derived(a, label: "b") { Saturating.add($0, 1) }
        let c = engine.derived(b, label: "c") { Saturating.add($0, 1) }
        engine.unsafeAddEdgeForAuditing(from: c.id, to: b.id)

        let before = (engine.value(of: a), engine.value(of: b), engine.value(of: c))
        XCTAssertThrowsError(try engine.write(100, to: a)) { error in
            guard case .cycleDetected(let nodes)? = error as? CoherenceError else {
                return XCTFail("expected .cycleDetected, got \(error)")
            }
            XCTAssertTrue(nodes.contains(b.id))
            XCTAssertTrue(nodes.contains(c.id))
        }
        let after = (engine.value(of: a), engine.value(of: b), engine.value(of: c))
        XCTAssertEqual(before.0, after.0, "a failed transaction must not leave the source written")
        XCTAssertEqual(before.1, after.1)
        XCTAssertEqual(before.2, after.2)
    }

    func testCycleDetectionIsNotVacuous() {
        // Same graph, WITHOUT the injected back edge: it must commit normally.
        // Otherwise the test above would pass against an engine that simply
        // throws on every write.
        let engine = CoherenceEngine()
        let a = engine.source(1, label: "a")
        let b = engine.derived(a, label: "b") { Saturating.add($0, 1) }
        let c = engine.derived(b, label: "c") { Saturating.add($0, 1) }
        XCTAssertNoThrow(try engine.write(100, to: a))
        XCTAssertEqual(engine.value(of: b), 101)
        XCTAssertEqual(engine.value(of: c), 102)
    }

    func testNonSettlingSinkCascadeThrowsInsteadOfHanging() {
        let engine = CoherenceEngine(policy: CoherencePolicy(maxCascadeDepth: 4))
        let ping = engine.source(0, label: "ping")

        final class Oscillator: CoherenceSink {
            var write: () -> Void = {}
            private(set) var notifications = 0
            func coherenceDidCommit(_ snapshot: CoherenceSnapshot) {
                notifications += 1
                write()
            }
        }
        let oscillator = Oscillator()
        var counter = 0
        oscillator.write = { [weak engine] in
            guard let engine else { return }
            counter += 1
            // Offset past the value the test wrote, so every cascade write is a
            // real change. A bare counter would collide with that first write
            // and settle, and this test would pass without ever exercising the
            // budget.
            try? engine.set(counter + 1_000, for: ping)
        }
        engine.addSink(oscillator)

        XCTAssertThrowsError(try engine.write(1, to: ping)) { error in
            XCTAssertEqual(error as? CoherenceError, .cascadeBudgetExceeded(depth: 4))
        }
        XCTAssertEqual(oscillator.notifications, 4, "the cascade must stop at the budget, not before or after")
    }

    func testSettlingSinkCascadeCompletes() throws {
        // A sink that writes once and then stops must NOT trip the budget.
        // Without this, the test above would pass against an engine that
        // rejected every sink write.
        let engine = CoherenceEngine(policy: CoherencePolicy(maxCascadeDepth: 4))
        let ping = engine.source(0, label: "ping")
        let mirror = engine.source(0, label: "mirror")

        final class OneShot: CoherenceSink {
            var write: () -> Void = {}
            private(set) var notifications = 0
            func coherenceDidCommit(_ snapshot: CoherenceSnapshot) {
                notifications += 1
                if notifications == 1 { write() }
            }
        }
        let sink = OneShot()
        sink.write = { [weak engine] in try? engine?.set(7, for: mirror) }
        engine.addSink(sink)

        let snapshot = try engine.write(1, to: ping)
        XCTAssertEqual(engine.value(of: mirror), 7)
        XCTAssertEqual(sink.notifications, 2, "one write plus one sink-triggered follow-up")
        XCTAssertEqual(snapshot?.cascadeDepth, 2)
    }

    func testReentrantCommitFromASinkDoesNotRecurse() throws {
        let engine = CoherenceEngine()
        let a = engine.source(0, label: "a")

        final class Reentrant: CoherenceSink {
            var body: () -> Void = {}
            private(set) var depth = 0
            private(set) var maxDepth = 0
            func coherenceDidCommit(_ snapshot: CoherenceSnapshot) {
                depth += 1
                maxDepth = max(maxDepth, depth)
                body()
                depth -= 1
            }
        }
        let sink = Reentrant()
        var fired = false
        sink.body = { [weak engine] in
            guard let engine, !fired else { return }
            fired = true
            try? engine.set(42, for: a)
            // Calling commit() from inside publish must be a no-op, not a
            // nested transaction.
            XCTAssertNil(try? engine.commit())
        }
        engine.addSink(sink)

        try engine.write(1, to: a)
        XCTAssertEqual(sink.maxDepth, 1, "publish must never be re-entered")
        XCTAssertEqual(engine.value(of: a), 42, "the staged write is applied by the following transaction")
    }

    func testCascadePolicyIsClampedToAtLeastOne() {
        XCTAssertEqual(CoherencePolicy(maxCascadeDepth: 0).maxCascadeDepth, 1)
        XCTAssertEqual(CoherencePolicy(maxCascadeDepth: -5).maxCascadeDepth, 1)
        XCTAssertEqual(CoherencePolicy(maxCascadeDepth: Int.max).maxCascadeDepth, 1_000)
        XCTAssertEqual(CoherencePolicy(maxCascadeDepth: 8).maxCascadeDepth, 8)
    }
}
