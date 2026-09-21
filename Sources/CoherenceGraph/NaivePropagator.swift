// NaivePropagator.swift
//
// The control group.
//
// This is a deliberately naive push propagator: the implementation almost every
// hand-rolled observable layer converges on, and the one a UIKit codebase
// accumulates by hand over years of `didSet` blocks calling other objects'
// update methods. It is included as *shipping library code*, not test scaffold,
// for one reason: a claim that `CoherenceEngine` eliminates glitches is
// unfalsifiable unless something in the repo actually exhibits one.
//
// `GraphAudit` runs the identical consistency check against both
// implementations. The check must pass for `CoherenceEngine` and must FAIL
// here. An audit that cannot fail is decoration.
//
// It is `Int`-only and intentionally minimal. Do not use it for anything.

/// A depth-first push propagator that exhibits the reactive glitch.
public final class NaivePropagator {

    private struct Node {
        var value: Int
        let inputs: [Int]
        var dependents: [Int]
        let recompute: (([Int]) -> Int)?
    }

    private var nodes: [Node] = []

    /// Called every time any node's value is written, including the
    /// intermediate inconsistent writes that are the point of this type.
    public var onNodeUpdated: ((_ index: Int, _ value: Int) -> Void)?

    /// One recorded write, with the whole graph as it stood at that instant.
    ///
    /// The full snapshot is the point. An update log of `(index, value)` pairs
    /// is useless for showing a glitch after the fact, because reading the
    /// other nodes later returns their settled values and the inconsistent
    /// moment has already vanished.
    public struct Update: Equatable, Sendable {
        public let index: Int
        public let value: Int
        public let snapshot: [Int]

        /// Bounds-checked read from the snapshot.
        public func value(at index: Int) -> Int? {
            snapshot.indices.contains(index) ? snapshot[index] : nil
        }
    }

    /// Bounded record of every write since the last `clearUpdateLog()`.
    ///
    /// Exists so a main-actor view model can read the history without
    /// installing a callback on this non-isolated type, which Swift 6 rejects.
    public private(set) var updateLog: [Update] = []

    /// Caps the log so a long-lived propagator cannot grow without bound.
    private let updateLogLimit = 256

    public func clearUpdateLog() { updateLog.removeAll(keepingCapacity: true) }

    public init() {}

    /// Registers a writable source, returning its index.
    public func source(_ initial: Int) -> Int {
        nodes.append(Node(value: initial, inputs: [], dependents: [], recompute: nil))
        return nodes.count - 1
    }

    /// Registers a derived node, returning its index.
    public func derived(_ inputs: [Int], _ transform: @escaping ([Int]) -> Int) -> Int {
        let index = nodes.count
        let seedInputs = inputs.compactMap { i -> Int? in
            nodes.indices.contains(i) ? nodes[i].value : nil
        }
        let seed = seedInputs.count == inputs.count ? transform(seedInputs) : 0
        nodes.append(Node(value: seed, inputs: inputs, dependents: [], recompute: transform))
        for input in inputs where nodes.indices.contains(input) {
            nodes[input].dependents.append(index)
        }
        return index
    }

    /// Current value, or `nil` for an out-of-range index.
    public func value(at index: Int) -> Int? {
        nodes.indices.contains(index) ? nodes[index].value : nil
    }

    /// Writes a source and pushes depth-first through dependents.
    ///
    /// This is where the glitch is born: the first dependent is fully
    /// propagated to the leaves before the second dependent has been touched,
    /// so any node downstream of both is computed once from a mixture of new
    /// and stale inputs — and that mixture is published.
    public func set(_ newValue: Int, at index: Int) {
        guard nodes.indices.contains(index) else { return }
        nodes[index].value = newValue
        recordUpdate(index: index, value: newValue)
        onNodeUpdated?(index, newValue)
        // `depth` bounds the recursion so a cyclic graph fails to terminate
        // *visibly* rather than blowing the stack. The naive design has no
        // better answer than a magic number, which is itself the point.
        push(from: index, depth: 0)
    }

    private func push(from index: Int, depth: Int) {
        guard depth < 64 else { return }
        guard nodes.indices.contains(index) else { return }
        for dependent in nodes[index].dependents {
            guard nodes.indices.contains(dependent),
                  let recompute = nodes[dependent].recompute else { continue }
            var inputValues: [Int] = []
            inputValues.reserveCapacity(nodes[dependent].inputs.count)
            var resolved = true
            for input in nodes[dependent].inputs {
                guard nodes.indices.contains(input) else { resolved = false; break }
                inputValues.append(nodes[input].value)
            }
            guard resolved else { continue }
            let updated = recompute(inputValues)
            nodes[dependent].value = updated
            recordUpdate(index: dependent, value: updated)
            onNodeUpdated?(dependent, updated)
            push(from: dependent, depth: depth + 1)
        }
    }

    private func recordUpdate(index: Int, value: Int) {
        updateLog.append(Update(index: index, value: value, snapshot: nodes.map(\.value)))
        if updateLog.count > updateLogLimit {
            updateLog.removeFirst(updateLog.count - updateLogLimit)
        }
    }
}
