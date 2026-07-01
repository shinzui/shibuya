---
id: 19
slug: batch-runner-and-app-integration
title: "Batch Runner and App Integration"
kind: exec-plan
created_at: 2026-07-01T15:34:32Z
intention: "intention_01kwf4q2bke2js9t0js53dwh5a"
master_plan: "docs/masterplans/3-first-class-batch-processing.md"
---

# Batch Runner and App Integration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the third runtime child of the MasterPlan at
`docs/masterplans/3-first-class-batch-processing.md` ("First-Class Batch Processing"). It is
the plan that makes batching **user-visible end to end**: after it lands, a Shibuya user can
call the public `runApp` function with a batching processor and watch a stream of messages be
grouped into batches, handed to a batch handler, and acknowledged through one resolved
decision plus confirmed finalization in the normal path — including partial batches flushed
at graceful shutdown.


## Purpose / Big Picture

Shibuya is a Haskell queue-processing framework. Today its public entry point,
`runApp` (in `shibuya-core/src/Shibuya/App.hs`), accepts a list of **queue processors**. A
queue processor is a value of the existential type `QueueProcessor es`, built with
`mkProcessor adapter handler`, that pairs a queue **adapter** (a stream source plus a
shutdown action) with a per-message **handler** (`Ingested es msg -> Eff es AckDecision`).
The framework pulls one message at a time from a bounded inbox, runs the handler, and
finalizes exactly one acknowledgement per message. There is no way to process messages in
groups.

Three prior plans in this initiative add the machinery for group processing but stop short of
exposing it. `docs/plans/16-batch-api-and-configuration-types.md` (EP-16) adds the public
`Shibuya.Batch` module — the batch handler type, batch configuration, grouping key, and the
`BatchAck` result that encodes one acknowledgement decision per retained message.
`docs/plans/17-batch-accumulation-engine.md` (EP-17) adds an internal engine that turns the
inbox stream into a stream of **ready batches** (size-, timeout-, or shutdown-triggered).
`docs/plans/18-batch-execution-and-exactly-once-ack.md` (EP-18) adds the stage that runs the
batch handler over each ready batch, finalizes messages with bounded retry/fail-loud
behavior, and preserves FIFO execution within each `BatchKey`.
None of these three is reachable from `runApp`: there is no batching constructor on
`QueueProcessor`, and the supervised runner only knows how to run the single-message path.

This plan closes that gap. After it, a user writes:

```haskell
let processor = mkBatchProcessor ordersAdapter ordersBatchHandler defaultBatchConfig
result <- runApp IgnoreFailures 1000 [(ProcessorId "orders", processor)]
```

and the framework accumulates messages into batches, runs `ordersBatchHandler` once per
batch, resolves and successfully finalizes every retained message in the normal path, and —
crucially — flushes any pending partial batch when the app is stopped with
`stopApp`/`stopAppGracefully`. The user can observe this by running the new test module (which
asserts that all N input messages receive one acknowledgement decision and one successful
finalization, and that the handler saw them arrive in batches) and by running the example app.
Nothing about the existing single-message path changes; batching is purely additive.

You can see this working by running `cabal test shibuya-core-test` and observing the new
`Shibuya.App.Batch` example group pass, in particular the assertions that a bad batch
configuration is rejected by `runApp` with a new `AppBatchConfigError` value, that every input
message receives one decision and one successful finalization, and that a partial batch is
flushed and acknowledged when the processor is stopped.


## Progress

Milestone 1 — types + validation:

- [x] Add the `BatchingProcessor` constructor to `QueueProcessor es` in `shibuya-core/src/Shibuya/App.hs`. (2026-07-01)
- [x] Add the `mkBatchProcessor` smart constructor (defaults `Unordered` + `Serial`). (2026-07-01)
- [x] Add the `AppBatchConfigError !BatchConfigError` constructor to `AppError`. (2026-07-01)
- [x] Import `Shibuya.Batch` unqualified into `Shibuya.App` and re-export it (`module Shibuya.Batch` in the export list); export `mkBatchProcessor` (the `QueueProcessor (..)` export already covers `BatchingProcessor`). (2026-07-01)
- [x] Change `validateAllPolicies` to return `Either AppError ()` and validate both `validatePolicy` and `validateBatchConfig` for a `BatchingProcessor`; update `runApp` to propagate its `Left` unchanged. (2026-07-01)
- [x] Convert the positional pattern-matches in `validateOne`, `spawnOne`, and `shutdownAdapter` to two-branch `case` expressions using field puns. (2026-07-01)
- [x] `cabal build shibuya-core` green; add the M1 unit test (bad batch config rejected with `AppBatchConfigError`) and `cabal test shibuya-core-test` green. (2026-07-01)

Milestone 2 — runner wired + dispatch:

- [x] Add `runIngesterAndProcessorBatch`, `runSupervisedBatch`, and `runWithMetricsBatch` to `shibuya-core/src/Shibuya/Runner/Supervised.hs`; export `runSupervisedBatch` and `runWithMetricsBatch`. (2026-07-01)
- [x] Update `spawnOne` in `App.hs` to dispatch `QueueProcessor{}` to `runSupervised` and `BatchingProcessor{}` to `runSupervisedBatch`. (2026-07-01)
- [x] Add the M2 end-to-end test (N messages through `runApp` with a `BatchingProcessor`, all acked exactly once, seen in batches) and confirm green. (2026-07-01)

Milestone 3 — graceful shutdown flush:

- [x] Add the M3 test: feed fewer than `batchSize` through a gated adapter, `stopApp`, assert the partial batch was flushed (`TriggerFlush`) and every message acked exactly once. (2026-07-01)
- [x] Confirm `SupervisedProcessor.done` is set only after the batch pipeline (including flush) completes, so `waitForDrainWithTimeout` waits for the flush. (2026-07-01)
- [x] `nix fmt` clean across all edited files. (2026-07-01)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Confirmed the "DEPENDENCY TO CONFIRM" seam: EP-18's `processBatchesUntilDrained` only *sets*
  `haltRef` and returns normally — it does **not** throw `ProcessorHalt` (only EP-18's
  `runBatchesWithMetrics` throws). So `runIngesterAndProcessorBatch` reads `haltRef` right
  after `processBatchesUntilDrained` returns and throws `ProcessorHalt` itself, inside the same
  `runInIO` block and before the ingester `poll` — mirroring the single-message
  `processUntilDrained` throw and preserving the parity that a halt leaves `doneVar` unset. This
  is the second contingency the plan's Context/Idempotence sections anticipated.

- Adding the `BatchingProcessor` constructor made two *pre-existing* `RunnerSpec` let-patterns
  (`QueueProcessor _ _ ordering _ = mkProcessor ...` at lines ~181/188) non-exhaustive, which
  `-Wincomplete-uni-patterns` flags under the `-Wall` test stanza. The plan predicted these
  "still compile unchanged" (true — they compile) but did not anticipate the warning. Rewrote
  both as total `case` expressions over both constructors (`QueueProcessor {ordering = o} -> o;
  BatchingProcessor {ordering = o} -> o`). Also dropped a now-unused `ProcessorState` import
  from `BatchProcessorSpec` (EP-18) that only surfaced once `Shibuya.Core` was recompiled.

- The plain streamly `Stream` type has **no** `Semigroup` instance, so the plan's sketched
  `Stream.fromList messages <> Stream.concatEffect (...)` for the M3 gated adapter does not
  compile ("Could not deduce Semigroup (Stream (Eff es) ...)"). Rewrote the gated adapter as a
  single `Stream.unfoldrM` state machine that yields each message and, once the list is
  exhausted, blocks on the gate (`readTVar gate >>= check`) before ending — same behavior, no
  stream append needed. `Adapter.source` is `Stream (Eff es) (Ingested es msg)`, so the gate
  wait runs in `Eff es`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add a **second GADT constructor** `BatchingProcessor` to the existing
  `QueueProcessor es`, rather than adding optional batch fields to the single `QueueProcessor`
  constructor.
  Rationale: A processor is either single-message or batch — never both, and the two carry
  different handler types (`Handler es msg` vs `BatchHandler es msg`) and, for batching, an
  extra `BatchConfig es msg`. A two-constructor GADT makes the dispatch total and obvious: the
  runner pattern-matches the constructor and calls `runSupervised` or `runSupervisedBatch`.
  The optional-field alternative (one constructor with `Maybe (BatchHandler …, BatchConfig …)`)
  would force a partial `fromJust`-style dispatch and let nonsensical values exist (a
  single-message handler *and* a batch config at once), which is exactly the kind of ambiguity
  the reliability effort is trying to avoid. `DuplicateRecordFields` (on by default) lets both
  constructors reuse the field names `adapter`, `ordering`, and `concurrency`, so the two
  constructors read almost identically.
  Date: 2026-07-01

- Decision: Use **field puns** (the `NamedFieldPuns` extension) to bind constructor fields in
  the updated pattern matches, not `RecordWildCards` (`{..}`).
  Rationale: `NamedFieldPuns` is part of the `GHC2021`/`GHC2024` language edition (the library
  and test suite both use `default-language: GHC2024`), so `QueueProcessor{ordering, concurrency}`
  compiles with **no** change to the cabal `default-extensions`. `RecordWildCards` is **not**
  in `GHC2024` and would have to be added to `default-extensions`; it also silently pulls every
  field into scope, which is noisier and clashes more easily under `DuplicateRecordFields`.
  Puns are the minimal, explicit choice.
  Date: 2026-07-01

- Decision: A `BatchingProcessor` is validated by **both** `validatePolicy ordering concurrency`
  **and** `validateBatchConfig batchConfig`, and any batch-config failure surfaces as a new
  top-level `AppError` constructor `AppBatchConfigError !BatchConfigError`.
  Rationale: `BatchConfigError` is defined in `Shibuya.Batch` (EP-16) precisely so this plan can
  wrap it into `AppError` at validation time (EP-16 Decision Log). `runApp` already returns
  `Either AppError (AppHandle es)`, so wrapping the batch error keeps a single error channel for
  the caller. `AppError` derives `Eq`/`Show` and `BatchConfigError` derives `stock (Eq, Show,
  Generic)`, so the new constructor derives cleanly with no orphan instances.
  Date: 2026-07-01

- Decision: **`StrictInOrder` + batching is permitted only with `Serial` batch execution**,
  enforced by reusing the existing `validatePolicy` unchanged.
  Rationale: `validatePolicy` already encodes the single-message invariant "`StrictInOrder`
  requires `Serial`" (it rejects `StrictInOrder` with `Ahead`/`Async`). Reusing it for batching
  gives the identical rule for free: with `Serial`, batches run one at a time in emission order,
  which preserves strict ordering across batches; `Ahead n`/`Async n` would run batches
  concurrently and break it. There is no separate batch ordering knob, so no new validation rule
  is needed — this plan simply calls `validatePolicy` for the `BatchingProcessor`'s ordering and
  concurrency exactly as it does for a `QueueProcessor`. `Serial` is also the default that
  `mkBatchProcessor` chooses (see next decision).
  Date: 2026-07-01

- Decision: `mkBatchProcessor` defaults to `Unordered` ordering and `Serial` concurrency ("one
  batch at a time").
  Rationale: `Serial` batch execution is the safest default: exactly one batch is in flight at a
  time, so batch handlers never contend and back-pressure is simplest to reason about. This
  mirrors `mkProcessor`, which defaults to `Unordered` + `Serial` for single messages. Users who
  want concurrent batches opt in with the full `BatchingProcessor{…}` record and `Ahead n` /
  `Async n`.
  Date: 2026-07-01

- Decision: The operator guidance is that **`drainTimeout` must be set comfortably larger than
  `batchTimeout`** (and larger than the batch handler's worst-case runtime).
  Rationale: On graceful shutdown the pending partial batch is flushed and the batch handler
  runs during the drain window; if `drainTimeout` were smaller than the time needed to flush and
  process, `waitForDrainWithTimeout` would force-stop the processor mid-flush, leaving those
  messages **un-finalized** (they redeliver later — no data loss, but wasted work and duplicate
  delivery). The default `drainTimeout` is 30s and the default `batchTimeout` is 1s, so the
  default configuration already satisfies this comfortably; the guidance matters only when an
  operator raises `batchTimeout`.
  Date: 2026-07-01

- Decision: `Shibuya.App` re-exports the whole `Shibuya.Batch` module (`module Shibuya.Batch`
  in the export list) rather than hand-listing each batch name.
  Rationale: Users writing a batching processor need `BatchConfig`, `defaultBatchConfig`,
  `BatchHandler`, `BatchAck`, and the `ackAll*`/`failMessages` smart constructors together with
  `mkBatchProcessor`; re-exporting the module keeps the import surface to a single
  `import Shibuya.App`. There are no name clashes because `Shibuya.App` does not itself export
  any of `Shibuya.Batch`'s names.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Completed 2026-07-01. Batching is now user-visible end to end through `runApp`. `Shibuya.App`
gained the `BatchingProcessor` GADT constructor, the `mkBatchProcessor` smart constructor
(defaulting `Unordered` + `Serial`), the `AppBatchConfigError` error constructor, and a whole-
module re-export of `Shibuya.Batch`. `validateAllPolicies` now returns `Either AppError ()` and
validates both policy and batch config; `spawnOne` and `shutdownAdapter` dispatch on the
constructor via field puns. `Shibuya.Runner.Supervised` gained `runSupervisedBatch`,
`runWithMetricsBatch`, and the shared `runIngesterAndProcessorBatch`, which wire EP-17's
`runBatcher` between `inboxToStream` and EP-18's `processBatchesUntilDrained` and add the
`haltRef` check-and-throw.

All three milestones are proven by `Shibuya.App.Batch` (150 examples total, 0 failures, no
warnings): M1 rejects `batchSize = 0` with `AppBatchConfigError`; M2 groups 10 messages into
batches summing to 10 with each id acked exactly once; M3 holds 3 messages below `batchSize`
behind a gated adapter and shows they are flushed (`TriggerFlush`) and acked exactly once only
when `stopApp` ends the source — proving graceful-shutdown flush works through the reused
`waitForDrainWithTimeout`/`done` machinery. The single-message path is untouched and all its
existing tests still pass.

No signature drift from the frozen MasterPlan interfaces. The three surprises above (the
halt-throw seam, the pre-existing-spec warnings, and the missing `Stream` `Semigroup`) were all
mechanical and are recorded. The public API (`BatchingProcessor`, `mkBatchProcessor`,
`AppBatchConfigError`, the re-exported `Shibuya.Batch`) is now stable for EP-20 (tests) and
EP-21 (docs + example) to build against.


## Context and Orientation

This section assumes no prior knowledge of the repository. Everything you need to make the
changes is here; where a type comes from a sibling plan that is not yet merged, its exact
signature is embedded below and the dependency is flagged.

Shibuya is a Cabal project rooted at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.
The library package is `shibuya-core`, with sources under `shibuya-core/src/Shibuya/`, tests
under `shibuya-core/test/`, and the cabal file `shibuya-core/shibuya-core.cabal`. The default
language is `GHC2024` and these extensions are on by default for both library and test suite:
`DeriveAnyClass`, `DerivingStrategies`, `DuplicateRecordFields`, `LambdaCase`,
`NoFieldSelectors`, `OverloadedLabels`, `OverloadedRecordDot`, `OverloadedStrings`,
`QuasiQuotes`. Because `NoFieldSelectors` is on there are **no** top-level field accessor
functions; you read a field with dot syntax (`value.field`, from `OverloadedRecordDot`).
Because `DerivingStrategies` is on, every `deriving` clause must name its strategy
(`stock`/`newtype`/`anyclass`). Because `DuplicateRecordFields` is on, two constructors may
reuse the same field name. **`NamedFieldPuns` (field puns like `Con{field}`) is part of
`GHC2024`, so it needs no extension.** `RecordWildCards` (`Con{..}`) is **not** part of
`GHC2024`.

Build, test, and format commands (run from the repository root):

```bash
cabal build shibuya-core
cabal test shibuya-core-test
nix fmt
```

Definitions of terms used throughout this plan:

- **Adapter**: `data Adapter es msg = Adapter { adapterName :: !Text, source :: Stream (Eff es)
  (Ingested es msg), shutdown :: Eff es () }` in `shibuya-core/src/Shibuya/Adapter.hs`. `source`
  is a Streamly stream of ingested messages; `shutdown` is an action that ends `source`.
- **Ingested**: `data Ingested es msg = Ingested { envelope :: !(Envelope msg), ack ::
  !(AckHandle es), lease :: !(Maybe (Lease es)) }` in `shibuya-core/src/Shibuya/Core/Ingested.hs`.
  Each carries its own acknowledgement handle.
- **AckHandle**: `newtype AckHandle es = AckHandle { finalize :: AckDecision -> Eff es () }` in
  `shibuya-core/src/Shibuya/Core/AckHandle.hs`. Calling `ingested.ack.finalize decision`
  acknowledges that one message.
- **AckDecision**: `data AckDecision = AckOk | AckRetry !RetryDelay | AckDeadLetter
  !DeadLetterReason | AckHalt !HaltReason` in `shibuya-core/src/Shibuya/Core/Ack.hs`.
- **Handler** (single-message): `type Handler es msg = Ingested es msg -> Eff es AckDecision`.
- **Ordering / Concurrency**: `data Ordering = StrictInOrder | PartitionedInOrder | Unordered`
  and `data Concurrency = Serial | Ahead !Int | Async !Int` in `shibuya-core/src/Shibuya/Policy.hs`.
  `validatePolicy :: Ordering -> Concurrency -> Either PolicyError ()` rejects only
  `StrictInOrder` with `Ahead`/`Async`. Note `Ordering` shadows the Prelude's, so
  `Shibuya.Policy` and `Shibuya.App` both `import Prelude hiding (Ordering)`.
- **Batch**: a non-empty group of ingested messages processed together.
- **Batch key**: a `Text`-wrapped value computed per message that decides which sub-batch it
  accumulates into; messages with the same key batch together.
- **Batch trigger**: the reason a batch was emitted — it reached the configured size
  (`TriggerSize`), its timeout elapsed (`TriggerTimeout`), or the processor is draining and
  flushed a partial batch (`TriggerFlush`).
- **Batch acknowledgement decision/finalization**: every message retained in an emitted
  batch receives exactly one `AckDecision`; that decision is applied through the message's
  idempotent finalizer with bounded retry and loud failure on permanent adapter errors.
- **Graceful shutdown flush**: when the app is stopped, the accumulation engine emits every
  pending partial batch (with `TriggerFlush`) so no accumulated message is dropped.

### EP-16 types you depend on (module `Shibuya.Batch`, `shibuya-core/src/Shibuya/Batch.hs`)

EP-16 (`docs/plans/16-batch-api-and-configuration-types.md`) is complete-by-assumption for this
plan; its module is exposed. You import these; do not redefine them:

```haskell
newtype BatchKey = BatchKey {unBatchKey :: Text}
  deriving stock (Eq, Ord, Show, Generic) deriving newtype (IsString) deriving anyclass (NFData)
defaultBatchKey :: BatchKey                       -- BatchKey "default"

data BatchTrigger = TriggerSize | TriggerTimeout | TriggerFlush
  deriving stock (Eq, Show, Generic) deriving anyclass (NFData)

data BatchInfo = BatchInfo
  { batchKey :: !BatchKey, size :: !Int, trigger :: !BatchTrigger, partition :: !(Maybe Text) }
  deriving stock (Eq, Show, Generic) deriving anyclass (NFData)

data BatchConfig es msg = BatchConfig
  { batchSize :: !Int
  , batchTimeout :: !NominalDiffTime
  , batchKey :: !(Envelope msg -> BatchKey)
  , tickInterval :: !(Maybe NominalDiffTime)      -- Nothing => use batchTimeout
  }
defaultBatchConfig :: BatchConfig es msg          -- size 100, timeout 1s, const defaultBatchKey, tick Nothing

data BatchConfigError
  = BatchSizeNotPositive !Int
  | BatchTimeoutNotPositive !NominalDiffTime
  | TickIntervalNotPositive !NominalDiffTime
  deriving stock (Eq, Show, Generic)
validateBatchConfig :: BatchConfig es msg -> Either BatchConfigError ()

type BatchHandler es msg = BatchInfo -> NonEmpty (Ingested es msg) -> Eff es BatchAck

data BatchAck = BatchAck { decisions :: !(Map MessageId AckDecision), fallback :: !AckDecision }
  deriving stock (Show, Generic)
ackAllOk     :: BatchAck                                 -- BatchAck empty AckOk
ackAll       :: AckDecision -> BatchAck
ackExcept    :: [(MessageId, AckDecision)] -> BatchAck
withFallback :: AckDecision -> [(MessageId, AckDecision)] -> BatchAck
failMessages :: [(MessageId, DeadLetterReason)] -> BatchAck
```

### EP-17 and EP-18 interfaces you mount (DEPENDENCY TO CONFIRM)

At the time this plan was authored, `docs/plans/17-batch-accumulation-engine.md` (EP-17) and
`docs/plans/18-batch-execution-and-exactly-once-ack.md` (EP-18) were still skeletons. This plan
**hard-depends on EP-18** (and transitively EP-17) and mounts the two internal functions below.
The exact module names and signatures are the ones this plan assumes; **when EP-17 and EP-18
are written, confirm they match and reconcile any difference here and in the Decision Log.**
Both modules are exposed library modules, matching the reconciled MasterPlan guidance:
`Shibuya.Runner.Batcher` and `Shibuya.Runner.BatchProcessor` go in `exposed-modules` so
their in-package specs and later plans can import them directly.

The **emitted-batch type** shared between EP-17 and EP-18 is `(BatchInfo, NonEmpty (Ingested es
msg))` (MasterPlan Integration Points). EP-17 produces a stream of these; EP-18 consumes it.

Assumed EP-17 accumulation engine, module `Shibuya.Runner.Batcher`
(`shibuya-core/src/Shibuya/Runner/Batcher.hs`):

```haskell
-- | Group a stream of ingested messages into ready batches according to the
-- BatchConfig: emit a sub-batch when it reaches batchSize, when its batchTimeout
-- elapses, or (on end-of-input) flush all pending partial batches with TriggerFlush.
-- The output stream contains each source message in exactly one emitted batch.
runBatcher ::
  Natural ->
  BatchConfig es msg ->
  Stream.Stream IO (Ingested es msg) ->
  Stream.Stream IO (BatchInfo, NonEmpty (Ingested es msg))
```

Assumed EP-18 execution stage, module `Shibuya.Runner.BatchProcessor`
(`shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`):

```haskell
-- | Run the batch handler over each ready batch, bounding concurrent batches with
-- the Concurrency policy while preserving FIFO execution within each BatchKey.
-- For each retained message in each batch it resolves one BatchAck decision (or
-- fallback), then applies that decision through the message's idempotent finalizer
-- with bounded retries. On a batch handler returning AckHalt or on exhausted
-- finalizer retries it sets haltRef; after the input stream drains it throws
-- ProcessorHalt if haltRef is set (mirroring processUntilDrained).
processBatchesUntilDrained ::
  (IOE :> es, Tracing :> es) =>
  TVar ProcessorMetrics ->
  ProcessorId ->
  Concurrency ->
  BatchHandler es msg ->
  Stream.Stream IO (BatchInfo, NonEmpty (Ingested es msg)) ->
  IORef (Maybe HaltReason) ->
  Eff es ()
```

EP-18 also extends `ProcessorMetrics` (in `shibuya-core/src/Shibuya/Runner/Metrics.hs`) with a
`BatchStats` field carrying batch counters. This plan does **not** touch `ProcessorMetrics`; see
"Metrics exposure" below.

If EP-17's `runBatcher` turns out to need `IO`-return (for example to spawn its timeout ticker
thread, so its type is `… -> IO (Stream.Stream IO …)`), adapt the one call site in
`runIngesterAndProcessorBatch` (bind it with `<-` before building `readyBatchStream`) and record
the change in the Decision Log. If EP-18 chooses **not** to throw `ProcessorHalt` internally but
only to set `haltRef`, add a `readIORef haltRef` check-and-throw immediately after the
`processBatchesUntilDrained` call in `runIngesterAndProcessorBatch`. These are the only two
integration seams that could shift.

### The existing runner (`shibuya-core/src/Shibuya/Runner/Supervised.hs`)

This is the production loop and the file you extend in Milestone 2. The relevant existing pieces
(read the file itself for the full bodies):

`runSupervised` (single-message, supervised) creates initial metrics, registers them with the
`Master`, then uses `withEffToIO (ConcUnlift Persistent Unlimited)` to `addChild
master.state.supervisor` a persistent `runInIO` of `runIngesterAndProcessor`, wrapped with
`` `catch` \(ProcessorHalt _) -> pure ()`` and `` `finally` unregisterProcessor master procId``,
and links the child. Its signature:

```haskell
runSupervised ::
  (IOE :> es, Tracing :> es) =>
  Master -> Natural -> ProcessorId -> Concurrency ->
  Adapter es msg -> Handler es msg -> Eff es SupervisedProcessor
```

`runIngesterAndProcessor` creates a bounded inbox (`newBoundedInbox inboxSize`), a
`streamDoneVar` (`newTVarIO False`), runs the ingester async
(`runIngesterWithMetrics metricsVar adapter.source inbox`) with a `` `finally` atomically
(writeTVar streamDoneVar True)`` so the done flag is always set, runs the processor in the main
thread via `processUntilDrained`, then `poll`s the ingester async for a failure and finally sets
`doneVar` True.

`inboxToStream :: Inbox (Ingested es msg) -> TVar Bool -> IORef (Maybe HaltReason) ->
Stream.Stream IO (Ingested es msg)` is the seam you **reuse**: it yields a Streamly `Stream IO
(Ingested es msg)` that stops when `haltRef` is set (`Just _`), and otherwise atomically either
receives the next message or — when `streamDoneVar` is True and the inbox is empty — ends.

`processUntilDrained` creates `haltRef <- newIORef Nothing`, builds `inboxToStream inbox
streamDoneVar haltRef`, folds it through `Stream.mapM` (Serial) or `StreamP.parMapM` (Ahead n /
Async n) applying `processOne`, and after draining throws `ProcessorHalt reason` if `haltRef` is
set. Your batch variant follows the same lifecycle shape but inserts EP-17's `runBatcher`
between `inboxToStream` and EP-18's `processBatchesUntilDrained`; EP-18 owns the keyed
scheduler instead of using raw global `parMapM` for batch execution.

`data SupervisedProcessor = SupervisedProcessor { metrics :: !(TVar ProcessorMetrics),
processorId :: !ProcessorId, done :: !(TVar Bool), child :: !(Maybe (Async ())) }`. The `done`
TVar is what `waitApp` and `waitForDrainWithTimeout` block on.

`ProcessorHalt` lives in `Shibuya.Runner.Halt`: `data ProcessorHalt = ProcessorHalt { reason ::
HaltReason }` with `instance Exception ProcessorHalt`.

### The public App API (`shibuya-core/src/Shibuya/App.hs`)

This is the file you extend in Milestone 1. The current shape:

```haskell
data QueueProcessor es where
  QueueProcessor ::
    { adapter :: Adapter es msg, handler :: Handler es msg,
      ordering :: Ordering, concurrency :: Concurrency } ->
    QueueProcessor es

mkProcessor :: Adapter es msg -> Handler es msg -> QueueProcessor es
mkProcessor adapter handler = QueueProcessor adapter handler Unordered Serial

data AppError
  = AppPolicyError !PolicyError
  | AppHandlerError !HandlerError
  | AppRuntimeError !RuntimeError
  deriving stock (Eq, Show)

runApp :: (IOE :> es, Tracing :> es) => SupervisionStrategy -> Int ->
          [(ProcessorId, QueueProcessor es)] -> Eff es (Either AppError (AppHandle es))
```

The **exact positional match sites you must update** (adding a constructor makes these
non-exhaustive or type-incorrect) are, from the current `App.hs`:

- `validateAllPolicies` / `validateOne` at `App.hs:194-197`:
  ```haskell
  validateAllPolicies :: [(ProcessorId, QueueProcessor es)] -> Either PolicyError ()
  validateAllPolicies = traverse_ validateOne
    where
      validateOne (_, QueueProcessor _ _ ord conc) = validatePolicy ord conc
  ```
- `spawnProcessors` / `spawnOne` at `App.hs:206-210`:
  ```haskell
  spawnProcessors master inboxSize = traverse spawnOne
    where
      spawnOne (procId, qp@(QueueProcessor adapter handler _ordering concurrency)) = do
        sp <- runSupervised master inboxSize procId concurrency adapter handler
        pure (procId, (sp, qp))
  ```
- `shutdownAdapter` inside `stopAppGracefully` at `App.hs:257`:
  ```haskell
  where
    shutdownAdapter (_, QueueProcessor adapter _ _ _) = adapter.shutdown
  ```

The other positional matches, in `runApp`'s use of `validateAllPolicies`
(`case validateAllPolicies namedProcessors of Left err -> pure $ Left $ AppPolicyError err …`),
change only because `validateAllPolicies` will now return `Either AppError ()` (so the `Left`
branch becomes `pure $ Left err`). The `QueueProcessor _ _ ordering _` let-bindings in the
existing `Shibuya.RunnerSpec` "mkProcessor" tests (`test/Shibuya/RunnerSpec.hs:181,188`) still
compile unchanged, because `mkProcessor` still returns the `QueueProcessor` constructor and a
constructor-specific let pattern is unaffected by adding a new constructor.

### The graceful-shutdown mechanism (`App.hs`, `stopAppGracefully` / `waitForDrainWithTimeout`)

`stopAppGracefully config appHandle` runs `mapM_ shutdownAdapter (Map.elems
appHandle.processors)` (calling each adapter's `shutdown`), then
`waitForDrainWithTimeout (floor (config.drainTimeout * 1_000_000)) (Map.elems
appHandle.processors)`, which blocks in STM until every processor's `done` TVar is True or the
timeout `registerDelay` fires, then `stopMaster`. The `done` TVar of a batching processor is set
at the end of `runIngesterAndProcessorBatch`, i.e. only after the whole batch pipeline (including
the flush) has drained — this is what makes shutdown wait for the flush. This plan does not change
`stopAppGracefully`, `waitForDrainWithTimeout`, or `waitApp`; it only ensures the batch path sets
`done` at the right moment, which the reused structure of `runIngesterAndProcessor` already does.


## Plan of Work

The work is three milestones. Milestone 1 makes batching **expressible and validated** through
the public API (types compile, a bad config is rejected). Milestone 2 makes batching **run** (a
supervised batch runner wired through `spawnOne`, proven end-to-end). Milestone 3 proves the
**graceful-shutdown flush** of a partial batch. Each milestone is independently verifiable by a
new test.

### Milestone 1 — Types and validation

Scope: after this milestone `Shibuya.App` exposes a `BatchingProcessor` constructor and a
`mkBatchProcessor` smart constructor, `runApp` validates a batching processor's policy and batch
config, and a bad batch config is rejected with a new `AppBatchConfigError`. Nothing runs a batch
yet (that is Milestone 2), but the API type-checks and the validation path is exercised by a unit
test. Commands: `cabal build shibuya-core` then `cabal test shibuya-core-test`. Acceptance: the
build is warning-clean and the new "rejects a bad batch config" example passes.

Edit `shibuya-core/src/Shibuya/App.hs` as follows.

Add imports. Add an unqualified import of `Shibuya.Batch` (so its names are re-exportable and
usable), add `runSupervisedBatch` to the existing `Shibuya.Runner.Supervised` import, and import
`first` from `Data.Bifunctor`:

```haskell
import Data.Bifunctor (first)
import Shibuya.Batch
  ( BatchConfig,
    BatchConfigError,
    BatchHandler,
    validateBatchConfig,
  )
import Shibuya.Runner.Supervised
  ( SupervisedProcessor (..),
    runSupervised,
    runSupervisedBatch,
  )
```

Note: importing only the four names above from `Shibuya.Batch` keeps the *use* surface tight; the
*re-export* surface (the whole module) is handled separately in the export list below. Because
`Shibuya.App` will re-export `module Shibuya.Batch`, and a `module X` re-export re-exports names
that are in scope via an import of `X`, you must import `Shibuya.Batch` **unqualified**. Replace
the selective import above with a bare `import Shibuya.Batch` if you re-export the whole module;
if instead you list individual batch names in the export list, keep the selective import. This
plan chooses the whole-module re-export (Decision Log), so use:

```haskell
import Data.Bifunctor (first)
import Shibuya.Batch
import Shibuya.Runner.Supervised
  ( SupervisedProcessor (..),
    runSupervised,
    runSupervisedBatch,
  )
```

Extend the module export list. Add `mkBatchProcessor` next to `mkProcessor`, and add `module
Shibuya.Batch` to a new "Batch API (re-exported)" group. `QueueProcessor (..)` already exports
all constructors, so it will export `BatchingProcessor` automatically; `AppError (..)` already
exports all constructors, so it will export `AppBatchConfigError` automatically. The export list
becomes:

```haskell
module Shibuya.App
  ( -- * Running Processors
    runApp,
    QueueProcessor (..),
    mkProcessor,
    mkBatchProcessor,
    AppHandle (..),

    -- * AppHandle Operations
    getAppMetrics,
    getAppMaster,
    stopApp,
    stopAppGracefully,
    waitApp,

    -- * Shutdown Configuration
    ShutdownConfig (..),
    defaultShutdownConfig,

    -- * Supervision Strategy
    SupervisionStrategy (..),

    -- * Errors
    AppError (..),

    -- * Batch API (re-exported from "Shibuya.Batch")
    module Shibuya.Batch,

    -- * Re-exports
    ProcessorId (..),
    ProcessorMetrics (..),
  )
where
```

Add the `AppBatchConfigError` constructor to `AppError`:

```haskell
data AppError
  = -- | Invalid policy configuration
    AppPolicyError !PolicyError
  | -- | Handler execution error
    AppHandlerError !HandlerError
  | -- | Runtime error
    AppRuntimeError !RuntimeError
  | -- | Invalid batch configuration for a 'BatchingProcessor'
    AppBatchConfigError !BatchConfigError
  deriving stock (Eq, Show)
```

Add the `BatchingProcessor` constructor to `QueueProcessor`:

```haskell
-- | A queue processor pairs an adapter with a handler. The message type is
-- existentially hidden, allowing heterogeneous queues in one 'runApp' call.
--
-- 'QueueProcessor' processes one message at a time; 'BatchingProcessor' groups
-- messages into batches (see "Shibuya.Batch") and runs a 'BatchHandler' over each.
data QueueProcessor es where
  QueueProcessor ::
    { adapter :: Adapter es msg,
      handler :: Handler es msg,
      ordering :: Ordering,
      concurrency :: Concurrency
    } ->
    QueueProcessor es
  BatchingProcessor ::
    { adapter :: Adapter es msg,
      batchHandler :: BatchHandler es msg,
      batchConfig :: BatchConfig es msg,
      ordering :: Ordering,
      concurrency :: Concurrency
    } ->
    QueueProcessor es
```

The reused field names (`adapter`, `ordering`, `concurrency`) are legal because
`DuplicateRecordFields` is on.

Add the `mkBatchProcessor` smart constructor beside `mkProcessor`:

```haskell
-- | Convenience constructor for a batching processor with safe default policies
-- (Unordered ordering + Serial concurrency, i.e. one batch at a time).
mkBatchProcessor ::
  Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es
mkBatchProcessor adapter batchHandler batchConfig =
  BatchingProcessor adapter batchHandler batchConfig Unordered Serial
```

Change `validateAllPolicies` to return `Either AppError ()` and validate both policy and batch
config for a `BatchingProcessor`, using field puns:

```haskell
-- | Validate all processor policies (and batch configs) before starting.
validateAllPolicies :: [(ProcessorId, QueueProcessor es)] -> Either AppError ()
validateAllPolicies = traverse_ validateOne
  where
    validateOne (_, qp) = case qp of
      QueueProcessor {ordering, concurrency} ->
        first AppPolicyError (validatePolicy ordering concurrency)
      BatchingProcessor {ordering, concurrency, batchConfig} -> do
        first AppPolicyError (validatePolicy ordering concurrency)
        first AppBatchConfigError (validateBatchConfig batchConfig)
```

`traverse_` over `Either AppError ()` is an `Applicative`/`Foldable` traversal that
short-circuits on the first `Left`. `first :: (a -> b) -> Either a c -> Either b c` (from
`Data.Bifunctor`) rewraps the error. The `do` block in the `BatchingProcessor` branch is the
`Either` monad: it runs the policy check, then (only if that succeeded) the batch-config check.

Update `runApp` to propagate the `AppError` unchanged (it was previously wrapping a `PolicyError`):

```haskell
runApp strategy inboxSize namedProcessors =
  case validateAllPolicies namedProcessors of
    Left err -> pure $ Left err
    Right () -> do
      …
```

Update `spawnOne` to dispatch by constructor (this is the M2 wiring, but making it total now
keeps the build compiling; a `BatchingProcessor` will call `runSupervisedBatch`, which you add in
Milestone 2 — if you are doing M1 strictly first, temporarily point the `BatchingProcessor` branch
at an `error "runSupervisedBatch not yet wired"` so the module compiles, then replace it in M2.
Cleaner: do the M2 runner edit first, then this dispatch compiles for real). The final form:

```haskell
spawnProcessors master inboxSize = traverse spawnOne
  where
    spawnOne (procId, qp) = case qp of
      QueueProcessor {adapter, handler, concurrency} -> do
        sp <- runSupervised master inboxSize procId concurrency adapter handler
        pure (procId, (sp, qp))
      BatchingProcessor {adapter, batchHandler, batchConfig, concurrency} -> do
        sp <-
          runSupervisedBatch
            master
            inboxSize
            procId
            concurrency
            batchConfig
            adapter
            batchHandler
        pure (procId, (sp, qp))
```

Update `shutdownAdapter` inside `stopAppGracefully` to match both constructors:

```haskell
  where
    shutdownAdapter (_, qp) = case qp of
      QueueProcessor {adapter} -> adapter.shutdown
      BatchingProcessor {adapter} -> adapter.shutdown
```

That is every positional `QueueProcessor` match in `App.hs`. There are no others (`waitApp` and
`waitForDrainWithTimeout` only touch the `SupervisedProcessor` half of the tuple).

### Milestone 2 — The batch runner and dispatch

Scope: after this milestone `Shibuya.Runner.Supervised` exposes `runSupervisedBatch` (supervised)
and `runWithMetricsBatch` (non-supervised, for finite-stream tests), and `runApp` actually runs a
batching processor end to end. Commands: `cabal build shibuya-core` then `cabal test
shibuya-core-test`. Acceptance: the M2 test drives `runApp` with a `BatchingProcessor` over N
messages and asserts every message receives one decision, records one successful finalization,
and the handler saw them in batches.

Edit `shibuya-core/src/Shibuya/Runner/Supervised.hs`.

Add to the export list, next to `runSupervised` and `runWithMetrics`:

```haskell
    -- * Running with Supervision
    runSupervised,
    runSupervisedBatch,

    -- * Standalone (without Master)
    runWithMetrics,
    runWithMetricsBatch,
```

Add imports for the batch types and the two mounted functions. Add near the other `Shibuya.*`
imports:

```haskell
import Shibuya.Batch (BatchConfig, BatchHandler)
import Shibuya.Runner.Batcher (runBatcher)
import Shibuya.Runner.BatchProcessor (processBatchesUntilDrained)
```

(`Shibuya.Runner.Batcher` and `Shibuya.Runner.BatchProcessor` are the EP-17/EP-18 runner
modules; both must be listed in the cabal `exposed-modules` — EP-17 and EP-18 add them
there, but if they are not yet present, add them so this module resolves.)

Add `runSupervisedBatch`, structurally identical to `runSupervised` but delegating to the batch
inner loop:

```haskell
-- | Run a batching processor under the Master's supervision with metrics.
--
-- Identical in shape to 'runSupervised' but the inner loop accumulates messages
-- into batches (via the BatchConfig) and runs a 'BatchHandler' over each batch,
-- finalizing every message exactly once. On a batch-handler halt the child exits
-- gracefully (the 'ProcessorHalt' is caught here), matching 'runSupervised'.
runSupervisedBatch ::
  (IOE :> es, Tracing :> es) =>
  Master ->
  -- | Inbox size (for backpressure)
  Natural ->
  -- | Processor identifier
  ProcessorId ->
  -- | Concurrency mode (bounds how many BATCHES run at once)
  Concurrency ->
  -- | Batch configuration
  BatchConfig es msg ->
  -- | Queue adapter
  Adapter es msg ->
  -- | Batch handler
  BatchHandler es msg ->
  Eff es SupervisedProcessor
runSupervisedBatch master inboxSize procId concurrency batchConfig adapter batchHandler = do
  now <- liftIO getCurrentTime

  let initialMetrics = emptyProcessorMetrics now
  metricsVar <- liftIO $ newTVarIO initialMetrics
  doneVar <- liftIO $ newTVarIO False

  registerProcessor master procId metricsVar

  supervisedChild <- withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
    addChild master.state.supervisor $
      runInIO $
        ( runIngesterAndProcessorBatch
            metricsVar
            procId
            doneVar
            inboxSize
            concurrency
            batchConfig
            adapter
            batchHandler
            `catch` \(ProcessorHalt _) -> pure ()
        )
          `finally` unregisterProcessor master procId

  unsafeEff_ $ UIO.link supervisedChild

  pure
    SupervisedProcessor
      { metrics = metricsVar,
        processorId = procId,
        done = doneVar,
        child = Just supervisedChild
      }
```

Add `runWithMetricsBatch`, the non-supervised, blocking variant used by finite-stream tests. It
mirrors `runWithMetrics` (no `Master`, `child = Nothing`) but reuses the shared batch inner loop
so accumulation and flush behave identically to the supervised path:

```haskell
-- | Run a batching processor with metrics but without Master supervision.
-- Blocks until the adapter stream is exhausted and every accumulated batch has
-- been processed (including the end-of-input flush). Useful for tests.
runWithMetricsBatch ::
  (IOE :> es, Tracing :> es) =>
  Natural ->
  ProcessorId ->
  Concurrency ->
  BatchConfig es msg ->
  Adapter es msg ->
  BatchHandler es msg ->
  Eff es SupervisedProcessor
runWithMetricsBatch inboxSize procId concurrency batchConfig adapter batchHandler = do
  now <- liftIO getCurrentTime

  let initialMetrics = emptyProcessorMetrics now
  metricsVar <- liftIO $ newTVarIO initialMetrics
  doneVar <- liftIO $ newTVarIO False

  runIngesterAndProcessorBatch
    metricsVar
    procId
    doneVar
    inboxSize
    concurrency
    batchConfig
    adapter
    batchHandler

  pure
    SupervisedProcessor
      { metrics = metricsVar,
        processorId = procId,
        done = doneVar,
        child = Nothing
      }
```

Add the shared inner loop `runIngesterAndProcessorBatch`, the batch analogue of
`runIngesterAndProcessor`. The only differences from the single-message version are: it takes a
  `BatchConfig` and a `BatchHandler`; it creates `haltRef` **here** (because the batcher's input
stream needs it, so `haltRef` must be shared between `inboxToStream` and
`processBatchesUntilDrained`); it inserts `runBatcher inboxSize batchConfig` between `inboxToStream` and the
processing stage; and it calls `processBatchesUntilDrained` instead of `processUntilDrained`:

```haskell
-- | Run ingester and batch processor with a bounded inbox.
-- The ingester reads from the adapter stream into the inbox exactly as in the
-- single-message path; 'inboxToStream' turns the inbox into a halt-aware,
-- stream-done-aware Stream; 'runBatcher' groups that into ready batches; and
-- 'processBatchesUntilDrained' runs the batch handler and finalizes each message
-- exactly once. When the adapter stream ends (including on graceful shutdown,
-- when 'Adapter.shutdown' ends 'source'), the ingester completes, sets
-- streamDoneVar, 'inboxToStream' terminates once the inbox is empty, the batcher
-- reaches end-of-input and flushes all pending partial batches with TriggerFlush,
-- and only then does 'processBatchesUntilDrained' return and 'doneVar' get set.
runIngesterAndProcessorBatch ::
  (IOE :> es, Tracing :> es) =>
  TVar ProcessorMetrics ->
  ProcessorId ->
  TVar Bool ->
  Natural ->
  Concurrency ->
  BatchConfig es msg ->
  Adapter es msg ->
  BatchHandler es msg ->
  Eff es ()
runIngesterAndProcessorBatch metricsVar procId doneVar inboxSize concurrency batchConfig adapter batchHandler = do
  inbox <- liftIO $ newBoundedInbox inboxSize
  streamDoneVar <- liftIO $ newTVarIO False
  haltRef <- liftIO $ newIORef Nothing

  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
    let ingesterWithSignal =
          runInIO (runIngesterWithMetrics metricsVar adapter.source inbox)
            `finally` atomically (writeTVar streamDoneVar True)

    UIO.withAsync ingesterWithSignal $ \ingesterAsync -> do
      let inboxStream = inboxToStream inbox streamDoneVar haltRef
          readyBatchStream = runBatcher inboxSize batchConfig inboxStream
      runInIO $
        processBatchesUntilDrained
          metricsVar
          procId
          concurrency
          batchHandler
          readyBatchStream
          haltRef
      UIO.poll ingesterAsync >>= \case
        Just (Left ingesterErr) -> do
          now <- getCurrentTime
          atomically $
            modifyTVar' metricsVar $ \m ->
              m & #state .~ Failed (Text.pack (displayException ingesterErr)) now
          atomically $ writeTVar doneVar True
          UIO.throwIO ingesterErr
        _ -> pure ()

  liftIO $ atomically $ writeTVar doneVar True
```

Note on the halt path: `processBatchesUntilDrained` (EP-18) throws `ProcessorHalt` after draining
if a batch handler returned `AckHalt` (mirroring `processUntilDrained`). That exception propagates
out of `runInIO`, skips the ingester `poll` and the final `writeTVar doneVar True`, and is caught
by the `` `catch` \(ProcessorHalt _) -> pure ()`` in `runSupervisedBatch` — exactly as in the
single-message path, where a halt likewise leaves `doneVar` unset. This intentional parity is
noted so a future reader does not "fix" the batch path to diverge from the single-message one. If
EP-18 instead only sets `haltRef` and returns normally, add `liftIO (readIORef haltRef) >>= maybe
(pure ()) (throwIO . ProcessorHalt)` right after `processBatchesUntilDrained` (see the DEPENDENCY
TO CONFIRM note in Context and Orientation).

With the runner exported, the `spawnOne` `BatchingProcessor` branch you wrote in Milestone 1 now
resolves against the real `runSupervisedBatch`.

### Milestone 3 — Graceful-shutdown flush

Scope: this milestone adds no production code — it proves, with a test, that a partial batch (one
smaller than `batchSize` whose timeout has not elapsed) is flushed and acknowledged when the app
is stopped. The mechanism is entirely a consequence of Milestone 2's structure and the reused
graceful-shutdown machinery, which this milestone documents and pins with a test. Command: `cabal
test shibuya-core-test`. Acceptance: the M3 test shows that after `stopApp`, all the fed messages
recorded one successful finalization and the batch handler saw them under `TriggerFlush`.

Why the flush happens (trace the causal chain, all mechanisms already present after Milestone 2):
`stopAppGracefully` calls each `adapter.shutdown`. `shutdown` ends the adapter's `source` stream.
The ingester folds `source`, so when `source` ends the ingester completes and its `` `finally`
atomically (writeTVar streamDoneVar True)`` sets `streamDoneVar`. `inboxToStream` observes
`streamDoneVar && inbox empty` and terminates. `runBatcher` sees end-of-input on its input stream
and, by EP-17's contract, emits every pending partial accumulator as a batch tagged
`TriggerFlush`. `processBatchesUntilDrained` runs the batch handler over each flushed batch and
applies every message's resolved acknowledgement decision through its finalizer, including
bounded retry/fail-loud behavior. Only after that whole ready-batch stream drains does
`processBatchesUntilDrained` return, and only then does `runIngesterAndProcessorBatch` set
`doneVar` True. `stopAppGracefully`'s `waitForDrainWithTimeout` blocks on exactly that `doneVar`,
so it waits for the flush (up to `drainTimeout`). Therefore the pre-existing `drainTimeout`
mechanism already covers batches, provided the operator sets `drainTimeout` comfortably larger than
`batchTimeout` plus the handler's runtime (Decision Log).

The M3 test uses a **gated adapter** whose `source` emits the fed messages and then blocks until
`shutdown` is called, so the batch stays pending (below `batchSize`, timeout far in the future)
until `stopApp` triggers the flush — this isolates the shutdown-flush path from the ordinary
end-of-input flush a plain finite list adapter would also exhibit.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

1. Apply the Milestone 2 edits to `shibuya-core/src/Shibuya/Runner/Supervised.hs` first (add the
   three functions and the exports and imports), so that the `App.hs` dispatch resolves. If
   `shibuya-core/src/Shibuya/Runner/Batcher.hs` (EP-17) and
   `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs` (EP-18) do not yet exist, this plan cannot
   complete — stop and land EP-17 and EP-18 first (this plan hard-depends on EP-18).

2. Apply the Milestone 1 edits to `shibuya-core/src/Shibuya/App.hs` (imports, exports,
   `AppError`, `QueueProcessor`, `mkBatchProcessor`, `validateAllPolicies`, `runApp`,
   `spawnOne`, `shutdownAdapter`).

3. Build:

```bash
cabal build shibuya-core
```

   Expected: a clean build. The library uses `-Wall` (the `warnings` common stanza), so fix any
   unused-import or incomplete-pattern warnings. A common one: if you keep the selective
   `import Shibuya.Batch (…)` while also re-exporting `module Shibuya.Batch`, GHC warns the
   re-export exports nothing from that import — use the bare `import Shibuya.Batch` as the plan
   specifies.

4. Create the test module `shibuya-core/test/Shibuya/App/BatchSpec.hs` with the contents in
   "Validation and Acceptance" below. Add `Shibuya.App.BatchSpec` to the test suite
   `other-modules` in `shibuya-core/shibuya-core.cabal` (alphabetically it sorts before
   `Shibuya.Core.AckSpec`), and wire it into `shibuya-core/test/Main.hs` with
   `import Shibuya.App.BatchSpec qualified` and, in the `hspec` block,
   `Shibuya.App.BatchSpec.spec` (the spec opens with its own `describe "Shibuya.App.Batch"`, so
   invoke it bare, matching the newest entries like `Shibuya.Runner.SupervisedSpec.spec`).

5. Build and run the tests:

```bash
cabal test shibuya-core-test
```

   Expected transcript excerpt:

```text
Shibuya.App.Batch
  runApp with a BatchingProcessor
    rejects a batch config with size 0 (AppBatchConfigError)
    processes all messages in batches and acks each exactly once
    flushes a pending partial batch on graceful shutdown
```

6. Format:

```bash
nix fmt
```

   Expected: no diff (or auto-formatted files you then `git add`). The pre-commit hook runs
   treefmt and rejects unformatted commits.


## Validation and Acceptance

Acceptance is behavioral: each milestone is proven by an example in the new test module
`shibuya-core/test/Shibuya/App/BatchSpec.hs`. The module and its helpers follow the style of the
existing `shibuya-core/test/Shibuya/RunnerSpec.hs` (which uses `runEff $ runTracingNoop $ …`,
`newTrackingAck`, and a mock adapter). `TrackingAck` records **every** `finalize` call into a
list `IORef` (`tracking.trackedDecisions :: IORef [(MessageId, AckDecision)]`), so normal-path
finalization is asserted by checking that each `MessageId` appears exactly once in that list.

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Shibuya.App.BatchSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar, writeTVar)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (nub, sort)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Mock (TrackingAck (..), newTrackingAck, trackingAckHandle)
import Shibuya.App
  ( AppError (..),
    SupervisionStrategy (..),
    mkBatchProcessor,
    runApp,
    stopApp,
    waitApp,
  )
import Shibuya.Batch
  ( BatchConfig (..),
    BatchInfo (..),
    BatchTrigger (..),
    ackAllOk,
    defaultBatchConfig,
  )
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Runner.Metrics (ProcessorId (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import Test.Hspec

spec :: Spec
spec = describe "Shibuya.App.Batch" $ do
  describe "runApp with a BatchingProcessor" $ do
    -- Milestone 1: a bad batch config is rejected by runApp with AppBatchConfigError.
    it "rejects a batch config with size 0 (AppBatchConfigError)" $ do
      result <- runEff $ runTracingNoop $ do
        sizeRef <- liftIO $ newIORef []
        messages <- createTrackedMessages' 1
        let adapter = listAdapter' (map snd messages)
            badConfig = defaultBatchConfig {batchSize = 0}
            processor = mkBatchProcessor adapter (recordingHandler sizeRef) badConfig
        runApp IgnoreFailures 100 [(ProcessorId "bad", processor)]
      case result of
        Left (AppBatchConfigError _) -> pure ()
        other ->
          expectationFailure $ "expected AppBatchConfigError, got: " ++ show (void' other)

    -- Milestone 2: all N messages are acked exactly once, seen in batches.
    it "processes all messages in batches and acks each exactly once" $ do
      (sizes, ids) <- runEff $ runTracingNoop $ do
        tracking <- newTrackingAck
        sizeRef <- liftIO $ newIORef []
        messages <- createTrackedMessages tracking 10
        let adapter = listAdapter' messages
            config = defaultBatchConfig {batchSize = 4, batchTimeout = 60}
            processor = mkBatchProcessor adapter (recordingHandler sizeRef) config
        res <- runApp IgnoreFailures 100 [(ProcessorId "batch", processor)]
        case res of
          Left err -> liftIO $ ioError (userError (show (void' (Left err))))
          Right appHandle -> do
            waitApp appHandle
            ss <- liftIO $ readIORef sizeRef
            decs <- liftIO $ readIORef tracking.trackedDecisions
            pure (ss, map fst decs)
      sum (map fst sizes) `shouldBe` 10
      length ids `shouldBe` 10          -- normal path: each message finalized once
      length (nub ids) `shouldBe` 10    -- and all distinct

    -- Milestone 3: a partial batch (< batchSize, timeout far off) is flushed on shutdown.
    it "flushes a pending partial batch on graceful shutdown" $ do
      (sizes, ids, triggers) <- runEff $ runTracingNoop $ do
        tracking <- newTrackingAck
        sizeRef <- liftIO $ newIORef []
        gate <- liftIO $ newTVarIO False
        messages <- createTrackedMessages tracking 3
        let adapter = gatedAdapter gate messages
            -- Never fills (size 100) and never times out during the test (60s).
            config = defaultBatchConfig {batchSize = 100, batchTimeout = 60}
            processor = mkBatchProcessor adapter (recordingHandler sizeRef) config
        res <- runApp IgnoreFailures 100 [(ProcessorId "flush", processor)]
        case res of
          Left err -> liftIO $ ioError (userError (show (void' (Left err))))
          Right appHandle -> do
            -- Let the 3 messages be ingested and accumulated.
            liftIO $ threadDelay 200000
            stopApp appHandle            -- ends source -> EOF flush -> waits for done
            ss <- liftIO $ readIORef sizeRef
            decs <- liftIO $ readIORef tracking.trackedDecisions
            pure (ss, map fst decs, map snd ss)
      sum (map fst sizes) `shouldBe` 3
      length ids `shouldBe` 3
      length (nub ids) `shouldBe` 3
      all (== TriggerFlush) triggers `shouldBe` True

-- Handler that records (batch size, trigger) and acks everything OK.
recordingHandler ::
  (IOE :> es) => IORef [(Int, BatchTrigger)] -> BatchInfo -> f -> Eff es a
recordingHandler = error "see note: replace with the BatchHandler below"
```

The `recordingHandler` stub above only marks where the real handler goes; use this actual
definition (a `BatchHandler es String` that records the batch's declared `size` and `trigger` and
returns `ackAllOk`):

```haskell
recordingHandler ::
  (IOE :> es) => IORef [(Int, BatchTrigger)] -> Shibuya.Batch.BatchHandler es String
recordingHandler ref info _batch = do
  liftIO $ modifyIORef' ref ((info.size, info.trigger) :)
  pure ackAllOk
```

Helper definitions (mirroring `RunnerSpec`'s helpers; `createTrackedMessages` returns
`[Ingested es String]` with tracking acks, and the two adapters wrap a message list):

```haskell
testTime :: UTCTime
testTime = UTCTime (fromGregorian 2024 1 1) 0

createTrackedMessages :: (IOE :> es) => TrackingAck -> Int -> Eff es [Ingested es String]
createTrackedMessages tracking n = mapM mk [1 .. n]
  where
    mk i = do
      let msgId = MessageId $ "msg-" <> (if i < 10 then "0" else "") <> Text.pack (show i)
          env =
            Envelope
              { messageId = msgId,
                cursor = Just (CursorInt i),
                partition = Nothing,
                enqueuedAt = Just testTime,
                traceContext = Nothing,
                headers = Nothing,
                attempt = Nothing,
                attributes = HashMap.empty,
                payload = "message-" <> show i
              }
      pure $ Ingested {envelope = env, ack = trackingAckHandle tracking msgId, lease = Nothing}

-- Finite adapter: ends as soon as its list is exhausted.
listAdapter' :: [Ingested es String] -> Adapter es String
listAdapter' messages =
  Adapter {adapterName = "test:batch", source = Stream.fromList messages, shutdown = pure ()}

-- Gated adapter: emits the messages, then blocks until 'shutdown' opens the gate,
-- so a partial batch stays pending until stopApp triggers the flush.
gatedAdapter :: (IOE :> es) => TVar Bool -> [Ingested es String] -> Adapter es String
gatedAdapter gate messages =
  Adapter
    { adapterName = "test:gated",
      source =
        Stream.fromList messages
          <> Stream.concatEffect (waitGate >> pure Stream.nil),
      shutdown = liftIO $ atomically $ writeTVar gate True
    }
  where
    waitGate = liftIO $ atomically $ readTVar gate >>= check
```

Notes on the test as written:

- `void'` is shorthand for "make the error printable without the existential adapter" — in
  practice just `show err` works because `AppError` derives `Show`; replace `show (void' …)` with
  `show err` (the `void'` wrapper in the sketch is only to avoid printing the whole `Either
  AppError (AppHandle es)`, whose `AppHandle` has no `Show`). Concretely: in the `Left err`
  branches print `show err`; in the M1 `other ->` branch, match `other` against the `Either`
  and print only its `Left` error, e.g. `case result of Left (AppBatchConfigError _) -> pure ();
  Left e -> expectationFailure ("expected AppBatchConfigError, got: " ++ show e); Right _ ->
  expectationFailure "expected Left, got a running AppHandle"`. Remove the `void'` helper entirely.
- The two `Stream.nil` / `Stream.concatEffect` names come from `Streamly.Data.Stream`
  (`Stream.concatEffect :: Monad m => m (Stream m a) -> Stream m a`, `Stream.nil :: Stream m a`).
  `(<>)` on streams appends. If `concatEffect` is not exported by your streamly version, use
  `Stream.before waitGate Stream.nil` or `Stream.fromEffect (waitGate >> pure ()) >> Stream.nil`
  as an equivalent "run the effect then end" — verify against the streamly `^>=0.11` API.
- `batchTimeout = 60` sets the flush-by-timeout far beyond the ~0.2s test, so in M3 the only
  trigger is `TriggerFlush`. In M2 with a finite `listAdapter'`, batches of 4 emit as
  `TriggerSize` and the trailing 2 emit as `TriggerFlush` at end-of-input; the test only asserts
  the *sum* of sizes and the one-successful-finalization id set, so it is agnostic to which
  trigger fired.

Acceptance is reached when all three examples pass:

1. **M1** proves validation: `runApp` returns `Left (AppBatchConfigError …)` for `batchSize = 0`,
   demonstrating a batching processor's config is validated before anything starts.
2. **M2** proves end-to-end batching and normal-path finalization: 10 input messages are
   grouped into batches whose sizes sum to 10, and each of the 10 `MessageId`s appears exactly
   once in the tracked acknowledgements.
3. **M3** proves the shutdown flush: 3 messages held below `batchSize` are flushed and
   acknowledged (each exactly once) only when `stopApp` ends the source, and the batch handler saw
   them under `TriggerFlush`.

Beyond the tests, you can demonstrate the API interactively:

```bash
cabal repl shibuya-core
```

```haskell
ghci> import Shibuya.App
ghci> :type mkBatchProcessor
mkBatchProcessor :: Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es
ghci> :type (AppBatchConfigError (BatchSizeNotPositive 0))
(AppBatchConfigError (BatchSizeNotPositive 0)) :: AppError
```


## Idempotence and Recovery

Every edit is additive and safe to re-run. Adding the `BatchingProcessor` constructor,
`mkBatchProcessor`, the `AppBatchConfigError` constructor, and the three runner functions does not
alter any existing single-message behavior; the existing `Shibuya.RunnerSpec` and
`Shibuya.Runner.SupervisedSpec` continue to pass unchanged. If you re-apply the plan, the `Edit`
operations are exact string replacements, so re-running them is a no-op once applied; the new test
file is created once (re-writing it overwrites with identical content); the cabal and `Main.hs`
insertions are idempotent list additions — do not add `Shibuya.App.BatchSpec` twice.

The most likely build failures and their fixes: a non-exhaustive-pattern warning at
`validateOne`/`spawnOne`/`shutdownAdapter` means one branch of the `case` is missing — both
`QueueProcessor{…}` and `BatchingProcessor{…}` must be present. An "ambiguous field" error under
`DuplicateRecordFields` means you used a bare field selector rather than a constructor-scoped pun
or dot-access — always match with the constructor named (`BatchingProcessor{adapter}`) or read via
`value.field`. A "module `Shibuya.Runner.Batcher` not found" (or `BatchProcessor`) means EP-17 or
EP-18 has not landed yet; this plan cannot complete without them. If `runBatcher`'s real type
differs (returns in `IO`), bind it with `<-` in `runIngesterAndProcessorBatch` and update the
Decision Log. If a build half-applies, `git checkout -- shibuya-core/src/Shibuya/App.hs
shibuya-core/src/Shibuya/Runner/Supervised.hs` reverts the two edited files and you re-apply.

Nothing in this plan is destructive: no data migration, no deletion of existing code, no change to
on-disk formats. The single-message path (`mkProcessor`, `runSupervised`) is untouched and remains
the tested default.


## Interfaces and Dependencies

Libraries and modules used and why. `Data.Bifunctor` (`first`) rewraps `PolicyError`/
`BatchConfigError` into `AppError` in `validateAllPolicies`. `Shibuya.Batch` (EP-16) supplies
`BatchConfig`, `BatchConfigError`, `BatchHandler`, `validateBatchConfig`, and the values re-
exported for users. `Shibuya.Runner.Batcher` (EP-17, internal) supplies `runBatcher`.
`Shibuya.Runner.BatchProcessor` (EP-18, internal) supplies `processBatchesUntilDrained`.
`Shibuya.Runner.Supervised` gains the batch runner functions. Streamly (`streamly ^>=0.11`,
`streamly-core ^>=0.3`) provides the `Stream` type threaded through. All are existing dependencies
of `shibuya-core`; no new `build-depends` are required (the test suite already depends on `stm`,
`streamly`, `text`, `time`, `unliftio`, `unordered-containers`, and the `Control.Concurrent`
`threadDelay` from `base`).

At the end of this plan the following must exist, exported from `Shibuya.App`
(`shibuya-core/src/Shibuya/App.hs`):

```haskell
data QueueProcessor es where
  QueueProcessor ::
    { adapter :: Adapter es msg, handler :: Handler es msg,
      ordering :: Ordering, concurrency :: Concurrency } -> QueueProcessor es
  BatchingProcessor ::
    { adapter :: Adapter es msg, batchHandler :: BatchHandler es msg,
      batchConfig :: BatchConfig es msg, ordering :: Ordering,
      concurrency :: Concurrency } -> QueueProcessor es

mkBatchProcessor ::
  Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es

data AppError
  = AppPolicyError !PolicyError
  | AppHandlerError !HandlerError
  | AppRuntimeError !RuntimeError
  | AppBatchConfigError !BatchConfigError
  deriving stock (Eq, Show)

-- validateAllPolicies changes its return type; it is not exported but its type must be:
validateAllPolicies :: [(ProcessorId, QueueProcessor es)] -> Either AppError ()
```

Plus the whole `Shibuya.Batch` module re-exported through `Shibuya.App` (`module Shibuya.Batch` in
the export list), so `import Shibuya.App` brings `BatchConfig(..)`, `defaultBatchConfig`,
`BatchHandler`, `BatchAck(..)`, `ackAllOk`, `ackAll`, `ackExcept`, `withFallback`, `failMessages`,
`BatchInfo(..)`, `BatchKey(..)`, `BatchTrigger(..)`, `BatchConfigError(..)`, and
`validateBatchConfig` into scope.

Exported from `Shibuya.Runner.Supervised` (`shibuya-core/src/Shibuya/Runner/Supervised.hs`):

```haskell
runSupervisedBatch ::
  (IOE :> es, Tracing :> es) =>
  Master -> Natural -> ProcessorId -> Concurrency ->
  BatchConfig es msg -> Adapter es msg -> BatchHandler es msg ->
  Eff es SupervisedProcessor

runWithMetricsBatch ::
  (IOE :> es, Tracing :> es) =>
  Natural -> ProcessorId -> Concurrency ->
  BatchConfig es msg -> Adapter es msg -> BatchHandler es msg ->
  Eff es SupervisedProcessor
```

with the internal helper `runIngesterAndProcessorBatch :: (IOE :> es, Tracing :> es) => TVar
ProcessorMetrics -> ProcessorId -> TVar Bool -> Natural -> Concurrency -> BatchConfig es msg ->
Adapter es msg -> BatchHandler es msg -> Eff es ()` (not exported).

Dependencies this plan hard-mounts and that must be confirmed when EP-17/EP-18 land: EP-17's
`runBatcher :: Natural -> BatchConfig es msg -> Stream.Stream IO (Ingested es msg) -> Stream.Stream IO
(BatchInfo, NonEmpty (Ingested es msg))` in `Shibuya.Runner.Batcher`; EP-18's
`processBatchesUntilDrained :: (IOE :> es, Tracing :> es) => TVar ProcessorMetrics -> ProcessorId
-> Concurrency -> BatchHandler es msg -> Stream.Stream IO (BatchInfo, NonEmpty (Ingested es msg))
-> IORef (Maybe HaltReason) -> Eff es ()` in `Shibuya.Runner.BatchProcessor`, which must set
`haltRef` on a batch-handler `AckHalt` and throw `ProcessorHalt` after draining (mirroring
`processUntilDrained`); and EP-18's addition of a `BatchStats` field to `ProcessorMetrics` in
`Shibuya.Runner.Metrics`. Both runner modules must appear in the cabal `exposed-modules`,
matching EP-17, EP-18, and the MasterPlan reconciliation note.

### Metrics exposure

EP-18 adds a `BatchStats` field to `ProcessorMetrics` (in `Shibuya.Runner.Metrics`) and records
batch counters there. This plan requires **no** new metrics code: `getAppMetrics` already returns
the whole `ProcessorMetrics` value (via `getAllMetrics appHandle.master`), so any field EP-18 adds
flows through to callers unchanged. The only obligation here is to confirm, once EP-18 lands, that
`getAppMetrics` on a `BatchingProcessor`'s handle returns a `ProcessorMetrics` whose `BatchStats`
reflects the batches processed — a one-line assertion the EP-20 reliability suite will make. The
pre-existing but unused `dropped` counter in `StreamStats` remains available for batch-drop
accounting if EP-18 chooses to use it.

### Cabal changes

`shibuya-core/shibuya-core.cabal`: add `Shibuya.App.BatchSpec` to the `test-suite
shibuya-core-test` `other-modules` list. No library `exposed-modules` change is needed in this
plan (`Shibuya.App`, `Shibuya.Batch`, `Shibuya.Runner.Supervised`, and `Shibuya.Runner.Metrics`
are already exposed; `Shibuya.Runner.Batcher` and `Shibuya.Runner.BatchProcessor` are added to
`exposed-modules` by EP-17/EP-18). No new `build-depends`.


## Revision History

- 2026-07-01: Initial authored version of EP-19. Written against the shared batch context and the
  live `App.hs`/`Supervised.hs`/`Policy.hs`/`Error.hs` sources. EP-17 and EP-18 were still
  skeletons at authoring time, so their mounted interfaces (`runBatcher`,
  `processBatchesUntilDrained`, the `BatchStats` metrics field) are embedded here as
  "DEPENDENCY TO CONFIRM" and must be reconciled when those plans land. Reason: EP-19 is the
  integration plan and cannot be implemented before EP-18, but the plan itself is authored now so
  the public API (`BatchingProcessor`, `mkBatchProcessor`, `AppBatchConfigError`) is pinned for
  EP-20 and EP-21 to build against in parallel.

- 2026-07-01: Reconciled EP-19 with the validated MasterPlan and EP-17. `runBatcher` now takes
  an explicit `Natural` output capacity, and EP-19 passes `inboxSize` so the ready-batch queue is
  bounded by the same backpressure knob as the inbox. The plan also now treats
  `Shibuya.Runner.Batcher` and `Shibuya.Runner.BatchProcessor` as exposed modules, not hidden
  `other-modules`.

- 2026-07-01: Reconciled EP-19 with the reliability-strengthened EP-18 contract. Integration
  prose now points to one decision per retained message, bounded finalizer retry/fail-loud
  behavior, and EP-18's keyed scheduler for per-key FIFO execution.
