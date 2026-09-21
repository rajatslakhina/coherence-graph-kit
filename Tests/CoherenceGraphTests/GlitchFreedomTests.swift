import XCTest
@testable import CoherenceGraph

/// The headline claim, and its control group.
///
/// `testNaivePropagatorIsIncoherent` is the important one. Without it,
/// `testCoherentEngineNeverPublishesAnIncoherentState` proves nothing: a graph
/// that published a single state would pass it trivially. These two tests are
/// only meaningful as a pair.
final class GlitchFreedomTests: XCTestCase {

    func testCoherentEngineNeverPublishesAnIncoherentState() {
        let log = CoherentDiamond.observations(writingCart: 25)
        XCTAssertFalse(log.isEmpty, "the engine must publish at least one state, or the check is vacuous")
        for observation in log {
            XCTAssertTrue(
                observation.isCoherent,
                "published an incoherent state: \(observation)"
            )
        }
        // 25 * 100 = 2500, 25 * 8 = 200, total 2700.
        XCTAssertEqual(log.last, GraphState(cart: 25, subtotal: 2500, tax: 200, total: 2700))
    }

    func testNaivePropagatorIsIncoherent() {
        let log = NaiveDiamond.observations(writingCart: 25)
        XCTAssertFalse(log.isEmpty)
        let incoherent = log.filter { !$0.isCoherent }
        XCTAssertFalse(
            incoherent.isEmpty,
            "the control implementation must exhibit the glitch, otherwise the coherent test is not evidence"
        )
        // The specific glitch: the two branches disagree about which cart they
        // came from. `subtotal` is 2500 (cart 25) while `tax` is still 80
        // (cart 10), so the receipt shows a total for a cart that never existed.
        // Note that 2500 + 80 == 2580 *does* hold — the apex is internally
        // consistent with its inputs, which is why a weaker invariant misses
        // this entirely.
        XCTAssertEqual(incoherent.first, GraphState(cart: 25, subtotal: 2500, tax: 80, total: 2580))
        // And it settles correctly afterwards, which is exactly why the bug
        // survives code review and manual testing.
        XCTAssertEqual(log.last, GraphState(cart: 25, subtotal: 2500, tax: 200, total: 2700))
    }

    func testCoherentEnginePublishesExactlyOnceWhereNaivePublishesTwice() {
        let coherentLog = CoherentDiamond.observations(writingCart: 25)
        let naiveLog = NaiveDiamond.observations(writingCart: 25)
        XCTAssertEqual(coherentLog.count, 1, "one write must produce one published state")
        XCTAssertEqual(naiveLog.count, 2, "the naive propagator recomputes and republishes the apex twice")
    }

    func testGlitchFreedomCheckFailsAgainstTheBrokenImplementation() {
        // Feeding the check a deliberately broken implementation and asserting
        // it FAILS is the only way to know the check can fail at all.
        let good = GraphAudit.glitchFreedom(of: CoherentDiamond.self)
        let bad = GraphAudit.glitchFreedom(of: NaiveDiamond.self)
        XCTAssertTrue(good.passed, good.detail)
        XCTAssertFalse(bad.passed, "the audit passed a graph that publishes incoherent states: \(bad.detail)")
    }
}
