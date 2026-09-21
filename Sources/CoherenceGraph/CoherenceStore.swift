// CoherenceStore.swift
//
// The isolation story, stated once and enforced by the type system.
//
// `CoherenceEngine` is synchronous and non-`Sendable` by design. This facade
// pins one to the main actor, which is where UI state belongs, and is the
// supported way to touch a graph from concurrent code: every caller hops to the
// main actor, and because a transaction contains no `await`, no two
// transactions can interleave. The engine therefore needs no locks, and the
// actor-reentrancy class of bug — read state, `await`, act on state that
// changed during the suspension — has nowhere to occur.
//
// The alternative, making the engine itself an actor, was rejected: it would
// make every read in a SwiftUI `body` an `await`, which is not expressible, and
// it would introduce exactly the suspension points this design removes.

/// Main-actor-confined owner of a `CoherenceEngine`.
@MainActor
public final class CoherenceStore {

    public let engine: CoherenceEngine

    /// Invoked after every committed transaction.
    ///
    /// Deliberately a callback rather than a registered `CoherenceSink`: the
    /// engine publishes synchronously inside the main-actor call that caused
    /// the commit, so the store already has the snapshot in hand and does not
    /// need a back-reference. Routing it through a `nonisolated` sink would
    /// mean claiming isolation the compiler cannot verify, in exchange for
    /// nothing. Non-UI observers still register as sinks directly on `engine`.
    public var onCommit: ((CoherenceSnapshot) -> Void)?

    public init(policy: CoherencePolicy = .default) {
        self.engine = CoherenceEngine(policy: policy)
    }

    /// Stages a write without committing.
    public func set<V: Equatable & Sendable>(_ value: V, for node: Node<V>, from stack: Stack? = nil) throws {
        try engine.set(value, for: node, from: stack)
    }

    /// Stages a write and commits.
    @discardableResult
    public func write<V: Equatable & Sendable>(_ value: V, to node: Node<V>, from stack: Stack? = nil) throws -> CoherenceSnapshot? {
        try set(value, for: node, from: stack)
        return try commit()
    }

    /// Commits everything staged so far as one transaction.
    @discardableResult
    public func commit() throws -> CoherenceSnapshot? {
        let snapshot = try engine.commit()
        if let snapshot { onCommit?(snapshot) }
        return snapshot
    }

    /// Reads a node, falling back for a handle this engine did not vend.
    public func value<V: Equatable & Sendable>(of node: Node<V>, default fallback: V) -> V {
        engine.value(of: node, default: fallback)
    }
}
