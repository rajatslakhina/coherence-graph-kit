#if canImport(SwiftUI)
import Foundation
import Observation
import CoherenceGraph

/// Drives two live graphs side by side over the same input.
///
/// Both graphs are real and stateful — this is the library running, not a
/// replay of a canned scenario. `NaivePropagator` is the implementation almost
/// every hand-rolled observable layer becomes; `CoherenceEngine` is the one
/// this package argues for. They are fed identical writes.
@MainActor
@Observable
public final class CoherenceDemoModel {

    /// States published by the most recent write only. This is the comparison
    /// that matters: one write, two implementations, different numbers of
    /// observable states.
    public private(set) var lastWriteCoherent: [GraphState] = []
    public private(set) var lastWriteNaive: [GraphState] = []
    /// Executed invariants, refreshed on demand.
    public private(set) var findings: [AuditFinding] = []
    /// Set when a commit throws, so failures are shown rather than swallowed.
    public private(set) var lastError: String?

    /// True when the last write was equal to the current value, so the
    /// coherent engine published nothing at all.
    ///
    /// Without this the panels invert: the naive propagator has no equality
    /// pruning and republishes regardless, so a no-op write would show two
    /// states on the left and an empty panel on the right — the screen saying
    /// the opposite of the argument. Naming the case turns it into a
    /// demonstration of the "minimal publish" guarantee instead.
    public private(set) var lastWriteWasNoOp = false

    /// Recorded ownership moves, newest last.
    public private(set) var transfers: [OwnershipRegistry.Transfer] = []

    /// Which stack currently owns the cart domain.
    public private(set) var cartOwner: Stack = .swiftUI

    public private(set) var cart: Int

    private let store: CoherenceStore
    private let cartNode: Node<Int>
    private let subtotalNode: Node<Int>
    private let taxNode: Node<Int>
    private let totalNode: Node<Int>

    private let naive = NaivePropagator()
    private let naiveCart: Int
    private let naiveSubtotal: Int
    private let naiveTax: Int
    private let naiveTotal: Int

    /// The domain whose single writer is declared below.
    public static let cartDomain = Domain("cart")

    /// The only definition of the quantity range.
    ///
    /// The view binds its slider to this rather than repeating `0...99`. Two
    /// copies of a bound in the demo whose entire thesis is that two sources
    /// of truth is the bug would be an unforced own goal.
    public static let quantityBounds = 0...99

    public init(policy: CoherencePolicy, initialCart: Int = 3) {
        // Clamped so a caller-supplied value can never drive the demo into an
        // out-of-range stepper state.
        let seed = min(max(initialCart, Self.quantityBounds.lowerBound), Self.quantityBounds.upperBound)
        cart = seed

        store = CoherenceStore(policy: policy)
        let engine = store.engine
        // During a migration this slice of state has exactly one writer. A
        // write attributed to the other stack is rejected — see `attemptRogueWrite`.
        var claimFailure: String?
        do {
            try engine.claimDomain(Self.cartDomain, for: .swiftUI)
        } catch {
            claimFailure = String(describing: error)
        }
        cartNode = engine.source(seed, domain: Self.cartDomain, label: "cart")
        subtotalNode = engine.derived(cartNode, label: "subtotal") {
            Saturating.multiply($0, GraphState.unitPrice)
        }
        taxNode = engine.derived(cartNode, label: "tax") {
            Saturating.multiply($0, GraphState.unitTax)
        }
        totalNode = engine.derived(subtotalNode, taxNode, label: "total") {
            Saturating.add($0, $1)
        }

        naiveCart = naive.source(seed)
        naiveSubtotal = naive.derived([naiveCart]) {
            Saturating.multiply($0.first ?? 0, GraphState.unitPrice)
        }
        naiveTax = naive.derived([naiveCart]) {
            Saturating.multiply($0.first ?? 0, GraphState.unitTax)
        }
        let apex = naive.derived([naiveSubtotal, naiveTax]) { values in
            guard values.count == 2 else { return 0 }
            return Saturating.add(values[0], values[1])
        }
        naiveTotal = apex

        store.onCommit = { [weak self] _ in self?.recordCoherent() }
        // No callback is installed on `naive`: it is not an isolated type, and
        // handing it a closure that captures this main-actor model is exactly
        // the cross-isolation capture Swift 6 rejects. Its own snapshot log is
        // read after each write instead.
        _ = apex

        findings = GraphAudit.runAll()
        lastError = claimFailure
        // Drive one write immediately so both panels show real published
        // states before the reader touches anything.
        setCart(Saturating.add(seed, 1))
    }

    /// Current coherent-engine reading.
    public var current: GraphState {
        GraphState(
            cart: store.value(of: cartNode, default: 0),
            subtotal: store.value(of: subtotalNode, default: 0),
            tax: store.value(of: taxNode, default: 0),
            total: store.value(of: totalNode, default: 0)
        )
    }

    /// Writes the same value into both graphs.
    public func setCart(_ newValue: Int) {
        let clamped = min(max(newValue, Self.quantityBounds.lowerBound), Self.quantityBounds.upperBound)
        cart = clamped
        lastError = nil
        lastWriteWasNoOp = false
        lastWriteCoherent.removeAll(keepingCapacity: true)
        lastWriteNaive.removeAll(keepingCapacity: true)
        do {
            let snapshot = try store.write(clamped, to: cartNode, from: cartOwner)
            lastWriteWasNoOp = (snapshot == nil)
        } catch {
            lastError = String(describing: error)
        }
        naive.clearUpdateLog()
        naive.set(clamped, at: naiveCart)
        drainNaiveLog()
    }

    public func increment() { setCart(Saturating.add(cart, 1)) }
    public func decrement() { setCart(Saturating.subtract(cart, 1)) }

    /// The stack that does *not* currently own the cart domain.
    public var nonOwningStack: Stack { cartOwner == .swiftUI ? .legacyUIKit : .swiftUI }

    /// Demonstrates single-writer ownership by attempting a write from the
    /// stack that does not own the cart domain.
    public func attemptRogueWrite() {
        do {
            // Saturating, not `cart + 1`: the README claims every operation
            // that can trap goes through this seam, and a plain `+` in
            // shipping library code would make that claim false.
            try store.write(Saturating.add(cart, 1), to: cartNode, from: nonOwningStack)
            lastError = "unexpected: the write from \(nonOwningStack) was accepted"
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Hands the cart domain to the other stack — the move a migration is
    /// actually made of, one domain at a time.
    public func migrateCartDomain() {
        let target = nonOwningStack
        do {
            try store.engine.transferDomain(Self.cartDomain, from: cartOwner, to: target)
            cartOwner = target
            transfers = store.engine.ownership.history
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    public func refreshAudit() { findings = GraphAudit.runAll() }

    /// True when every real invariant held and the control group still failed.
    public var auditIsHealthy: Bool { GraphAudit.isHealthy(findings) }

    /// Invariants that are supposed to fail, so the UI can label them honestly
    /// instead of showing a scary red row.
    public func isExpectedFailure(_ finding: AuditFinding) -> Bool {
        GraphAudit.expectedFailures.contains(finding.invariant)
    }

    private func recordCoherent() {
        lastWriteCoherent.append(current)
        trim(&lastWriteCoherent)
    }

    /// Turns the propagator's recorded writes into the states an observer of
    /// the apex would have seen, using the same core function the test suite
    /// exercises rather than a private copy of it.
    private func drainNaiveLog() {
        lastWriteNaive.append(
            contentsOf: GraphState.statesObservedAtApex(
                in: naive.updateLog,
                cart: naiveCart,
                subtotal: naiveSubtotal,
                tax: naiveTax,
                apex: naiveTotal
            )
        )
        trim(&lastWriteNaive)
    }

    /// Bounded: an unbounded log in a long-lived view model is a leak.
    private func trim(_ log: inout [GraphState]) {
        let limit = 40
        guard log.count > limit else { return }
        log.removeFirst(log.count - limit)
    }
}
#endif
