import XCTest
@testable import CoherenceGraph

final class OwnershipTests: XCTestCase {

    func testDomainCannotBeClaimedByTwoStacks() throws {
        var registry = OwnershipRegistry()
        let cart = Domain("cart")
        try registry.claim(cart, for: .legacyUIKit)
        XCTAssertThrowsError(try registry.claim(cart, for: .swiftUI)) { error in
            XCTAssertEqual(error as? CoherenceError, .domainAlreadyOwned(domain: cart, owner: .legacyUIKit))
        }
        XCTAssertEqual(registry.owner(of: cart), .legacyUIKit)
    }

    func testReclaimingForTheSameStackIsIdempotent() throws {
        var registry = OwnershipRegistry()
        let cart = Domain("cart")
        try registry.claim(cart, for: .swiftUI)
        XCTAssertNoThrow(try registry.claim(cart, for: .swiftUI))
        XCTAssertEqual(registry.claims.count, 1)
    }

    func testNonOwnerWriteIsRejectedAtTheEngine() throws {
        let engine = CoherenceEngine()
        let cart = Domain("cart")
        try engine.claimDomain(cart, for: .legacyUIKit)
        let node = engine.source(1, domain: cart, label: "cart")

        XCTAssertThrowsError(try engine.set(2, for: node, from: .swiftUI)) { error in
            XCTAssertEqual(
                error as? CoherenceError,
                .ownershipViolation(domain: cart, owner: .legacyUIKit, attemptedBy: .swiftUI)
            )
        }
        XCTAssertEqual(engine.value(of: node), 1, "a rejected write must not land")
        XCTAssertNoThrow(try engine.set(3, for: node, from: .legacyUIKit))
        try engine.commit()
        XCTAssertEqual(engine.value(of: node), 3)
    }

    func testUnclaimedDomainsAndUnattributedWritesAreUnconstrained() throws {
        let engine = CoherenceEngine()
        // No domain at all: the registry does not force every value through a
        // ceremony.
        let free = engine.source(1, label: "free")
        XCTAssertNoThrow(try engine.set(2, for: free, from: .swiftUI))

        // Domain present but unclaimed.
        let unclaimed = engine.source(1, domain: Domain("unclaimed"), label: "unclaimed")
        XCTAssertNoThrow(try engine.set(2, for: unclaimed, from: .swiftUI))

        // Domain claimed, but the caller did not say which stack it is. Reads
        // and unattributed writes are deliberately allowed; attribution is how
        // a migrating team opts a call site in.
        let cart = Domain("cart")
        try engine.claimDomain(cart, for: .legacyUIKit)
        let owned = engine.source(1, domain: cart, label: "owned")
        XCTAssertNoThrow(try engine.set(2, for: owned, from: nil))
    }
}
