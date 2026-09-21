// CoherenceTypes.swift — identifiers, handles, errors and policy.

/// Opaque, stable identity for a node in a `CoherenceEngine`.
///
/// The raw value is an index into the engine's dense storage. It is
/// deliberately not public to write: a `NodeID` can only be obtained from the
/// engine that created it, which is what lets every lookup be bounds-checked
/// against that engine rather than trusted.
public struct NodeID: Hashable, Sendable, CustomStringConvertible {
    /// Identity of the engine that vended this id.
    ///
    /// Without it, a handle from a *different* engine whose index happens to
    /// be in range is silently accepted: the write lands in a node of an
    /// unrelated type, every dependent then fails its cast, and the graph
    /// quietly stops updating instead of crashing. Bounds-checking alone does
    /// not catch that, because both engines number their nodes from zero.
    ///
    /// A per-instance random value rather than `ObjectIdentifier`: an address
    /// can be reused after an engine is deallocated, and a stale handle would
    /// then match a brand-new engine. A random 64-bit tag needs no global
    /// counter, no synchronisation, and survives deallocation.
    @usableFromInline let engine: UInt64
    @usableFromInline let rawValue: Int
    @usableFromInline init(engine: UInt64, rawValue: Int) {
        self.engine = engine
        self.rawValue = rawValue
    }
    public var description: String { "#\(rawValue)" }
}

/// A typed handle to a node.
///
/// `Node<Value>` is the only way to read or write a node, and the engine only
/// ever vends one at the type it stored. That is what keeps the erased core
/// (which stores `any Sendable`) type-safe at the API boundary.
public struct Node<Value: Equatable & Sendable>: Hashable, Sendable {
    public let id: NodeID
    init(id: NodeID) { self.id = id }
}

/// Which UI stack owns a domain's truth during a migration.
public enum Stack: String, Sendable, CaseIterable, CustomStringConvertible {
    case legacyUIKit
    case swiftUI
    public var description: String {
        switch self {
        case .legacyUIKit: return "legacy UIKit"
        case .swiftUI: return "SwiftUI"
        }
    }
}

/// A named slice of application state that exactly one `Stack` may write.
public struct Domain: Hashable, Sendable, CustomStringConvertible {
    public let name: String
    public init(_ name: String) { self.name = name }
    public var description: String { name }
}

/// Failures a commit can report.
///
/// Every case is a condition the naive implementation turns into a hang, a
/// crash, or silent corruption. Making them typed values is the point.
public enum CoherenceError: Error, Equatable, CustomStringConvertible {
    /// The dirty subgraph contains a dependency cycle. Carries the nodes that
    /// could not be ordered. The transaction is rolled back.
    case cycleDetected([NodeID])
    /// Sinks kept writing during publish and the cascade did not settle within
    /// `CoherencePolicy.maxCascadeDepth` transactions. The graph is left at the
    /// last successfully committed state.
    case cascadeBudgetExceeded(depth: Int)
    /// A write was attempted from a stack that does not own the node's domain.
    case ownershipViolation(domain: Domain, owner: Stack, attemptedBy: Stack)
    /// A domain was claimed by a second stack.
    case domainAlreadyOwned(domain: Domain, owner: Stack)
    /// A transfer was attempted for a domain nobody owns.
    case domainNotOwned(domain: Domain)
    /// A write was attempted against a derived node.
    ///
    /// A derived value is a function of its inputs. Writing one directly
    /// produces a state no input could have produced, and the topological walk
    /// will not correct it — the node's own inputs did not change, so it is
    /// not recomputed, and the fabricated value propagates downward and is
    /// published. `derived` and `source` return the same `Node<V>` type, so
    /// the type system cannot catch this; the engine does.
    case notASource(NodeID)
    /// The handle was not vended by this engine, or its index is out of range.
    case unknownNode(NodeID)

    public var description: String {
        switch self {
        case .cycleDetected(let nodes):
            return "cycle detected among \(nodes.map(\.description).joined(separator: ", "))"
        case .cascadeBudgetExceeded(let depth):
            return "cascade did not settle within \(depth) transactions"
        case .ownershipViolation(let domain, let owner, let attemptedBy):
            return "\(attemptedBy) wrote '\(domain)', which is owned by \(owner)"
        case .domainAlreadyOwned(let domain, let owner):
            return "'\(domain)' is already owned by \(owner)"
        case .domainNotOwned(let domain):
            return "'\(domain)' is not owned by any stack, so there is nothing to transfer"
        case .notASource(let id):
            return "node \(id) is derived; write its inputs instead"
        case .unknownNode(let id):
            return "node \(id) was not vended by this engine"
        }
    }
}

/// Tunable limits. Injected rather than hardcoded so tests can drive the
/// failure paths without waiting on production-sized budgets.
public struct CoherencePolicy: Sendable, Equatable {
    /// Maximum number of chained transactions a single `commit()` may run when
    /// sinks write back during publish. Clamped to at least 1.
    public let maxCascadeDepth: Int

    public init(maxCascadeDepth: Int = 8) {
        // Clamped rather than precondition-failed: a policy value is often
        // config-driven, and a bad config should degrade, not crash.
        self.maxCascadeDepth = max(1, min(maxCascadeDepth, 1_000))
    }

    public static let `default` = CoherencePolicy()
}

/// Metadata published to sinks after a successful commit.
public struct CoherenceSnapshot: Sendable, Equatable {
    /// Monotonic commit counter. Saturates rather than wrapping; at one commit
    /// per nanosecond this would take ~584 years to reach, and a wrapped
    /// version that went backwards would be worse than one that stops rising.
    public let version: UInt64
    /// Nodes whose value actually changed in this commit. A node that was
    /// recomputed to the same value is deliberately absent.
    public let changed: Set<NodeID>
    /// How many derived nodes the engine actually recomputed.
    public let recomputedCount: Int
    /// How deep the sink-write cascade went. 1 means sinks did not write back.
    public let cascadeDepth: Int
}

/// Receives one notification per committed transaction, after every derived
/// value in the graph is already consistent.
///
/// Held weakly by the engine, so conforming to it does not create a retain
/// cycle between a view model and the graph it observes.
public protocol CoherenceSink: AnyObject {
    func coherenceDidCommit(_ snapshot: CoherenceSnapshot)
}
