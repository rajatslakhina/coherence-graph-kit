// GraphAudit.swift
//
// The invariants this package claims are *executed here*, not asserted in the
// README. Every finding below is produced by building a real graph, driving it,
// and observing what happened.
//
// The load-bearing one is `glitchFreedom`. It is written once, against a
// protocol, and run twice: against `CoherenceEngine` (must pass) and against
// `NaivePropagator` (must fail). A check that has never been observed failing
// is not evidence of anything.

/// One state of the demo graph as it was made visible to an observer.
///
/// `cart` is part of the observation on purpose. The first version of this type
/// recorded only the three derived values and asked whether
/// `total == subtotal + tax` — and the naive propagator *passed*, because it
/// computes the apex from whatever the two branches currently hold. The
/// inconsistency is not between the apex and its inputs; it is between the two
/// branches, which disagree about which `cart` they were computed from. An
/// invariant that does not mention the source cannot see the glitch at all.
public struct GraphState: Equatable, Sendable, CustomStringConvertible {
    /// Line-item multiplier applied to the cart, in cents.
    public static let unitPrice = 100
    /// Tax applied to the cart, in cents per unit.
    public static let unitTax = 8

    public let cart: Int
    public let subtotal: Int
    public let tax: Int
    public let total: Int

    public init(cart: Int, subtotal: Int, tax: Int, total: Int) {
        self.cart = cart
        self.subtotal = subtotal
        self.tax = tax
        self.total = total
    }

    /// Every derived value is a consistent function of the same `cart`.
    public var isCoherent: Bool {
        subtotal == Saturating.multiply(cart, Self.unitPrice)
            && tax == Saturating.multiply(cart, Self.unitTax)
            && total == Saturating.add(subtotal, tax)
    }

    public var description: String {
        "cart=\(cart) subtotal=\(subtotal) tax=\(tax) total=\(total)"
            + (isCoherent ? "" : "  <- INCOHERENT")
    }

    /// The quantity `subtotal` was actually computed from.
    public var subtotalSource: Int { Saturating.divide(subtotal, Self.unitPrice) }

    /// The quantity `tax` was actually computed from.
    public var taxSource: Int { Saturating.divide(tax, Self.unitTax) }

    /// Plain-language account of which quantity each value came from.
    ///
    /// This exists because the three derived numbers alone look *fine* in the
    /// glitched state — 2500 + 80 really is 2580 — so a UI that renders only
    /// them communicates nothing but a red badge. Naming the disagreeing
    /// sources is what makes the defect visible rather than asserted.
    public var sourceNarrative: String {
        if isCoherent {
            return "every value computed from quantity \(cart)"
        }
        return "quantity is \(cart), but subtotal came from \(subtotalSource) "
            + "and tax came from \(taxSource) — the two branches disagree"
    }
}

/// Builds the diamond `cart -> (subtotal, tax) -> total` and reports every
/// state an observer was shown while `cart` was written.
public protocol DiamondScenario {
    static var name: String { get }
    /// Writes `cart` and returns the observations published, in order.
    static func observations(writingCart cart: Int) -> [GraphState]
}

/// The diamond built on `CoherenceEngine`.
public enum CoherentDiamond: DiamondScenario {
    public static let name = "CoherenceEngine"

    private final class Recorder: CoherenceSink {
        var log: [GraphState] = []
        var read: () -> GraphState = { GraphState(cart: 0, subtotal: 0, tax: 0, total: 0) }
        func coherenceDidCommit(_ snapshot: CoherenceSnapshot) { log.append(read()) }
    }

    public static func observations(writingCart cart: Int) -> [GraphState] {
        let engine = CoherenceEngine()
        let cartNode = engine.source(10, label: "cart")
        let subtotal = engine.derived(cartNode, label: "subtotal") {
            Saturating.multiply($0, GraphState.unitPrice)
        }
        let tax = engine.derived(cartNode, label: "tax") {
            Saturating.multiply($0, GraphState.unitTax)
        }
        let total = engine.derived(subtotal, tax, label: "total") { Saturating.add($0, $1) }

        let recorder = Recorder()
        recorder.read = {
            GraphState(
                cart: engine.value(of: cartNode, default: 0),
                subtotal: engine.value(of: subtotal, default: 0),
                tax: engine.value(of: tax, default: 0),
                total: engine.value(of: total, default: 0)
            )
        }
        engine.addSink(recorder)
        // A thrown error would itself be a failure; recorded as an empty log.
        do { _ = try engine.write(cart, to: cartNode) } catch { return [] }
        return recorder.log
    }
}

/// The same diamond built on `NaivePropagator`. Expected to be incoherent.
public enum NaiveDiamond: DiamondScenario {
    public static let name = "NaivePropagator"

    public static func observations(writingCart cart: Int) -> [GraphState] {
        let graph = NaivePropagator()
        let cartNode = graph.source(10)
        let subtotal = graph.derived([cartNode]) {
            Saturating.multiply($0.first ?? 0, GraphState.unitPrice)
        }
        let tax = graph.derived([cartNode]) {
            Saturating.multiply($0.first ?? 0, GraphState.unitTax)
        }
        let total = graph.derived([subtotal, tax]) { values in
            guard values.count == 2 else { return 0 }
            return Saturating.add(values[0], values[1])
        }

        var log: [GraphState] = []
        graph.onNodeUpdated = { index, _ in
            // The naive propagator has no commit boundary, so every node write
            // is observable. That is precisely the defect.
            guard index == total else { return }
            log.append(
                GraphState(
                    cart: graph.value(at: cartNode) ?? 0,
                    subtotal: graph.value(at: subtotal) ?? 0,
                    tax: graph.value(at: tax) ?? 0,
                    total: graph.value(at: total) ?? 0
                )
            )
        }
        graph.set(cart, at: cartNode)
        return log
    }
}

extension GraphState {
    /// Rebuilds the states an observer of `apex` was shown, from a
    /// `NaivePropagator` update log.
    ///
    /// Lives here rather than in the view model so the test suite exercises
    /// the *same* function the UI calls. A test that re-implements the
    /// reconstruction inline proves only that the test author can write it
    /// twice.
    public static func statesObservedAtApex(
        in updates: [NaivePropagator.Update],
        cart: Int,
        subtotal: Int,
        tax: Int,
        apex: Int
    ) -> [GraphState] {
        updates
            .filter { $0.index == apex }
            .map { update in
                GraphState(
                    cart: update.value(at: cart) ?? 0,
                    subtotal: update.value(at: subtotal) ?? 0,
                    tax: update.value(at: tax) ?? 0,
                    total: update.value(at: apex) ?? 0
                )
            }
    }
}

/// Result of one executed invariant.
public struct AuditFinding: Sendable, Equatable, CustomStringConvertible {
    public let invariant: String
    public let passed: Bool
    public let detail: String

    public var description: String { "\(passed ? "PASS" : "FAIL")  \(invariant) — \(detail)" }
}

/// Runs every invariant this package claims.
public enum GraphAudit {

    /// Runs `check` against a scenario and reports whether every published
    /// state was coherent.
    public static func glitchFreedom<S: DiamondScenario>(of _: S.Type) -> AuditFinding {
        let log = S.observations(writingCart: 25)
        let incoherent = log.filter { !$0.isCoherent }
        let detail: String
        if log.isEmpty {
            detail = "\(S.name) published nothing"
        } else if incoherent.isEmpty {
            detail = "\(S.name): all \(log.count) published state(s) were a consistent function of the source"
        } else {
            let first = incoherent[0]
            detail = "\(S.name): \(incoherent.count) of \(log.count) published state(s) were not a "
                + "consistent function of the source (first: \(first))"
        }
        return AuditFinding(
            invariant: "glitch freedom (\(S.name))",
            passed: !log.isEmpty && incoherent.isEmpty,
            detail: detail
        )
    }

    /// Each derived node is recomputed at most once per transaction.
    public static func exactlyOnceRecompute() -> AuditFinding {
        let engine = CoherenceEngine()
        let cart = engine.source(10, label: "cart")
        let subtotal = engine.derived(cart, label: "subtotal") { Saturating.multiply($0, 100) }
        let tax = engine.derived(cart, label: "tax") { Saturating.multiply($0, 8) }
        _ = engine.derived(subtotal, tax, label: "total") { Saturating.add($0, $1) }
        do { _ = try engine.write(25, to: cart) } catch {
            return AuditFinding(invariant: "exactly-once recompute", passed: false, detail: "threw \(error)")
        }
        let counts = engine.lastRecomputeCounts
        let worst = counts.values.max() ?? 0
        return AuditFinding(
            invariant: "exactly-once recompute",
            passed: worst <= 1,
            detail: "\(counts.count) derived node(s) recomputed, max recomputes for any one node = \(worst) "
                + "(a depth-first push recomputes the diamond apex twice)"
        )
    }

    /// Every node is visited after all of its inputs.
    public static func topologicalVisitOrder() -> AuditFinding {
        let engine = CoherenceEngine()
        let cart = engine.source(10, label: "cart")
        let subtotal = engine.derived(cart, label: "subtotal") { Saturating.multiply($0, 100) }
        let tax = engine.derived(cart, label: "tax") { Saturating.multiply($0, 8) }
        let total = engine.derived(subtotal, tax, label: "total") { Saturating.add($0, $1) }
        _ = total
        do { _ = try engine.write(25, to: cart) } catch {
            return AuditFinding(invariant: "topological visit order", passed: false, detail: "threw \(error)")
        }
        var position: [NodeID: Int] = [:]
        for (index, id) in engine.lastVisitOrder.enumerated() { position[id] = index }
        var violations: [String] = []
        for (id, index) in position {
            for input in engine.inputs(of: id) {
                guard let inputIndex = position[input] else { continue }
                if inputIndex > index {
                    violations.append("\(engine.label(of: input)) visited after \(engine.label(of: id))")
                }
            }
        }
        return AuditFinding(
            invariant: "topological visit order",
            passed: violations.isEmpty,
            detail: violations.isEmpty
                ? "visit order \(engine.lastVisitOrder.map { engine.label(of: $0) }.joined(separator: " -> ")) respects every edge"
                : violations.joined(separator: "; ")
        )
    }

    /// A cycle is reported as a typed error and every value is rolled back.
    public static func cycleDetectionAndRollback() -> AuditFinding {
        let engine = CoherenceEngine()
        let a = engine.source(1, label: "a")
        let b = engine.derived(a, label: "b") { Saturating.add($0, 1) }
        let c = engine.derived(b, label: "c") { Saturating.add($0, 1) }
        // Close the loop c -> b, which the public API cannot express.
        engine.unsafeAddEdgeForAuditing(from: c.id, to: b.id)

        let before = (
            a: engine.value(of: a, default: 0),
            b: engine.value(of: b, default: 0),
            c: engine.value(of: c, default: 0)
        )
        do {
            _ = try engine.write(100, to: a)
            return AuditFinding(
                invariant: "cycle detection + rollback",
                passed: false,
                detail: "a cyclic graph committed instead of throwing"
            )
        } catch let error as CoherenceError {
            let after = (
                a: engine.value(of: a, default: 0),
                b: engine.value(of: b, default: 0),
                c: engine.value(of: c, default: 0)
            )
            let isCycle: Bool
            if case .cycleDetected = error { isCycle = true } else { isCycle = false }
            let restored = before == after
            return AuditFinding(
                invariant: "cycle detection + rollback",
                passed: isCycle && restored,
                detail: "threw \(error); values \(restored ? "restored to" : "left at") "
                    + "a=\(after.a) b=\(after.b) c=\(after.c) (pre-transaction a=\(before.a) b=\(before.b) c=\(before.c))"
            )
        } catch {
            return AuditFinding(
                invariant: "cycle detection + rollback",
                passed: false,
                detail: "threw an unexpected error: \(error)"
            )
        }
    }

    /// Sinks that write back during publish terminate with a typed error
    /// instead of recursing forever.
    public static func cascadeBudget() -> AuditFinding {
        let engine = CoherenceEngine(policy: CoherencePolicy(maxCascadeDepth: 4))
        let ping = engine.source(0, label: "ping")

        final class Oscillator: CoherenceSink {
            var write: () -> Void = {}
            func coherenceDidCommit(_ snapshot: CoherenceSnapshot) { write() }
        }
        let oscillator = Oscillator()
        var counter = 0
        oscillator.write = { [weak engine] in
            guard let engine else { return }
            counter += 1
            // Offset past the value the test itself wrote. Writing a bare
            // counter starting at 1 would collide with that first write, the
            // engine would correctly treat it as a no-op, and the cascade would
            // settle — making this check silently prove nothing.
            try? engine.set(Saturating.add(counter, 1_000), for: ping)
        }
        engine.addSink(oscillator)

        do {
            _ = try engine.write(1, to: ping)
            return AuditFinding(
                invariant: "bounded sink cascade",
                passed: false,
                detail: "a non-settling sink cascade returned normally"
            )
        } catch let error as CoherenceError {
            if case .cascadeBudgetExceeded(let depth) = error {
                return AuditFinding(
                    invariant: "bounded sink cascade",
                    passed: true,
                    detail: "a sink that writes on every commit stopped after \(depth) transactions "
                        + "with a typed error instead of recursing"
                )
            }
            return AuditFinding(invariant: "bounded sink cascade", passed: false, detail: "wrong error: \(error)")
        } catch {
            return AuditFinding(invariant: "bounded sink cascade", passed: false, detail: "unexpected error: \(error)")
        }
    }

    /// A domain cannot be owned by two stacks, and a non-owner cannot write it.
    public static func ownershipExclusivity() -> AuditFinding {
        var registry = OwnershipRegistry()
        let cartDomain = Domain("cart")
        do {
            try registry.claim(cartDomain, for: .legacyUIKit)
        } catch {
            return AuditFinding(invariant: "single-writer ownership", passed: false, detail: "first claim threw \(error)")
        }
        var secondClaimRejected = false
        do { try registry.claim(cartDomain, for: .swiftUI) } catch { secondClaimRejected = true }

        var foreignWriteRejected = false
        do { try registry.validateWrite(to: cartDomain, by: .swiftUI) } catch { foreignWriteRejected = true }

        var ownerWriteAllowed = true
        do { try registry.validateWrite(to: cartDomain, by: .legacyUIKit) } catch { ownerWriteAllowed = false }

        // A migration moves domains deliberately. Transfer must succeed from
        // the real owner, fail from a non-owner, and be recorded.
        var transferSucceeded = true
        do { try registry.transfer(cartDomain, from: .legacyUIKit, to: .swiftUI) } catch { transferSucceeded = false }
        var staleTransferRejected = false
        do { try registry.transfer(cartDomain, from: .legacyUIKit, to: .swiftUI) } catch { staleTransferRejected = true }
        let recorded = registry.history.count == 1
        let ownerMoved = registry.owner(of: cartDomain) == .swiftUI

        let passed = secondClaimRejected && foreignWriteRejected && ownerWriteAllowed
            && transferSucceeded && staleTransferRejected && recorded && ownerMoved
        return AuditFinding(
            invariant: "single-writer ownership",
            passed: passed,
            detail: "second claim rejected: \(secondClaimRejected); "
                + "non-owner write rejected: \(foreignWriteRejected); owner write allowed: \(ownerWriteAllowed); "
                + "transfer by owner accepted: \(transferSucceeded); repeat transfer by stale owner rejected: "
                + "\(staleTransferRejected); transfers recorded: \(registry.history.count); "
                + "owner is now \(registry.owner(of: cartDomain).map(String.init(describing:)) ?? "nobody")"
        )
    }

    /// A write equal to the current value publishes nothing.
    public static func minimalPublish() -> AuditFinding {
        let engine = CoherenceEngine()
        let cart = engine.source(10, label: "cart")
        _ = engine.derived(cart, label: "subtotal") { Saturating.multiply($0, 100) }
        do {
            let first = try engine.write(10, to: cart)   // same value
            let second = try engine.write(11, to: cart)  // real change
            return AuditFinding(
                invariant: "no-op writes publish nothing",
                passed: first == nil && second != nil,
                detail: "writing the current value produced \(first == nil ? "no snapshot" : "a snapshot"); "
                    + "writing a new value produced \(second == nil ? "no snapshot" : "a snapshot")"
            )
        } catch {
            return AuditFinding(invariant: "no-op writes publish nothing", passed: false, detail: "threw \(error)")
        }
    }

    /// Runs every invariant. `NaiveDiamond` is included deliberately and is
    /// expected to fail — see `expectedFailures`.
    public static func runAll() -> [AuditFinding] {
        [
            glitchFreedom(of: CoherentDiamond.self),
            glitchFreedom(of: NaiveDiamond.self),
            exactlyOnceRecompute(),
            topologicalVisitOrder(),
            cycleDetectionAndRollback(),
            cascadeBudget(),
            ownershipExclusivity(),
            minimalPublish(),
        ]
    }

    /// The invariants that are *supposed* to fail, because they are run against
    /// the deliberately broken control implementation.
    public static let expectedFailures: Set<String> = ["glitch freedom (NaivePropagator)"]

    /// Every invariant `runAll()` is expected to produce.
    ///
    /// Named explicitly so a truncated or empty report is a failure rather
    /// than a pass: `allSatisfy` on an empty array is `true`, which would make
    /// a gutted `runAll()` look perfectly healthy.
    public static let expectedInvariants: Set<String> = [
        "glitch freedom (CoherenceEngine)",
        "glitch freedom (NaivePropagator)",
        "exactly-once recompute",
        "topological visit order",
        "cycle detection + rollback",
        "bounded sink cascade",
        "single-writer ownership",
        "no-op writes publish nothing",
    ]

    /// True when every check behaved as designed: the report is complete, all
    /// real invariants held, and the control group still fails.
    public static func isHealthy(_ findings: [AuditFinding]) -> Bool {
        guard Set(findings.map(\.invariant)) == expectedInvariants else { return false }
        return findings.allSatisfy { finding in
            expectedFailures.contains(finding.invariant) ? !finding.passed : finding.passed
        }
    }

    /// The report as text, exactly as the README quotes it.
    ///
    /// Exists so the block in the README is reproducible rather than
    /// hand-typed: `swift test --filter testPrintAuditReport` prints this.
    public static func report(_ findings: [AuditFinding] = runAll()) -> String {
        findings.map(\.description).joined(separator: "\n")
    }
}
