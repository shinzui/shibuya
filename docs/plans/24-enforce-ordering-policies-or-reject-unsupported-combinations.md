---
id: 24
slug: enforce-ordering-policies-or-reject-unsupported-combinations
title: "Enforce ordering policies or reject unsupported combinations"
kind: exec-plan
created_at: 2026-07-02T03:49:03Z
master_plan: "docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md"
---

# Enforce ordering policies or reject unsupported combinations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is EP-24 of the master plan at
`docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md`.
It has a soft dependency on EP-22 (`docs/plans/22-fix-processor-lifecycle-and-supervision-semantics.md`):
EP-22 edits other regions of `shibuya-core/src/Shibuya/Runner/Supervised.hs` (child spawning,
done-flag semantics), so if both plans are in flight, rebase this plan's Milestone 2 work on
EP-22's merged changes before touching that file. Milestone 1 of this plan touches no file that
EP-22 edits and can ship at any time.


## Purpose / Big Picture

Shibuya lets users declare an ordering policy (`StrictInOrder`, `PartitionedInOrder`,
`Unordered`) and a concurrency mode (`Serial`, `Ahead n`, `Async n`) per queue processor.
Today the combination `PartitionedInOrder` + `Ahead`/`Async` is accepted by validation but
silently ignored: nothing in the runtime keys work by partition, so messages from the same
partition run fully concurrently and can be acknowledged out of order. A user who chose
`PartitionedInOrder` because their Kafka-style workload requires per-partition ordering gets
no ordering at all, with no error and no warning. Separately, the documentation for `Ahead`
claims "Prefetch N, process in order", which is false for the effects users actually care
about (handler execution and acknowledgement), and can lead users to build systems on an
ordering guarantee that does not exist.

After Milestone 1, configuring `PartitionedInOrder` with `Ahead` or `Async` fails fast:
`runApp` returns `Left (AppPolicyError (InvalidPolicyCombo ...))` before any processor
starts, and the `Ahead` documentation states precisely what is and is not ordered. After
Milestone 2, the combination is accepted again for single-message processors and actually
works: messages sharing a partition key are processed and acknowledged strictly in arrival
order, while different partitions run concurrently up to the configured bound — verified by
property tests. If Milestone 2 proves disproportionate in practice, the recorded fallback is
to keep the Milestone 1 rejection permanently, with rationale documented here and in the
master plan (see Decision Log).

This is a behavior change for users: a configuration that previously started (and silently
misbehaved) now returns an error. The plan therefore includes a `CHANGELOG.md` entry and a
PVP-appropriate version bump (see Milestone 1).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

Milestone 1 — reject the unenforceable combination, fix Ahead docs:

- [ ] `validatePolicy` in `shibuya-core/src/Shibuya/Policy.hs` rejects `PartitionedInOrder` + `Ahead`/`Async` with a clear message.
- [ ] `Ahead` Haddock in `shibuya-core/src/Shibuya/Policy.hs` corrected to state exactly what is ordered (downstream yield order) and what is not (handler execution, acknowledgement).
- [ ] `PartitionedInOrder` Haddock updated to state the current enforcement status.
- [ ] `shibuya-core/test/Shibuya/PolicySpec.hs`: existing `PartitionedInOrder` allows-`Ahead`/`Async` tests flipped to expect rejection; exhaustive 3x3 `Ordering` x `Concurrency` verdict matrix test added.
- [ ] `docs/architecture/CONCURRENCY.md` updated: policy matrix, Ahead section, and the example that pairs `PartitionedInOrder` with `Ahead 3`.
- [ ] `CHANGELOG.md` entry added under a new unreleased `0.8.0.0` heading; `version:` in `shibuya-core/shibuya-core.cabal` bumped to `0.8.0.0`.
- [ ] `cabal build all`, `cabal test shibuya-core-test`, `nix fmt` pass; Milestone 1 committed with the required trailers.

Milestone 2 — partition-keyed dispatch for the single-message path, then re-allow:

- [ ] Generic keyed FIFO scheduler extracted to `shibuya-core/src/Shibuya/Runner/KeyedScheduler.hs` (parameterized over an `item -> Maybe key` extractor, with a bounded pending buffer); module registered in `shibuya-core/shibuya-core.cabal`.
- [ ] `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs` delegates its per-`BatchKey` scheduling to the extracted scheduler (integrating with EP-23's bounding if it has landed; see Plan of Work).
- [ ] `Ordering` threaded through `spawnProcessors` (`shibuya-core/src/Shibuya/App.hs`), `runSupervised`, `runIngesterAndProcessor`, and `processUntilDrained` (`shibuya-core/src/Shibuya/Runner/Supervised.hs`).
- [ ] `processUntilDrained` dispatches `PartitionedInOrder` + `Ahead n`/`Async n` through the keyed scheduler keyed on `envelope.partition`; `Nothing` partitions are unkeyed (fully concurrent).
- [ ] `trackingAckHandle` in `shibuya-core/src/Shibuya/Adapter/Mock.hs` made thread-safe (`atomicModifyIORef'`).
- [ ] Property tests in new `shibuya-core/test/Shibuya/Runner/PartitionOrderingSpec.hs` (registered in `shibuya-core/shibuya-core.cabal` and `shibuya-core/test/Main.hs`): per-partition finalize order equals arrival order under random delays; exactly-once finalization; global concurrency bound respected; cross-partition parallelism demonstrated.
- [ ] `validatePolicy` re-allows `PartitionedInOrder` + `Ahead`/`Async`; batch processors (`BatchingProcessor`) with that combination remain rejected via `validateAllPolicies` in `shibuya-core/src/Shibuya/App.hs`, with a test through `runApp`.
- [ ] `PolicySpec` matrix updated; `docs/architecture/CONCURRENCY.md` matrix and future-work note updated; `CHANGELOG.md` amended.
- [ ] `cabal build all`, `cabal test shibuya-core-test`, `nix fmt` pass; Milestone 2 committed with the required trailers; master plan checklist items for EP-24 ticked.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Milestone 1 makes `validatePolicy` reject `PartitionedInOrder` + `Ahead`/`Async`; Milestone 2 implements partition-keyed dispatch and then re-allows the combination.
  Rationale: The rejection is a one-line change that immediately stops the silent ordering-guarantee violation; the keyed dispatch is real machinery that deserves its own milestone with property tests. Shipping the rejection first means correctness does not wait on the feature.
  Date: 2026-07-02

- Decision: If Milestone 2 proves disproportionate during implementation, the fallback recorded in the master plan is to keep the Milestone 1 rejection permanent, with the rationale documented in this plan and in `docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md` (its EP-24 checklist item reads "partition-keyed dispatch implemented (or the rejection made permanent with rationale)").
  Rationale: A permanent, documented rejection is strictly better than a silent guarantee violation; the feature can be revisited later without blocking the correctness fix.
  Date: 2026-07-02

- Decision: Messages whose `envelope.partition` is `Nothing` are treated as unkeyed under `PartitionedInOrder`: they have no ordering constraint and run fully concurrently, subject only to the global concurrency bound.
  Rationale: `PartitionedInOrder` promises ordering only *within* a partition; a message with no partition key belongs to no partition, so no ordering promise exists for it. The considered alternative — hashing the `MessageId` into a key — is a no-op in disguise: `MessageId`s are unique per message, so each message would get its own singleton key, which is exactly "fully concurrent" plus pointless bookkeeping. Treating `Nothing` as unkeyed gives identical semantics with less machinery.
  Date: 2026-07-02

- Decision: Under `PartitionedInOrder`, `Ahead n` and `Async n` behave identically (per-partition FIFO dispatch with global bound `n`).
  Rationale: `Ahead`'s only distinction from `Async` is input-ordered yielding of downstream results, but the processing pipeline yields `()` per message and is drained, so that distinction is unobservable here; per-partition FIFO already provides the only ordering `PartitionedInOrder` promises. Documenting them as equivalent in this combination is honest and avoids maintaining two schedulers.
  Date: 2026-07-02

- Decision: In Milestone 2, `PartitionedInOrder` + `Ahead`/`Async` is re-allowed only for single-message processors (`QueueProcessor`); `BatchingProcessor` with that combination stays rejected, enforced in `validateAllPolicies` in `shibuya-core/src/Shibuya/App.hs`.
  Rationale: The batch path serializes per user-supplied `BatchKey`, not per `envelope.partition`; a batch may mix partitions and nothing forces the batch key to be the partition, so per-key serialization does not imply per-partition ordering. Keeping `validatePolicy` a pure `Ordering` x `Concurrency` function and adding the batch-specific check where the processor kind is known keeps both checks simple.
  Date: 2026-07-02

- Decision: The extracted keyed scheduler bounds its internal pending buffer at `2 * max 1 n` items (where `n` is the concurrency bound), blocking its reader via STM `retry` when full.
  Rationale: EP-23's review finding is that the existing batch scheduler's `pending` `Seq` is unbounded, which defeats the bounded-inbox backpressure design. A bound of twice the concurrency gives enough look-ahead to find startable work when head-of-queue keys are busy, while keeping scheduler memory O(n); messages beyond the bound simply remain in the bounded inbox, which is the system's designed backpressure point. If EP-23 (`docs/plans/23-fix-finalize-on-exception-and-batch-path-reliability.md`) lands its own bounding first, adopt its mechanism instead of introducing a second one — its `max 2 (2 * maxConcurrency)` formula is numerically identical to `2 * max 1 n` for every `n >= 0`, so this is purely a matter of reusing one spelling.
  Date: 2026-07-02


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shibuya is a Haskell queue-processing framework (workspace root:
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`; the library lives in the
`shibuya-core/` subdirectory). An *adapter* wraps a message source (Kafka, PGMQ, an
in-memory list for tests) as a stream of messages. A *handler* is a user function that
processes one message and returns an *ack decision* (`AckOk`, `AckRetry`, `AckDeadLetter`,
`AckHalt`) — "ack" is short for acknowledgement, the signal back to the broker that decides
whether the message is done, redelivered, or dead-lettered. The framework applies the
decision by calling the message's *finalizer* (`ack.finalize decision`), an adapter-supplied
action. Messages flow: adapter stream -> ingester (an async task) -> bounded inbox (an NQE
mailbox providing backpressure) -> processing loop -> handler -> finalize.

The policy vocabulary lives in `shibuya-core/src/Shibuya/Policy.hs`. `Ordering` (lines
20–27) has three constructors: `StrictInOrder` ("Event-sourced subscriptions - must be
Serial"), `PartitionedInOrder` ("Kafka-style - parallel across partitions"), and `Unordered`.
`Concurrency` (lines 30–37) has `Serial` (one at a time), `Ahead !Int` (currently documented
as "Prefetch N, process in order"), and `Async !Int` (process N concurrently).
`validatePolicy :: Ordering -> Concurrency -> Either PolicyError ()` (lines 41–44) rejects
only `StrictInOrder` + `Ahead`/`Async`; everything else passes. `PolicyError` is
`InvalidPolicyCombo !Text` in `shibuya-core/src/Shibuya/Core/Error.hs`.

The entry point `runApp` in `shibuya-core/src/Shibuya/App.hs` validates every processor's
policy via `validateAllPolicies` (lines 221–229) and then spawns processors via
`spawnProcessors` (lines 232–254). Here is the first verified problem: `spawnProcessors`
destructures `QueueProcessor {adapter, handler, concurrency}` — the `ordering` field is
**used only by validation and then discarded**. `runSupervised` in
`shibuya-core/src/Shibuya/Runner/Supervised.hs` (line 140) takes a `Concurrency` but no
`Ordering`, and the processing loop `processUntilDrained` (lines 469–505) dispatches purely
on concurrency: `Serial` uses `Stream.mapM`, `Ahead n` uses
`StreamP.parMapM (StreamP.maxBuffer n . StreamP.ordered True)`, and `Async n` uses
`StreamP.parMapM (StreamP.maxBuffer n)`. No code anywhere keys work by
`envelope.partition` (the `partition :: Maybe Text` field of `Envelope` in
`shibuya-core/src/Shibuya/Core/Types.hs`, line 77). Consequence: `PartitionedInOrder` +
`Async 8` passes validation, and same-partition messages then run fully concurrently,
silently violating the documented guarantee. The existing test file
`shibuya-core/test/Shibuya/PolicySpec.hs` even asserts (lines 46–54) that
`PartitionedInOrder` "allows Ahead" and "allows Async" — those assertions codify the bug.

The second verified problem is documentation: `Ahead`'s Haddock and
`docs/architecture/CONCURRENCY.md` (the "Ahead" section around lines 190–230, including
"Output order preserved") say or imply in-order processing. In reality streamly's
`ordered True` only makes the parallel stream *yield results downstream in input order*;
the handler executions — and crucially the `finalize` calls, which happen inside the same
per-message action (`processOne`) — run concurrently and complete in any order. Since the
per-message result is `()` and the stream is drained, the yield order is unobservable: the
only observable effects are handler side effects and acknowledgements, and neither is
ordered. `CONCURRENCY.md` also shows an example configuration pairing
`ordering = PartitionedInOrder` with `concurrency = Ahead 3` (around line 228) and a policy
matrix (around lines 297–305) marking all `PartitionedInOrder` rows as allowed; both must be
updated in Milestone 1.

Machinery to reuse for Milestone 2: the *batch* path already solves per-key FIFO dispatch.
`shibuya-core/src/Shibuya/Runner/BatchProcessor.hs` contains `runKeyedBatchScheduler`
(lines 400–503): a reader async enqueues items into a `pending :: Seq` inside a single
`TVar`-guarded state (`KeyedSchedulerState`, lines 377–398); a dispatch loop atomically pops
the first pending item whose `BatchKey` is not currently active (`popStartable`,
lines 489–503), respecting FIFO within each key, bounded by a global `running < maxConcurrency`
check (`nextSchedulerStep`, lines 454–474); worker asyncs report completion via `finishBatch`,
and the first worker/reader exception is recorded and rethrown after everything drains. This
is exactly the shape partition-keyed message dispatch needs, with two adaptations: the key
becomes `envelope.partition :: Maybe Text` (with `Nothing` meaning "no constraint" — see
Decision Log), and the `pending` buffer must be bounded (the review behind EP-23 found it is
currently unbounded, which silently defeats the bounded-inbox backpressure; see Decision Log
for the bound chosen here and the EP-23 integration rule).

Test infrastructure: `shibuya-core/src/Shibuya/Adapter/Mock.hs` provides `listAdapter`
(adapter from an in-memory list), `TrackingAck` (an `IORef` recording
`(MessageId, AckDecision)` pairs on every finalize), `trackedListAdapter`, and
`getTrackedDecisions`. Note `trackingAckHandle` records with `modifyIORef'`, which is not
atomic — fine for today's serial tests, but Milestone 2's concurrent finalizes could lose
updates, so it must switch to `atomicModifyIORef'`. Tests run with
`runEff $ runTracingNoop $ ...` (see `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs`
for the established pattern: `startMaster IgnoreAll`, `runSupervised master 10 procId
(Async 3) adapter handler`, wait on the processor's `done` TVar, `stopMaster`). Test modules
are explicitly listed: add new ones to both the `other-modules` of the `shibuya-core-test`
stanza in `shibuya-core/shibuya-core.cabal` and the imports/spec list in
`shibuya-core/test/Main.hs`.

Coordination with the rest of the initiative (from the master plan): EP-22 (hard owner of
`Supervised.hs` lifecycle structure) and EP-23 (batch scheduler bounding, finalize on
exception) are separate plans whose files may still be skeletons — check their Progress
sections before starting Milestone 2 and rebase accordingly. EP-25 must not relocate or
rename the `Policy` types until this plan completes. EP-28 (Kafka adapter) cites Milestone
1's rejection in its Serial-only documentation, so keep the rejection message stable once
shipped. `shibuya-core` is currently at version `0.7.1.0` (see `shibuya-core/shibuya-core.cabal`
and the root `CHANGELOG.md`); PVP (the Package Versioning Policy: breaking changes bump one
of the first two version components) requires a major bump for rejecting previously-accepted
configurations, hence `0.8.0.0`.


## Plan of Work

### Milestone 1 — Reject the unenforceable combination and fix the Ahead documentation

Scope: `shibuya-core/src/Shibuya/Policy.hs`, `shibuya-core/test/Shibuya/PolicySpec.hs`,
`docs/architecture/CONCURRENCY.md`, `CHANGELOG.md`, `shibuya-core/shibuya-core.cabal`. At
the end of this milestone, `runApp` with a `PartitionedInOrder` + `Ahead`/`Async` processor
returns `Left (AppPolicyError (InvalidPolicyCombo ...))` instead of starting a processor
that violates its guarantee, the `Ahead` docs are truthful, and a test matrix pins every
`Ordering` x `Concurrency` verdict. This milestone touches no file EP-22 edits and ships
alone.

In `shibuya-core/src/Shibuya/Policy.hs`, add two clauses to `validatePolicy` before the
catch-all:

```haskell
validatePolicy PartitionedInOrder (Ahead _) = Left $ InvalidPolicyCombo partitionedMsg
validatePolicy PartitionedInOrder (Async _) = Left $ InvalidPolicyCombo partitionedMsg
```

with a shared message such as: "PartitionedInOrder with Ahead/Async is not implemented:
the runtime has no partition-keyed dispatch, so concurrent modes would violate
per-partition ordering. Use Serial (see docs/plans/24-enforce-ordering-policies-or-reject-unsupported-combinations.md)."
Update the function's Haddock invariant comment (currently "Invariant: StrictInOrder =>
Serial") to list both invariants. Keep the message wording stable after shipping — EP-28
cites it.

In the same file, rewrite the `Ahead` constructor Haddock. It must state precisely: up to N
messages are processed concurrently; the parallel stream yields per-message results
downstream in input order (streamly `ordered True`), but handler execution and
acknowledgement (`finalize`) run concurrently and may complete in any order; because the
processing pipeline discards per-message results, the input-ordered yielding is not
observable — `Ahead` guarantees completion order of stream outputs, not execution order and
not ack order. Suggested wording:

```haskell
  | -- | Process up to N messages concurrently. Stream results are yielded
    -- downstream in input order, but handler execution and acknowledgement
    -- run concurrently and may complete in ANY order. Ahead does NOT order
    -- side effects or acks; if you need per-partition ack ordering use
    -- 'PartitionedInOrder', and for global ordering use 'StrictInOrder'
    -- with 'Serial'.
    Ahead !Int
```

Also adjust the `PartitionedInOrder` Haddock to state the enforcement status introduced by
this milestone (Serial-only until partition-keyed dispatch exists; Milestone 2 updates it
again).

In `shibuya-core/test/Shibuya/PolicySpec.hs`, flip the two tests at lines 50–54 ("allows
Ahead", "allows Async" under `PartitionedInOrder`) to expect `Left`, and add an exhaustive
matrix test that enumerates all nine `(Ordering, Concurrency)` combinations with their
expected verdicts, so any future change to `validatePolicy` must consciously edit the
matrix. A table-driven form keeps it readable:

```haskell
describe "validatePolicy matrix" $ do
  let ok = True; rejected = False
      cases =
        [ (StrictInOrder, Serial, ok),
          (StrictInOrder, Ahead 4, rejected),
          (StrictInOrder, Async 4, rejected),
          (PartitionedInOrder, Serial, ok),
          (PartitionedInOrder, Ahead 4, rejected), -- flips to ok in Milestone 2
          (PartitionedInOrder, Async 4, rejected), -- flips to ok in Milestone 2
          (Unordered, Serial, ok),
          (Unordered, Ahead 4, ok),
          (Unordered, Async 4, ok)
        ]
  mapM_
    ( \(o, c, expected) ->
        it (show o <> " + " <> show c) $
          isRight (validatePolicy o c) `shouldBe` expected
    )
    cases
```

(Add an `isRight` helper next to the existing `isLeft`.)

In `docs/architecture/CONCURRENCY.md`: change the policy matrix (around lines 297–305) so
the `PartitionedInOrder` row shows `Ahead`/`Async` as rejected with a pointer to this plan;
rewrite the "Ahead" section (around lines 190–230) to remove "process in order" / "Output
order preserved" claims in favor of the precise statement above; and fix the example around
line 228 that configures `ordering = PartitionedInOrder, concurrency = Ahead 3` (make it
`Serial`, or switch the example's ordering to `Unordered`).

Changelog and version: in the root `CHANGELOG.md`, add a new top section:

```text
## 0.8.0.0 — Unreleased

### Breaking Changes

- `shibuya-core`: `validatePolicy` (and therefore `runApp`) now rejects
  `PartitionedInOrder` combined with `Ahead` or `Async`. Previously this
  combination was accepted but the ordering guarantee was silently not
  enforced — same-partition messages ran fully concurrently. Configurations
  using it must switch to `Serial` until partition-keyed dispatch ships.
- `shibuya-core`: corrected `Ahead` documentation — it never guaranteed
  ordered handler execution or ordered acknowledgement, only input-ordered
  yielding of (unobservable) stream results.
```

and bump `version:` in `shibuya-core/shibuya-core.cabal` from `0.7.1.0` to `0.8.0.0` (PVP
major bump: a documented, previously-accepted configuration now errors). If another plan in
this initiative has already opened an unreleased `0.8.0.0` section by the time you get here,
append to it instead of creating a duplicate heading.

Acceptance: `cabal test shibuya-core-test` passes with the flipped expectations and the new
matrix; a `runApp` call with `QueueProcessor adapter handler PartitionedInOrder (Async 4)`
returns `Left (AppPolicyError (InvalidPolicyCombo _))` (this falls out of
`validateAllPolicies` with no `App.hs` change — verify via the matrix tests plus, if you
want an end-to-end check, a quick REPL or a small spec in `PolicySpec`). Commit as described
in Concrete Steps.

### Milestone 2 — Partition-keyed dispatch for the single-message path, then re-allow

Scope: substantial. New module `shibuya-core/src/Shibuya/Runner/KeyedScheduler.hs`; edits to
`shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`,
`shibuya-core/src/Shibuya/Runner/Supervised.hs`, `shibuya-core/src/Shibuya/App.hs`,
`shibuya-core/src/Shibuya/Policy.hs`, `shibuya-core/src/Shibuya/Adapter/Mock.hs`; new test
module `shibuya-core/test/Shibuya/Runner/PartitionOrderingSpec.hs`; doc and changelog
updates. At the end, `PartitionedInOrder` + `Ahead n`/`Async n` on a `QueueProcessor` is
accepted and provides real per-partition FIFO acknowledgement with cross-partition
concurrency, proven by property tests. Before starting, read the Progress sections of
`docs/plans/22-fix-processor-lifecycle-and-supervision-semantics.md` and
`docs/plans/23-fix-finalize-on-exception-and-batch-path-reliability.md`: rebase on EP-22's
merged `Supervised.hs` changes if landed, and adopt EP-23's scheduler bounding if landed
(otherwise apply the bound decided in the Decision Log). If, mid-milestone, the work proves
disproportionate (for example, unresolvable interaction with EP-22/EP-23 restructuring),
stop, keep the Milestone 1 rejection permanent, record the rationale in the Decision Log and
the master plan, and update the Purpose section — that fallback is a sanctioned outcome, not
a failure.

Step 2a — extract a generic keyed scheduler. Create
`shibuya-core/src/Shibuya/Runner/KeyedScheduler.hs` by generalizing
`runKeyedBatchScheduler` and its helpers (`KeyedSchedulerState`, `SchedulerStep`,
`enqueueBatch`, `markInputDone`, `nextSchedulerStep`, `finishBatch`, `popStartable`) out of
`shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`. Target signature:

```haskell
-- | Run every item of the stream through the action, at most @maxConcurrency@
-- at a time, such that items sharing a key ('Just' k) run strictly in stream
-- order relative to each other. Unkeyed items ('Nothing') have no mutual
-- ordering constraint. The internal pending buffer is bounded at @maxPending@;
-- when full, the stream reader blocks, propagating backpressure upstream.
-- The first worker or reader exception is rethrown after all started work
-- finishes.
runKeyedScheduler ::
  (Ord key) =>
  -- | maxConcurrency (values < 1 are treated as 1)
  Int ->
  -- | maxPending bound for the internal buffer
  Int ->
  -- | key extractor; Nothing = unkeyed
  (item -> Maybe key) ->
  -- | worker action
  (item -> IO ()) ->
  Stream IO item ->
  IO ()
```

Semantics, carried over from the batch scheduler with two changes: (1) `activeKeys` is a
`Set key` and only `Just`-keyed items are inserted/checked/deleted — `popStartable` treats a
`Nothing`-keyed item as always startable; (2) the enqueue path blocks in STM (`retry`) while
`Seq.length pending >= maxPending`, instead of growing without bound. Preserve the existing
failure semantics exactly: reader exceptions and worker exceptions set `firstFailure`,
scheduling continues for remaining startable items, and the recorded exception is rethrown
once `inputDone && Seq.null pending && running == 0`. Register the module under
`exposed-modules` (next to `Shibuya.Runner.BatchProcessor`) or `other-modules` in
`shibuya-core/shibuya-core.cabal` — prefer `other-modules` since it is internal machinery,
unless the test suite needs direct access (it should not: tests go through `runSupervised`).

Step 2b — make the batch path delegate. In
`shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`, replace `runKeyedBatchScheduler n ...`
(both the `Ahead n` and `Async n` arms of `processBatchesUntilDrained`, lines 368–375) with
`runKeyedScheduler (max 1 n) (2 * max 1 n) (\(info, _) -> Just info.batchKey) batchAction
batchStream`, and delete the now-duplicated scheduler code. If EP-23 has already landed its
own bounding/bracketing of this scheduler, generalize *its* version instead and keep its
bound; note whichever happened in Surprises & Discoveries. All existing batch tests
(`shibuya-core/test/Shibuya/Runner/BatchProcessorSpec.hs`,
`shibuya-core/test/Shibuya/Batch/ReliabilitySpec.hs`) must still pass — they are the
regression net for this extraction.

Step 2c — thread `Ordering` to the processing loop. In `shibuya-core/src/Shibuya/App.hs`,
`spawnProcessors` (lines 238–243) currently ignores `ordering` for `QueueProcessor`; pass it:
`runSupervised master inboxSize procId ordering concurrency adapter handler`. In
`shibuya-core/src/Shibuya/Runner/Supervised.hs`, add an `Ordering` parameter (import
`Shibuya.Policy (Concurrency (..), Ordering (..))` and `Prelude hiding (Ordering)` as
`App.hs` does) to `runSupervised` (line 140), `runIngesterAndProcessor` (line 233), and
`processUntilDrained` (line 469), passing it straight through. This changes the exported
signature of `runSupervised` — a breaking API change already covered by the 0.8.0.0 bump;
update its call sites in `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` (roughly ten
calls; use `Unordered` to preserve their current behavior) and any other caller
`grep -rn "runSupervised " shibuya-core shibuya-example` finds. `runWithMetrics` (serial
drain, used by tests) and the batch path (`runSupervisedBatch`) do not take the parameter —
batch ordering enforcement is intentionally out of scope (Decision Log).

Step 2d — dispatch. Rewrite the `case concurrency of` in `processUntilDrained` (lines
490–499) to dispatch on the pair:

```haskell
case (ordering, concurrency) of
  (_, Serial) ->
    Stream.fold Fold.drain $ Stream.mapM processAction inboxStream
  (PartitionedInOrder, Ahead n) -> partitioned n
  (PartitionedInOrder, Async n) -> partitioned n
  (_, Ahead n) ->
    Stream.fold Fold.drain $
      StreamP.parMapM (StreamP.maxBuffer n . StreamP.ordered True) processAction inboxStream
  (_, Async n) ->
    Stream.fold Fold.drain $
      StreamP.parMapM (StreamP.maxBuffer n) processAction inboxStream
  where-like local:
    partitioned n =
      runKeyedScheduler
        (max 1 n)
        (2 * max 1 n)
        (\ingested -> ingested.envelope.partition)
        processAction
        inboxStream
```

(The snippet above is illustrative shape, not paste-ready: bind `partitioned` in a `let`
inside the `withEffToIO` block where `processAction` and `inboxStream` are in scope.) Two
properties come for free and must not be broken: halt handling (a handler returning
`AckHalt` makes `processOne` set `haltRef`; `inboxToStream` checks `haltRef` before each
pull, so the scheduler's input stream ends; started workers drain; `processUntilDrained`
then throws `ProcessorHalt`) and metrics (all in-flight accounting lives inside
`processOne`, which the scheduler invokes unchanged). Arrival order is well-defined here:
the adapter stream, the bounded inbox, and `inboxToStream` are all single-reader FIFO, so
the scheduler's pending order equals adapter emission order.

Step 2e — thread-safe tracking ack. In `shibuya-core/src/Shibuya/Adapter/Mock.hs`, change
`trackingAckHandle` to record with `atomicModifyIORef'` (e.g.
`atomicModifyIORef' tracking.trackedDecisions (\xs -> ((msgId, decision) : xs, ()))`) so
concurrent finalizes cannot lose updates. This is behavior-preserving for existing serial
tests.

Step 2f — property tests. Create
`shibuya-core/test/Shibuya/Runner/PartitionOrderingSpec.hs`; register it in
`shibuya-core/shibuya-core.cabal` (`other-modules` of `shibuya-core-test`) and
`shibuya-core/test/Main.hs`. Use the established run pattern (`runEff . runTracingNoop`,
`startMaster IgnoreAll`, `runSupervised`, block on the processor's `done` TVar with
`atomically (readTVar sp.done >>= check)`, `stopMaster`). Tests:

1. Per-partition FIFO property (QuickCheck). Generate a plan: a list of messages where each
   message has an index-derived `MessageId` (e.g. `"msg-7"`), a partition chosen from
   `Just "p0" | Just "p1" | Just "p2" | Nothing`, and a handler delay generated in the range
   0–2000 microseconds; also generate the concurrency bound `n` in 2–8 and pick `Ahead n` or
   `Async n`. The handler looks up its message's delay (carry the delay in the message
   payload itself — simplest), sleeps `threadDelay delay`, returns `AckOk`. Build envelopes
   with the generated partitions, wrap with `mkTrackedIngested` against one shared
   `TrackingAck`, feed through `listAdapter`, run with `PartitionedInOrder`. After
   completion, read `getTrackedDecisions`, reverse it (the handle prepends), and assert: for
   every partition key `p`, the subsequence of finalized `MessageId`s whose envelope had
   partition `Just p` equals the arrival-order list of that partition's `MessageId`s.
   Use `ioProperty` (or hspec's `prop` with a `Testable IO` body) and cap runs (e.g.
   `modifyMaxSuccess (const 30)`) because each case really runs threads and sleeps.
2. Exactly-once finalization (same property run): the multiset of finalized `MessageId`s
   equals the multiset of input ids — no drops, no duplicates.
3. Concurrency bound: a non-property test with a handler that bumps an "in flight now"
   counter via `atomicModifyIORef'`, records the high-water mark, sleeps, decrements (copy
   the pattern from the existing "Ahead mode"/"Async mode" limit tests in
   `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` around lines 255–330); assert the
   high-water mark never exceeds `n` under `PartitionedInOrder` + `Async n` with messages
   spread over many partitions.
4. Cross-partition parallelism (deterministic, generous margins): partition "slow" has 3
   messages sleeping 50 ms each; partition "fast" has 3 messages sleeping 1 ms each; under
   `PartitionedInOrder` + `Async 4`, assert all "fast" finalizes are recorded before the
   last "slow" finalize. This fails under accidental global serialization (Serial would
   interleave by arrival), proving partitions actually run concurrently.
5. `Nothing`-partition freedom: messages with `partition = Nothing` complete and are
   finalized exactly once (covered by test 2's generator including `Nothing`); no ordering
   assertion is made for them — assert only their presence.

If any property fails, do not weaken the assertion — the assertions are the plan's
definition of "implemented".

Step 2g — re-allow, with the batch carve-out. In `shibuya-core/src/Shibuya/Policy.hs`,
delete the two Milestone 1 rejection clauses and update the Haddocks (`PartitionedInOrder`
now: per-partition FIFO acknowledgement, cross-partition concurrency, `Nothing` partition =
unconstrained; `validatePolicy` invariant list back to `StrictInOrder => Serial` only). In
`shibuya-core/src/Shibuya/App.hs` `validateAllPolicies`, add a batch-specific check for
`BatchingProcessor`: `PartitionedInOrder` with `Ahead`/`Async` remains rejected with a
message explaining that batch scheduling serializes per user-supplied `BatchKey`, not per
partition, so per-partition ordering cannot be guaranteed for batches (use Serial or key
batches by partition and choose `Unordered`). Update the `PolicySpec` matrix (the two
`PartitionedInOrder` rows flip to accepted — the Milestone 1 comments mark them). Add a
spec (e.g. in `shibuya-core/test/Shibuya/App/BatchSpec.hs` or a small new describe block in
`PolicySpec`'s home for app-level checks — `runApp` is the only public route to
`validateAllPolicies`) asserting `runApp` returns `Left (AppPolicyError _)` for a
`BatchingProcessor` with `PartitionedInOrder` + `Async 2`, and `Right` for a
`QueueProcessor` with the same policy (remember to `stopApp` the handle in the `Right`
case).

Step 2h — docs and changelog. Update `docs/architecture/CONCURRENCY.md`: policy matrix
(single-message path: `PartitionedInOrder` allowed for all modes; add a note that batching
processors remain Serial-only under `PartitionedInOrder`), a short section describing the
keyed scheduler semantics (per-key FIFO, global bound, `Nothing` unconstrained, `Ahead` ==
`Async` under this ordering), and remove/replace the "Future work: per-partition
concurrency" item around line 429. Amend the root `CHANGELOG.md` `0.8.0.0` section:

```text
- `shibuya-core`: `PartitionedInOrder` + `Ahead`/`Async` is supported for
  single-message processors: messages sharing an `Envelope.partition` key are
  processed and acknowledged in arrival order while distinct partitions run
  concurrently (global bound N). Messages with no partition key are
  unconstrained. Batching processors still reject the combination because
  batches are keyed by `BatchKey`, not partition.
- `shibuya-core`: `Shibuya.Runner.Supervised.runSupervised` now takes the
  `Ordering` policy in addition to `Concurrency` (breaking signature change).
```

Acceptance: full suite green; the four new test behaviors pass; batch regression specs
unchanged and green. Commit with trailers; then tick the two EP-24 checklist items in
`docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md`
and set EP-24's row in its plan table to Complete.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

Build and test after each coherent edit:

```bash
cabal build all
cabal test shibuya-core-test
```

Expected test output tail on success (counts will differ as tests are added):

```text
Finished in 12.3456 seconds
187 examples, 0 failures
Test suite shibuya-core-test: PASS
```

A Milestone 1 failure you should see *before* flipping `PolicySpec` (proof the change
bites), if you run the suite mid-edit:

```text
Shibuya.Policy, validatePolicy, PartitionedInOrder, allows Ahead FAILED [1]
```

Format before every commit (the pre-commit hook rejects unformatted files; if it
auto-formats, re-stage and commit again):

```bash
nix fmt
git add <files>
git commit
```

Milestone 1 commit message (conventional commits, with the required trailers):

```text
feat(policy)!: reject PartitionedInOrder with Ahead/Async and fix Ahead docs (EP-24 M1)

PartitionedInOrder passed validation with concurrent modes but nothing
implemented partition-keyed dispatch, silently violating the documented
per-partition ordering guarantee. Reject the combination until keyed
dispatch exists, correct the Ahead haddock (only stream yield order was
ever ordered; execution and acks are not), and pin the full
Ordering x Concurrency verdict matrix in tests.

BREAKING CHANGE: PartitionedInOrder + Ahead/Async now fails validatePolicy.

MasterPlan: docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
ExecPlan: docs/plans/24-enforce-ordering-policies-or-reject-unsupported-combinations.md
```

Milestone 2 commit message:

```text
feat(runner)!: partition-keyed dispatch for PartitionedInOrder + Ahead/Async (EP-24 M2)

Extract the batch path's per-key FIFO scheduler into a generic bounded
KeyedScheduler, key single-message dispatch on Envelope.partition,
thread Ordering through runSupervised, and re-allow the combination for
single-message processors (batching processors keep the rejection —
BatchKey is not the partition). Property tests assert per-partition
finalize order equals arrival order under random delays.

BREAKING CHANGE: runSupervised takes an Ordering parameter.

MasterPlan: docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
ExecPlan: docs/plans/24-enforce-ordering-policies-or-reject-unsupported-combinations.md
```

Commit each milestone separately (Milestone 1 is designed to ship alone). Update this
plan's Progress section in the same commit as the work it describes.


## Validation and Acceptance

Milestone 1 observable acceptance: running `cabal test shibuya-core-test` shows the
`validatePolicy matrix` group with nine passing cases, including
`PartitionedInOrder + Ahead 4` and `PartitionedInOrder + Async 4` expecting rejection. In
`cabal repl shibuya-core`:

```haskell
ghci> import Shibuya.Policy
ghci> import Prelude hiding (Ordering)
ghci> validatePolicy PartitionedInOrder (Async 4)
Left (InvalidPolicyCombo "PartitionedInOrder with Ahead/Async is not implemented: ...")
```

and consequently any `runApp` invocation containing such a processor returns
`Left (AppPolicyError (InvalidPolicyCombo _))` without starting a Master. The `Ahead`
Haddock and `docs/architecture/CONCURRENCY.md` no longer claim ordered processing;
`CHANGELOG.md` carries the 0.8.0.0 breaking-change entry and the cabal version matches.

Milestone 2 observable acceptance: `cabal test shibuya-core-test` shows the new
`PartitionOrderingSpec` group green, in particular (names indicative): "finalize order
within a partition matches arrival order" (property, ~30 random cases with random handler
delays), "every message is finalized exactly once" (property), "respects the global
concurrency bound", and "slow partition does not block fast partition". The same REPL check
now yields `Right ()` for `validatePolicy PartitionedInOrder (Async 4)`, while a
`BatchingProcessor` with that policy still makes `runApp` return `Left (AppPolicyError _)`
(covered by a spec). The pre-existing batch reliability and batch processor specs pass
unchanged, proving the scheduler extraction preserved batch semantics. Beyond compilation,
the property tests are the demonstration: they fail against the pre-M2 `parMapM` dispatch
(you can verify non-vacuity once, mid-implementation, by pointing the `PartitionedInOrder`
arm at the plain `Async` implementation and watching test 1 fail).

Full gate for each milestone, from the repository root:

```bash
cabal build all
cabal test shibuya-core-test
nix fmt
```

All three must succeed (and `git status` must be clean of unstaged formatter output) before
committing.


## Idempotence and Recovery

Every step is an ordinary source edit; re-running builds, tests, and `nix fmt` is safe and
idempotent. Milestone 1 is independently shippable — if Milestone 2 is abandoned (see the
fallback in the Decision Log), the codebase is left in a correct, documented state with the
rejection permanent; in that case update the `PartitionedInOrder` Haddock, `CONCURRENCY.md`,
and the changelog entry to drop the "until partition-keyed dispatch ships" framing, and
record the outcome in this plan and the master plan. Within Milestone 2, do the scheduler
extraction (steps 2a–2b) as its own verifiable unit: after it, the batch specs must be green
with zero behavior change, giving a safe point to pause or roll back (`git revert` of the
extraction commit restores the previous batch scheduler wholesale). If the property tests
expose ordering bugs in the scheduler adaptation, the rejection clauses in
`validatePolicy` must not be removed until they pass — re-allowing is the last step (2g) for
exactly this reason. If a rebase over EP-22/EP-23 conflicts in `Supervised.hs`, redo steps
2c–2d on top of their merged structure rather than force-merging: the changes are small and
mechanical relative to whatever lifecycle shape EP-22 lands.


## Interfaces and Dependencies

Libraries already in `shibuya-core`'s build-depends and used here: `streamly`/`streamly-core`
(`Streamly.Data.Stream`, `Streamly.Data.Stream.Prelude.parMapM` — the existing concurrent
dispatch), `stm` (the scheduler's `TVar` state and `retry`-based blocking), `unliftio`
(`async`, `catchAny`, `throwIO` in the scheduler; `UnliftIO.Concurrent.threadDelay` in
tests), `containers` (`Data.Sequence` for the pending buffer, `Data.Set` for active keys,
`Data.Map.Strict` in tests), `effectful` (the `Eff es` stacks and
`withEffToIO (ConcUnlift Persistent Unlimited)` unlifting pattern that `processUntilDrained`
already uses), `nqe` (bounded inbox), and `QuickCheck` + `hspec` in the test suite. No new
dependencies are introduced.

End state of each milestone's interfaces:

Milestone 1: `Shibuya.Policy.validatePolicy :: Ordering -> Concurrency -> Either PolicyError ()`
(unchanged signature) rejects `StrictInOrder`+concurrent and `PartitionedInOrder`+concurrent.
No other signature changes.

Milestone 2: new internal module `Shibuya.Runner.KeyedScheduler` exporting
`runKeyedScheduler :: (Ord key) => Int -> Int -> (item -> Maybe key) -> (item -> IO ()) -> Stream IO item -> IO ()`;
`Shibuya.Runner.BatchProcessor` no longer defines its own scheduler and delegates with
`(\(info, _) -> Just info.batchKey)`;
`Shibuya.Runner.Supervised.runSupervised :: (IOE :> es, Tracing :> es) => Master -> Natural -> ProcessorId -> Ordering -> Concurrency -> Adapter es msg -> Handler es msg -> Eff es SupervisedProcessor`
(the `Ordering` parameter is new; `runIngesterAndProcessor` and `processUntilDrained` gain
it internally); `Shibuya.App.spawnProcessors` passes the `QueueProcessor.ordering` field
through; `Shibuya.App.validateAllPolicies` additionally rejects `BatchingProcessor` +
`PartitionedInOrder` + `Ahead`/`Async`; `Shibuya.Adapter.Mock.trackingAckHandle` records
atomically. `Shibuya.Policy` types must not be renamed or relocated by anyone (EP-25 waits
on this plan), and the Milestone 1 rejection message for the batch case remains available
for EP-28 to cite.
