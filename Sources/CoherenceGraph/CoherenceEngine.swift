// CoherenceEngine.swift — the coherent propagation core.
//
// WHAT THIS FIXES
//
// Consider the smallest interesting shape in any reactive UI, the diamond:
//
//         cart
//         /   \
//   subtotal  taxRate
//         \   /
//         total
//
// A naive push propagator walks dependents depth-first the moment a value
// changes. Writing `cart` reaches `total` through `subtotal` *before* `taxRate`
// has been recomputed, so `total` is calculated once from a new subtotal and a
// stale tax, publishes that, and is then recalculated correctly. For one
// propagation pass, every observer sees a total that does not equal its own
// line items. This is the classic reactive "glitch", and it is invisible in
// code review because every individual function is correct.
//
// In a single-stack SwiftUI app you often get away with it, because SwiftUI
// coalesces at the frame boundary and the inconsistent intermediate never
// reaches the screen. During a UIKit -> SwiftUI migration you have two
// propagation engines over one source of truth, neither can see the other's
// in-flight state, and the intermediate does reach the screen: a UIKit cell and
// a SwiftUI view render two different answers from the same data in the same
// frame.
//
// THE GUARANTEES
//
// 1. Glitch freedom     - no sink observes a derived value that disagrees with
//                         its own inputs. Enforced by recomputing in
//                         topological order and publishing once, after.
// 2. Exactly-once       - each derived node is recomputed at most once per
//                         transaction, never twice as in the diamond above.
// 3. Atomicity          - a transaction that fails (cycle) restores every value
//                         it touched and publishes nothing.
// 4. Minimal publish    - a node recomputed to an equal value is not reported
//                         as changed and does not dirty its dependents.
// 5. Bounded re-entrancy- a sink that writes during publish does not recurse;
//                         the write is sequenced into a following transaction,
//                         and an oscillating pair fails loudly via the cascade
//                         budget instead of hanging.
//
// ISOLATION
//
// `CoherenceEngine` is a plain `final class` and is deliberately NOT `Sendable`.
// Every operation is synchronous and there is no `await` anywhere inside a
// transaction, so there is no suspension point at which another task could
// observe a half-committed graph. Confining the engine to one isolation domain
// (`CoherenceStore` pins it to the main actor) is therefore sufficient, and the
// reentrancy class of bug that actors invite simply cannot arise here. That is
// a design decision, not an omission: making the engine an actor would add
// `await` to every read in a SwiftUI body and buy nothing.

public final class CoherenceEngine {

    // MARK: - Storage

    private struct NodeRecord {
        /// `nil` means "not yet computed". Only a derived node whose inputs
        /// could not be resolved at registration is ever left unset, and it
        /// resolves on the first commit that touches it. Modelling this as an
        /// optional is what lets the engine avoid a force-unwrap and a trap on
        /// a path that would otherwise need to invent a value of type `V`.
        var value: (any Sendable)?
        /// Captured at registration where the concrete type is statically
        /// known, so equality never needs an unsafe cast.
        let equals: ((any Sendable)?, (any Sendable)?) -> Bool
        var inputs: [NodeID]
        var dependents: [NodeID]
        /// `nil` for source nodes. Returns `nil` if the inputs it was handed do
        /// not match the types it was registered with.
        let recompute: (([any Sendable]) -> (any Sendable)?)?
        let domain: Domain?
        let label: String
    }

    private var nodes: [NodeRecord] = []
    private var dirty: Set<NodeID> = []
    private var pendingWrites: [NodeID: any Sendable] = [:]
    private var sinks: [WeakSink] = []
    private var isPublishing = false
    private var versionCounter: UInt64 = 0

    /// Random per-instance tag stamped into every `NodeID` this engine vends,
    /// so a handle from another engine is rejected rather than silently
    /// writing into an unrelated node of an unrelated type.
    private let identity: UInt64 = .random(in: UInt64.min...UInt64.max)

    public let policy: CoherencePolicy
    public private(set) var ownership: OwnershipRegistry

    /// Counts type mismatches in the erased core.
    ///
    /// With engine identity checked on every lookup, a mismatch means a
    /// derived node's inputs did not match the types it was registered with.
    /// Surfaced rather than swallowed: a silent zero would hide it.
    public private(set) var typeMismatchCount = 0

    /// Order in which nodes were visited by the most recent transaction.
    /// Consumed by `GraphAudit` to prove the order was topological.
    public private(set) var lastVisitOrder: [NodeID] = []

    /// How many times each node was recomputed in the most recent transaction.
    /// Consumed by `GraphAudit` to prove exactly-once recomputation.
    public private(set) var lastRecomputeCounts: [NodeID: Int] = [:]

    /// Every snapshot published by the most recent `commit()`, in order.
    ///
    /// `commit()` returns only the last one, which is what a caller usually
    /// wants — but a sink cascade publishes several, and a facade that reports
    /// only the final state silently collapses exactly the intermediate
    /// publications this package exists to reason about.
    public private(set) var snapshotsFromLastCommit: [CoherenceSnapshot] = []

    public init(policy: CoherencePolicy = .default, ownership: OwnershipRegistry = OwnershipRegistry()) {
        self.policy = policy
        self.ownership = ownership
    }

    private struct WeakSink {
        weak var sink: (any CoherenceSink)?
    }

    // MARK: - Bounds-checked access

    private func record(_ id: NodeID) -> NodeRecord? {
        guard id.engine == identity, nodes.indices.contains(id.rawValue) else { return nil }
        return nodes[id.rawValue]
    }

    private func mutate(_ id: NodeID, _ body: (inout NodeRecord) -> Void) {
        guard id.engine == identity, nodes.indices.contains(id.rawValue) else { return }
        body(&nodes[id.rawValue])
    }

    /// Number of nodes registered.
    public var nodeCount: Int { nodes.count }

    /// Human-readable label for a node, for diagnostics and the demo UI.
    public func label(of id: NodeID) -> String {
        record(id).map { $0.label.isEmpty ? id.description : $0.label } ?? id.description
    }

    /// Inputs of a node, in declaration order.
    public func inputs(of id: NodeID) -> [NodeID] { record(id)?.inputs ?? [] }

    /// Every node id, in registration order.
    public var allNodes: [NodeID] { nodes.indices.map { NodeID(engine: identity, rawValue: $0) } }

    // MARK: - Registration

    /// Registers a writable source node.
    @discardableResult
    public func source<V: Equatable & Sendable>(
        _ initial: V,
        domain: Domain? = nil,
        label: String = ""
    ) -> Node<V> {
        let id = NodeID(engine: identity, rawValue: nodes.count)
        nodes.append(
            NodeRecord(
                value: initial,
                equals: Self.equality(for: V.self),
                inputs: [],
                dependents: [],
                recompute: nil,
                domain: domain,
                label: label
            )
        )
        return Node<V>(id: id)
    }

    /// Registers a node derived from one input.
    @discardableResult
    public func derived<A: Equatable & Sendable, V: Equatable & Sendable>(
        _ a: Node<A>,
        label: String = "",
        _ transform: @escaping (A) -> V
    ) -> Node<V> {
        register(inputs: [a.id], label: label, as: V.self) { values in
            guard values.count == 1, let a0 = values[0] as? A else { return nil }
            return transform(a0)
        }
    }

    /// Registers a node derived from two inputs.
    @discardableResult
    public func derived<A: Equatable & Sendable, B: Equatable & Sendable, V: Equatable & Sendable>(
        _ a: Node<A>,
        _ b: Node<B>,
        label: String = "",
        _ transform: @escaping (A, B) -> V
    ) -> Node<V> {
        register(inputs: [a.id, b.id], label: label, as: V.self) { values in
            guard values.count == 2,
                  let a0 = values[0] as? A,
                  let b0 = values[1] as? B else { return nil }
            return transform(a0, b0)
        }
    }

    /// Registers a node derived from three inputs.
    @discardableResult
    public func derived<A: Equatable & Sendable, B: Equatable & Sendable, C: Equatable & Sendable, V: Equatable & Sendable>(
        _ a: Node<A>,
        _ b: Node<B>,
        _ c: Node<C>,
        label: String = "",
        _ transform: @escaping (A, B, C) -> V
    ) -> Node<V> {
        register(inputs: [a.id, b.id, c.id], label: label, as: V.self) { values in
            guard values.count == 3,
                  let a0 = values[0] as? A,
                  let b0 = values[1] as? B,
                  let c0 = values[2] as? C else { return nil }
            return transform(a0, b0, c0)
        }
    }

    private func register<V: Equatable & Sendable>(
        inputs: [NodeID],
        label: String,
        as _: V.Type,
        _ body: @escaping ([any Sendable]) -> V?
    ) -> Node<V> {
        let id = NodeID(engine: identity, rawValue: nodes.count)
        let erased: ([any Sendable]) -> (any Sendable)? = { values in body(values) }
        nodes.append(
            NodeRecord(
                value: nil,
                equals: Self.equality(for: V.self),
                inputs: inputs,
                dependents: [],
                recompute: erased,
                domain: nil,
                label: label
            )
        )
        for input in inputs {
            mutate(input) { $0.dependents.append(id) }
        }
        // Seed immediately from the already-consistent inputs, so a freshly
        // built graph is readable before any write. If an input handle is not
        // from this engine the node stays unset and the mismatch is counted —
        // a visible `nil`, never a trap.
        seed(id)
        return Node<V>(id: id)
    }

    /// Computes a newly registered derived node from its current inputs.
    private func seed(_ id: NodeID) {
        guard let rec = record(id), let recompute = rec.recompute else { return }
        var inputValues: [any Sendable] = []
        inputValues.reserveCapacity(rec.inputs.count)
        for input in rec.inputs {
            guard let inputRecord = record(input), let value = inputRecord.value else {
                typeMismatchCount += 1
                return
            }
            inputValues.append(value)
        }
        guard let seeded = recompute(inputValues) else {
            typeMismatchCount += 1
            return
        }
        mutate(id) { $0.value = seeded }
    }

    private static func equality<V: Equatable>(for _: V.Type) -> ((any Sendable)?, (any Sendable)?) -> Bool {
        { lhs, rhs in
            switch (lhs, rhs) {
            case (nil, nil): return true
            case (nil, _), (_, nil): return false
            case (let l?, let r?):
                guard let l = l as? V, let r = r as? V else { return false }
                return l == r
            }
        }
    }

    // MARK: - Reading

    /// Current value, or `nil` if the handle is not from this engine (or the
    /// node has not resolved, which only a foreign input can cause).
    public func value<V: Equatable & Sendable>(of node: Node<V>) -> V? {
        guard let stored = record(node.id)?.value else { return nil }
        return stored as? V
    }

    /// Current value, falling back to `fallback` for a foreign handle.
    ///
    /// The cast cannot fail for a handle this engine vended, but the API
    /// refuses to force-unwrap a structurally-impossible branch; SwiftUI call
    /// sites that want a plain value supply a fallback instead.
    public func value<V: Equatable & Sendable>(of node: Node<V>, default fallback: V) -> V {
        value(of: node) ?? fallback
    }

    // MARK: - Writing

    /// Stages a write without committing. Several `set` calls followed by one
    /// `commit()` are coalesced into a single recompute pass and a single
    /// publish — this is the batching path.
    public func set<V: Equatable & Sendable>(
        _ newValue: V,
        for node: Node<V>,
        from stack: Stack? = nil
    ) throws {
        guard let rec = record(node.id) else { throw CoherenceError.unknownNode(node.id) }
        if let domain = rec.domain, let stack {
            try ownership.validateWrite(to: domain, by: stack)
        }
        pendingWrites[node.id] = newValue
        dirty.insert(node.id)
    }

    /// Stages a write and commits immediately.
    @discardableResult
    public func write<V: Equatable & Sendable>(
        _ newValue: V,
        to node: Node<V>,
        from stack: Stack? = nil
    ) throws -> CoherenceSnapshot? {
        try set(newValue, for: node, from: stack)
        return try commit()
    }

    /// Claims a domain for a stack on this engine's registry.
    public func claimDomain(_ domain: Domain, for stack: Stack) throws {
        try ownership.claim(domain, for: stack)
    }

    /// Moves a domain from one stack to the other, recording the move.
    public func transferDomain(_ domain: Domain, from: Stack, to: Stack) throws {
        try ownership.transfer(domain, from: from, to: to)
    }

    // MARK: - Cycle-path test hook

    /// Adds a dependency edge directly, bypassing registration.
    ///
    /// The public API cannot build a cycle: `derived` may only reference nodes
    /// that already exist, so the graph is a DAG by construction. That makes
    /// the cycle branch in `runTransaction` unreachable from outside — and an
    /// unreachable safety branch that nothing exercises is indistinguishable
    /// from a broken one. This internal hook exists solely so `GraphAudit` and
    /// the test suite can build a real cycle and prove the branch detects it
    /// and rolls back. It is not public and is never called in normal use.
    func unsafeAddEdgeForAuditing(from source: NodeID, to dependent: NodeID) {
        guard nodes.indices.contains(source.rawValue),
              nodes.indices.contains(dependent.rawValue) else { return }
        // Both halves of the edge. Appending only to `dependents` would make
        // the cone reachable but leave the in-degree unchanged, and Kahn's
        // algorithm would order the graph happily — a back edge that is not
        // also an input is not a cycle.
        mutate(source) { $0.dependents.append(dependent) }
        mutate(dependent) { $0.inputs.append(source) }
    }

    // MARK: - Sinks

    /// Registers a sink. The engine holds it weakly.
    public func addSink(_ sink: any CoherenceSink) {
        sinks.append(WeakSink(sink: sink))
    }

    // MARK: - Commit

    /// Runs staged writes to completion.
    ///
    /// Returns the snapshot of the last transaction performed, or `nil` when
    /// nothing was staged or every staged write was a no-op.
    @discardableResult
    public func commit() throws -> CoherenceSnapshot? {
        guard !isPublishing else {
            // Re-entrant commit from inside a sink. The write is already staged;
            // the outer commit loop will pick it up. Recursing here is exactly
            // the bug this class exists to prevent.
            return nil
        }
        var depth = 0
        var last: CoherenceSnapshot?
        snapshotsFromLastCommit.removeAll(keepingCapacity: true)
        while !dirty.isEmpty {
            depth += 1
            if depth > policy.maxCascadeDepth {
                dirty.removeAll()
                pendingWrites.removeAll()
                throw CoherenceError.cascadeBudgetExceeded(depth: policy.maxCascadeDepth)
            }
            guard let snapshot = try runTransaction(cascadeDepth: depth) else { continue }
            last = snapshot
            snapshotsFromLastCommit.append(snapshot)
            publish(snapshot)
        }
        return last
    }

    private func runTransaction(cascadeDepth: Int) throws -> CoherenceSnapshot? {
        let dirtySources = dirty
        dirty.removeAll()

        // Captures the pre-transaction value of every node this transaction
        // writes, so a cycle can be rolled back to an exactly-consistent state.
        // `rollback.keys.contains` is used rather than `rollback[id] == nil`,
        // because the stored value is itself optional and `== nil` would
        // conflate "not captured" with "captured as unset".
        var rollback: [NodeID: (any Sendable)?] = [:]
        var changed: Set<NodeID> = []

        // 1. Apply staged source writes. A write equal to the current value is
        //    not a change and does not dirty anything downstream.
        for id in dirtySources.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let newValue = pendingWrites.removeValue(forKey: id),
                  let rec = record(id) else { continue }
            guard !rec.equals(rec.value, newValue) else { continue }
            rollback[id] = rec.value
            mutate(id) { $0.value = newValue }
            changed.insert(id)
        }
        guard !changed.isEmpty else { return nil }

        // 2. Forward cone of everything reachable from the changed sources.
        //    Terminates even in the presence of a cycle: each node is enqueued
        //    at most once.
        var affected: Set<NodeID> = []
        var frontier = Array(changed)
        while let id = frontier.popLast() {
            guard affected.insert(id).inserted else { continue }
            for dependent in record(id)?.dependents ?? [] {
                frontier.append(dependent)
            }
        }

        // 3. In-degree restricted to the affected cone.
        var indegree: [NodeID: Int] = [:]
        for id in affected {
            var count = 0
            for input in record(id)?.inputs ?? [] where affected.contains(input) {
                count += 1
            }
            indegree[id] = count
        }

        // 4. Kahn's algorithm. Sorting the seed queue makes the visit order
        //    deterministic, which is what lets the audit assert on it.
        var queue = affected.filter { indegree[$0] == 0 }.sorted { $0.rawValue < $1.rawValue }
        var head = 0
        var visitOrder: [NodeID] = []
        var recomputeCounts: [NodeID: Int] = [:]
        var recomputedCount = 0

        while head < queue.count {
            let id = queue[head]
            head += 1
            visitOrder.append(id)

            if let rec = record(id), let recompute = rec.recompute {
                // Recompute only if an input actually changed. Skipping an
                // unchanged branch is safe here precisely because the visit is
                // topological: every input has already been finalised.
                let inputChanged = rec.inputs.contains { changed.contains($0) }
                if inputChanged {
                    var inputValues: [any Sendable] = []
                    inputValues.reserveCapacity(rec.inputs.count)
                    var resolved = true
                    for input in rec.inputs {
                        guard let inputRecord = record(input),
                              let inputValue = inputRecord.value else { resolved = false; break }
                        inputValues.append(inputValue)
                    }
                    if resolved, let newValue = recompute(inputValues) {
                        recomputedCount += 1
                        recomputeCounts[id, default: 0] += 1
                        if !rec.equals(rec.value, newValue) {
                            if !rollback.keys.contains(id) { rollback[id] = rec.value }
                            mutate(id) { $0.value = newValue }
                            changed.insert(id)
                        }
                    } else {
                        typeMismatchCount += 1
                    }
                }
            }

            for dependent in record(id)?.dependents ?? [] where affected.contains(dependent) {
                guard let remaining = indegree[dependent] else { continue }
                let next = remaining - 1
                indegree[dependent] = next
                if next == 0 { queue.append(dependent) }
            }
        }

        // 5. Anything left unvisited is in a cycle. Roll back and report.
        if visitOrder.count < affected.count {
            for (id, value) in rollback {
                mutate(id) { $0.value = value }
            }
            let unresolved = affected.subtracting(visitOrder).sorted { $0.rawValue < $1.rawValue }
            throw CoherenceError.cycleDetected(unresolved)
        }

        lastVisitOrder = visitOrder
        lastRecomputeCounts = recomputeCounts
        // Saturating rather than wrapping: a version that stops rising is
        // debuggable, a version that goes backwards corrupts every consumer.
        versionCounter = versionCounter == UInt64.max ? UInt64.max : versionCounter + 1

        return CoherenceSnapshot(
            version: versionCounter,
            changed: changed,
            recomputedCount: recomputedCount,
            cascadeDepth: cascadeDepth
        )
    }

    private func publish(_ snapshot: CoherenceSnapshot) {
        isPublishing = true
        defer { isPublishing = false }
        sinks.removeAll { $0.sink == nil }
        // Iterate a copy: a sink may add another sink during notification.
        for entry in sinks {
            entry.sink?.coherenceDidCommit(snapshot)
        }
    }
}
