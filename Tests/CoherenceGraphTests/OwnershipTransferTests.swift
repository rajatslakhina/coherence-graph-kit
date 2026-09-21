import XCTest
@testable import CoherenceGraph

/// Transfer is the mechanism a migration actually runs on: domains move one at
/// a time, deliberately, and the moves are auditable afterwards.
final class OwnershipTransferTests: XCTestCase {

    func testOwnerCanTransferADomain() throws {
        var registry = OwnershipRegistry()
        let cart = Domain("cart")
        try registry.claim(cart, for: .legacyUIKit)
        try registry.transfer(cart, from: .legacyUIKit, to: .swiftUI)
        XCTAssertEqual(registry.owner(of: cart), .swiftUI)
        XCTAssertNoThrow(try registry.validateWrite(to: cart, by: .swiftUI))
        XCTAssertThrowsError(try registry.validateWrite(to: cart, by: .legacyUIKit))
    }

    func testTransferFromAStaleOwnerIsRejected() throws {
        var registry = OwnershipRegistry()
        let cart = Domain("cart")
        try registry.claim(cart, for: .legacyUIKit)
        try registry.transfer(cart, from: .legacyUIKit, to: .swiftUI)
        // A second transfer quoting the old owner must fail, so two concurrent
        // migration steps cannot both believe they won.
        XCTAssertThrowsError(try registry.transfer(cart, from: .legacyUIKit, to: .swiftUI)) { error in
            XCTAssertEqual(
                error as? CoherenceError,
                .ownershipViolation(domain: cart, owner: .swiftUI, attemptedBy: .legacyUIKit)
            )
        }
        XCTAssertEqual(registry.history.count, 1, "a rejected transfer must not be recorded")
    }

    func testTransferringAnUnclaimedDomainIsRejected() {
        var registry = OwnershipRegistry()
        let ghost = Domain("ghost")
        XCTAssertThrowsError(try registry.transfer(ghost, from: .legacyUIKit, to: .swiftUI)) { error in
            XCTAssertEqual(error as? CoherenceError, .domainNotOwned(domain: ghost))
        }
        XCTAssertTrue(registry.history.isEmpty)
    }

    func testEveryTransferIsRecordedInOrder() throws {
        var registry = OwnershipRegistry()
        let cart = Domain("cart")
        let user = Domain("user")
        try registry.claim(cart, for: .legacyUIKit)
        try registry.claim(user, for: .legacyUIKit)
        try registry.transfer(cart, from: .legacyUIKit, to: .swiftUI)
        try registry.transfer(user, from: .legacyUIKit, to: .swiftUI)
        try registry.transfer(cart, from: .swiftUI, to: .legacyUIKit)   // a rollback
        XCTAssertEqual(registry.history.map(\.description), [
            "cart: legacy UIKit -> SwiftUI",
            "user: legacy UIKit -> SwiftUI",
            "cart: SwiftUI -> legacy UIKit",
        ])
    }

    func testClaimStillRefusesToActAsATransfer() throws {
        // The two verbs stay distinct: accidental dual ownership must remain
        // impossible even though deliberate migration is now supported.
        var registry = OwnershipRegistry()
        let cart = Domain("cart")
        try registry.claim(cart, for: .legacyUIKit)
        XCTAssertThrowsError(try registry.claim(cart, for: .swiftUI))
        XCTAssertEqual(registry.owner(of: cart), .legacyUIKit)
        XCTAssertTrue(registry.history.isEmpty)
    }
}
