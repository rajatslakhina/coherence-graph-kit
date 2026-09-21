import XCTest
@testable import CoherenceGraph

final class GraphAuditTests: XCTestCase {

    func testEveryRealInvariantPasses() {
        let findings = GraphAudit.runAll()
        // Without this, the loop below runs zero times against a gutted
        // `runAll()` returning `[]` and the test passes having checked nothing.
        XCTAssertFalse(findings.isEmpty)
        XCTAssertEqual(findings.count, GraphAudit.expectedInvariants.count)
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
        var faked = GraphAudit.runAll().filter { $0.invariant != "topological visit order" }
        faked.append(AuditFinding(invariant: "topological visit order", passed: false, detail: "fabricated"))
        XCTAssertFalse(GraphAudit.isHealthy(faked))
    }

    func testIsHealthyRejectsAnEmptyReport() {
        // `allSatisfy` on an empty array is `true`, so a gutted `runAll()`
        // would otherwise look perfectly healthy.
        XCTAssertFalse(GraphAudit.isHealthy([]))
    }

    func testIsHealthyRejectsATruncatedReport() {
        let truncated = Array(GraphAudit.runAll().prefix(3))
        XCTAssertFalse(GraphAudit.isHealthy(truncated))
    }

    func testAuditCoversEveryClaimedInvariant() {
        let names = Set(GraphAudit.runAll().map(\.invariant))
        // Compared against a literal rather than against
        // `GraphAudit.expectedInvariants`, so that editing the constant alone
        // cannot make this test agree with itself.
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
        XCTAssertEqual(GraphAudit.expectedInvariants, expected)
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

/// The demo's headline row text is produced here, not in the SwiftUI layer,
/// so the thing a reader is promised they will *see* is actually covered by a
/// test that runs.
final class GraphStateNarrativeTests: XCTestCase {

    func testNarrativeNamesTheDisagreeingSources() {
        // The real glitch: subtotal from cart 25, tax still from cart 10.
        let glitched = GraphState(cart: 25, subtotal: 2500, tax: 80, total: 2580)
        XCTAssertFalse(glitched.isCoherent)
        XCTAssertEqual(glitched.subtotalSource, 25)
        XCTAssertEqual(glitched.taxSource, 10)
        XCTAssertEqual(
            glitched.sourceNarrative,
            "quantity is 25, but subtotal came from 25 and tax came from 10 — the two branches disagree"
        )
    }

    func testNarrativeIsPlainForACoherentState() {
        let good = GraphState(cart: 25, subtotal: 2500, tax: 200, total: 2700)
        XCTAssertTrue(good.isCoherent)
        XCTAssertEqual(good.sourceNarrative, "every value computed from quantity 25")
    }

    func testNarrativeDoesNotTrapOnExtremeValues() {
        let extreme = GraphState(cart: Int.min, subtotal: Int.min, tax: Int.min, total: Int.min)
        XCTAssertFalse(extreme.sourceNarrative.isEmpty)
    }
}
