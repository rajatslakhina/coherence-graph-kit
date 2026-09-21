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

    func testReportRendersOneLinePerFinding() {
        let findings = GraphAudit.runAll()
        let lines = GraphAudit.report(findings).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, findings.count)
        for line in lines {
            XCTAssertTrue(line.hasPrefix("PASS  ") || line.hasPrefix("FAIL  "), "unexpected line: \(line)")
        }
    }
}
