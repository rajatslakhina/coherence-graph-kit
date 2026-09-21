import XCTest
@testable import CoherenceGraph

/// A derived value is a function of its inputs. Writing one directly used to
/// be accepted, and the write *survived the transaction*: step 4 only
/// recomputes a node when one of its own inputs changed, and nothing upstream
/// had. The fabricated value then propagated downward and was published.
final class SourceOnlyWriteTests: XCTestCase {

    private func diamond(_ engine: CoherenceEngine)
        -> (cart: Node<Int>, subtotal: Node<Int>, tax: Node<Int>, total: Node<Int>) {
        let cart = engine.source(10, label: "cart")
        let subtotal = engine.derived(cart, label: "subtotal") {
            Saturating.multiply($0, GraphState.unitPrice)
        }
        let tax = engine.derived(cart, label: "tax") {
            Saturating.multiply($0, GraphState.unitTax)
        }
        let total = engine.derived(subtotal, tax, label: "total") { Saturating.add($0, $1) }
        return (cart, subtotal, tax, total)
    }

    func testWritingADerivedNodeIsRefused() {
        let engine = CoherenceEngine()
        let g = diamond(engine)
        XCTAssertThrowsError(try engine.set(999, for: g.subtotal)) { error in
            XCTAssertEqual(error as? CoherenceError, .notASource(g.subtotal.id))
        }
        XCTAssertThrowsError(try engine.write(999, to: g.total)) { error in
            XCTAssertEqual(error as? CoherenceError, .notASource(g.total.id))
        }
    }

    func testARefusedDerivedWriteLeavesTheGraphCoherent() throws {
        let engine = CoherenceEngine()
        let g = diamond(engine)
        _ = try? engine.write(999, to: g.subtotal)
        try engine.commit()

        let state = GraphState(
            cart: engine.value(of: g.cart, default: -1),
            subtotal: engine.value(of: g.subtotal, default: -1),
            tax: engine.value(of: g.tax, default: -1),
            total: engine.value(of: g.total, default: -1)
        )
        XCTAssertTrue(state.isCoherent, "a refused write must not leave a fabricated value behind: \(state)")
        XCTAssertEqual(state.subtotal, 1000)
        XCTAssertEqual(engine.stagedWriteCount, 0, "a refused write must not stay staged")
    }

    func testSourceWritesStillWork() throws {
        // Non-vacuity: if `set` rejected everything, the two tests above would
        // pass against a useless engine.
        let engine = CoherenceEngine()
        let g = diamond(engine)
        try engine.write(25, to: g.cart)
        XCTAssertEqual(engine.value(of: g.total), 2700)
    }

    func testOwnershipCannotBeBypassedThroughADerivedNode() throws {
        // Domains attach to sources only. Before derived writes were refused,
        // a non-owner could corrupt the same displayed number by writing the
        // derived node instead of the source it was denied.
        let engine = CoherenceEngine()
        let cartDomain = Domain("cart")
        try engine.claimDomain(cartDomain, for: .swiftUI)
        let cart = engine.source(10, domain: cartDomain, label: "cart")
        let subtotal = engine.derived(cart, label: "subtotal") {
            Saturating.multiply($0, GraphState.unitPrice)
        }
        XCTAssertThrowsError(try engine.set(1, for: cart, from: .legacyUIKit))
        XCTAssertThrowsError(try engine.set(999, for: subtotal, from: .legacyUIKit)) { error in
            XCTAssertEqual(error as? CoherenceError, .notASource(subtotal.id))
        }
        try engine.commit()
        XCTAssertEqual(engine.value(of: subtotal), 1000)
    }
}
