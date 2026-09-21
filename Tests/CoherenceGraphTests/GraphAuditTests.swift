import XCTest
@testable import CoherenceGraph

final class GraphAuditTests: XCTestCase {

    func testEveryRealInvariantPasses() {
        let findings = GraphAudit.runAll()
        for finding in findings where !GraphAudit.expectedFailures.contains(finding.invariant) {
            XCTAssertTrue(finding.passed, "invariant failed: \(finding)")
        }
    }

    func testTheControlGroupStillFails() {
        let findings = GraphAudit.runAll()
        let control = findings.filter { GraphAudit.expectedFailures.contains($0.invariant) }
        XCTAssertEqual(control.count, 1, "the audit must actually run the control implementation")
        for finding in control {
            XCTAssertFalse(finding.passed, "the control group stopped failing, so the audit proves nothing now")
        }
    }

    func testAuditIsHealthyOverall() {
        XCTAssertTrue(GraphAudit.isHealthy(GraphAudit.runAll()))
    }

    func testIsHealthyRejectsAnAuditWhoseControlGroupPassed() {
        // If the control group ever passes, `isHealthy` must say no. Written as
        // a direct test because it is the one branch a real run never takes.
        let faked = [
            AuditFinding(invariant: "glitch freedom (NaivePropagator)", passed: true, detail: "fabricated"),
        ]
        XCTAssertFalse(GraphAudit.isHealthy(faked))
    }

    func testIsHealthyRejectsAFailedRealInvariant() {
        let faked = [
            AuditFinding(invariant: "topological visit order", passed: false, detail: "fabricated"),
        ]
        XCTAssertFalse(GraphAudit.isHealthy(faked))
    }

    func testAuditCoversEveryClaimedInvariant() {
        let names = Set(GraphAudit.runAll().map(\.invariant))
        let expected: Set<String> = [
            "glitch freedom (CoherenceEngine)",
            "glitch freedom (NaivePropagator)",
            "exactly-once recompute",
            "topological visit order",
            "cycle detection + rollback",
            "bounded sink cascade",
            "single-writer ownership",
            "no-op writes publish nothing",
        ]
        XCTAssertEqual(names, expected)
    }

    func testObservationCoherenceUsesGuardedArithmetic() {
        // A total that would overflow must not trap while deciding coherence.
        // cart * 100 and cart * 8 both overflow here; deciding coherence must
        // clamp rather than trap.
        let cart = Int.max
        let observation = GraphState(
            cart: cart,
            subtotal: Saturating.multiply(cart, GraphState.unitPrice),
            tax: Saturating.multiply(cart, GraphState.unitTax),
            total: Saturating.add(
                Saturating.multiply(cart, GraphState.unitPrice),
                Saturating.multiply(cart, GraphState.unitTax)
            )
        )
        XCTAssertTrue(observation.isCoherent)
    }
}
