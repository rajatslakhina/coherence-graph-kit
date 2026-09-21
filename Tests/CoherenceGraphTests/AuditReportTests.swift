import XCTest
@testable import CoherenceGraph

/// Prints the audit report so the block quoted in the README is reproducible
/// rather than hand-typed.
///
///     swift test --filter testPrintAuditReport
final class AuditReportTests: XCTestCase {

    func testPrintAuditReport() {
        let findings = GraphAudit.runAll()
        print("\n--- GraphAudit.report() ---")
        print(GraphAudit.report(findings))
        print("--- end ---\n")
        XCTAssertFalse(findings.isEmpty)
    }

    /// The README quotes this block verbatim and calls it program output.
    /// Without this assertion nothing stops the two drifting, and the earlier
    /// version of that block was hand-aligned text presented as output — the
    /// exact failure a README whose pitch is "these are run, not asserted"
    /// cannot afford. Update this literal when the audit output changes on
    /// purpose, and update the README in the same commit.
    func testReportMatchesTheBlockQuotedInTheReadme() {
        let expected = [
            "PASS  glitch freedom (CoherenceEngine) — CoherenceEngine: all 1 published state(s) were a consistent function of the source",
            "FAIL  glitch freedom (NaivePropagator) — NaivePropagator: 1 of 2 published state(s) were not a consistent function of the source (first: cart=25 subtotal=2500 tax=80 total=2580  <- INCOHERENT)",
            "PASS  exactly-once recompute — 3 derived node(s) recomputed, max recomputes for any one node = 1 (a depth-first push recomputes the diamond apex twice)",
            "PASS  topological visit order — visit order cart -> subtotal -> tax -> total respects every edge",
            "PASS  cycle detection + rollback — threw cycle detected among #1, #2; values restored to a=1 b=2 c=3 (pre-transaction a=1 b=2 c=3)",
            "PASS  bounded sink cascade — a sink that writes on every commit stopped after 4 transactions with a typed error instead of recursing",
            "PASS  single-writer ownership — second claim rejected: true; non-owner write rejected: true; owner write allowed: true; transfer by owner accepted: true; repeat transfer by stale owner rejected: true; transfers recorded: 1; owner is now SwiftUI",
            "PASS  no-op writes publish nothing — writing the current value produced no snapshot; writing a new value produced a snapshot",
        ].joined(separator: "\n")
        XCTAssertEqual(GraphAudit.report(), expected)
    }

    func testReportRendersOneLinePerFinding() {
        let findings = GraphAudit.runAll()
        let lines = GraphAudit.report(findings).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, findings.count)
        for line in lines {
            XCTAssertTrue(line.hasPrefix("PASS  ") || line.hasPrefix("FAIL  "), "unexpected line: \(line)")
        }
    }
}
