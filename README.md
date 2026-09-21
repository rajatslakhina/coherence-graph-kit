# CoherenceGraph

**Your receipt shows a total for a cart that never existed. For one frame. Then it corrects itself, which is why nobody has ever filed the bug.**

This package is about the smallest graph in which update *order* becomes observable, and about what happens to that graph when a codebase has two propagation engines — a legacy UIKit stack and SwiftUI — running over one source of truth.

---

## The bug

```
          cart
         /    \
   subtotal    tax
         \    /
         total
```

`subtotal` and `tax` both derive from `cart`. `total` derives from both. A push propagator — the thing a hand-rolled observable layer becomes after two years of `didSet` blocks calling other objects' update methods — walks dependents depth-first the moment a value changes:

1. `cart` 10 → 25
2. recompute `subtotal` → 2500, push to its dependents
3. recompute `total` → 2500 + **80** = 2580 ← **published**
4. recompute `tax` → 200, push to its dependents
5. recompute `total` → 2500 + 200 = 2700 ← published

Step 3 is the defect. `subtotal` came from a cart of 25 and `tax` still came from a cart of 10, so the state published to every observer describes a cart that has never existed in the system.

Note what is *not* wrong with it: `2500 + 80 == 2580`. The apex is perfectly consistent with its own inputs. Every individual function is correct. An invariant that only asks "does the total equal the sum of the line items?" passes this state — which is exactly why the first version of this package's audit passed the broken implementation, and why the check now includes the source value. That mistake is preserved in the comments on `GraphState`.

This is the reactive **glitch**, and it is invisible in code review because there is no line of code to point at.

## Why it matters more during a migration

In a single-stack SwiftUI app you usually get away with it. SwiftUI coalesces at the frame boundary, so the inconsistent intermediate frequently never reaches the screen.

During a UIKit → SwiftUI migration you have **two propagation engines over one source of truth**, and neither can see the other's in-flight state. Now the intermediate does reach the screen: a UIKit cell and a SwiftUI view, in the same frame, rendering two different answers from the same data. The bug report says "the totals flicker sometimes," it never reproduces on the reporter's device, and it closes as unactionable.

That is the Engineering-Lead-shaped problem here. It is not "adopt Observation." It is: **who owns truth, in what order does a change become visible, and what does the other stack see while that is happening.**

## The guarantees

| Guarantee | What it means | Enforced by |
|---|---|---|
| **Glitch freedom** | No observer sees a derived value that disagrees with the source it came from | Topological recompute, single publish after |
| **Exactly-once recompute** | A diamond apex is recomputed once per transaction, not twice | Kahn's algorithm over the dirty cone |
| **Atomicity** | A transaction that fails restores every value it touched and publishes nothing | Pre-write rollback capture |
| **Minimal publish** | A node recomputed to an equal value is not reported changed and does not dirty its dependents | Equality pruning inside the topological walk |
| **Bounded re-entrancy** | A sink that writes during publish is sequenced, not recursed; an oscillating pair fails loudly | `isPublishing` gate + cascade budget |
| **Single-writer ownership** | A state domain has exactly one owning stack; the other gets a typed error | `OwnershipRegistry` |

## Design decisions, and what was rejected

**The engine is a synchronous `final class`, deliberately not `Sendable`.**
Rejected: making it an `actor`. An actor would put an `await` in front of every read, which is not expressible inside a SwiftUI `body`, and it would introduce suspension points *inside* transactions — the exact reentrancy hazard this design removes. Instead `CoherenceStore` pins an engine to the main actor. Because a transaction contains no `await`, no two transactions can interleave, so the engine needs no locks and actor-reentrancy bugs have nowhere to occur.

**Equality pruning happens inside the topological walk, not before it.**
Rejected: computing a minimal dirty set up front. Pruning is only *safe* mid-walk because the visit is topological — when a node is reached, every one of its inputs is already final, so "did any input change?" is a question with a settled answer. Pruning before the walk has to guess.

**Values are type-erased in the core, typed at the boundary.**
Rejected: `CoherenceGraph<Value>` generic over a single value type, which would force every node in a graph to be the same type. The erased core stores `any Sendable` with an equality function captured at registration where the concrete type is statically known, so equality never needs an unsafe cast, and `Node<V>` keeps the API type-safe.

**A node's stored value is optional.**
Rejected: seeding derived nodes with a caller-supplied default, and rejected: force-unwrapping. Modelling "not yet computed" as `nil` is what lets the package avoid needing to invent a value of an arbitrary type `V` on the one path — a `Node` handle from a *different* engine — where it otherwise could not. That path returns `nil` and increments `typeMismatchCount` rather than trapping.

**Saturating arithmetic, not wrapping.**
Every operation that can trap (`+`, `*`, `/`, `%`, and `Int.min / -1`) goes through `Saturating`. Rejected: `&+`. Wrapping turns a too-large total into a *negative* one, which renders as a plausible number and is a silent correctness bug. Saturation clamps to something obviously wrong at the edge, and therefore visible.

**Cycles are unrepresentable through the public API.**
`derived` may only reference nodes that already exist, so the graph is a DAG by construction. The cycle branch in `runTransaction` is therefore unreachable from outside — and an unreachable safety branch that nothing exercises is indistinguishable from a broken one. An `internal` hook (`unsafeAddEdgeForAuditing`) exists solely so the audit and the test suite can build a real cycle and prove the branch detects it *and* rolls back.

## The control group ships with the library

`NaivePropagator` is a deliberately broken depth-first push propagator, and it is shipping library code rather than test scaffold, for one reason:

> A claim that this package eliminates glitches is unfalsifiable unless something in the repo actually exhibits one.

`GraphAudit` runs the identical coherence check against both implementations. It **must** pass for `CoherenceEngine` and **must fail** for `NaivePropagator`. `GraphAudit.isHealthy(_:)` returns `true` only when the real invariants held *and* the control group still failed. If the control group ever starts passing, the audit is reporting nothing and says so.

The same idea runs through the test suite. `testCycleDetectionIsNotVacuous` builds the same graph *without* the back edge and asserts it commits — otherwise `testCycleIsDetectedAndTheTransactionRollsBack` would pass against an engine that throws on every write. `testSettlingSinkCascadeCompletes` is the counterpart to the cascade-budget test. `testReadingCurrentValuesInsteadOfSnapshotsWouldHideTheGlitch` proves why the demo reads snapshots.

## Executed invariants

`GraphAudit.runAll()` does not assert; it builds graphs, drives them, and reports what happened. This block is the literal output of `GraphAudit.report()` — reproduce it with:

```
swift test --filter testPrintAuditReport
```

```
PASS  glitch freedom (CoherenceEngine) — CoherenceEngine: all 1 published state(s) were a consistent function of the source
FAIL  glitch freedom (NaivePropagator) — NaivePropagator: 1 of 2 published state(s) were not a consistent function of the source (first: cart=25 subtotal=2500 tax=80 total=2580  <- INCOHERENT)
PASS  exactly-once recompute — 3 derived node(s) recomputed, max recomputes for any one node = 1 (a depth-first push recomputes the diamond apex twice)
PASS  topological visit order — visit order cart -> subtotal -> tax -> total respects every edge
PASS  cycle detection + rollback — threw cycle detected among #1, #2; values restored to a=1 b=2 c=3 (pre-transaction a=1 b=2 c=3)
PASS  bounded sink cascade — a sink that writes on every commit stopped after 4 transactions with a typed error instead of recursing
PASS  single-writer ownership — second claim rejected: true; non-owner write rejected: true; owner write allowed: true; transfer by owner accepted: true; repeat transfer by stale owner rejected: true; transfers recorded: 1; owner is now SwiftUI
PASS  no-op writes publish nothing — writing the current value produced no snapshot; writing a new value produced a snapshot
```

The `FAIL` row is the control group and is supposed to be there. `GraphAudit.isHealthy(_:)` returns `true` only when the report is **complete** (an empty or truncated report is a failure, because `allSatisfy` on an empty array is vacuously `true`), every real invariant held, and the control group still failed.

## Usage

```swift
import CoherenceGraph

let engine = CoherenceEngine()

let cart     = engine.source(10, label: "cart")
let subtotal = engine.derived(cart, label: "subtotal") { Saturating.multiply($0, 100) }
let tax      = engine.derived(cart, label: "tax")      { Saturating.multiply($0, 8) }
let total    = engine.derived(subtotal, tax, label: "total") { Saturating.add($0, $1) }

try engine.write(25, to: cart)
engine.value(of: total)               // Optional(2700) — and no observer ever saw 2580
```

Batching several writes into one publish:

```swift
let taxRate = engine.source(8, label: "taxRate")          // percent, in whole points
let tax     = engine.derived(cart, taxRate, label: "tax") { Saturating.multiply($0, $1) }

try engine.set(25, for: cart)
try engine.set(9, for: taxRate)
try engine.commit()                   // one recompute pass, one notification
```

Declaring a single writer during a migration:

```swift
try engine.claimDomain(Domain("cart"), for: .swiftUI)
let cart = engine.source(10, domain: Domain("cart"), label: "cart")

try engine.set(1, for: cart, from: .legacyUIKit)
// throws .ownershipViolation(domain: cart, owner: SwiftUI, attemptedBy: legacy UIKit)
```

### Installation

```swift
.package(url: "https://github.com/rajatslakhina/coherence-graph-kit.git", from: "2.0.0")
```

### Running it yourself

```bash
git clone https://github.com/rajatslakhina/coherence-graph-kit.git
cd coherence-graph-kit
rm -rf .build && swift build -Xswiftc -warnings-as-errors   # zero warnings
swift test                                                   # 69 tests
swift test --filter testPrintAuditReport                     # prints the block above
```

Linux or macOS both work for the library; `CoherenceGraphUI` needs an Apple SDK, and the [demo app](#demo-app) is the way to see it.

## Demo app

**[coherence-graph-demo-app](https://github.com/rajatslakhina/coherence-graph-demo-app)** — a runnable iOS app that builds both graphs side by side and lets you watch the naive one publish a cart that never existed. It consumes this package as a *remote* `XCRemoteSwiftPackageReference` pinned `upToNextMajorVersion` from a released tag, never a local path and never `branch = main`.

This repository deliberately contains **no app target of any kind** — no executable product, no `.xcodeproj`. The runnable app lives in its own repository and depends on this one exactly the way any other consumer would.

## Verification

- **Clean `swift build -Xswiftc -warnings-as-errors`, zero warnings.** `.build` is removed first, because `swift build` on an up-to-date tree compiles nothing and still prints "Build complete!" — which is evidence of nothing. The claim is machine-enforced in CI, not asserted here.
- **69 XCTest tests, 0 failures** on Swift 6.0.3.
- **CI: [Actions](https://github.com/rajatslakhina/coherence-graph-kit/actions).** The Linux job re-runs the clean warnings-as-errors build, builds the tests under the same flag, and runs the suite. The macOS job compiles **every** scheme for `generic/platform=iOS Simulator` — and that job is load-bearing rather than tidy, because `CoherenceGraphUI` sits entirely inside `#if canImport(SwiftUI)` and the Linux job therefore compiles none of it. The scheme count is checked explicitly: a `while read` over an empty list exits 0, and a green job that built nothing is worse than a red one.
- **The app was never run on a Simulator, and no screenshots exist in either repository.** This package was built by an unattended scheduled job that is refused interactive control of the machine. "Compiles for an iOS Simulator destination" is not "ran on a Simulator," and nothing here claims it is.

### What is therefore still untested

The Linux suite covers the engine, the audit, ownership and its transfer history, guarded arithmetic, display formatting and the update log. The SwiftUI layer (`CoherenceDemoView`, `CoherenceDemoModel`) is **compiled** for iOS by the macOS job and by the demo app's own CI, but its runtime behaviour — that the panels actually render two rows against one — has never been observed on a device.

Two things deliberately narrow that gap. `UpdateLogTests` exercises the exact snapshot reconstruction the view model performs. And the logic that would otherwise have hidden inside the view — currency formatting, slider-to-quantity clamping, and the row narrative that names which quantity each value came from — lives in the core module instead, where `DisplayTests` and `GraphStateNarrativeTests` actually run it. What remains untested is SwiftUI layout and wiring, not arithmetic or text.

## Scope, and what this deliberately does not do

Naming the edges is part of the design, not an apology for it.

**No node teardown.** `CoherenceEngine.nodes` only grows; there is no `remove` or `reset`. That is fine for a graph built once at startup and wrong for the thing this README pitches — a long-lived store that screens register derived nodes against as they appear. Adding removal means deciding what happens to a dependent of a removed node, which is a real design question (cascade? orphan? refuse?) and not one to answer by accident. Until it is answered, build graphs whose node set is fixed.

**No UIKit in this repository.** The migration argument is about two propagation engines over one source of truth, and `NaivePropagator` stands in for the legacy one. It is a faithful model of the *propagation* defect — it is not a UIKit view hierarchy, and nothing here renders from UIKit. The "same frame, two answers" scenario is therefore reasoned about here and demonstrated only in the propagation layer.

**No scale claims.** The worked example is four nodes. Commit is `O(affected + edges)` over the dirty cone, which is the right shape, but nothing in this repository benchmarks a large graph, so there is no performance claim to quote.

**Ownership transfer is manual and single-step.** `transfer(_:from:to:)` moves one domain and records it. There is no notion of a staged rollout, a percentage, or an automatic rollback — a migration is a sequence of deliberate human decisions here, and the registry's job is only to make each one explicit and auditable.

## License

MIT
