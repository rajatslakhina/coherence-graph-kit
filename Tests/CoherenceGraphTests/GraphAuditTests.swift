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

    func testCoherenceCheckClampsInsteadOfTrappingAtTheExtreme() {
        // The version this replaces built its expected state with the same
        // `Saturating` calls `isCoherent` uses to check it — X == X, three
        // times, and it passed against `Saturating.multiply { _,_ in 0 }`.
        // Assert the concrete clamped constants instead.
        XCTAssertEqual(Saturating.multiply(Int.max, GraphState.unitPrice), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.max, GraphState.unitTax), Int.max)
        XCTAssertEqual(Saturating.add(Int.max, Int.max), Int.max)
        XCTAssertTrue(GraphState(cart: .max, subtotal: .max, tax: .max, total: .max).isCoherent)
    }

    func testCoherenceCheckRejectsAStateThatDoesNotMatchItsSource() {
        // The apex adds up (2500 + 80 == 2580) while `tax` came from a
        // different cart. `isCoherent` must still say no, or the headline
        // check is decoration.
        let glitched = GraphState(cart: 25, subtotal: 2500, tax: 80, total: 2580)
        XCTAssertEqual(Saturating.add(glitched.subtotal, glitched.tax), glitched.total)
        XCTAssertFalse(glitched.isCoherent)
        XCTAssertTrue(GraphState(cart: 25, subtotal: 2500, tax: 200, total: 2700).isCoherent)
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
        // `Int.min / 100` and `Int.min / 8` both route through `Saturating`.
        // Note the state is genuinely *coherent* at this extreme: every
        // saturating operation clamps to `Int.min`, so the relation holds.
        // That is worth asserting rather than assuming it must be broken.
        let extreme = GraphState(cart: .min, subtotal: .min, tax: .min, total: .min)
        XCTAssertTrue(extreme.isCoherent)
        XCTAssertEqual(extreme.sourceNarrative, "every value computed from quantity \(Int.min)")
        XCTAssertEqual(extreme.subtotalSource, Saturating.divide(Int.min, GraphState.unitPrice))
        XCTAssertEqual(extreme.taxSource, Saturating.divide(Int.min, GraphState.unitTax))
    }

    func testNarrativeReportsDisagreementAtExtremeValuesToo() {
        // Asserting only `!isEmpty` would pass against `return "x"`.
        let mixed = GraphState(cart: .min, subtotal: 0, tax: .min, total: .min)
        XCTAssertFalse(mixed.isCoherent)
        XCTAssertTrue(mixed.sourceNarrative.contains("the two branches disagree"))
        XCTAssertTrue(mixed.sourceNarrative.contains("\(Int.min)"))
    }
}
