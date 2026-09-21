import XCTest
@testable import CoherenceGraph

/// `engine.commit()` runs the whole sink cascade and returns only the final
/// snapshot. A facade that forwarded just that return value would silently
/// collapse exactly the intermediate publications this package exists to
/// reason about.
final class StoreCascadeTests: XCTestCase {

    func testEngineRecordsEverySnapshotOfACascade() throws {
        let engine = CoherenceEngine(policy: CoherencePolicy(maxCascadeDepth: 8))
        let ping = engine.source(0, label: "ping")

        final class TwoShot: CoherenceSink {
            var write: (Int) -> Void = { _ in }
            private(set) var notifications = 0
            func coherenceDidCommit(_ snapshot: CoherenceSnapshot) {
                notifications += 1
                if notifications <= 2 { write(notifications) }
            }
        }
        let sink = TwoShot()
        sink.write = { [weak engine] n in try? engine?.set(100 + n, for: ping) }
        engine.addSink(sink)

        let last = try engine.write(1, to: ping)
        XCTAssertEqual(engine.snapshotsFromLastCommit.count, 3, "one write plus two sink-driven follow-ups")
        XCTAssertEqual(engine.snapshotsFromLastCommit.map(\.cascadeDepth), [1, 2, 3])
        XCTAssertEqual(last, engine.snapshotsFromLastCommit.last)
        XCTAssertEqual(engine.value(of: ping), 102)
    }

    func testSnapshotsAreClearedBetweenCommits() throws {
        let engine = CoherenceEngine()
        let a = engine.source(0, label: "a")
        try engine.write(1, to: a)
        XCTAssertEqual(engine.snapshotsFromLastCommit.count, 1)
        try engine.write(2, to: a)
        XCTAssertEqual(engine.snapshotsFromLastCommit.count, 1, "the previous commit's snapshots must not accumulate")
    }

    func testStoreForwardsEveryTransactionNotJustTheLast() async throws {
        try await MainActor.run {
            let store = CoherenceStore(policy: CoherencePolicy(maxCascadeDepth: 8))
            let ping = store.engine.source(0, label: "ping")

            final class TwoShot: CoherenceSink {
                var write: (Int) -> Void = { _ in }
                private(set) var notifications = 0
                func coherenceDidCommit(_ snapshot: CoherenceSnapshot) {
                    notifications += 1
                    if notifications <= 2 { write(notifications) }
                }
            }
            let sink = TwoShot()
            let engine = store.engine
            sink.write = { [weak engine] n in try? engine?.set(100 + n, for: ping) }
            engine.addSink(sink)

            var seen: [Int] = []
            store.onCommit = { seen.append($0.cascadeDepth) }
            try store.write(1, to: ping)

            XCTAssertEqual(seen, [1, 2, 3], "onCommit must fire once per transaction, not once per commit()")
        }
    }

    func testStoreFiresNothingForANoOpWrite() async throws {
        try await MainActor.run {
            let store = CoherenceStore()
            let a = store.engine.source(7, label: "a")
            var fired = 0
            store.onCommit = { _ in fired += 1 }
            try store.write(7, to: a)
            XCTAssertEqual(fired, 0)
            try store.write(8, to: a)
            XCTAssertEqual(fired, 1)
        }
    }
}
