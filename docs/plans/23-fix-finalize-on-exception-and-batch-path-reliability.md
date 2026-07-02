---
id: 23
slug: fix-finalize-on-exception-and-batch-path-reliability
title: "Fix finalize-on-exception and batch-path reliability"
kind: exec-plan
created_at: 2026-07-02T03:49:03Z
master_plan: "docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md"
---

# Fix finalize-on-exception and batch-path reliability

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is EP-23 of the master plan at
`docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md`.
It has one hard dependency: EP-22
(`docs/plans/22-fix-processor-lifecycle-and-supervision-semantics.md`) must be complete
before this plan starts. See "Dependency on EP-22" in the Context section for exactly what
this plan assumes from it and how to verify it is in place.


## Purpose / Big Picture

Shibuya is a queue-processing framework: an *adapter* (queue-specific code, e.g. for PGMQ or
Kafka) produces messages, a user-supplied *handler* processes each message and returns an
*ack decision* (`AckOk`, `AckRetry`, `AckDeadLetter`, or `AckHalt`), and the framework calls
the adapter's *finalizer* (`AckHandle.finalize`) with that decision so the queue can commit,
redeliver, or dead-letter the message. The framework's central reliability promise is
**message conservation**: every message the adapter hands to the framework is finalized with
a well-defined decision — no message is silently dropped, and no acknowledgement happens
after the framework has been torn down.

A three-repository review (2026-07-01) found five confirmed MAJOR bugs that break this
promise, all in `shibuya-core`:

1. On the single-message path, a handler exception means `finalize` is never called at all.
   For adapters that require an explicit acknowledgement (PGMQ, Kafka) the message is left
   in limbo: stuck until a visibility timeout, or lost forever. The batch path already
   substitutes "retry everything" on a handler exception; the single-message path is
   inconsistent with it.
2. The batch accumulation engine swallows exceptions from its internal consumer thread. If
   the user's `batchKey` function throws, the consumer dies, buffered messages are never
   flushed or finalized, and the processor reports clean completion.
3. Batch halt isolation is violated: after a batch handler returns `AckHalt`, batches that
   were already buffered downstream still run through the user's batch handler.
4. The keyed batch scheduler drains its bounded input into an unbounded in-memory buffer,
   defeating the backpressure the bounded inbox exists to provide.
5. The keyed batch scheduler spawns unsupervised threads; cancelling the processor (e.g. at
   shutdown) leaves them running, so acknowledgements can fire against a torn-down adapter,
   and a killed worker permanently corrupts the scheduler's accounting.

After this plan is implemented: a handler exception finalizes the message with
`AckRetry (RetryDelay 0)` (redeliver, no loss); a crash inside the batcher fails the
processor loudly instead of silently dropping messages; `AckHalt` in a batch stops all
further batch-handler executions for that processor while still finalizing every buffered
message; batch memory stays bounded under a slow handler; shutdown reliably stops all batch
work with no post-shutdown acknowledgements; and the `AckHandle` documentation states a
single, non-contradictory idempotency contract that the adapter plans (EP-27, EP-28) build
against. Each fix is demonstrated by tests in `shibuya-core/test/` that fail before the fix
and pass after, runnable with `cabal test shibuya-core-test` from the repository root.


## Progress

- [x] 2026-07-02: Verify EP-22 is complete (masterplan registry row 22 marked Complete; `Shibuya/Runner/Supervised.hs` uses `finally`-based `doneVar` writes and `waitCatch` on the ingester) and rebase this plan's file/line references onto the post-EP-22 tree.
- [x] 2026-07-02: M1: extract shared bounded-retry finalizer into `shibuya-core/src/Shibuya/Runner/Finalize.hs`; register the module in `shibuya-core/shibuya-core.cabal`.
- [x] 2026-07-02: M1: restructure `processOne` in `shibuya-core/src/Shibuya/Runner/Supervised.hs` so the handler call and the finalize call are isolated separately; handler exception substitutes `AckRetry (RetryDelay 0)`; finalize uses bounded retry; exhausted finalize retry sets the halt flag with a `HaltFatal` naming the message id.
- [x] 2026-07-02: M1: rewrite the Haddock contract in `shibuya-core/src/Shibuya/Core/AckHandle.hs` (remove "Must be called exactly once") and reference it from `shibuya-core/src/Shibuya/Handler.hs`.
- [x] 2026-07-02: M1: tests — single-message conservation with throwing handlers (exactly one finalize, decision `AckRetry (RetryDelay 0)`), transient finalize-retry success, exhausted finalize retry fails loudly with the message id.
- [x] 2026-07-02: M1: `cabal build all`, `cabal test shibuya-core-test` (181 examples, 0 failures), `nix fmt`, commit with trailers.
- [ ] M2: propagate batcher consumer failure in `shibuya-core/src/Shibuya/Runner/Batcher.hs` (`waitCatch` the consumer async at drain end, rethrow).
- [ ] M2: tests — a throwing `batchKey` fails the processor loudly, no message is finalized more than once, no clean-completion report.
- [ ] M2: build, test, format, commit with trailers.
- [ ] M3: halt isolation in `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs` — `processOneBatch` checks the halt flag before running the handler; halt-skipped batches finalize every message with `AckRetry (RetryDelay 0)` and are accounted like exception-substituted batches.
- [ ] M3: tests — after `AckHalt`, buffered batches never reach the batch handler yet all their messages are finalized exactly once with the retry decision.
- [ ] M3: build, test, format, commit with trailers.
- [ ] M4: bound the keyed scheduler's pending buffer in `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs` (reader blocks when pending reaches `max 2 (2 * maxConcurrency)`).
- [ ] M4: bracket the scheduler's reader and workers (structured concurrency; cancellation-safe `finishBatch` accounting; cancel-and-await all workers on any scheduler exit).
- [ ] M4: tests — backpressure bound holds under a blocked handler; forced shutdown produces zero finalizations after `stopAppGracefully` returns; scheduler terminates after a worker is cancelled.
- [ ] M4: build, test, format, commit with trailers; update masterplan Progress rows for EP-23; write Outcomes & Retrospective.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: On a handler exception, the single-message path finalizes the message with
  `AckRetry (RetryDelay 0)` before recording the failure.
  Rationale: Aligns with the batch path, which already substitutes retry-all
  (`ackAll (AckRetry (RetryDelay 0))`) on a batch-handler exception in
  `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`. Guarantees no message is left
  un-finalized. Adapters map `AckRetry` to their redelivery mechanism; the Kafka adapter's
  broken `AckRetry` mapping (which would turn this into an explicit commit-past) is fixed in
  EP-28 (`docs/plans/28-make-kafka-adapter-ack-model-safe-for-at-least-once-delivery.md`)
  before the two ship together.
  Date: 2026-07-02

- Decision: The `AckHandle` idempotency contract is: the framework calls `finalize` at most
  once per message on the single-message path, and possibly multiple times (bounded retry
  after a transient failure) on the batch path; adapters must make `finalize` idempotent or
  internally phase-tracked. The contradictory "Must be called exactly once" wording in
  `shibuya-core/src/Shibuya/Core/AckHandle.hs` is removed.
  Rationale: The current Haddock says both "exactly once" and "adapter enforces idempotency",
  which contradict each other. The batch path's `finalizeWithRetry` loop already depends on
  the idempotent reading; adding a once-only latch to the framework instead would break batch
  retry. EP-27 (PGMQ phase-tracked dead-lettering) and EP-28 (Kafka handle guard) implement
  against this wording.
  Date: 2026-07-02

- Decision: The single-message path adopts the batch path's bounded finalize retry
  (delays 10 ms, 50 ms, 250 ms), via a shared helper extracted to a new module
  `shibuya-core/src/Shibuya/Runner/Finalize.hs`. If the retry budget is exhausted, the
  processor fails loudly: the halt flag is set with
  `HaltFatal ("finalization failed for message id: " <> ...)`, the metrics state becomes
  `Failed`, and the processor halts — a finalize failure is thereby always distinguishable
  from a handler failure (a handler failure finalizes-with-retry and the processor keeps
  running; a finalize failure stops the processor and names the message).
  Rationale: A single transient adapter blip (network hiccup on ack) should not halt a
  processor when the batch path already tolerates it; sharing one helper keeps the two paths'
  semantics and retry schedule identical and gives EP-27/EP-28 one contract to test against.
  Failing loudly on exhaustion mirrors the batch path's `finalizationHalt` behavior, which
  the EP-20 reliability suite already pins down (scenario "#6 Permanent finalizer failure").
  Date: 2026-07-02

- Decision: Batches that are skipped because the halt flag is already set finalize every one
  of their messages with `AckRetry (RetryDelay 0)` (not left to adapter redelivery timeouts),
  and are accounted in metrics exactly like exception-substituted batches (every message
  counts as failed; batch counters still advance).
  Rationale: Consistent with the two exception-substitution decisions above — the framework
  never leaves a message it accepted un-finalized when it is still able to finalize it.
  Leaving skipped messages to visibility-timeout redelivery would be silent and slow for PGMQ
  and lost-forever for auto-commit-style adapters. Reusing the existing exception-substitution
  accounting (`handlerThrew`-style) avoids inventing a third metrics category.
  Date: 2026-07-02

- Decision: The keyed scheduler's pending buffer is bounded at
  `pendingLimit = max 2 (2 * maxConcurrency)`; the reader blocks (STM `retry`) when the
  buffer is full.
  Rationale: The buffer must hold at least a little more than `maxConcurrency` batches so the
  scheduler can look past head-of-line batches whose key is busy and still keep all workers
  fed; twice the concurrency is a conventional lookahead factor. Anything unbounded defeats
  the inbox's backpressure (the confirmed bug). The batcher's own output queue (capacity =
  inbox size) sits upstream and provides the rest of the buffering, so the total in-memory
  window is `inboxSize + outputCapacity + pendingLimit + maxConcurrency`, all bounded. The
  minimum of 2 guarantees progress even at `Serial`-equivalent concurrency of 1 (one running,
  one waiting behind a busy key cannot deadlock the reader).
  Date: 2026-07-02

- Decision: Batcher consumer failure is propagated by keeping the consumer's `Async` handle
  and calling `waitCatch` on it when the output stream reaches its natural end, rethrowing
  any `Left`. This mirrors the ingester pattern established by EP-22 in
  `shibuya-core/src/Shibuya/Runner/Supervised.hs` (`waitCatch` the background async at the
  drain point; never `poll`).
  Rationale: The consumer's `finally (writeTVar doneVar True)` must stay (it is what lets the
  output stream terminate instead of blocking forever), so the failure has to be surfaced at
  the same point the done-signal is consumed. `waitCatch` at end-of-stream is race-free:
  `doneVar` is only set after the consumer's body has finished or thrown.
  Date: 2026-07-02


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The system in one paragraph

`shibuya-core` (the Haskell library under `shibuya-core/` in this repository) runs
"processors" under supervision. For each processor, an *ingester* (a background thread) pulls
messages from the adapter's stream and pushes them into a *bounded inbox* (a fixed-capacity
mailbox from the NQE library; its bound is what creates backpressure — when the inbox is
full, the ingester blocks, which stops pulling from the queue). Each message arrives as an
`Ingested` value: the message `Envelope` (id, payload, metadata) plus an `AckHandle`, a
record holding one function, `finalize :: AckDecision -> Eff es ()`, provided by the adapter.
On the *single-message path*, a processor loop pops messages from the inbox and runs the
user's `Handler`, which returns an `AckDecision`; the framework then calls `finalize` with
that decision. On the *batch path*, the inbox is drained into a stream, the *batcher*
(`Shibuya.Runner.Batcher`) groups messages into batches by a user-supplied `batchKey`
function (flushing on size, timeout, or end-of-input), and the *batch processor*
(`Shibuya.Runner.BatchProcessor`) runs the user's `BatchHandler` over each batch and
finalizes every message in it. "Halt" means a handler returned `AckHalt`: the processor must
stop taking new work, drain what is in flight, and exit; other processors continue. The
`effectful` library provides the `Eff es` monad (an IO-capable effect stack); "async" refers
to `UnliftIO.Async` green threads; a `TBQueue` is a bounded STM queue.

### Key files

- `shibuya-core/src/Shibuya/Runner/Supervised.hs` — supervised runner. `processOne`
  (currently around lines 531–650) processes one message: tracing span, in-flight metrics,
  the handler call, the finalize call, halt flag. `runIngesterAndProcessor` and
  `runIngesterAndProcessorBatch` wire the ingester, inbox, and (for batch) the batcher and
  batch processor together. EP-22 restructures the lifecycle parts of this file; this plan
  edits only the `processOne` body.
- `shibuya-core/src/Shibuya/Runner/Batcher.hs` — batch accumulation engine. A pure core
  (`stepArrival`/`stepTick`/`stepFlush`) plus an IO wrapper `runBatcher` that spawns a
  *consumer* async (folds the input stream into the state and flushes at end-of-input) and a
  *ticker* async (timeout flushes), buffering ready batches in a bounded `TBQueue` (`outQ`)
  drained by `drainQueue`.
- `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs` — batch execution. `processOneBatch`
  runs the batch handler with exception isolation, resolves one decision per message, and
  finalizes each with `finalizeWithRetry` (bounded retry, delays
  `finalizeRetryDelaysMicros = [10_000, 50_000, 250_000]`). `processBatchesUntilDrained`
  folds the ready-batch stream; for `Ahead`/`Async` concurrency it uses
  `runKeyedBatchScheduler`, which serializes same-key batches and runs distinct keys
  concurrently via a reader async, a pending `Seq`, and per-batch worker asyncs.
- `shibuya-core/src/Shibuya/Core/AckHandle.hs` — the `AckHandle` newtype and its (currently
  self-contradictory) contract documentation.
- `shibuya-core/src/Shibuya/Core/Ack.hs` — `AckDecision`, `RetryDelay`, `DeadLetterReason`,
  `HaltReason` (constructors `HaltOrderedStream`, `HaltFatal`).
- `shibuya-core/src/Shibuya/Handler.hs` — the `Handler` type alias and its user-facing docs.
- `shibuya-core/src/Shibuya/Adapter/Mock.hs` — test adapters, including `TrackingAck` /
  `mkTrackedIngested` / `trackedListAdapter`, whose `finalize` appends one
  `(MessageId, AckDecision)` pair per call, so duplicate or missing finalizations are
  observable in tests.
- `shibuya-core/test/Shibuya/Batch/TestHarness.hs` — the EP-20 reliability harness:
  randomized `BatchScenario` generation and the `finalizedExactlyOnce` checker (returns
  `Right ()` iff every expected id was finalized exactly once with its expected decision).
- `shibuya-core/test/Shibuya/Batch/ReliabilitySpec.hs` — the EP-20 reliability suite: a
  QuickCheck conservation property driven through the real `runApp`/`stopAppGracefully`
  path, plus numbered deterministic scenarios (#2 timeout flush … #11 backpressure
  liveness). New batch-path tests in this plan extend this file and harness.
- `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` — single-message-path runner tests
  (including an existing "Error handling" describe block). New single-message tests extend
  this file.
- `shibuya-core/shibuya-core.cabal` — module lists. Any new source module (M1's
  `Shibuya.Runner.Finalize`) must be added to the library's `exposed-modules`; any new test
  module to the test-suite's `other-modules`.

### The six defects, precisely

Line numbers below are from the pre-EP-22 tree and will drift; always locate by function
name.

**Defect 1 — handler exception never finalizes (Supervised.hs, `processOne`).** The current
code wraps the handler call *and* the finalize call in one `catchAny`:

```haskell
result <-
  catchAny
    ( do
        decision <- handler ingested
        ingested.ack.finalize decision
        pure (Right decision)
    )
    ( \ex -> do
        recordException traceSpan ex
        pure $ Left $ HandlerException $ Text.pack $ show ex
    )
```

If `handler` throws, execution jumps to the exception branch and `finalize` is never called:
the message is recorded as failed in metrics but the adapter is never told anything. A second
consequence of the shared `catchAny`: an exception thrown by `finalize` itself is
indistinguishable from a handler failure. Contrast with the batch path, which substitutes
`ackAll (AckRetry (RetryDelay 0))` on a handler exception and then finalizes every message
with bounded retry.

**Defect 2 — batcher consumer swallows exceptions (Batcher.hs, `runBatcher`).** The consumer
async's body is

```haskell
consumer =
  ( do
      Stream.fold Fold.drain (Stream.mapM onArrival input)
      emitStep lock stateRef outQ stepFlush
  )
    `finally` atomically (writeTVar doneVar True)
```

and nothing ever inspects the consumer's `Async` result (`release` merely `cancel`s it). If
`onArrival` throws — the user's `batchKey` function runs inside it — the consumer dies,
`doneVar` is still set by the `finally`, `drainQueue` terminates cleanly, and the processor
reports successful completion while every message still sitting in accumulators (and every
message the dead consumer never read) is silently un-finalized.

**Defect 3 — batch halt isolation violated.** When a batch handler returns `AckHalt`,
`processOneBatch` sets `haltRef` (an `IORef (Maybe HaltReason)`). The only reader of
`haltRef` before this plan is `inboxToStream` in Supervised.hs, which stops pulling *new*
messages from the inbox. But batches already emitted into the batcher's `outQ`, plus the
accumulator remainders that `stepFlush` emits when the input stream ends (which the halt
itself causes), still flow through `processBatchesUntilDrained` and are executed by the
user's `BatchHandler` after the halt. The single-message path does not have this bug: its
`processOne` calls all go through the halted stream. Halt is supposed to mean "run nothing
further through the handler" (its purpose is ordered-stream and fatal-error protection).

**Defect 4 — unbounded pending buffer (BatchProcessor.hs, `runKeyedBatchScheduler`).** The
reader async drains the ready-batch stream as fast as it can:

```haskell
_reader <-
  async $
    ( do
        Stream.fold Fold.drain $
          Stream.mapM (enqueueBatch scheduler) batchStream
        atomically $ markInputDone scheduler Nothing
    )
      `catchAny` \ex -> ...
```

`enqueueBatch` appends to `pending :: Seq ...` with no size check. Since the upstream
`TBQueue` is emptied immediately, the bounded inbox never fills, and under a slow handler the
entire queue backlog is pulled into process memory — exactly what the bounded inbox exists to
prevent.

**Defect 5 — unbracketed scheduler asyncs (same function).** The reader is spawned with bare
`async` (handle discarded) and each batch worker with bare `async` inside `loop`. If the
processor thread running `runKeyedBatchScheduler` is cancelled (graceful-shutdown timeout, or
supervision kill), those asyncs keep running: workers finish their batches and call
`finalize` against an adapter whose `shutdown` has already run. Separately, a worker's
accounting (`finishBatch`, which decrements `running` and frees the key) runs only via
`catchAny`, which does not fire on (async) cancellation — a killed worker leaves `running`
stuck above zero and `nextSchedulerStep` retries forever.

**Defect 6 — contradictory `AckHandle` contract.** The module header of
`shibuya-core/src/Shibuya/Core/AckHandle.hs` currently says "Must be called exactly once;
adapter enforces idempotency." Those two clauses contradict each other, and the batch path's
retry loop already calls `finalize` more than once after a transient failure. The agreed
contract (Decision Log) must replace this wording, and `Shibuya/Handler.hs` should point
handler authors at it.

### Dependency on EP-22

EP-22 (`docs/plans/22-fix-processor-lifecycle-and-supervision-semantics.md`) restructures the
lifecycle around the code this plan edits: it makes every child exit path set `doneVar` via
`finally`, replaces the racy `UIO.poll ingesterAsync` checks with `waitCatch`, and fixes
supervision-strategy mapping. This plan is written against the *post-EP-22* tree and assumes:
(a) processor children set `doneVar` in a `finally`, so this plan's new failure paths
(propagated batcher exception in M2, halt-on-exhausted-finalize in M1) do not need their own
`doneVar` bookkeeping; and (b) the "background async failure is surfaced with `waitCatch` at
the drain point" pattern exists in `Supervised.hs` for M2 to mirror. Before starting, open
the masterplan's Exec-Plan Registry table and confirm row 22 is `Complete`; then read
`shibuya-core/src/Shibuya/Runner/Supervised.hs` and confirm the ingester result is consumed
with `waitCatch` (not `poll`). If EP-22 is not complete, stop and implement it first. Where
this plan quotes pre-EP-22 line numbers, re-locate by function name after rebasing your
understanding on the current file contents.

### Integration constraints with other plans

EP-28 (`docs/plans/28-make-kafka-adapter-ack-model-safe-for-at-least-once-delivery.md`)
writes tests that assume this plan's new behavior: a handler exception finalizes with
`AckRetry (RetryDelay 0)`. Do not weaken or rename that behavior after M1 lands. EP-27
(`docs/plans/27-harden-pgmq-adapter-ack-paths-and-dead-lettering.md`) implements
phase-tracked finalization against the `AckHandle` contract wording fixed in M1 — the
wording in the Decision Log is contractual; if you must adjust a word, update the masterplan
Decision Log and notify EP-27. EP-26
(`docs/plans/26-reduce-per-message-hot-path-overhead.md`) later rewrites the metrics/tracing
hot path in the same `processOne` region; keep M1's restructuring minimal and well-factored
(handler isolation, finalize isolation, decision classification as separate, clearly named
steps) so EP-26 can rework the instrumentation around it without re-deriving the ack
semantics.


## Plan of Work

The work is four milestones, ordered by blast radius: first the single-message ack semantics
and the contract wording (M1), then the batcher's failure propagation (M2), then batch halt
isolation (M3), then the scheduler's bounding and bracketing (M4). Each milestone is a
self-contained commit that builds, passes the full test suite, and adds tests that fail
before its code change and pass after. All commits carry the two trailers given in Concrete
Steps.

### Milestone 1 — finalize on handler exception, shared finalize retry, contract wording

Scope: the single-message path in `shibuya-core/src/Shibuya/Runner/Supervised.hs`, a new
shared module, and the Haddock contract. At the end of this milestone, a throwing handler no
longer strands its message: the message is finalized with `AckRetry (RetryDelay 0)`, the
failure is still recorded in metrics and on the trace span, and a finalize failure is a
distinct, louder event than a handler failure.

First create `shibuya-core/src/Shibuya/Runner/Finalize.hs` exporting `finalizeWithRetry` and
`finalizeRetryDelaysMicros`, moved verbatim from `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`
(which then imports them from the new module; keep behavior byte-identical — same delays
`[10_000, 50_000, 250_000]`, same "record the exception on the span, sleep, retry, return
`Left` when the budget is exhausted" shape, same property that the resolved decision is never
recomputed between attempts). Add `Shibuya.Runner.Finalize` to `exposed-modules` in
`shibuya-core/shibuya-core.cabal`. The module's Haddock should state that this is the only
place the framework calls `AckHandle.finalize` from, on both paths, and restate the retry
schedule.

Then restructure the `processOne` body in `Supervised.hs`. Replace the single `catchAny`
around `handler >>= finalize` with three separately-observable steps. Step one isolates the
handler: `handlerResult <- catchAny (Right <$> handler ingested) (\ex -> recordException
traceSpan ex >> pure (Left ex))`. Step two computes the decision to finalize:
`Right d -> d; Left _ -> AckRetry (RetryDelay 0)`. Step three finalizes with the shared
helper: `finalizeResult <- finalizeWithRetry traceSpan ingested decision`. Classification
afterwards: if the handler succeeded and finalize succeeded, behavior is exactly as today
(`Right decision` drives events, span status, and `decrementAndUpdate`). If the handler threw
and finalize succeeded, keep today's failure accounting (`Left (HandlerException …)` into
`decrementAndUpdate`, span status `Error`) but additionally add a span event recording that
the framework substituted and finalized `ack_retry` (so traces show the message was not
dropped). If finalize returned `Left ex` after exhausting its retries — regardless of what
the handler did — record the exception, set the metrics state to
`Failed ("finalization failed for message id: " <> msgIdText) now`, count the message as
failed, and set the halt flag: `atomicWriteIORef haltRef (Just (HaltFatal ("finalization
failed for message id: " <> msgIdText)))`. Setting `haltRef` reuses the existing drain-then-
`ProcessorHalt` machinery in `processUntilDrained`, so an adapter whose ack path is down
stops the processor loudly instead of grinding through the backlog — the same behavior the
batch path already has (its `finalizationHalt`). Keep the existing `AckHalt`-sets-`haltRef`
logic unchanged.

Also in this milestone, fix the contract documentation. In
`shibuya-core/src/Shibuya/Core/AckHandle.hs`, delete the "Must be called exactly once"
sentence and write the agreed contract in the module header and on the `finalize` field: the
framework calls `finalize` at most once per message on the single-message path; on the batch
path (and on the single-message path's transient-failure retry) it may be called multiple
times with the same decision, under a bounded retry schedule; therefore adapters must make
`finalize` idempotent or phase-tracked (safe to re-run a partially-completed finalization);
the framework never calls `finalize` twice with *different* decisions for one delivery. In
`shibuya-core/src/Shibuya/Handler.hs`, add one sentence to the Haddock: handler exceptions do
not lose messages — the framework finalizes the message with `AckRetry (RetryDelay 0)` and
records the failure; handlers that want different disposition must catch their own
exceptions and return a decision.

Tests, in `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` (extend the existing
"Error handling" describe block) using `TrackingAck`/`mkTrackedIngested`/`trackedListAdapter`
from `Shibuya.Adapter.Mock` and `finalizedExactlyOnce` from `Shibuya.Batch.TestHarness`
(both are already in the same test suite): (a) a run of N tracked messages where the handler
throws for a chosen subset asserts, after the run completes, `finalizedExactlyOnce tracked
expected == Right ()` where `expected` maps throwing ids to `AckRetry (RetryDelay 0)` and the
rest to `AckOk` — this is the "every ingested message gets exactly one finalize even when
handlers throw" adapter-level assertion, and it fails before the fix with an "id set
mismatch: missing=…" counterexample; (b) a flaky `AckHandle` that throws on its first two
calls and records on the third asserts one recorded finalization and exactly three attempts
(transient finalize retry on the single-message path); (c) a permanently failing `AckHandle`
for msg-1 alongside a tracked msg-2 asserts the processor's metrics state is
`Failed` with text containing `msg-1`, and msg-2 was still finalized `AckOk` exactly once
(mirrors the batch suite's scenario #6; remember to allow ~700 ms for the retry schedule).
Also add a property-style variant to the EP-20 suite if convenient: a single-message analogue
of the conservation property, iterating a randomized throw-set. Keep runtimes modest
(`withMaxSuccess 30` is plenty).

Acceptance: the new tests fail on the pre-milestone tree and pass after;
`cabal test shibuya-core-test` is fully green; behavior beyond compilation is demonstrated by
the tracked-decision assertions (the adapter observed the finalizations).

### Milestone 2 — propagate batcher consumer failure

Scope: `shibuya-core/src/Shibuya/Runner/Batcher.hs` only, plus tests. At the end, a crash
anywhere in the batcher's consumer (in practice: the user's `batchKey` function, which is the
only user code it runs) fails the processor loudly instead of reporting clean completion.

Change `drainQueue` to accept the consumer's `Async ()` handle (thread it through from
`acquire`'s returned tuple in `runBatcher`; `consume` already receives that tuple). The
`step` function of `drainQueue` runs in IO around an `atomically` block; restructure it so
the STM part returns either a batch or a "drained" signal, and in the drained case the IO
part performs `UIO.waitCatch consumerA` and either rethrows the `Left` exception with
`throwIO` or returns `Nothing` to end the stream. This mirrors the EP-22 ingester pattern:
the background async's outcome is consumed with `waitCatch` at the drain point, never
`poll`ed and never discarded. Keep the consumer's `finally (writeTVar doneVar True)` — it is
what guarantees `drainQueue` reaches the drained case at all — and keep `release` cancelling
both asyncs (cancelling an already-dead async is a no-op). Update the consumer's Haddock
comment, which currently defers failure propagation to "the integration plan (EP-19)": that
deferral is what this milestone closes.

The propagated exception flows out of the ready-batch stream into
`processBatchesUntilDrained`'s fold, up through `runIngesterAndProcessorBatch` in
`Supervised.hs`, and into the (post-EP-22) child failure path: metrics `Failed`, `doneVar`
set via `finally`, supervision notified. No changes in `Supervised.hs` should be needed;
verify rather than edit.

Tests, in `shibuya-core/test/Shibuya/Batch/ReliabilitySpec.hs` (new deterministic scenario,
following the numbered-scenario style): build a `BatchConfig` whose `batchKey` function
throws (`error "boom in batchKey"`) for one specific envelope (say msg-3 of 5, detectable via
its `partition` field as `scenarioBatchKey` does), with a `batchSize` large enough that
msg-1/msg-2 are still buffered when the crash happens. Run it through `runApp` with
`IgnoreFailures`, wait briefly, and assert: the processor's metrics state (read via the
`metricsFor` helper already in the file) is `Failed` with text containing the exception
message; no message was finalized more than once (`finalizedExactlyOnce` is too strict here
since buffered messages legitimately go un-finalized on a crash — assert instead that the
tracked list has no duplicate ids and contains no unexpected decisions); and the
`SupervisedProcessor.done` TVar is set (no hang). Before the fix this test fails because the
processor completes with a clean (non-`Failed`) state. Also assert the app itself survives
(`stopAppGracefully` returns) so a batcher crash cannot wedge shutdown.

Acceptance: new scenario fails before, passes after; the whole suite stays green (in
particular the existing EP-20 property, which proves normal-path conservation is untouched).

### Milestone 3 — batch halt isolation

Scope: `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs` (`processOneBatch`), plus tests.
At the end, once any batch sets the halt flag, no later batch for that processor reaches the
user's `BatchHandler`; every message in a skipped batch is still finalized, with
`AckRetry (RetryDelay 0)`.

Edit `processOneBatch`: immediately on entry (before opening the span is acceptable, but
inside the span is better for observability — keep the span, add an event/attribute marking
the batch as skipped-after-halt), read `haltRef`. If it is `Just _`, take a skip path: do not
call `handler`; substitute `resolvedAck = ackAll (AckRetry (RetryDelay 0))` exactly as the
exception path does, run the same retained-list finalize loop (`finalizeWithRetry` per
message, one decision each), set the span status to `Error "skipped after halt"`, and record
metrics through the existing `recordBatchOutcome` with the `handlerThrew`-style flag set so
every skipped message counts as failed (see Decision Log: skipped batches are accounted like
exception-substituted batches). Pass `Nothing` as the skip path's own halt reason — the halt
state was already recorded by the batch that halted, and `recordBatchOutcome`'s state logic
already preserves an existing `Failed` state. Finalize failures on the skip path go through
the existing `finalizationHalt` machinery unchanged. Implementation note: the cleanest shape
is to compute `(resolvedAck, handlerThrew)` from a three-way source — halt-skip, handler
exception, handler result — and leave everything downstream of that pair untouched; that
keeps the diff small for EP-26.

Do not try to make the check race-free against batches already *running* under `Async`
concurrency: halt isolation means no batch *starts* the handler after the flag is observed
set; in-flight batches drain normally (this matches the single-message path's documented
"waits for in-flight to complete before halting" behavior in
`shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs`).

Tests, in `shibuya-core/test/Shibuya/Batch/ReliabilitySpec.hs`: a deterministic scenario with
`batchSize = 1`, `Serial` batch concurrency (the `mkBatchProcessor` default), five tracked
messages, and a recording handler (the file's `recordingHandler`) that returns
`ackExcept [(MessageId "msg-2", AckHalt (HaltFatal "stop"))]` for msg-2's batch and blocks
msg-1's batch for ~200 ms on entry (a `threadDelay`, or a gate opened by the test) so the
batcher demonstrably buffers batches 2–5 into its output queue before any halt is set. After
the app stops, assert: the observed-batch list contains msg-1 and msg-2 only (before the fix
it contains msg-3..5 too — that is the failing assertion); and `finalizedExactlyOnce` holds
with expected decisions msg-1 `AckOk`, msg-2 `AckHalt (HaltFatal "stop")`, msg-3..5
`AckRetry (RetryDelay 0)`. Add a second variant exercising the `stepFlush` remainder: batch
size 100 with a gated adapter (the file's `gatedTrackedAdapter`) so messages 3..5 are still
in an accumulator when the halt lands; the end-of-input flush then emits them as a
`TriggerFlush` batch, which must be skipped-and-finalized, not handled. Keep the existing
scenario #7 green — it pins "the halting batch itself is finalized and other processors are
spared", which this milestone must not disturb.

Acceptance: both new tests fail before and pass after; full suite green.

### Milestone 4 — bound and bracket the keyed batch scheduler

Scope: `runKeyedBatchScheduler` and its helpers in
`shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`, plus tests. At the end, batch-path
memory is bounded end-to-end and cancelling the processor cannot leak workers or produce
post-shutdown acknowledgements.

Bounding. Give `runKeyedBatchScheduler` a pending bound: in `processBatchesUntilDrained`
compute `pendingLimit = max 2 (2 * maxConc)` (Decision Log) and pass it down. Change
`enqueueBatch` to an STM transaction that `retry`s while `Seq.length s.pending >=
pendingLimit` (track the length in the state record as an `Int` alongside the `Seq` if you
prefer O(1); `Seq.length` is O(1) anyway). Because `nextSchedulerStep` removes items from
`pending` inside the same `TVar`, a full buffer wakes the reader as soon as a worker starts a
batch; no deadlock is possible while `pendingLimit >= 1` plus running workers eventually
calling `finishBatch` (which M4's bracketing guarantees even under cancellation).

Bracketing. Restructure the function to structured concurrency. Spawn the reader with
`UIO.withAsync` so it is cancelled when the scheduler scope exits for any reason. Track live
workers in a `TVar (Map Unique (Async ()))` (or a plain list TVar): each `StartBatch` spawns
the worker with `async`, registers it, and the worker's body has the shape "run
`batchAction batch`, catching synchronous exceptions into a result IORef, `finally`
(unconditionally) `atomically (finishBatch scheduler batch result)` and self-deregistration"
— because the accounting runs in a `finally`, a worker killed by an asynchronous cancellation
still decrements `running`, frees its key, and deregisters, which fixes the
stuck-`running`-retries-forever defect. `finishBatch` and deregistration are a fast STM
transaction, so the `finally` needs no `uninterruptibleMask` gymnastics beyond what `finally`
already provides (its cleanup runs masked). Wrap the scheduler's main `loop` in a `finally`
(or `bracket`) whose cleanup reads the worker map and `cancel`s every live worker —
`UnliftIO.Async.cancel` waits for the target to finish, so when `runKeyedBatchScheduler`
returns or is itself cancelled, it is guaranteed that no worker is still running and
therefore no `finalize` can fire afterwards. On the normal exit path (`SchedulerDone`)
`running == 0` already, so the cleanup is a no-op; on the failure path
(`SchedulerDone (Just ex)` rethrow) and on cancellation it is what restores the invariant.
Preserve existing semantics: same-key serialization (`popStartable`/`activeKeys`) and
first-failure-wins (`firstFailure`) must not change; the existing reliability scenario #10
(per-key FIFO under `Async 2`) pins the former.

Tests, in `shibuya-core/test/Shibuya/Batch/ReliabilitySpec.hs`: (a) *backpressure bound* —
`Async 2`, `batchSize = 1`, a small inbox (say 2), a source adapter that counts how many
messages the framework has pulled (wrap `Stream.unfoldrM` around a counter IORef over 50
envelopes), and a batch handler that blocks on a gate. After letting the pipeline saturate
(~200 ms), assert the pull counter is at most
`inboxSize + outputCapacity + pendingLimit + maxConc + a-small-slack` (with these numbers,
well under 20; before the fix the counter reaches 50 because the reader drains everything),
then open the gate and assert all 50 messages finalize exactly once — the bound must not
cost conservation. (b) *no finalize after shutdown* — `Async 2`, many one-message batches, a
batch handler that sleeps 200 ms per batch, tracked acks; call
`stopAppGracefully (ShutdownConfig {drainTimeout = 0.05})` so the drain times out and the
master *cancels* the processors mid-flight; when it returns, snapshot
`getTrackedDecisions`, sleep 300 ms (longer than a handler sleep), snapshot again, and assert
the two snapshots are identical — before the fix, leaked workers keep finalizing after the
forced stop, and the second snapshot grows. Also assert no id appears twice in the final
snapshot. (c) *cancellation liveness* — same setup, but assert `stopAppGracefully` itself
returns within a bounded time (wrap in `UnliftIO.timeout` of a few seconds): before the fix a
killed worker can leave `running` stuck and wedge the scheduler loop that the cancel must
tear down. Test (b) is the plan-mandated cancellation test proving no finalize occurs after
shutdown.

Acceptance: the three new tests fail before and pass after; the whole suite (including the
QuickCheck conservation property and scenario #10) stays green. This milestone completes the
plan; update the masterplan's three EP-23 Progress rows and this plan's Outcomes section.


## Concrete Steps

All commands run from the repository root,
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. Repeat the build/test/format cycle
for every milestone.

First confirm the EP-22 prerequisite:

```bash
grep -n "| 22 " docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
grep -n "waitCatch\|poll" shibuya-core/src/Shibuya/Runner/Supervised.hs
```

The registry row must read `Complete`, and the ingester result must be consumed with
`waitCatch` (no `UIO.poll` remaining on the ingester path). If not, stop: implement EP-22
first.

Build and test:

```bash
cabal build all
cabal test shibuya-core-test
```

A passing test run ends like:

```text
Finished in 12.3456 seconds
187 examples, 0 failures
Test suite shibuya-core-test: PASS
```

(The example count grows as milestones add tests; what matters is `0 failures` and `PASS`.)
To iterate on just the new tests while developing, use HSpec's match flag, for example:

```bash
cabal test shibuya-core-test --test-options='--match "finalize"'
cabal test shibuya-core-test --test-options='--match "halt"'
```

To demonstrate a test fails before its fix (do this once per milestone and keep the evidence
in mind for the Outcomes section): commit or stash the source-file change, run the matching
test, observe the failure (for M1 it is a `finalizedExactlyOnce` counterexample of the form
`id set mismatch: missing=[MessageId "msg-…"]`), then restore the change and observe the
pass.

Before every commit:

```bash
nix fmt
git add <files>
```

Commit one milestone per commit, Conventional Commits style, with both required trailers.
Example for M1:

```text
fix(runner): finalize with AckRetry on handler exception and codify AckHandle contract

Handler exceptions on the single-message path previously skipped finalize
entirely, stranding the message. Now the framework substitutes
AckRetry (RetryDelay 0), finalizes with the shared bounded-retry helper
(new Shibuya.Runner.Finalize), and halts loudly (HaltFatal naming the
message id) if the finalize retry budget is exhausted. AckHandle docs now
state the at-most-once / idempotent-retry contract.

MasterPlan: docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
ExecPlan: docs/plans/23-fix-finalize-on-exception-and-batch-path-reliability.md
```

Suggested subjects for the other milestones (same trailers on each):
`fix(batch): propagate batcher consumer failures to the processor` (M2),
`fix(batch): enforce halt isolation for buffered and flushed batches` (M3),
`fix(batch): bound and bracket the keyed batch scheduler` (M4). If the pre-commit hook
auto-formats, re-stage (`git add`) and commit again. Update this plan's Progress section (and
at the end, the masterplan's Progress rows for EP-23) in the same commit as the work it
describes, or in an immediately following `docs:` commit with the same trailers.


## Validation and Acceptance

The overall acceptance is behavioral, verified by tests that encode the message-conservation
property against a tracking adapter (every `finalize` call is recorded as a
`(MessageId, AckDecision)` pair, so drops and duplicates are directly observable):

- Handler exception (M1): given 5 tracked messages where the handler throws on msg-2 and
  msg-4, after the run `getTrackedDecisions` contains exactly five entries — msg-2 and msg-4
  with `AckRetry (RetryDelay 0)`, the rest `AckOk` — and `metrics.stats.failed == 2`,
  `metrics.stats.processed == 3`. Before M1, msg-2 and msg-4 are absent from the tracked
  list entirely.
- Finalize failure remains distinguishable (M1): a permanently throwing `AckHandle` yields
  metrics state `Failed` whose text contains the message id, while a throwing *handler*
  leaves the processor running. The transient case (two throws, then success) yields exactly
  one recorded finalization and three attempts.
- Batcher crash (M2): a throwing `batchKey` puts the processor in `Failed` state (text
  contains the thrown message), sets `done`, never double-finalizes, and does not hang
  `stopAppGracefully`. Before M2, the processor state is clean and messages vanish.
- Halt isolation (M3): with a halt on msg-2's batch and batches 3–5 buffered, the batch
  handler observes only batches 1 and 2, and the tracked decisions are msg-1 `AckOk`, msg-2
  `AckHalt …`, msg-3..5 `AckRetry (RetryDelay 0)`, each exactly once. Before M3, the handler
  observes batches 3–5.
- Bounded backpressure (M4): with a blocked handler, the adapter-pull counter stays below
  the derived bound (< 20 in the test's configuration) instead of draining all 50 messages;
  after unblocking, all 50 finalize exactly once.
- No finalize after shutdown (M4): after a forced `stopAppGracefully` (drain timeout 50 ms)
  returns, the tracked-decision list does not change for at least 300 ms, and contains no
  duplicate ids; `stopAppGracefully` returns within a bounded time.

Full-suite commands and expected results:

```bash
cabal build all              # exits 0, no warnings introduced by this plan's changes
cabal test shibuya-core-test # "0 failures", "Test suite shibuya-core-test: PASS"
nix fmt                      # rewrites nothing on a properly formatted tree
```

Regression guardrails that must stay green throughout: the EP-20 QuickCheck conservation
property ("finalizes every normal-path message once with the intended decision"), scenario
#7 (halting batch finalized, sibling processor spared), and scenario #10 (per-key FIFO under
`Async 2`).


## Idempotence and Recovery

Every step is an ordinary source edit plus tests; re-running builds, tests, and `nix fmt` is
always safe. Milestones are independent commits: if a milestone's change proves wrong, revert
that commit alone (`git revert <sha>`) — no migrations, no generated artifacts, no state. The
only cross-milestone coupling is M1's new `Shibuya.Runner.Finalize` module, which M3 also
uses on its skip path; if M1 must be reverted after M3 lands, the batch path still compiles
by pointing `BatchProcessor.hs`'s imports back at local copies (the helper was extracted
verbatim). Tests in M4 involve timing (sleeps, drain timeouts); if one flakes in CI, widen
its time margins rather than weakening its assertions — the assertions (counter bound,
snapshot equality, no duplicates) are the acceptance, the sleeps are just scheduling slack.
If a pre-commit formatting hook rejects a commit, run `nix fmt`, re-stage, and commit again;
the hook is idempotent.


## Interfaces and Dependencies

No new external dependencies. Everything uses libraries already in
`shibuya-core/shibuya-core.cabal`: `effectful` (the `Eff es` monad), `unliftio`
(`async`/`withAsync`/`waitCatch`/`cancel`/`finally`/`catchAny`/`throwIO`), `stm`
(`TVar`/`TBQueue`/`retry`), `streamly-core` (streams and folds), `nqe` (bounded inbox),
`containers` (`Seq`, `Map`, `Set`), and `hspec`/`QuickCheck` for tests.

Signatures that must exist at the end of each milestone (full module paths; `es` and `msg`
as in the existing code):

- M1, new module `Shibuya.Runner.Finalize`
  (`shibuya-core/src/Shibuya/Runner/Finalize.hs`, added to `exposed-modules`):

```haskell
finalizeRetryDelaysMicros :: [Int]

finalizeWithRetry ::
  (IOE :> es, Tracing :> es) =>
  OTel.Span ->
  Ingested es msg ->
  AckDecision ->
  Eff es (Either SomeException ())
```

  `Shibuya.Runner.BatchProcessor` no longer defines these locally; both it and
  `Shibuya.Runner.Supervised` import them. `processOne` in
  `Shibuya.Runner.Supervised` keeps its existing signature. `Shibuya.Core.AckHandle` and
  `Shibuya.Handler` change documentation only — no type changes.

- M2, `Shibuya.Runner.Batcher`: `runBatcher :: Natural -> BatchConfig es msg -> Stream IO
  (Ingested es msg) -> Stream IO (ReadyBatch es msg)` is unchanged externally; internally
  `drainQueue` gains the consumer's `Async ()` parameter:

```haskell
drainQueue ::
  Async () ->
  TBQueue (ReadyBatch es msg) ->
  TVar Bool ->
  Stream IO (ReadyBatch es msg)
```

- M3, `Shibuya.Runner.BatchProcessor`: `processOneBatch` keeps its signature (it already
  receives `haltRef :: IORef (Maybe HaltReason)`); only its body gains the skip path.

- M4, `Shibuya.Runner.BatchProcessor`: `runKeyedBatchScheduler` gains the pending bound:

```haskell
runKeyedBatchScheduler ::
  Int ->  -- max concurrency
  Int ->  -- pending bound: max 2 (2 * maxConcurrency), computed by the caller
  ((BatchInfo, NonEmpty (Ingested es msg)) -> IO ()) ->
  Stream IO (BatchInfo, NonEmpty (Ingested es msg)) ->
  IO ()
```

  `processBatchesUntilDrained` keeps its public signature and computes the bound internally.

Consumers of this plan's outputs: EP-27 and EP-28 (adapter repositories) depend on the M1
contract wording and the M1 `AckRetry (RetryDelay 0)` substitution; EP-26 edits the same
`processOne` region afterwards and relies on M1's separation of handler isolation, decision
resolution, and finalization; EP-25 will later move these modules under `Shibuya.Internal.*`
and must find the contract wording already in place.


## Revision Notes

2026-07-02: Marked the EP-22 prerequisite and all M1 progress items complete after
extracting `Shibuya.Runner.Finalize`, applying single-message finalize-on-exception
semantics, updating the `AckHandle` and `Handler` Haddocks, adding regression tests, and
validating with `cabal build all`, `cabal test shibuya-core-test`, and `nix fmt`.
