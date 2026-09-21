import XCTest
@testable import CoherenceGraph

/// Concurrency tests with an actual concurrent writer.
///
/// The point is not that the engine is thread-safe — it deliberately is not.
/// The point is that `CoherenceStore` confines it to the main actor, so many
/// tasks writing at once produce a serialized sequence of transactions and
/// every published state is coherent. A test with a single writer would prove
/// none of that.
///
/// Test methods are plain `async` rather than `@MainActor`, and hop explicitly.
/// Marking the methods `@MainActor` makes XCTest's own generated runner pass a
/// non-`Sendable` test case into a main-actor context, which is a warning today
/// and an error under the Swift 6 language mode.
final class StoreConcurrencyTests: XCTestCase {

    /// A main-actor-isolated class is implicitly `Sendable`, so the harness can
    /// be created in one hop and used from many tasks.
    @MainActor
    private final class Harness {
        let store = CoherenceStore()
        let cart: Node<Int>
        let subtotal: Node<Int>
        let tax: Node<Int>
        let total: Node<Int>
        private(set) var published: [GraphState] = []

        init() {
            let engine = store.engine
            cart = engine.source(0, label: "cart")
            subtotal = engine.derived(cart, label: "subtotal") {
                Saturating.multiply($0, GraphState.unitPrice)
            }
            tax = engine.derived(cart, label: "tax") {
                Saturating.multiply($0, GraphState.unitTax)
            }
            total = engine.derived(subtotal, tax, label: "total") { Saturating.add($0, $1) }
            store.onCommit = { [weak self] _ in self?.record() }
        }

        private func record() {
            published.append(
                GraphState(
                    cart: store.value(of: cart, default: -1),
                    subtotal: store.value(of: subtotal, default: -1),
                    tax: store.value(of: tax, default: -1),
                    total: store.value(of: total, default: -1)
                )
            )
        }

        func write(_ value: Int) { _ = try? store.write(value, to: cart) }
        var publishedStates: [GraphState] { published }
        var cartValue: Int { store.value(of: cart, default: -1) }
    }

    func testManyConcurrentWritersProduceOnlyCoherentStates() async {
        let harness = await MainActor.run { Harness() }
        let writerCount = 200

        await withTaskGroup(of: Void.self) { group in
            for value in 1...writerCount {
                group.addTask {
                    await MainActor.run { harness.write(value) }
                }
            }
            await group.waitForAll()
        }

        let published = await MainActor.run { harness.publishedStates }
        let cart = await MainActor.run { harness.cartValue }

        XCTAssertEqual(
            published.count,
            writerCount,
            "each of \(writerCount) distinct writes must commit exactly once"
        )
        for observation in published {
            XCTAssertTrue(observation.isCoherent, "a concurrent write produced \(observation)")
        }
        XCTAssertTrue((1...writerCount).contains(cart))
        // The last published state must match the final stored value: no
        // transaction was lost or reordered past the last one.
        XCTAssertEqual(published.last?.cart, cart)
    }

    func testConcurrencyCheckWouldCatchAnIncoherentState() async {
        // Non-vacuity: the assertion loop above only means something if an
        // incoherent observation would actually fail `isCoherent`.
        let fabricated = GraphState(cart: 25, subtotal: 2500, tax: 80, total: 2580)
        XCTAssertFalse(fabricated.isCoherent)
    }

    func testStoreCommitsStagedWritesAsOneTransaction() async throws {
        try await MainActor.run {
            let store = CoherenceStore()
            let a = store.engine.source(1, label: "a")
            let b = store.engine.source(2, label: "b")
            let sum = store.engine.derived(a, b, label: "sum") { Saturating.add($0, $1) }
            var commits = 0
            store.onCommit = { _ in commits += 1 }

            try store.set(10, for: a)
            try store.set(20, for: b)
            try store.commit()

            XCTAssertEqual(commits, 1)
            XCTAssertEqual(store.value(of: sum, default: 0), 30)
        }
    }
}
