---
id: 22
slug: fix-processor-lifecycle-and-supervision-semantics
title: "Fix processor lifecycle and supervision semantics"
kind: exec-plan
created_at: 2026-07-02T03:49:03Z
master_plan: "docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md"
---

# Fix processor lifecycle and supervision semantics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is EP-22 under the master plan
`docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md`.
Every commit made while implementing this plan must be a conventional commit (for example
`fix(runner): ...` or `test(runner): ...`) and must carry these two trailers:

```text
MasterPlan: docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
ExecPlan: docs/plans/22-fix-processor-lifecycle-and-supervision-semantics.md
```


## Purpose / Big Picture

Shibuya is a queue-processing framework: an application calls `runApp` with a list of
processors, each of which reads messages from a queue adapter and runs a user handler on
each message. Today the framework has seven verified lifecycle and supervision bugs that
make shutdown and failure handling unreliable in ways an application author can observe
directly:

- If any handler returns `AckHalt` (the "stop this processor" acknowledgement), `waitApp`
  blocks forever and `stopAppGracefully` always burns its full drain timeout (30 seconds
  by default), because the flag that marks a processor as finished is never set on the
  halt path. The same is true when a processor is cancelled or when its stream source
  fails.
- The `StopAllOnFailure` supervision strategy currently kills every processor as soon as
  any one of them finishes *successfully* (for example, when a finite stream is drained,
  or when a halt is converted to a graceful exit), because it maps to the wrong strategy
  in the underlying supervision library.
- The `IgnoreFailures` strategy is dead code: every processor is unconditionally "linked"
  to the application thread, so any processor failure crashes the whole application
  regardless of the chosen strategy.
- A race in ingester failure detection can silently swallow an adapter failure, making a
  broken queue connection look like a clean end-of-stream.
- The standalone runner `runWithMetrics` deadlocks whenever the message stream is longer
  than the inbox size.
- `runApp` leaks a live supervisor if spawning fails partway, and querying master metrics
  after `stopMaster` blocks forever.

After this plan is implemented, all of the following become observably true and are locked
in by regression tests in `shibuya-core/test/`: `waitApp` returns promptly after a handler
halts; `stopAppGracefully` returns `True` without waiting out its timeout when processors
are done; one processor finishing (or halting) under `StopAllOnFailure` leaves its siblings
running; a processor failure under `IgnoreFailures` is recorded in metrics without crashing
the app; an adapter stream failure is always recorded (never silently dropped);
`runWithMetrics` completes for streams of any length; and metrics queries after shutdown
return instead of hanging. All of this is demonstrated by running:

```bash
cabal test shibuya-core-test
```

from the repository root and seeing the suite pass, where several of the new tests fail
(hang or assert) against the pre-plan code.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Remove `doneVar` writes (and the `doneVar` parameter) from
      `runIngesterAndProcessor` and `runIngesterAndProcessorBatch` in
      `shibuya-core/src/Shibuya/Runner/Supervised.hs`.
- [ ] M1: Set `doneVar` via an IO-level `finally` around the entire child action in
      `runSupervised` and `runSupervisedBatch`; set it via `finally` in
      `runWithMetricsBatch`; delete the stale "leaves doneVar unset on halt" comment
      above `runIngesterAndProcessorBatch`.
- [ ] M1: Add `shibuya-core/test/Shibuya/App/LifecycleSpec.hs` (registered in
      `shibuya-core/test/Main.hs` and in `other-modules` of
      `shibuya-core/shibuya-core.cabal`) with the halt/waitApp, halt/stopAppGracefully,
      cancellation, and batch-halt regression tests.
- [ ] M1: `cabal build all` and `cabal test shibuya-core-test` pass; `nix fmt`; commit.
- [ ] M2: Change `toNQEStrategy` in `shibuya-core/src/Shibuya/App.hs` to map
      `StopAllOnFailure` to `NQE.IgnoreGraceful`.
- [ ] M2: Add strategy-semantics tests (graceful completion and halt do not kill siblings
      under `StopAllOnFailure`; failure does kill siblings and propagates).
- [ ] M2: Build, test, format, commit.
- [ ] M3: Add `propagateFailures :: !Bool` to `MasterState` in
      `shibuya-core/src/Shibuya/Runner/Master.hs`, derived from the NQE strategy in
      `startMaster`.
- [ ] M3: Make `UIO.link` conditional on `master.state.propagateFailures` in both
      `runSupervised` and `runSupervisedBatch`.
- [ ] M3: Rewrite the existing "Adapter source exceptions" test and the "KillAll
      supervision strategy" test in
      `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs`; add an `IgnoreFailures`
      end-to-end isolation test.
- [ ] M3: Build, test, format, commit.
- [ ] M4: Replace `UIO.poll` with `UIO.waitCatch` in both ingester-failure checks in
      `shibuya-core/src/Shibuya/Runner/Supervised.hs`; add the repeated
      failing-source test.
- [ ] M4: Rewrite `runWithMetrics` to delegate to `runIngesterAndProcessor` (concurrent
      draining); delete `drainInboxWithMetrics`; add the longer-than-inbox test.
- [ ] M4: Tear down the master in `runApp` (in `shibuya-core/src/Shibuya/App.hs`) when
      `spawnProcessors` throws.
- [ ] M4: Convert master introspection and registration
      (`getAllMetrics`, `getAllMetricsIO`, `getProcessorMetrics`,
      `getProcessorMetricsIO`, `registerProcessor`, `unregisterProcessor`) in
      `shibuya-core/src/Shibuya/Runner/Master.hs` to direct TVar operations; add the
      metrics-after-stop test.
- [ ] M4: Build, test, format, commit.
- [ ] Update the master plan's Progress section (the four EP-22 checkboxes) when done.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Remap `StopAllOnFailure` to `NQE.IgnoreGraceful` (it currently maps to
  `NQE.KillAll`).
  Rationale: NQE's `processDead` for `KillAll` removes the dead child, calls `stopAll`,
  and returns `False` (stopping the supervisor loop) even when the child exited with
  `Right ()`. So under `KillAll`, one processor finishing a finite stream — or halting,
  since `runSupervised` converts `ProcessorHalt` into a graceful exit — kills every
  sibling and shuts the supervisor down. `IgnoreGraceful` ignores `Right ()` exits
  (removes the child and keeps running) and performs `stopAll` plus exception rethrow
  only on `Left e`, which is exactly the documented intent of `StopAllOnFailure`:
  "a single processor *failure* triggers shutdown of all processors".
  Date: 2026-07-02.
- Decision: `doneVar` (the per-processor completion flag consumed by `waitApp` and
  `stopAppGracefully`) must be set by a `finally` wrapped around the *entire* child
  action at the IO level, covering every exit path: normal completion, `ProcessorHalt`,
  ingester failure, handler-thread failure, and asynchronous cancellation. No code path
  may exit the child without passing through that `finally`.
  Rationale: any exit path that skips the write deadlocks `waitApp` and forces
  `stopAppGracefully` to burn its whole `drainTimeout`. EP-23
  (`docs/plans/23-fix-finalize-on-exception-and-batch-path-reliability.md`) builds
  directly on this `finally`-based structure and assumes no alternative exit paths exist.
  Date: 2026-07-02.
- Decision (plan authoring): make child linking strategy-aware by storing a
  `propagateFailures :: Bool` flag on `MasterState`, derived from the NQE strategy in
  `startMaster` (`KillAll`/`IgnoreGraceful` propagate; `IgnoreAll`/`Notify` do not), and
  calling `UIO.link` only when that flag is set — rather than catching and routing child
  failures manually.
  Rationale: the link is the only channel through which the *application thread* learns
  of a child failure (under `IgnoreGraceful`, the supervisor thread rethrows the failure,
  but nothing observes the supervisor's own `Async`, so that rethrow dies silently).
  Keeping the link for `StopAllOnFailure` preserves the existing propagation behavior
  that tests and the example app rely on; dropping it for `IgnoreFailures` makes that
  strategy actually isolate failures. Deriving the flag inside `startMaster` avoids a
  module cycle (the user-facing `SupervisionStrategy` type lives in `Shibuya.App`, which
  imports `Shibuya.Runner.Master`) and avoids changing `runSupervised`'s signature.
  Note that `UIO.link` (from the `async` package via `unliftio`) ignores
  `AsyncCancelled`, so a linked child being cancelled by `stopMaster` does not kill the
  application thread.
  Date: 2026-07-02.
- Decision (plan authoring): fix the "metrics query after `stopMaster` hangs forever"
  bug by rewriting `getAllMetrics`, `getAllMetricsIO`, `getProcessorMetrics`,
  `getProcessorMetricsIO`, `registerProcessor`, and `unregisterProcessor` as direct STM
  operations on `master.state.metrics`, bypassing the master's message loop entirely.
  Rationale: the message-loop handlers for these operations do nothing but read/modify
  that same `TVar` map, so direct access has identical semantics, is O(1), cannot hang on
  a dead inbox, and additionally removes a latent shutdown hazard where a child's
  `finally`-time `unregisterProcessor` could block forever if the master loop died first.
  The `MasterMessage` type and `masterLoop` are kept unchanged for compatibility (they
  are exported), but no internal call site sends queries to the loop anymore.
  Date: 2026-07-02.
- Decision (plan authoring): fix the `runWithMetrics` drain deadlock by making it run the
  ingester concurrently with draining — concretely, by delegating to
  `runIngesterAndProcessor` with `Serial` concurrency — rather than documenting and
  deprecating the function.
  Rationale: `runWithMetrics` is a supported public entry point ("Standalone (without
  Master)") used by tests; after M1 removes the `doneVar` parameter,
  `runIngesterAndProcessor` is a drop-in body for it, so the fix is smaller than a
  deprecation cycle and deletes the now-redundant `drainInboxWithMetrics`.
  Date: 2026-07-02.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Everything in this section describes the code as it exists at the commit this plan was
written against (`bdfccae`, branch `master`). Line numbers are anchors, not gospel; they
shift as milestones land, so always locate code by function name.

### Vocabulary

- **Processor**: one unit of queue consumption: an *adapter* (queue-specific message
  source) paired with a *handler* (user function deciding what to do with each message).
  Configured via the `QueueProcessor` type in `shibuya-core/src/Shibuya/App.hs`.
- **Adapter**: the record `Adapter { adapterName, source, shutdown }` in
  `shibuya-core/src/Shibuya/Adapter.hs`. `source` is a streamly `Stream` of `Ingested`
  messages; `shutdown` asks the adapter to end that stream.
- **Handler**: `type Handler es msg = Ingested es msg -> Eff es AckDecision`
  (`shibuya-core/src/Shibuya/Handler.hs`). `AckDecision` is `AckOk`, `AckRetry`,
  `AckDeadLetter`, or `AckHalt` (`shibuya-core/src/Shibuya/Core/Ack.hs`). `AckHalt`
  means "stop this processor".
- **`Eff es`**: the `effectful` library's monad; `es` is the list of available effects.
  `withEffToIO ... $ \runInIO -> ...` obtains a function `runInIO :: Eff es a -> IO a`
  so that `Eff` actions can be run inside plain-`IO` machinery such as `async`.
- **Ingester**: the thread that pulls messages from `adapter.source` and pushes them into
  a bounded **inbox** (an NQE mailbox with a maximum size, created via
  `newBoundedInbox`; a full inbox blocks the sender, which is how backpressure works).
  Code: `shibuya-core/src/Shibuya/Runner/Ingester.hs` (`runIngesterWithMetrics`).
- **Master**: a small coordinator (`shibuya-core/src/Shibuya/Runner/Master.hs`) holding a
  `TVar (Map ProcessorId (TVar ProcessorMetrics))` plus an NQE **supervisor**. Started by
  `startMaster`, stopped by `stopMaster` (which cancels the supervisor — thereby
  cancelling all children — and then cancels the master's message loop).
- **NQE supervisor**: from the `nqe` library (`Control.Concurrent.NQE.Supervisor`). A
  thread that owns a list of child `Async () ` handles. `addChild sup action` spawns
  `action` with `async` and registers it. When any child terminates, the supervisor's
  `processDead` function runs with the child's result (`Right ()` for a graceful exit,
  `Left e` for an exception) and the supervisor's `Strategy` decides what happens. The
  exact semantics are quoted below because they are the heart of bug 2.
- **`doneVar`**: the `done :: TVar Bool` field of `SupervisedProcessor`
  (`shibuya-core/src/Shibuya/Runner/Supervised.hs`). `waitApp` and
  `stopAppGracefully`/`waitForDrainWithTimeout` in `shibuya-core/src/Shibuya/App.hs`
  block (via STM `check`) until every processor's `doneVar` is `True`.
- **`ProcessorHalt`**: an exception (`shibuya-core/src/Shibuya/Runner/Halt.hs`) thrown by
  the processing loop when a handler returned `AckHalt`; `runSupervised` catches it and
  converts it into a graceful child exit so a halt does not look like a failure.
- **`link`**: `UnliftIO.link child` registers the calling thread to receive an
  `ExceptionInLinkedThread` whenever `child` terminates with an exception (cancellation
  excluded). Used at the end of `runSupervised`/`runSupervisedBatch`.
- **TVar / STM**: GHC software transactional memory. `check b` retries the transaction
  until `b` is `True` — this is how `waitApp` blocks without polling.

### The runtime shape

`runApp` (in `shibuya-core/src/Shibuya/App.hs`) validates policies, converts the
user-facing `SupervisionStrategy` to an NQE `Strategy` via `toNQEStrategy`, calls
`startMaster`, then `spawnProcessors`, which calls `runSupervised` (single-message) or
`runSupervisedBatch` (batching) per processor. Each of those registers metrics with the
master, calls `addChild` on the master's supervisor with a child action that runs
`runIngesterAndProcessor` (or the `Batch` variant), links the child to the calling
thread, and returns a `SupervisedProcessor` handle. Inside the child,
`runIngesterAndProcessor` creates the bounded inbox, spawns the ingester with
`UIO.withAsync`, runs `processUntilDrained` (the handler loop) in the child thread, and
checks the ingester's fate afterwards.

### NQE `processDead` semantics (quoted knowledge — do not skip)

This is the verbatim decision logic from the `nqe` library's
`Control.Concurrent.NQE.Supervisor.processDead` (the function the supervisor runs when a
child terminates; `state` is the supervisor's child list, `a` the dead child, and the
`Bool` it returns is "keep the supervisor loop running"):

```haskell
processDead state IgnoreAll (a, _) = do
  atomically . modifyTVar' state $ filter (/= a)
  return True
processDead state KillAll (a, e) = do
  atomically $ modifyTVar' state . filter $ (/= a)
  stopAll state
  case e of
    Left x -> throwIO x
    Right () -> return False
processDead state IgnoreGraceful (a, Right ()) = do
  atomically (modifyTVar' state (filter (/= a)))
  return True
processDead state IgnoreGraceful (a, Left e) = do
  atomically $ modifyTVar' state (filter (/= a))
  stopAll state
  throwIO e
```

Read carefully: `KillAll` calls `stopAll` (which `cancel`s every remaining child)
*unconditionally*, and even on a graceful `Right ()` exit it returns `False`, which ends
the supervisor loop (the loop's own `finally (stopAll state)` then runs too). So `KillAll`
means "the first child to terminate, for any reason including success, takes everything
down". `IgnoreGraceful` is the strategy that means "graceful exits are fine; a failure
kills all siblings and rethrows" — the rethrow happens *in the supervisor's own thread*,
whose `Async` nothing in Shibuya observes, so propagation to the application relies on the
per-child `link`. `IgnoreAll` never stops anything and never rethrows.

### The seven bugs, precisely

1. CRITICAL — `doneVar` never set on halt/cancel. In `runSupervised`
   (`shibuya-core/src/Shibuya/Runner/Supervised.hs`, ~lines 167–178), the child action is
   `runIngesterAndProcessor ... \`catch\` \(ProcessorHalt _) -> pure ()`. But the only
   `writeTVar doneVar True` on the halt path lives *inside* `runIngesterAndProcessor`
   *after* its body (~line 272) — when `processUntilDrained` throws `ProcessorHalt`
   (~line 504), that write is skipped, and the `catch` sits *outside* the function, so
   nothing else sets it. Consequence: after any `AckHalt`, `waitApp` blocks forever and
   `stopAppGracefully` waits out the full `drainTimeout` and returns `False`. The batch
   variant has the same hole and its own comment admits it (the comment above
   `runIngesterAndProcessorBatch`, ~lines 379–383: "The throw ... leaves 'doneVar' unset
   on halt"). Asynchronous cancellation (e.g. `stopMaster` cancelling children) also
   skips the write.
2. CRITICAL — `StopAllOnFailure` maps to `NQE.KillAll` (`toNQEStrategy`,
   `shibuya-core/src/Shibuya/App.hs` ~lines 91–94). Per the quoted `processDead`
   semantics, a *graceful* exit of one processor (finite stream drained, or halt
   converted to graceful exit) cancels all siblings and stops the supervisor.
3. MAJOR — unconditional `UIO.link supervisedChild`
   (`shibuya-core/src/Shibuya/Runner/Supervised.hs` ~lines 177–178 and again ~line 321 in
   the batch variant) throws `ExceptionInLinkedThread` into the application thread on
   *any* child failure, regardless of strategy. `IgnoreFailures` is therefore dead code:
   choosing it does not prevent one processor's failure from crashing the app.
4. MAJOR — ingester-failure poll race. In `runIngesterAndProcessor` (~lines 254–269; same
   pattern in the batch variant ~lines 401–426), the ingester sets `streamDoneVar` in a
   `finally` and the processor loop exits when the inbox is drained. The code then calls
   the *non-blocking* `UIO.poll ingesterAsync`. But `streamDoneVar` is set by the
   `finally` *before* the `Async` transitions to its terminal state, so `poll` can return
   `Nothing` even though the ingester failed — the failure is silently dropped, the child
   exits gracefully, and a broken adapter is indistinguishable from a cleanly completed
   stream (no `Failed` metrics state, no propagation).
5. MAJOR — `runWithMetrics` (~lines 191–228) runs
   `runIngesterWithMetrics ...` *to completion* against the bounded inbox *before*
   calling `drainInboxWithMetrics`. If the stream holds more messages than `inboxSize`,
   the ingester blocks on the full inbox and nobody ever drains: deterministic deadlock.
6. MINOR — `runApp` failure path (~lines 200–218 of `shibuya-core/src/Shibuya/App.hs`):
   if `spawnProcessors` throws after `startMaster` succeeded (possibly with some
   processors already spawned), the surrounding `catch` converts the exception to
   `Left ...` but never stops the master, leaking a live master loop, supervisor, and any
   already-spawned processors.
7. MINOR — `getAllMetricsIO` (and the other query-based accessors) in
   `shibuya-core/src/Shibuya/Runner/Master.hs` (~lines 164–182) send a `query` to
   `master.inbox` and wait for a reply. After `stopMaster` cancels the master loop there
   is no responder, so the call blocks forever. This bites metrics/web servers that
   outlive shutdown.

### Integration constraints (read before changing anything)

- EP-23 (`docs/plans/23-fix-finalize-on-exception-and-batch-path-reliability.md`) builds
  on the `finally`-based `doneVar` structure this plan introduces. Do not leave or add
  any child exit path that bypasses the `finally`; EP-23's exception-propagation tests
  assume it.
- EP-26 (`docs/plans/26-reduce-per-message-hot-path-overhead.md`) will later rewrite the
  metrics update sites (`processOne`, `runIngesterWithMetrics`, the `Failed`-state
  writes). Keep metrics logic where it currently lives and do not restructure it beyond
  what the fixes require.
- EP-24 may add partition-keyed dispatch inside `processUntilDrained`; that is out of
  scope here — do not touch `processUntilDrained`'s dispatch logic.


## Plan of Work

The work is four milestones. Each is a small, self-contained diff plus tests, and each is
independently verifiable with `cabal test shibuya-core-test`. Tests live under
`shibuya-core/test/Shibuya/`, mirroring the source layout; new test modules must be added
both to `shibuya-core/test/Main.hs` (import + call in `main`) and to the `other-modules`
list of the `test-suite shibuya-core-test` stanza in `shibuya-core/shibuya-core.cabal`.
Run `nix fmt` before every commit (the pre-commit hook rejects unformatted files), and use
the commit trailers shown at the top of this plan.

The existing test file `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` contains all
the helper patterns you need (building `Envelope`/`Ingested` values by hand with a no-op
`AckHandle $ \_ -> pure ()`, `testAdapter` wrapping `Stream.fromList`, `runEff $
runTracingNoop $ ...` to run `Eff` test bodies). Reuse those patterns; where a new module
needs them, copy the small helpers (`createTestMessages`, `testAdapter`, `testTime`)
rather than exporting them across test modules.

### Milestone 1 — `doneVar` is set on every child exit path

Scope: bug 1. At the end of this milestone, a processor that halts, fails, or is
cancelled still flips its `doneVar`, so `waitApp` returns and `stopAppGracefully` stops
waiting the moment processors are actually finished. This is the structural foundation
EP-23 depends on.

All edits are in `shibuya-core/src/Shibuya/Runner/Supervised.hs`.

First, remove `doneVar` from `runIngesterAndProcessor`: delete the `TVar Bool` parameter
(and the corresponding argument at both call sites), delete the trailing
`liftIO $ atomically $ writeTVar doneVar True` (~line 272), and delete the
`atomically $ writeTVar doneVar True` inside the ingester-failure branch (~line 267).
Do exactly the same for `runIngesterAndProcessorBatch` (parameter, trailing write at
~line 428, failure-branch write at ~line 424), and delete the now-false sentence in its
haddock comment claiming the halt throw "leaves 'doneVar' unset on halt, matching the
single-message parity" — replace it with a note that `doneVar` is owned by the spawn
sites (`runSupervised`/`runSupervisedBatch`/`runWithMetricsBatch`) via `finally`.

Then make ownership of `doneVar` explicit at the three spawn/run sites. In
`runSupervised`, the child action handed to `addChild` becomes (note the *outer*
`finally` is in `IO`, wrapped around `runInIO`, so it also fires if the effectful unlift
machinery itself is interrupted, and it runs during asynchronous cancellation):

```haskell
supervisedChild <- withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
  addChild master.state.supervisor $
    runInIO
      ( ( runIngesterAndProcessor metricsVar procId inboxSize concurrency adapter handler
            `catch` \(ProcessorHalt _) -> pure () -- Halt is intentional: graceful exit
        )
          `finally` unregisterProcessor master procId
      )
      `finally` atomically (writeTVar doneVar True)
```

(`finally` is already imported unqualified from `UnliftIO`; it works in both `Eff es` and
`IO` because both are `MonadUnliftIO`.) Apply the identical shape in
`runSupervisedBatch` around `runIngesterAndProcessorBatch`. In `runWithMetricsBatch`
(which runs the body synchronously, not as a child), wrap the call instead:

```haskell
runIngesterAndProcessorBatch metricsVar procId inboxSize concurrency batchConfig adapter batchHandler
  `finally` liftIO (atomically (writeTVar doneVar True))
```

`runWithMetrics` still sets `doneVar` after its (currently sequential) body; it is
restructured in Milestone 4 and gets the same `finally` shape there.

Why an IO-level `finally` and not a write inside the worker function: the worker can be
exited by `ProcessorHalt` (thrown from `processUntilDrained` after draining), by an
ingester exception rethrow, by a handler-thread exception, or by `AsyncCancelled` when
`stopMaster` cancels the supervisor's children. A `finally` wrapped around the entire
child action is the only construction that covers all four without enumerating them, and
it is the invariant EP-23 will build on (see Decision Log).

Tests: create `shibuya-core/test/Shibuya/App/LifecycleSpec.hs` exposing `spec :: Spec`,
register it in `shibuya-core/test/Main.hs` and the cabal `other-modules`. It needs local
copies of the `createTestMessages`/`testAdapter`/`testTime` helpers from
`SupervisedSpec`, plus an infinite adapter helper:

```haskell
-- | An adapter whose stream never ends (one message every 5ms).
infiniteAdapter :: (IOE :> es) => Adapter es String
infiniteAdapter =
  Adapter
    { adapterName = "test:infinite",
      source = Stream.unfoldrM step (1 :: Int),
      shutdown = pure ()
    }
  where
    step n = do
      liftIO $ threadDelay 5000
      msg <- createTestMessage n
      pure (Just (msg, n + 1))
```

Write these four tests (all fail — by hanging or asserting — against pre-M1 code; use
`UIO.timeout` so a regression fails instead of hanging the suite):

1. "waitApp returns after a handler halts": handler always returns
   `AckHalt (HaltFatal "stop")` over 10 messages; `runApp IgnoreFailures 10 [...]`, then
   `waitApp`. Wrap the whole `runEff ...` in `UIO.timeout 5_000_000` and assert the
   result is `Just ...`.
2. "stopAppGracefully returns True promptly after halt": same halting processor; sleep
   ~200ms to let the halt happen, then `stopAppGracefully (ShutdownConfig {drainTimeout = 5})`
   and assert it returns `True` (pre-M1 it burns the 5 seconds and returns `False`).
   Additionally record `getCurrentTime` before/after and assert the elapsed time is under
   2 seconds, proving the timeout was not consumed.
3. "cancellation sets done": `startMaster IgnoreAll`, `runSupervised` with
   `infiniteAdapter` and an `AckOk` handler, sleep ~50ms, `stopMaster`, then
   `readTVarIO sp.done` must be `True` (NQE's `stopAll` uses `cancel`, which blocks until
   the child finished, so no extra wait is needed after `stopMaster` returns).
4. "waitApp returns after a batch handler halts": `mkBatchProcessor` with
   `defaultBatchConfig {batchSize = 2, batchTimeout = 0.1}` and a `BatchHandler` of
   `\_info _msgs -> pure (ackAll (AckHalt (HaltFatal "stop")))` over 10 messages; same
   timeout-wrapped `waitApp` assertion as test 1.

Acceptance: `cabal test shibuya-core-test` passes with the new tests included; reverting
only the `Supervised.hs` changes makes tests 1, 2, and 4 fail by timeout/False (you can
spot-check this once with `git stash` if desired, but it is not required for completion).

Commit as:

```text
fix(runner): set doneVar via finally on all child exit paths

MasterPlan: docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
ExecPlan: docs/plans/22-fix-processor-lifecycle-and-supervision-semantics.md
```

### Milestone 2 — `StopAllOnFailure` means "on failure", not "on any exit"

Scope: bug 2. At the end of this milestone, one processor completing its finite stream
(or halting) under `StopAllOnFailure` no longer kills its siblings, while a real failure
still does.

The code edit is one line in `shibuya-core/src/Shibuya/App.hs`:

```haskell
toNQEStrategy :: SupervisionStrategy -> NQE.Strategy
toNQEStrategy = \case
  IgnoreFailures -> NQE.IgnoreAll
  StopAllOnFailure -> NQE.IgnoreGraceful
```

The justification is the quoted `processDead` semantics in Context and Orientation:
`KillAll` treats `Right ()` as a reason to `stopAll` and stop supervising;
`IgnoreGraceful` ignores `Right ()` and reserves `stopAll` + rethrow for `Left e`. Also
update the haddock on `StopAllOnFailure` to state explicitly that graceful exits
(finite stream drained, `AckHalt`) do not trigger the stop-all behavior. Note that after
this change the failure rethrow happens in the supervisor's own (unobserved) thread, so
propagation to the application thread still comes from the per-child `link` — which is
unconditional until Milestone 3, so propagation behavior for `StopAllOnFailure` is
unchanged through this milestone.

Tests: add to `shibuya-core/test/Shibuya/App/LifecycleSpec.hs` (these exercise the public
`runApp` API):

1. "graceful completion under StopAllOnFailure does not kill siblings": processor A has 3
   messages and an instant `AckOk` handler; processor B has 30 messages and a handler
   that sleeps 10ms then counts into an `IORef` before returning `AckOk`.
   `runApp StopAllOnFailure 10 [...]`, `UIO.timeout`-wrapped `waitApp`, then assert B's
   count is exactly 30. Pre-M2, A's graceful exit triggers `stopAll` and B's count comes
   up short.
2. "halt under StopAllOnFailure does not kill siblings": same shape, but A's handler
   returns `AckHalt (HaltFatal "A stops")` after 2 messages; assert B still processes all
   30 (the halt is converted to a graceful exit by `runSupervised`, which pre-M2 was
   fatal to siblings).
3. "failure under StopAllOnFailure kills siblings and propagates": A's adapter `source`
   is a `Stream.unfoldrM` that yields 3 messages then calls
   `error "Adapter A source failed!"`; B has 50 messages with a 20ms handler. Run the
   whole `runEff ... runApp StopAllOnFailure ... threadDelay ...` inside
   `UIO.withAsync ... UIO.waitCatch` (copy the shape of the existing "KillAll supervision
   strategy" test in `SupervisedSpec.hs`); assert the result is `Left` containing
   "Adapter A source failed" and that B's count is < 50.

Acceptance: all three pass; test 1 and 2 fail against pre-M2 code.

Commit as `fix(app): map StopAllOnFailure to NQE IgnoreGraceful` with the standard
trailers.

### Milestone 3 — linking is strategy-aware; `IgnoreFailures` actually isolates

Scope: bug 3. At the end of this milestone, a processor failure under `IgnoreFailures`
is recorded in that processor's metrics (`Failed` state) and its `doneVar`, while the
application thread and sibling processors are untouched. Under `StopAllOnFailure`
behavior is as in Milestone 2 (propagation via link preserved).

Edit 1 — `shibuya-core/src/Shibuya/Runner/Master.hs`: add a field to `MasterState`:

```haskell
data MasterState = MasterState
  { metrics :: !(TVar (Map ProcessorId (TVar ProcessorMetrics))),
    supervisor :: !Supervisor,
    -- | Whether child failures should be linked into the spawning thread.
    -- Derived from the supervision strategy: True for KillAll/IgnoreGraceful
    -- (failure must reach the application), False for IgnoreAll/Notify.
    propagateFailures :: !Bool
  }
  deriving (Generic)
```

and derive it in `startMaster` from the NQE strategy it already receives:

```haskell
let propagate = case strategy of
      KillAll -> True
      IgnoreGraceful -> True
      IgnoreAll -> False
      Notify _ -> False
```

passing it into the `MasterState` constructor. (`Strategy`'s constructors are imported
already via `Control.Concurrent.NQE.Supervisor (Strategy (..), Supervisor)`.)

Edit 2 — `shibuya-core/src/Shibuya/Runner/Supervised.hs`: in both `runSupervised` and
`runSupervisedBatch`, replace the unconditional link:

```haskell
-- before
unsafeEff_ $ UIO.link supervisedChild

-- after
when master.state.propagateFailures $
  unsafeEff_ $
    UIO.link supervisedChild
```

(add `when` to the existing `import Control.Monad (unless)`). Rationale for keeping
`link` as the propagation mechanism rather than catching-and-routing is in the Decision
Log: under `IgnoreGraceful` the supervisor rethrows into its own unobserved `Async`, so
the per-child link is the only path to the application thread, and `link` ignores
`AsyncCancelled` so shutdown cancellation cannot crash the app.

Edit 3 — update the two existing test groups in
`shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` whose expectations encode the old
unconditional-link behavior:

- "Adapter source exceptions" ("drains already-ingested messages, marks Failed, and
  propagates the ingester exception", ~line 520): it uses `startMaster IgnoreAll` yet
  expects the exception in the app thread. Split it in two. (a) Keep the propagation
  variant but run it with `startMaster IgnoreGraceful` (title: "...propagates the
  ingester exception under IgnoreGraceful"), keeping all existing assertions including
  `done == True` and `Failed` metrics. (b) Add an `IgnoreAll` variant asserting the
  *absence* of propagation: the `runEff` block completes normally (`Right ()` from
  `waitCatch`), the 3 good messages were processed, `sp.done` is `True`, and metrics
  state is `Failed` with the error text.
- "KillAll supervision strategy" (~line 626): rename the group to "IgnoreGraceful
  supervision strategy (StopAllOnFailure)" and change `startMaster KillAll` to
  `startMaster IgnoreGraceful`. Assertions stay the same (failure propagates, sibling B
  killed before finishing 20 messages).

Edit 4 — add one end-to-end test to `LifecycleSpec.hs`: "IgnoreFailures isolates a
failing processor": A's source throws after 3 messages; B has 20 messages with a 10ms
handler. `runApp IgnoreFailures 10 [...]`, `UIO.timeout`-wrapped `waitApp` (works because
M1's `finally` sets A's `doneVar` even on failure), then assert: no exception escaped
(the block ran to completion), B's count is exactly 20, and A's metrics (via
`getAppMetrics` or the `SupervisedProcessor` handle in `appHandle.processors`) show a
`Failed` state containing the error text. Pre-M3, the linked `ExceptionInLinkedThread`
crashes the `runEff` thread and the test fails.

Acceptance: full suite green; the new `IgnoreFailures` test fails against pre-M3 code.

Commit as `fix(runner): link supervised children only when the strategy propagates
failures` with the standard trailers.

### Milestone 4 — ingester failure detection, `runWithMetrics` drain, teardown, and non-blocking master queries

Scope: bugs 4, 5, 6, 7. Four small independent fixes grouped because each is a short diff
with a focused test.

Fix 4a — poll race (`shibuya-core/src/Shibuya/Runner/Supervised.hs`). In
`runIngesterAndProcessor`, replace the non-blocking check:

```haskell
-- before
UIO.poll ingesterAsync >>= \case
  Just (Left ingesterErr) -> do
    ...

-- after
UIO.waitCatch ingesterAsync >>= \case
  Left ingesterErr -> do
    now <- getCurrentTime
    atomically $
      modifyTVar' metricsVar $ \m ->
        m & #state .~ Failed (Text.pack (displayException ingesterErr)) now
    UIO.throwIO ingesterErr
  Right () -> pure ()
```

This is safe because the check only runs after `processUntilDrained` returned *normally*,
which requires `streamDoneVar` to be `True` and the inbox empty — and `streamDoneVar` is
set in the ingester's `finally`, so at that point the ingester's body has finished and its
`Async` is guaranteed to reach a terminal state; `waitCatch` blocks only for the tiny
window between the `finally` firing and the `Async` transitioning, and never blocks
indefinitely. (On the `ProcessorHalt` path the check is not reached and `withAsync`
cancels the possibly-still-running ingester, as before.) Make the identical replacement in
`runIngesterAndProcessorBatch`. Remember the `doneVar` writes in these branches were
already removed in Milestone 1.

Test 4a, in `SupervisedSpec.hs` under "Adapter source exceptions": "never drops an
ingester failure (repeated)". The race window is timing-dependent, so run the scenario 25
times: each iteration builds a source that throws immediately
(`Stream.unfoldrM (\_ -> error "boom immediately") ()`), runs
`startMaster IgnoreAll` + `runSupervised ... Serial ...`, waits for `sp.done` to become
`True` (STM `check` under `UIO.timeout 2_000_000`), reads `sp.metrics`, then `stopMaster`.
Assert every one of the 25 iterations ends in `Failed` state mentioning "boom
immediately". Against pre-4a code, iterations where `poll` loses the race end in
`Idle`/non-`Failed` state and the test fails.

Fix 4b — `runWithMetrics` concurrent drain
(`shibuya-core/src/Shibuya/Runner/Supervised.hs`). Replace the body of `runWithMetrics`
so the ingester and the handler loop run concurrently, by delegating to the (post-M1)
`runIngesterAndProcessor` with `Serial` concurrency, keeping the `finally`-based
`doneVar` write:

```haskell
runWithMetrics inboxSize procId adapter handler = do
  now <- liftIO getCurrentTime
  metricsVar <- liftIO $ newTVarIO (emptyProcessorMetrics now)
  doneVar <- liftIO $ newTVarIO False
  runIngesterAndProcessor metricsVar procId inboxSize Serial adapter handler
    `finally` liftIO (atomically (writeTVar doneVar True))
  pure
    SupervisedProcessor
      { metrics = metricsVar,
        processorId = procId,
        done = doneVar,
        child = Nothing
      }
```

Behavior is preserved for the existing tests: `processUntilDrained` (via `processOne`)
counts failures the same way `drainInboxWithMetrics` did, ends in `Idle` after success,
and throws `ProcessorHalt` after a halting message exactly like the old drain loop, so
the "stops processing when handler returns AckHalt" test still sees 3 processed messages.
Then delete `drainInboxWithMetrics` entirely (its only caller was `runWithMetrics`) and
prune imports that become unused (`receive`, `mailboxEmpty` from
`Control.Concurrent.NQE.Process`, `unless` if nothing else uses it). Update the haddock
on `runWithMetrics` to document `Serial` processing.

Test 4b, in `SupervisedSpec.hs` under "runWithMetrics": "completes when the stream is
longer than the inbox": 100 messages, `runWithMetrics 5 ...` (inbox size 5), counting
handler; wrap the whole `runEff` in `UIO.timeout 10_000_000`, assert `Just`, processed
count 100, and final metrics `received == 100`, `processed == 100`. Pre-4b this
deadlocks (the timeout turns the hang into a failure).

Fix 4c — `runApp` teardown on spawn failure (`shibuya-core/src/Shibuya/App.hs`).
Restructure the `Right ()` branch so a failure *after* `startMaster` stops the master
(cancelling the supervisor and therefore any already-spawned children) before returning
`Left`:

```haskell
Right () -> do
  let nqeStrategy = toNQEStrategy strategy
  catch
    ( do
        master <- startMaster nqeStrategy
        spawnResult <- try (spawnProcessors master (fromIntegral inboxSize) namedProcessors)
        case spawnResult of
          Left (e :: SomeException) -> do
            stopMaster master
            pure $ Left $ AppRuntimeError $ SupervisorFailed $ Text.pack $ displayException e
          Right processors ->
            pure $
              Right
                AppHandle
                  { master = master,
                    processors = Map.fromList processors
                  }
    )
    ( \(e :: SomeException) ->
        pure $ Left $ AppRuntimeError $ SupervisorFailed $ Text.pack $ displayException e
    )
```

(`try` comes from `UnliftIO`, alongside the already-imported `catch`.) The outer `catch`
now only guards `startMaster` itself (nothing to tear down if that throws). This fix is
defensive: with the current code, `spawnProcessors` can only throw on internal failures
(effectful unlift errors, async exceptions, a dead master inbox), none of which can be
triggered deterministically through the public API, so there is **no direct regression
test**; correctness is established by inspection (`stopMaster` is idempotent-enough for
this path: it just `cancel`s two `Async`es) and by the full suite staying green. State
this in the Surprises section if anything unexpected turns up.

Fix 4d — non-blocking master introspection
(`shibuya-core/src/Shibuya/Runner/Master.hs`). Rewrite the six inbox-query functions as
direct STM operations on `master.state.metrics` (semantics identical to what the message
loop did, per the Decision Log):

```haskell
getAllMetricsIO :: Master -> IO MetricsMap
getAllMetricsIO master = atomically $ do
  tvarsMap <- readTVar master.state.metrics
  traverse readTVar tvarsMap

getAllMetrics :: (IOE :> es) => Master -> Eff es MetricsMap
getAllMetrics = liftIO . getAllMetricsIO

getProcessorMetricsIO :: Master -> ProcessorId -> IO (Maybe ProcessorMetrics)
getProcessorMetricsIO master pid = atomically $ do
  tvarsMap <- readTVar master.state.metrics
  traverse readTVar (Map.lookup pid tvarsMap)

getProcessorMetrics :: (IOE :> es) => Master -> ProcessorId -> Eff es (Maybe ProcessorMetrics)
getProcessorMetrics master = liftIO . getProcessorMetricsIO master

registerProcessor :: (IOE :> es) => Master -> ProcessorId -> TVar ProcessorMetrics -> Eff es ()
registerProcessor master pid metricsTVar =
  liftIO $ atomically $ modifyTVar' master.state.metrics $ Map.insert pid metricsTVar

unregisterProcessor :: (IOE :> es) => Master -> ProcessorId -> Eff es ()
unregisterProcessor master pid =
  liftIO $ atomically $ modifyTVar' master.state.metrics $ Map.delete pid
```

Keep `MasterMessage`, `masterLoop`, and `handleMessage` unchanged (they are exported API
and still answer queries for any external sender); only the internal call sites stop
using the loop. Prune the now-unused `query` import if nothing else references it. A side
benefit worth a code comment: `unregisterProcessor` runs in each child's `finally` during
shutdown, and as a direct TVar operation it can no longer block on a dead master inbox.

Test 4d, in `SupervisedSpec.hs` under the existing "Shibuya.Runner.Master" describe
block: "metrics queries return after stopMaster": `startMaster IgnoreAll`, `stopMaster`,
then in plain `IO`: `UIO.timeout 1_000_000 (getAllMetricsIO master)` must return
`Just` an empty map, and `UIO.timeout 1_000_000 (getProcessorMetricsIO master (ProcessorId "x"))`
must return `Just Nothing`. Pre-4d both time out (`Nothing`).

Acceptance for the milestone: full suite green including the three new tests; the
poll-race test and metrics-after-stop test fail against pre-M4 code, the
longer-than-inbox test hangs (fails via timeout) against pre-M4 code.

Commit as `fix(runner): fix ingester failure race, runWithMetrics drain deadlock, runApp
teardown, and dead-inbox metrics queries` (or as up to four separate conventional
commits, one per fix, if you prefer smaller diffs), each with the standard trailers.
Finally, tick the four EP-22 checkboxes in the master plan's Progress section and commit
that as `docs(masterplan): mark EP-22 complete` with the same trailers.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` (a Nix devshell provides `cabal`,
`ghc`, and `nix fmt`).

Build and test before starting, to confirm a green baseline:

```bash
cabal build all
cabal test shibuya-core-test
```

Expected tail of the test output (counts will differ as tests are added; the line that
matters is the final PASS):

```text
Finished in ... seconds
... examples, 0 failures
Test suite shibuya-core-test: PASS
```

Then, for each milestone in order (M1 → M2 → M3 → M4):

1. Make the source edits described in Plan of Work for that milestone.
2. Add/adjust the tests described for that milestone. For Milestone 1 this includes
   creating `shibuya-core/test/Shibuya/App/LifecycleSpec.hs`, adding
   `import Shibuya.App.LifecycleSpec qualified` and a `Shibuya.App.LifecycleSpec.spec`
   call to `shibuya-core/test/Main.hs`, and adding `Shibuya.App.LifecycleSpec` to
   `other-modules` in `shibuya-core/shibuya-core.cabal`.
3. Rebuild and run the suite:

   ```bash
   cabal build all
   cabal test shibuya-core-test
   ```

   Interpret results: `Test suite shibuya-core-test: PASS` means the milestone's
   acceptance holds; a `FAIL` prints the failing example names — the timeout-wrapped
   tests report assertion failures such as `expected: Just () but got: Nothing` when a
   lifecycle hang regressed.
4. Format and commit with the required trailers:

   ```bash
   nix fmt
   git add -A
   git commit -m "$(cat <<'EOF'
   fix(runner): <milestone summary line>

   <body explaining the bug and the fix>

   MasterPlan: docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
   ExecPlan: docs/plans/22-fix-processor-lifecycle-and-supervision-semantics.md
   EOF
   )"
   ```

   If the pre-commit hook rejects the commit for formatting, it auto-formats; re-run
   `git add -A` and commit again.
5. Update the Progress section of this plan (and, after M4, the master plan's EP-22
   checkboxes) and include those doc updates in the commit.

The test suite exercises real concurrency (`-threaded -with-rtsopts=-N`); if a
timing-sensitive test flakes, prefer widening its `UIO.timeout`/`threadDelay` margins
over weakening its assertion, and record the flake in Surprises & Discoveries.


## Validation and Acceptance

The change is accepted when all of the following observable behaviors hold, each backed
by a named test that runs in `cabal test shibuya-core-test`:

1. With a processor whose handler returns `AckHalt`, `waitApp` returns within the test
   timeout (LifecycleSpec "waitApp returns after a handler halts", and the batch variant)
   and `stopAppGracefully (ShutdownConfig {drainTimeout = 5})` returns `True` in well
   under 2 seconds (LifecycleSpec "stopAppGracefully returns True promptly after halt").
   Before this plan, the first blocks forever and the second returns `False` after the
   full 5 seconds.
2. After `stopMaster` cancels a processor mid-stream, its `done` TVar reads `True`
   (LifecycleSpec "cancellation sets done").
3. Under `runApp StopAllOnFailure`, a sibling processes its full message count even when
   another processor finishes first or halts (LifecycleSpec, two tests), while an adapter
   failure still cancels siblings and surfaces as an exception containing the adapter's
   error text (LifecycleSpec "failure under StopAllOnFailure ...").
4. Under `runApp IgnoreFailures`, an adapter failure leaves the application thread alive,
   the sibling completes all messages, and the failed processor's metrics show `Failed`
   with the error text (LifecycleSpec "IgnoreFailures isolates a failing processor").
5. A source that throws immediately produces a `Failed` metrics state on every one of 25
   repeated runs (SupervisedSpec "never drops an ingester failure (repeated)") — no run
   may look like a clean completion.
6. `runWithMetrics 5` over 100 messages completes with `received == 100` and
   `processed == 100` inside a 10-second timeout (SupervisedSpec "completes when the
   stream is longer than the inbox"). Before this plan it deadlocks.
7. `getAllMetricsIO` and `getProcessorMetricsIO` return within 1 second after
   `stopMaster` (SupervisedSpec "metrics queries return after stopMaster"). Before this
   plan both block forever.
8. Every pre-existing test still passes, with the two documented rewrites
   ("Adapter source exceptions" split into IgnoreGraceful/IgnoreAll variants; "KillAll
   supervision strategy" renamed to IgnoreGraceful) reflecting the corrected semantics.

Final check before declaring completion:

```bash
cabal build all
cabal test shibuya-core-test
nix flake check
```

all succeeding, plus commits carrying the required trailers (verify with
`git log --format='%B' -n 6 | grep -c 'ExecPlan: docs/plans/22-'` returning the number of
EP-22 commits made).


## Idempotence and Recovery

Every step is an ordinary source edit plus a test run; all are safe to repeat. Milestones
are ordered by dependency (M1's `finally` structure is assumed by M3's and M4's tests;
M2's strategy change is assumed by M3's test rewrites) but each milestone leaves the tree
compiling and the suite green, so you can stop and commit after any milestone. If a
milestone goes wrong, `git checkout -- shibuya-core` restores the last committed state;
nothing in this plan touches databases, generated files, or anything outside
`shibuya-core/` and the two plan documents. If a test added here proves flaky under load
(these are timing-based concurrency tests), widen its timeout rather than deleting it,
and note the adjustment in Surprises & Discoveries. Re-running `cabal test`, `nix fmt`,
or any listed command multiple times is harmless.


## Interfaces and Dependencies

No new dependencies are added; the work uses libraries already in
`shibuya-core/shibuya-core.cabal`: `effectful` (the `Eff es` monad and
`withEffToIO`/`ConcUnlift` unlifting), `nqe` (supervisor, `addChild`, bounded inboxes;
strategy semantics quoted in Context and Orientation), `unliftio` (`finally`, `catch`,
`try`, `link`, `waitCatch`, `withAsync`, `timeout`), `stm` (`TVar`, `atomically`,
`check`), `streamly-core` (adapter streams), and `hspec` for tests. Dependency sources
can be located with `mori registry list` / `mori registry show <project> --full` if
deeper inspection is needed, but this plan embeds all required NQE knowledge.

Signatures that must hold at the end of the plan (all in `shibuya-core/src/`):

- `Shibuya.Runner.Supervised.runSupervised :: (IOE :> es, Tracing :> es) => Master -> Natural -> ProcessorId -> Concurrency -> Adapter es msg -> Handler es msg -> Eff es SupervisedProcessor` — unchanged public signature; child body wrapped in `finally` setting `done`; `link` conditional on `master.state.propagateFailures`.
- `Shibuya.Runner.Supervised.runSupervisedBatch` — same treatment, unchanged signature.
- `Shibuya.Runner.Supervised.runIngesterAndProcessor :: (IOE :> es, Tracing :> es) => TVar ProcessorMetrics -> ProcessorId -> Natural -> Concurrency -> Adapter es msg -> Handler es msg -> Eff es ()` — the `TVar Bool` (`doneVar`) parameter is gone; uses `UIO.waitCatch` for the ingester result. Likewise `runIngesterAndProcessorBatch` loses its `TVar Bool` parameter. Both are internal (not exported), so this breaks no downstream code.
- `Shibuya.Runner.Supervised.runWithMetrics :: (IOE :> es, Tracing :> es) => Natural -> ProcessorId -> Adapter es msg -> Handler es msg -> Eff es SupervisedProcessor` — unchanged signature, now drains concurrently (Serial); `drainInboxWithMetrics` is deleted.
- `Shibuya.App.toNQEStrategy :: SupervisionStrategy -> NQE.Strategy` — `StopAllOnFailure ↦ NQE.IgnoreGraceful`.
- `Shibuya.Runner.Master.MasterState` — gains `propagateFailures :: !Bool`. This is a record extension of an exported type; the only construction site is `startMaster`, so downstream breakage is limited to anyone pattern-matching `MasterState` exhaustively (none in this repo outside `Master.hs`).
- `Shibuya.Runner.Master.getAllMetrics`, `getAllMetricsIO`, `getProcessorMetrics`, `getProcessorMetricsIO`, `registerProcessor`, `unregisterProcessor` — unchanged signatures, reimplemented as direct STM on `master.state.metrics`; guaranteed non-blocking after `stopMaster`.
- `Shibuya.App.runApp` — unchanged signature; on a spawn failure after `startMaster`, calls `stopMaster` before returning `Left (AppRuntimeError (SupervisorFailed ...))`.

New test module: `shibuya-core/test/Shibuya/App/LifecycleSpec.hs` exporting
`spec :: Test.Hspec.Spec`, wired into `shibuya-core/test/Main.hs` and the
`other-modules` of the `shibuya-core-test` stanza in `shibuya-core/shibuya-core.cabal`.
