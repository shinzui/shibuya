---
id: 3
slug: first-class-batch-processing
title: "First-Class Batch Processing"
kind: master-plan
created_at: 2026-07-01T15:34:17Z
intention: "intention_01kwf4q2bke2js9t0js53dwh5a"
---

# First-Class Batch Processing

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shibuya today processes one message at a time. Its two-stage pipeline —
`Adapter.source (stream) → Ingester (async, bounded inbox) → Processor → Ack` — pulls a
single `Ingested es msg` from a bounded inbox, hands it to a `Handler es msg`
(`Ingested es msg -> Eff es AckDecision`), and finalizes exactly one acknowledgement per
message via that message's own `AckHandle` (`finalize :: AckDecision -> Eff es ()`). This
is clean and reliable, but it forces every consumer that wants to write to a downstream
system in bulk — a database `INSERT ... VALUES` with many rows, an S3 multipart upload, a
batched HTTP API call — to invent its own accumulation logic inside the handler. That
user-space accumulation is error-prone, does not integrate with the framework's
backpressure, and easily loses or double-acknowledges messages on shutdown or failure.
Broadway (the Elixir framework Shibuya is modeled on) treats batching as first-class, and
`docs/BROADWAY_COMPARISON.md` in this repository lists "Batching" as the single largest
feature gap.

After this initiative, a Shibuya user can opt a processor into batching by supplying a
batch handler and a batch configuration instead of (or in addition to) a per-message
handler. The framework accumulates messages pulled from the inbox into batches, emits a
batch when it reaches a configured size **or** a configured timeout elapses (whichever
comes first), optionally groups messages into independent sub-batches by a **batch key**,
runs the user's batch handler once over the whole batch, resolves exactly one
`AckDecision` for every retained message, and then drives that message's idempotent
`AckHandle.finalize` until it succeeds or a bounded finalization retry policy is
exhausted. A handler can succeed the whole batch, fail individual messages while acking
the rest (partial failure), dead-letter, retry, or halt the processor. The reliability
contract is the point of the whole effort: **no message that enters a batch is ever
silently lost, skipped by the ack-decision loop, double-resolved, or abandoned after an
adapter finalization failure** — not on batch-handler exceptions, not on timeout races,
not on graceful shutdown, not under concurrency. If an adapter's `finalize` keeps
throwing after the bounded retries, the batch processor records the affected
`MessageId`s, marks the processor failed, and halts loudly rather than pretending the
message was acknowledged. This is stated as an explicit, property-tested invariant
because the user needs it for an important production use case.

Concretely, the following will exist that does not exist today: a public
`Shibuya.Batch` API (batch handler type, `BatchInfo`, `BatchConfig`, `BatchKey`,
`BatchTrigger`, and a `BatchAck` result with smart constructors); an internal
accumulation engine that groups the inbox stream into size-or-timeout-or-flush batches
per batch key with guaranteed message-conserving hand-off; an execution stage that runs the
batch handler, resolves one ack decision per retained message, finalizes through the
message's idempotent `AckHandle` with bounded retries and crash isolation, preserves
per-key batch order under concurrent execution, and supports halt; batch-aware metrics
and OpenTelemetry spans; a `BatchingProcessor`
variant of `QueueProcessor` wired through `runApp`/`runSupervised` with graceful-shutdown
flushing of partial batches; a comprehensive reliability test suite (HSpec + QuickCheck)
that proves decision resolution, finalization resilience, and keyed ordering under randomized
schedules; and updated
architecture docs plus a runnable batching example in `shibuya-example`.

In scope: opt-in batching for a single adapter per processor; batch size, batch timeout,
and batch key (multiple concurrent sub-batches keyed by a pure function of the envelope);
per-message ack decisions within a batch; batch-handler exception isolation; bounded
retry and fail-loud behavior for adapter finalization failures; halt within a batch;
graceful-shutdown flush; batch metrics and tracing; per-key serialized batch execution;
reuse of the existing `Concurrency` policy (`Serial`/`Ahead n`/`Async n`) to bound how
many different-key batches run at once.

Explicitly out of scope (to keep the reliability surface tight and reviewable): a
pre-batch per-message transform/routing stage à la Broadway's `handle_message` +
`put_batcher` (v1 routes purely via the pure `batchKey` function; the per-message
`handler` and the batch handler are alternatives, not composed); dynamic runtime
reconfiguration of batch size/timeout; rate limiting; hash-based partition *routing* to
multiple inboxes (that is a separate gap in `BROADWAY_COMPARISON.md`, tracked
independently — this initiative only *reuses* `Envelope.partition` and `batchKey` to
choose accumulation groups and serialize execution within a key, it does not shard the
inbox); and changes to the `Adapter`
interface (batching sits entirely on the consumer side of the existing per-message
`AckHandle`, so no adapter needs to change).


## Decomposition Strategy

The initiative is decomposed by functional concern along the natural seams of the
existing pipeline, with a deliberate split that isolates the two independent reliability
invariants so each can be property-tested on its own: (1) *accumulation correctness* —
every message pulled from the inbox lands in exactly one emitted batch, and batches emit
on the right trigger — and (2) *acknowledgement resolution and finalization resilience* —
every message in an emitted batch receives exactly one resolved `AckDecision`, messages
with the same `BatchKey` are executed in FIFO batch order, and adapter finalization is
retried or surfaced as a processor failure instead of being swallowed. Separating these
means a reviewer can convince themselves of "no message is lost or duplicated during
grouping" without reasoning about handler exceptions, and separately convince themselves
of "every grouped message is acked or fails loudly with evidence" without reasoning about
timers.

There are six child plans grouped into four phases. **Phase 1 (Foundation)** is EP-16,
the pure types and the acknowledgement decision contract — no runtime, so it can be reviewed purely
for API ergonomics and correctness of the smart constructors. **Phase 2 (Runtime core)**
is EP-17 (the accumulation engine: STM accumulators + a timeout ticker + size and flush
triggers, producing a stream of ready batches) and EP-18 (the execution stage: run the
batch handler under exception isolation, resolve the `BatchAck` result onto each retained
message exactly once, drive idempotent finalization with bounded retries, enforce per-key
batch order under concurrency, handle halt, record batch metrics and spans). EP-18 hard-depends
on EP-17 because it consumes the engine's emitted-batch type. **Phase 3 (Integration)**
is EP-19, which adds the `BatchingProcessor` constructor to `QueueProcessor`, threads
batching through `runSupervised`/`runIngesterAndProcessor`, validates batch policies, and
makes graceful shutdown flush pending partial batches. **Phase 4 (Verification & docs)**
is EP-20 (the reliability test suite that proves the acknowledgement/finalization invariant
end-to-end through `runApp`, plus mock batch test helpers) and EP-21 (architecture docs + a runnable
example); these two can proceed in parallel once EP-19 stabilizes the public API.

The guiding principles were: minimize cross-plan coupling (the one genuinely shared,
must-agree artifact — the `BatchAck`/ack-decision contract — is defined once in EP-16 and
only consumed thereafter); maximize independent verifiability (EP-17 and EP-18 each own a
distinct property-tested invariant; EP-16 is unit-testable with no runtime); respect
natural ordering (execution is meaningless without an accumulator to feed it, so EP-17
precedes EP-18; integration is meaningless without an execution stage, so EP-18 precedes
EP-19); and balance scope (no single plan does the bulk of the work — the reliability
weight is spread across EP-17, EP-18, and EP-20).

Alternatives considered and rejected. **One monolithic "batching" ExecPlan** was rejected
because it would exceed five milestones and touch the accumulation engine, ack semantics,
runner wiring, metrics, and tests all at once, making the acknowledgement/finalization
reasoning impossible to review in isolation — the exact failure mode the user is worried about.
**Merging accumulation and execution (EP-17 + EP-18)** was rejected because the two
reliability invariants are genuinely independent and each deserves its own property-test
harness; keeping them apart lets the accumulation engine be fuzzed for message
conservation without any handler in the picture. **Reusing Broadway's positional
"return all messages in order" contract** (batch handler returns `[AckDecision]` zipped
against the input) was rejected in EP-16's design in favor of a `BatchAck` that the
framework applies over *its own* retained list of `Ingested` (keyed by `MessageId` with a
fallback decision), because positional zipping silently loses or misassigns
acknowledgements if the handler returns the wrong length or reorders — unacceptable given
the one-decision-per-retained-message requirement. **A separate metrics ExecPlan** was rejected as too thin;
batch metric *types* are defined and recorded in EP-18 (where the data originates) and
merely exposed in EP-19.


## Exec-Plan Registry

| #  | Title | Path | Hard Deps | Soft Deps | Status |
|----|-------|------|-----------|-----------|--------|
| 16 | Batch API and Configuration Types | docs/plans/16-batch-api-and-configuration-types.md | None | None | Complete |
| 17 | Batch Accumulation Engine | docs/plans/17-batch-accumulation-engine.md | EP-16 | None | Complete |
| 18 | Batch Execution and Exactly-Once Ack | docs/plans/18-batch-execution-and-exactly-once-ack.md | EP-16, EP-17 | None | Complete |
| 19 | Batch Runner and App Integration | docs/plans/19-batch-runner-and-app-integration.md | EP-18 | None | Complete |
| 20 | Batch Reliability Test Suite | docs/plans/20-batch-reliability-test-suite.md | EP-19 | None | Complete |
| 21 | Batch Documentation and Example | docs/plans/21-batch-documentation-and-example.md | EP-19 | EP-20 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-16, EP-17).

Phase grouping: Phase 1 (Foundation) = EP-16; Phase 2 (Runtime core) = EP-17, EP-18;
Phase 3 (Integration) = EP-19; Phase 4 (Verification & docs) = EP-20, EP-21.


## Dependency Graph

The chain is mostly linear because each stage physically consumes the artifact the
previous stage produces, which is the correct shape for a pipeline feature where every
layer sits on top of the one below.

EP-16 has no dependencies. It defines the pure `Shibuya.Batch` types and the
`BatchAck` decision contract. Everything else imports these types, so it must land
first, but it needs nothing itself and is independently unit-testable.

EP-17 hard-depends on EP-16 because the accumulation engine's public signatures mention
`BatchConfig`, `BatchKey`, `BatchInfo`, and `BatchTrigger` — it cannot compile without
them. EP-17 produces the "emitted batch" value (`(BatchInfo, NonEmpty (Ingested es msg))`)
and guarantees each ingested message is emitted exactly once. It deliberately does **not**
call the batch handler or any `AckHandle`, so it is verifiable purely as a stream
transformer.

EP-18 hard-depends on EP-16 (for `BatchAck` and `BatchInfo`) and on EP-17 (it consumes the
emitted-batch stream EP-17 produces). It cannot be built or meaningfully tested until the
engine exists, because its whole job is to turn an emitted batch into one decision per
retained message plus confirmed or loudly failed finalization. This is the strictest
ordering constraint in the initiative.

EP-19 hard-depends on EP-18 because it wires the execution stage into the supervised
runner and the public `QueueProcessor`/`runApp` API. Transitively it needs EP-16 and
EP-17, but EP-18 is the direct artifact it mounts. Nothing else can proceed to a
user-visible feature until EP-19 exposes the `BatchingProcessor` constructor.

EP-20 hard-depends on EP-19 because the end-to-end reliability tests drive the full
`runApp` path with a batching processor; the invariant it proves only becomes observable
once the runner is wired. EP-21 hard-depends on EP-19 for the same reason (the example and
docs describe the public API EP-19 finalizes) and soft-depends on EP-20 (the docs should
cite the reliability guarantees the test suite establishes, but can be drafted against the
API before the tests are green).

Parallelism: within Phase 2, EP-18 cannot start until EP-17 is complete, so the two are
sequential despite sharing a phase. The genuine parallel opportunity is Phase 4: once
EP-19 stabilizes the public types, EP-20 (tests) and EP-21 (docs + example) can be worked
concurrently by different sessions, reconciling only on the exact spelling of the public
API.


## Integration Points

The BatchAck ack-decision and finalization contract. Involved: EP-16 (defines), EP-18 (consumes), EP-20
(asserts). The shared artifact is the `BatchAck` type and its documented semantics: given
an emitted batch of messages and the handler's returned `BatchAck`, the framework resolves
**one** `AckDecision` for **each** message in its own retained list, looking the message's
`MessageId` up in `BatchAck`'s decision map and applying the `BatchAck` fallback decision
for any message not explicitly listed. EP-16 is responsible for defining the type, the
smart constructors (`ackAllOk`, `ackAll`, `ackExcept`, `failMessages`), and writing the
decision-resolution semantics down in the module haddock as the normative spec. EP-18 must
iterate its own `NonEmpty (Ingested es msg)` (never the handler's output), then call each
message's idempotent `AckHandle.finalize` with bounded retries. If all finalization
attempts for a message fail, EP-18 records the `MessageId`, marks the processor failed,
sets a fatal halt, and continues attempting the rest of the batch before surfacing the
failure. EP-20 asserts both the one-decision-per-message invariant and the retry/fail-loud
finalization behavior with property and scenario tests. This is the one artifact where a
silent disagreement would break the core guarantee, so all three plans quote the same
contract text verbatim.

The emitted-batch type. Involved: EP-17 (defines/produces), EP-18 (consumes). The shared
artifact is the value the accumulation engine hands downstream — specified as
`(BatchInfo, NonEmpty (Ingested es msg))`, where `BatchInfo` (from EP-16) carries the
batch key, final size, trigger, and optional partition. EP-17 owns the exact type and the
guarantee that the `NonEmpty` list contains each source message at most once and that
across the whole run every source message appears in exactly one emitted batch. EP-18
consumes it read-only. If EP-17 needs to enrich the type (for example to thread an
internal batch sequence number for metrics), it updates this section and EP-18's plan.

The QueueProcessor / App public API. Involved: EP-19 (defines), EP-20 (tests against),
EP-21 (documents and demonstrates). The shared artifact is the new `BatchingProcessor`
constructor of the existential GADT `QueueProcessor es` in `shibuya-core/src/Shibuya/App.hs`
and the `mkBatchProcessor` smart constructor, plus any re-exports from `Shibuya.Batch`.
EP-19 defines the exact field names and order; EP-20 and EP-21 must match them precisely.
Because `QueueProcessor` is pattern-matched positionally in `spawnProcessors`
(`App.hs:206-210`) and `stopAppGracefully` (`App.hs:257`), EP-19 must update every existing
match site; this section records that those two call sites are the ones to change.

Processor metrics. Involved: EP-18 (defines and records batch metric fields), EP-19
(exposes them through `getAppMetrics`), EP-20 (asserts them). The shared artifact is the
extension of `ProcessorMetrics`/`StreamStats` in
`shibuya-core/src/Shibuya/Runner/Metrics.hs` with batch counters (batches emitted, total
batched messages, partial-failure count, and per-trigger counts). EP-18 owns the field
additions and their JSON encoding (the module hand-writes some `ToJSON`/`FromJSON`
instances, so any new field must be added to both directions); EP-19 and EP-20 consume
them. The pre-existing but unused `dropped` counter in `StreamStats` is available for
batch-drop accounting if needed.

Concurrency policy reuse with per-key serialization. Involved: EP-16/EP-18 (interpret it for batch execution), EP-19
(validates it). The shared artifact is the existing `Concurrency` type
(`Serial | Ahead Int | Async Int`) in `shibuya-core/src/Shibuya/Policy.hs`, reused to bound
how many *different-key batches* run concurrently rather than how many messages. EP-18 owns
a keyed scheduler: batches with the same `BatchInfo.batchKey` must run one at a time in
emission order, while batches with different keys may run concurrently up to the selected
bound. EP-19 owns any
extension to `validatePolicy` for batching (for example, deciding whether
`StrictInOrder` + batching is permitted and, if so, forcing `Serial` batch execution). The
interpretation of each mode for batches (Serial = one batch at a time in emission order;
Ahead n = bounded concurrent execution that preserves per-key FIFO and waits for earlier
emitted batches before reporting drain; Async n = bounded concurrent execution that still
preserves per-key FIFO but does not preserve cross-key completion order) is documented in
EP-18 and must match EP-19's validation.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-16: `Shibuya.Batch` types compile and are exported (BatchKey, BatchTrigger, BatchInfo, BatchConfig, BatchHandler, BatchAck) (2026-07-01)
- [x] EP-16: Smart constructors + `validateBatchConfig` with unit tests green (2026-07-01)
- [x] EP-17: STM accumulator groups inbox stream by batch key with size trigger (2026-07-01)
- [x] EP-17: Timeout ticker and shutdown flush triggers, with message-conservation property tests green (2026-07-01)
- [x] EP-18: Batch handler invocation with exception isolation, one decision per retained message, and resilient finalization (2026-07-01)
- [x] EP-18: Halt-in-batch handling + batch metrics/tracing spans (2026-07-01)
- [x] EP-19: `BatchingProcessor` constructor + `mkBatchProcessor`, threaded through `runSupervised` (2026-07-01)
- [x] EP-19: Batch policy validation + graceful-shutdown flush of pending batches (2026-07-01)
- [x] EP-20: End-to-end decision/finalization property test through `runApp` (randomized sizes/timeouts/failures) (2026-07-01)
- [x] EP-20: Timeout, partial-failure, halt, and drain-flush scenario tests + mock batch harness (2026-07-01)
- [x] EP-21: Architecture docs updated (MESSAGE_FLOW, CORE_TYPES, METRICS, BROADWAY_COMPARISON) + README (2026-07-01)
- [x] EP-21: Runnable batching example in `shibuya-example` (2026-07-01)


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

Frozen public/shared signatures (2026-07-01, after drafting all six child plans). During
drafting the child plans independently proposed slightly different spellings for the shared
seams; these are the reconciled, authoritative signatures. All child plans must match them
verbatim; EP-20 was corrected to conform.

```haskell
-- Smart constructor (Adapter first, config last — matches existing mkProcessor):
mkBatchProcessor :: Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es

-- New GADT constructor on QueueProcessor (App.hs):
BatchingProcessor :: { adapter :: Adapter es msg, batchHandler :: BatchHandler es msg,
                       batchConfig :: BatchConfig es msg, ordering :: Ordering,
                       concurrency :: Concurrency } -> QueueProcessor es

-- Accumulation engine output (EP-17 produces, EP-18 consumes):
type ReadyBatch es msg = (BatchInfo, NonEmpty (Ingested es msg))
runBatcher :: Natural -> BatchConfig es msg
           -> Streamly.Data.Stream.Stream IO (Ingested es msg)
           -> Streamly.Data.Stream.Stream IO (ReadyBatch es msg)  -- (exact IO/Eff boundary per EP-17)

-- Execution stage (EP-18):
processBatchesUntilDrained :: (IOE :> es, Tracing :> es)
  => TVar ProcessorMetrics -> ProcessorId -> Concurrency -> BatchHandler es msg
  -> Streamly.Data.Stream.Stream IO (ReadyBatch es msg) -> IORef (Maybe HaltReason) -> Eff es ()

-- Runner wiring (EP-19; note Adapter BEFORE BatchHandler, mirroring runWithMetrics):
runSupervisedBatch  :: Master -> Natural -> ProcessorId -> Concurrency
                    -> BatchConfig es msg -> Adapter es msg -> BatchHandler es msg -> Eff es SupervisedProcessor
runWithMetricsBatch :: Natural -> ProcessorId -> Concurrency
                    -> BatchConfig es msg -> Adapter es msg -> BatchHandler es msg -> Eff es SupervisedProcessor
```

Batch metrics live in a NEW record, not on `StreamStats`. EP-18 adds
`data BatchStats = BatchStats { batchesEmitted, batchedMessages, partialFailures,
sizeTriggered, timeoutTriggered, flushTriggered :: !Int }` (Generic-derived JSON) and a
field `batch :: !BatchStats` on `ProcessorMetrics`, accessed as `metrics.batch.batchedMessages`.
Per-message `processed`/`failed` REMAIN on `StreamStats` (`metrics.stats.processed`) so the
single-message and batch paths report those consistently. `partialFailures` is defined
per-batch (a batch counts once if any of its messages received a non-fallback failing
decision), not per-message. Evidence: EP-18 lines ~492-573 define the record and helpers;
EP-20 originally asserted `metrics.stats.batchedMessages` and was corrected to
`metrics.batch.batchedMessages`.

Batch runner modules are EXPOSED, not internal. Unlike `Runner.Ingester`/`Runner.Halt`
(which are `other-modules`), both `Shibuya.Runner.Batcher` (EP-17) and
`Shibuya.Runner.BatchProcessor` (EP-18) go in the library `exposed-modules` so their own
test specs can import them directly. This is consistent with the already-exposed
`Runner.Supervised`/`Runner.Master`/`Runner.Metrics`. This supersedes the "internal
other-module" phrasing in the shared design context; EP-17 was reconciled to drop an
`hs-source-dirs`-hack testing approach in favor of exposing the module.

Accumulation engine refined the "atomic STM move" (EP-17). The shared design said "remove
the accum from the map AND enqueue the ready batch in one atomic STM transaction." EP-17
refined this to a single-mutex (`MVar`) critical section that atomically removes the map
entry and then enqueues items, because a single timeout scan can emit more batches than a
bounded output queue's capacity, which would deadlock one all-in-one STM transaction. The
no-double-emit guarantee still rests solely on the atomic map removal. This refinement is
compatible with EP-18 (which just consumes the emitted-batch stream).

Batch finalization is retry-then-fail-loud, not best-effort. EP-18 must not swallow an
adapter-level `AckHandle.finalize` exception and continue as if the message had been
acknowledged. It resolves each message's `AckDecision` once, then calls the message's
idempotent finalizer with a small bounded retry schedule. If a message still cannot be
finalized, EP-18 records the failed `MessageId`, marks the processor failed, sets a fatal
halt, and continues attempting the remaining messages before surfacing the failure. This
leans on the existing `AckHandle` contract that adapters enforce idempotency and gives the
operator a visible failure instead of silent unacknowledged work.

Batch execution is keyed. EP-17 only guarantees per-key accumulation order; EP-18 must
preserve that order when running batch handlers. Under `Ahead n` and `Async n`, batches for
different `BatchKey`s may run concurrently up to the configured bound, but a later batch
for key `k` cannot start until the previous emitted batch for key `k` has finished
finalization. This resolves the earlier ambiguity where global Streamly concurrency could
overlap same-key batches.

Halt during a batch is drain-on-halt, and requires no special handling in the batcher. When
a batch handler resolves any message to `AckHalt`, EP-18 sets the shared
`IORef (Maybe HaltReason)` after finalizing that whole batch (not throwing). The batcher
(EP-17) reads its input from `inboxToStream`, which already checks that same `IORef` and
stops yielding once halt is set, so the batcher simply hits end-of-input, flushes any
accumulated partial batches as `TriggerFlush`, and EP-18 finalizes those too. Consequence:
messages already pulled into accumulators before the halt are still processed — consistent
with the single-message path letting in-flight messages finish before the processor exits.

Latent parity issue inherited by the batch path (EP-19). On `ProcessorHalt` the existing
single-message runner leaves the `done` TVar unset, so `waitApp` would block after a halt.
The batch runner deliberately mirrors this parity rather than silently diverging. EP-20's
reliability suite may choose to address it; recorded here so it is not mistaken for a
batch-specific regression.

Test-suite gained `containers` + `DataKinds` while implementing EP-16 (2026-07-01). The
`shibuya-core-test` suite did not previously depend on `containers` and did not enable
`DataKinds`. Implementing EP-16's `BatchSpec` required both: `containers` for
`Data.Map.Strict` in the spec, and `DataKinds` for the concrete `BatchConfig '[] Int`
helper that pins the phantom `es` parameter so config fields can be read unambiguously.
Both are now in place in `shibuya-core/shibuya-core.cabal`, so EP-17's and EP-20's specs
(which also use `Data.Map`/`Data.List.NonEmpty` and concrete effect lists) inherit them and
need not re-add them. Also note: `Shibuya.Prelude` does not re-export `IsString` (import it
explicitly), and `AckDecision`/`BatchAck` fields are strict (test fixtures must use concrete
`RetryDelay`/decision values, never `undefined`).

Halt-throw seam resolved: EP-18 sets, EP-19 throws (2026-07-01, affects EP-20). As
implemented, EP-18's `processBatchesUntilDrained` only *sets* the shared
`IORef (Maybe HaltReason)` and returns normally — it does not throw `ProcessorHalt`. Only
EP-18's standalone test driver `runBatchesWithMetrics` reads the ref and throws. EP-19's
`runIngesterAndProcessorBatch` therefore performs the read-and-throw itself
(`readIORef haltRef >>= maybe (pure ()) (throwIO . ProcessorHalt)`) right after
`processBatchesUntilDrained` returns, inside `runInIO` and before the ingester poll, mirroring
the single-message `processUntilDrained`. Consequence for EP-20: to observe a halt end-to-end,
drive `runApp`/`runWithMetricsBatch` (which throw) — a bare `processBatchesUntilDrained` call
will not throw, it only leaves the halt reason in the ref. The `runSupervisedBatch` child
catches `ProcessorHalt` and exits gracefully (parity with the single-message runner, including
leaving `done` unset on halt).

Test specs that build `Ingested` values must pin the empty effect stack's kind (EP-17,
2026-07-01, affects EP-18 and EP-20). A top-level signature written as
`... :: BatchConfig '[] String -> ...` makes GHC kind-generalize `'[]` to a fresh kind
variable, which then fails to unify with the `[Effect]`-kinded `'[]` that
`Ingested '[] msg` forces through `AckHandle`'s `Eff es`. The fix used in
`shibuya-core/test/Shibuya/Runner/BatcherSpec.hs` is to `import Effectful (Effect)` and
define `type E = ('[] :: [Effect])`, then write `Ingested E String`, `BatchConfig E String`,
etc. EP-16's `BatchSpec` avoided this only because its `cfg :: BatchConfig '[] Int` never
meets an `Ingested`. EP-18's `BatchProcessorSpec` and EP-20's reliability specs, which build
`Ingested` fixtures, must reuse this `type E = ('[] :: [Effect])` alias. (EP-17's
`runBatcher` signature itself is unaffected — it is polymorphic in `es`.)

`getAppMetrics` returns nothing for a finished/halted processor (EP-20/EP-21). The precise
mechanism (confirmed while writing EP-20): every processor calls
`unregisterProcessor master procId` in its `finally` when its runner returns — normally or via
a caught `ProcessorHalt` — and `unregisterProcessor` does `Map.delete` on the Master's registry
(`Shibuya.Runner.Master` ~line 157). Since `getAppMetrics` reads that registry, it yields an
empty entry for any processor that has completed or halted. Two consequences: (a) EP-21's
runnable example cannot read post-flush batch counters through `getAppMetrics` after `stopApp`
(it demonstrates flush via the handler's own console output instead); (b) EP-20's tests read
metrics directly from the persistent `SupervisedProcessor.metrics` TVar via the `AppHandle`
(`app.processors`) — a `metricsFor app pid` helper — which survives unregistration and holds
the final metrics. If a metrics-read-before-unregister path is later exposed, both can be
strengthened.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Decompose batching into six child plans (EP-16..EP-21) across four phases,
  splitting accumulation (EP-17) from execution/ack (EP-18).
  Rationale: The two reliability invariants — message conservation during grouping, and
  one-decision-per-retained-message acknowledgement with resilient finalization — are
  independent and each warrants its own property-test harness. A single monolithic plan
  would make the acknowledgement/finalization reasoning impossible to review in isolation,
  which is precisely the risk the user flagged ("super reliable ... important use case").
  Date: 2026-07-01

- Decision: The batch handler returns a `BatchAck` (per-`MessageId` decision map + a
  fallback decision) rather than a positional `[AckDecision]` aligned to the input order.
  Rationale: Positional zipping silently loses or misassigns acknowledgements if the
  handler returns the wrong-length list or reorders messages. Instead the framework
  resolves each message's decision from *its own retained* `NonEmpty (Ingested es msg)` list,
  looking each message up by `MessageId` and applying the fallback for any not listed, so
  one-decision-per-retained-message holds regardless of handler behavior. Requires unique
  `MessageId` within a batch (documented; already true for all real adapters and the mock).
  Date: 2026-07-01

- Decision: v1 batching is batch-handler-only; the per-message `handler` and the batch
  handler are alternatives, not composed. Routing is done by a pure
  `batchKey :: Envelope msg -> BatchKey` in `BatchConfig`, not a Broadway-style
  `handle_message` + `put_batcher` pre-stage.
  Rationale: Keeps the reliability surface small and reviewable. A pre-batch transform
  stage is a natural follow-up but adds a second ack path (early-ack in the per-message
  stage vs batch-ack) that complicates the acknowledgement/finalization proof. Deferred, noted as
  out-of-scope in Vision & Scope.
  Date: 2026-07-01

- Decision: Reuse the existing `Concurrency` type (`Serial`/`Ahead n`/`Async n`) to bound
  concurrent *batches* instead of adding a new batch-concurrency knob; use a single
  timeout *ticker* thread that scans accumulators rather than one OS/registerDelay timer
  per batch key.
  Rationale: Reusing `Concurrency` keeps the policy model unified and the
  `validatePolicy` story consistent. A single scanning ticker (flush latency bounded by
  the tick interval) is far simpler to make correct in STM than dynamically selecting over
  N per-key timers, and Broadway's per-key erlang timers are an implementation detail, not
  a semantic guarantee — bounded-latency flushing satisfies the `batch_timeout` contract.
  Date: 2026-07-01

- Decision: No change to the `Adapter` interface; batching sits on the consumer side of
  the existing per-message `AckHandle`.
  Rationale: Each `Ingested` already carries its own `finalize`, which supports
  heterogeneous per-message outcomes within one batch. This means no existing adapter
  (pgmq, kafka, kiroku, mock) needs modification, dramatically shrinking blast radius.
  Date: 2026-07-01

- Decision: Adapter finalization failures are handled with bounded retries and then a
  fatal processor halt, never by silent best-effort continuation.
  Rationale: The user explicitly needs production-grade reliability. `AckHandle.finalize`
  is effectful and can throw, so the architecture cannot honestly promise that every
  message is acknowledged unless it defines what happens when the adapter finalizer fails.
  Retrying uses the existing adapter idempotency contract; halting after exhaustion makes
  the failure observable and prevents the framework from reporting success for a message
  whose acknowledgement was not confirmed.
  Date: 2026-07-01

- Decision: Batch execution preserves FIFO order within each `BatchKey` even when global
  batch concurrency is enabled.
  Rationale: `batchKey` is meaningful only if it is more than an accumulation bucket. If
  two same-key batches can run concurrently, downstream writes for a tenant, partition, or
  stream can be reordered. A keyed scheduler keeps the reliability contract simple:
  concurrency is across keys, never within a key.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

All six exec-plans complete (2026-07-01). First-class batch processing shipped end to end,
matching the Vision & Scope. What now exists that did not before:

- **EP-16** — the public `Shibuya.Batch` API: `BatchKey`, `BatchTrigger`, `BatchInfo`,
  `BatchConfig`, `BatchHandler`, `BatchAck` + smart constructors (`ackAllOk`, `ackAll`,
  `ackExcept`, `withFallback`, `failMessages`), and `validateBatchConfig`. The
  one-decision-per-retained-message contract is written down as the normative haddock spec.
- **EP-17** — `Shibuya.Runner.Batcher`: a pure, deterministic accumulation core
  (`stepArrival`/`stepTick`/`stepFlush`) plus the `runBatcher` IO engine (single timeout
  ticker, `MVar`-serialized hand-off, bounded `TBQueue` for backpressure, EOF flush). Message
  conservation is property-tested with no threads.
- **EP-18** — `Shibuya.Runner.BatchProcessor`: runs the handler under exception isolation,
  resolves exactly one `AckDecision` per retained message, drives idempotent finalization with
  a bounded `[10ms,50ms,250ms]` retry schedule and fail-loud on exhaustion, a keyed STM
  scheduler for per-key FIFO under `Ahead`/`Async`, halt-sets-flag semantics, and the
  `BatchStats` metrics record + batch tracing attributes/events.
- **EP-19** — the `BatchingProcessor` GADT constructor + `mkBatchProcessor`, threaded through
  `runSupervisedBatch`/`runWithMetricsBatch`/`runIngesterAndProcessorBatch`, batch-config
  validation (`AppBatchConfigError`), and graceful-shutdown flush of pending partial batches.
- **EP-20** — the reliability suite: a 50-run QuickCheck exactly-once-finalization property
  through the real `runApp` path plus ten scenario tests (timeout, partial failure, handler
  exception, transient-finalizer retry, permanent fail-loud, halt-with-isolation, drain flush,
  multi-key, per-key FIFO under `Async`, backpressure liveness) and the reusable
  `mkTrackedIngested`/`trackedListAdapter`/`finalizedExactlyOnce` harness. Shown non-vacuous by
  a double-finalize perturbation.
- **EP-21** — a runnable `shibuya-batch-example` and updated architecture docs
  (MESSAGE_FLOW, CORE_TYPES, METRICS, BROADWAY_COMPARISON) + README; Broadway's "single largest
  feature gap" is closed.

Final verification: `cabal build all` green; `cabal test shibuya-core-test` = 161 examples, 0
failures; no compiler warnings; `nix fmt` clean; `cabal run shibuya-batch-example` reproduces
the documented transcript.

The reliability contract in the Vision held under test: no message that enters a batch is lost,
skipped, double-resolved, or silently abandoned — including on handler exceptions, timeout and
shutdown flushes, and under concurrency across keys; adapter finalization failures are retried
and, if permanent, surfaced loudly with the affected `MessageId`.

Decomposition retrospective. The six-plan split held up: the accumulation invariant (EP-17) and
the acknowledgement/finalization invariant (EP-18) were each property-tested in isolation, and
the one genuinely shared artifact (`BatchAck`) was defined once (EP-16) and only consumed
thereafter. The linear dependency chain matched reality — each stage physically consumed the
previous stage's artifact — so no plan started before its inputs existed. The main
cross-plan reconciliations discovered during implementation (all recorded in Surprises &
Discoveries): the halt-throw seam moved from EP-18 (sets `haltRef`) to EP-19 (reads it and
throws); `getAppMetrics` is empty for a completed/halted processor (processors unregister in
their `finally`), so tests read the persistent `SupervisedProcessor` TVar; test specs building
`Ingested` values must pin the empty effect stack's kind (`type E = ('[] :: [Effect])`); and
EP-21's docs use the shipped `BatchStats` field names (`sizeTriggered`/`timeoutTriggered`/
`flushTriggered`).

Known gaps / deferred (as scoped): no pre-batch `handle_message` + `put_batcher` transform
stage (routing is purely by `batchKey`); no dynamic runtime reconfiguration of batch
size/timeout; no hash-based partition routing to multiple inboxes. One latent parity issue is
carried, not fixed: on `ProcessorHalt` the batch runner (like the single-message runner) leaves
`done` unset, so `waitApp`/`waitForDrainWithTimeout` block until the drain timeout after a halt
— EP-20's halt/permanent-failure scenarios use a short `drainTimeout` to accommodate this.


## Revision Notes

- 2026-07-01: Strengthened the architecture review findings into the plan. The master
  contract now distinguishes one-time ack-decision resolution from idempotent
  finalization attempts, requires bounded retry/fail-loud behavior on adapter finalizer
  failures, requires per-key serialized batch execution under concurrent modes, and
  reconciles `runBatcher` to EP-17's `Natural -> BatchConfig -> Stream -> Stream`
  signature.
