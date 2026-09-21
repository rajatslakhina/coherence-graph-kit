import XCTest
@testable import CoherenceGraph

/// Staging, discarding and detaching — the operations a long-lived store needs
/// and the first version did not have.
final class LifecycleTests: XCTestCase {

    func testStagedWritesCanBeDiscarded() throws {
        let engine = CoherenceEngine()
        let a = engine.source(1, label: "a")
        let b = engine.source(2, label: "b")
        try engine.set(10, for: a)
        try engine.set(20, for: b)
        XCTAssertEqual(engine.stagedWriteCount, 2)

        XCTAssertEqual(engine.discardStagedWrites(), 2)
        XCTAssertEqual(engine.stagedWriteCount, 0)
        XCTAssertNil(try engine.commit(), "discarded writes must not commit later")
        XCTAssertEqual(engine.value(of: a), 1)
        XCTAssertEqual(engine.value(of: b), 2)
    }

    func testAPartiallyFailedBatchDoesNotLeakIntoTheNextCommit() throws {
        let engine = CoherenceEngine()
        let domain = Domain("cart")
        try engine.claimDomain(domain, for: .swiftUI)
        let owned = engine.source(1, domain: domain, label: "owned")
        let free = engine.source(1, label: "free")

        try engine.set(5, for: free, from: .legacyUIKit)                       // accepted
        XCTAssertThrowsError(try engine.set(5, for: owned, from: .legacyUIKit)) // refused
        // Without discarding, `free` would land on the next unrelated commit.
        engine.discardStagedWrites()
        try engine.commit()
        XCTAssertEqual(engine.value(of: free), 1)
    }

    func testSinksCanBeDetached() throws {
        let engine = CoherenceEngine()
        let a = engine.source(0, label: "a")
        final class Counter: CoherenceSink {
            var commits = 0
            func coherenceDidCommit(_ snapshot: CoherenceSnapshot) { commits += 1 }
        }
        let counter = Counter()
        engine.addSink(counter)
        XCTAssertEqual(engine.sinkCount, 1)

        try engine.write(1, to: a)
        XCTAssertEqual(counter.commits, 1)

        XCTAssertTrue(engine.removeSink(counter))
        XCTAssertEqual(engine.sinkCount, 0)
        try engine.write(2, to: a)
        XCTAssertEqual(counter.commits, 1, "a detached sink must stop being notified")
        XCTAssertFalse(engine.removeSink(counter), "removing twice reports no change")
    }

    func testTransferHistoryIsBounded() throws {
        var registry = OwnershipRegistry()
        let cart = Domain("cart")
        try registry.claim(cart, for: .legacyUIKit)
        var owner = Stack.legacyUIKit
        for _ in 0..<(OwnershipRegistry.historyLimit + 50) {
            let next: Stack = owner == .legacyUIKit ? .swiftUI : .legacyUIKit
            try registry.transfer(cart, from: owner, to: next)
            owner = next
        }
        XCTAssertEqual(registry.history.count, OwnershipRegistry.historyLimit)
        XCTAssertEqual(registry.history.last?.to, owner, "the cap must drop the oldest, not the newest")
    }

    func testStoreForwardsPublishedTransactionsEvenWhenCommitThrows() async throws {
        try await MainActor.run {
            let store = CoherenceStore(policy: CoherencePolicy(maxCascadeDepth: 3))
            let ping = store.engine.source(0, label: "ping")

            final class Oscillator: CoherenceSink {
                var write: (Int) -> Void = { _ in }
                private(set) var n = 0
                func coherenceDidCommit(_ snapshot: CoherenceSnapshot) { n += 1; write(n) }
            }
            let sink = Oscillator()
            let engine = store.engine
            sink.write = { [weak engine] n in try? engine?.set(Saturating.add(n, 1_000), for: ping) }
            engine.addSink(sink)

            var seen: [Int] = []
            store.onCommit = { seen.append($0.cascadeDepth) }

            XCTAssertThrowsError(try store.write(1, to: ping))
            // Engine-registered sinks saw three publishes; `onCommit` must not
            // silently miss them just because the cascade ended in a throw.
            XCTAssertEqual(sink.n, 3)
            XCTAssertEqual(seen, [1, 2, 3])
        }
    }
}
