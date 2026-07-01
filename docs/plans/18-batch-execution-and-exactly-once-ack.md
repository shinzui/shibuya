---
id: 18
slug: batch-execution-and-exactly-once-ack
title: "Batch Execution and Exactly-Once Ack"
kind: exec-plan
created_at: 2026-07-01T15:34:31Z
intention: "intention_01kwf4q2bke2js9t0js53dwh5a"
master_plan: "docs/masterplans/3-first-class-batch-processing.md"
---

# Batch Execution and Exactly-Once Ack

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is the third child plan of the MasterPlan at
`docs/masterplans/3-first-class-batch-processing.md` ("First-Class Batch Processing"). It is
the **reliability heart** of the initiative: it takes a stream of already-grouped batches and
turns each one into acknowledgements that fire **exactly once per message**, no matter what
the user's batch handler does or how it fails.


## Purpose / Big Picture

Shibuya is a Haskell queue-processing framework. A "processor" pulls messages off a queue
(via an adapter), hands each one to a user function, and then acknowledges the message so the
queue knows it is done. Today that happens one message at a time. The sibling plans in this
initiative add *batching*: instead of one message, the framework accumulates a group of
messages and hands the whole group to a **batch handler** so the user can, for example,
insert 500 database rows in one statement instead of 500 separate round trips.

Two independent reliability problems arise when you batch. The first — *did every message
land in exactly one group?* — is solved by the accumulation engine
(`docs/plans/17-batch-accumulation-engine.md`, "EP-17"), which produces a stream of ready
batches. The second — *does every message in a group receive exactly one acknowledgement
decision, with that decision either confirmed by finalization or surfaced as a loud
finalization failure?* — is the subject of **this** plan ("EP-18"). We deliberately keep
these two problems in separate plans so each can be reasoned about and tested on its own.

After this plan, the codebase contains a new module,
`shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`, that consumes the ready-batch stream
EP-17 produces and, for each batch: opens an OpenTelemetry span (a timed, attributed record
of the work, sent to a tracing backend such as Jaeger); runs the user's batch handler under
exception isolation; resolves exactly one acknowledgement decision for every retained
message; and then drives each message's idempotent acknowledgement finalizer with bounded
retries. To "finalize" a message means to call that message's own acknowledgement function
(`ingested.ack.finalize`) with the resolved decision — acknowledge-OK, retry, dead-letter,
or halt. If an adapter finalizer keeps throwing after the retry budget, this stage records
the affected `MessageId`, marks the processor failed, sets a fatal halt, and still attempts
the rest of the batch before surfacing the failure. The plan also extends the metrics record
with batch counters and wires batch execution to the existing concurrency policy so
different batch keys can run concurrently while batches for the same key remain serialized.

You can see it working by running the new unit tests (`cabal test shibuya-core-test`), which
construct a batch of five in-memory messages, run a handler that deliberately fails two of
them (and, in further scenarios, one that throws an exception, and one that halts), and then
assert — using a tracking acknowledgement handle that records successful finalize calls —
that **each of the five message ids appears exactly once** in that successful-finalization
list, with the expected decision, and that the batch metrics counters advanced correctly.
Additional tests use a deliberately flaky `AckHandle` to prove transient finalizer failures
are retried and permanent finalizer failures halt loudly with the failed message id recorded.

This plan does **not** wire batching into the public `runApp`/`QueueProcessor` API; that is
the next plan, `docs/plans/19-batch-runner-and-app-integration.md` ("EP-19"). EP-18 delivers
a self-contained, independently testable batch-execution function plus the metrics extensions
that EP-19 will mount.


## Progress

- [x] Extend `shibuya-core/src/Shibuya/Runner/Metrics.hs`: add `BatchStats` record, `emptyBatchStats`, a `batch :: !BatchStats` field on `ProcessorMetrics`, initialize it in `emptyProcessorMetrics`, and add increment helpers (`incBatchesEmitted`, `addBatchedMessages`, `incPartialFailures`, `incSizeTriggered`, `incTimeoutTriggered`, `incFlushTriggered`). Export all of them. (2026-07-01)
- [x] Extend `shibuya-core/src/Shibuya/Telemetry/Semantic.hs`: add batch attribute keys (`attrShibuyaBatchKey`, `attrShibuyaBatchSize`, `attrShibuyaBatchTrigger`) and batch event names (`eventBatchStarted`, `eventBatchCompleted`). Export them. (2026-07-01)
- [x] Create `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs` with `processOneBatch`, `finalizeWithRetry`, `processBatchesUntilDrained`, and the test driver `runBatchesWithMetrics`. (2026-07-01)
- [x] Implement keyed batch scheduling so `Ahead n`/`Async n` run different keys concurrently but never overlap two batches with the same `BatchKey`. (2026-07-01)
- [x] Add finalization-failure handling: transient finalizer exceptions are retried; exhausted retries mark the processor failed and surface a fatal halt after the batch's remaining messages are attempted. (2026-07-01)
- [x] Add `Shibuya.Runner.BatchProcessor` to the library `exposed-modules` in `shibuya-core/shibuya-core.cabal`. (2026-07-01)
- [x] Create `shibuya-core/test/Shibuya/Runner/BatchProcessorSpec.hs` with the M1 and M2 scenarios; register it in the test-suite `other-modules` and wire it into `shibuya-core/test/Main.hs`. (2026-07-01)
- [x] `cabal build shibuya-core` and `cabal test shibuya-core-test` both green (147 examples, 0 failures; no warnings). (2026-07-01)
- [x] `nix fmt` leaves the tree clean. (2026-07-01)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The module listing in Concrete Steps indented `haltReasonText` and `tshow` as if they were
  inside a `where` block (lines ~984-989), but they are top-level helpers used by both
  `processOneBatch` and `recordBatchOutcome`. Implemented them at top level; no behavioral
  change.

- Two imports the listing named were redundant under `-Wall` in this GHC (9.12.4 / base 4.21):
  `Data.List (foldl')` — `foldl'` is re-exported by the implicit `Prelude` now — and
  `MessageId` from `Shibuya.Core.Types`, which is only needed at type level via `Envelope`
  and `Map` and so is imported without being named. Both were dropped to keep the build
  warning-free, exactly as the plan's Idempotence/Recovery note anticipated.

- `BatchKey` lives in `Shibuya.Batch`, not `Shibuya.Core.Types`; the test spec must import it
  from `Shibuya.Batch (BatchKey (..))`. (An initial draft imported it from `Core.Types` and
  failed to resolve.)

- The test spec's local `AckHandle`-typed helpers (`flakyAckHandle`, `alwaysFailAckHandle`)
  carry `(IOE :> es)` constraints, so the test module must add `(:>)` to its `Effectful`
  import list (`import Effectful (..., (:>))`). The batch fixtures here are built inside a
  concrete `runEff $ runTracingNoop $ do ...` block, so — unlike EP-17's `BatcherSpec` — no
  `type E = ('[] :: [Effect])` kind alias is needed; `es` is inferred concretely.


## Decision Log

Record every decision made while working on the plan.

- Decision: Decision resolution iterates the framework's **own retained**
  `NonEmpty (Ingested es msg)` list, never the handler's returned value. For each retained
  message we compute
  `Data.Map.Strict.findWithDefault batchAck.fallback ingested.envelope.messageId batchAck.decisions`
  exactly once, then pass that resolved decision to the message's idempotent
  `ingested.ack.finalize` through bounded retries.
  Rationale: This is the core guarantee. The handler's `BatchAck` only *supplies*
  decisions; it never *drives which* messages are acked. A handler that returns a
  wrong-length, reordered, empty, or bogus decision map cannot cause a message to be skipped
  or assigned another message's decision, because the loop is over the retained list, keyed
  by identity, with a fallback for anything unlisted. Finalization itself is effectful and
  can fail; retrying relies on the existing `AckHandle` idempotency contract, and exhausted
  retries must halt loudly rather than pretending the message was acknowledged. Quoted from
  the MasterPlan Integration Points and from
  `docs/plans/16-batch-api-and-configuration-types.md` ("EP-16").
  Date: 2026-07-01

- Decision: If the batch handler throws any exception, the whole batch is finalized with the
  substituted default `ackAll (AckRetry (RetryDelay 0))` — every message retried with zero
  delay (redelivered by the adapter, no data loss) — and the exception is recorded on the
  span. This default is not user-configurable in v1. Encodes MasterPlan Decision #6.
  Rationale: On a crash we cannot trust any partial result the handler may have produced, so
  the safe universal action is "make the queue redeliver the whole batch". Retrying loses no
  data (the adapter re-emits unacked messages) whereas dead-lettering or dropping would.
  Date: 2026-07-01

- Decision: Each individual `ingested.ack.finalize` call is isolated and retried with a
  small bounded retry schedule (`[10ms, 50ms, 250ms]` after the initial attempt). If all
  attempts fail, record the exception and `MessageId`, continue attempting the remaining
  messages, then mark the processor failed and set a fatal halt after the batch is fully
  attempted.
  Rationale: One adapter hiccup must not abort the rest of the batch (which would leave
  later messages unattempted), and a transient adapter failure should not cause redelivery
  when a retry would confirm the ack. Silent best-effort continuation is not reliable
  enough for this feature: after retries are exhausted the operator must see a processor
  failure with the affected message ids. Multiple finalizer calls are acceptable here
  because `AckHandle` is documented as adapter-idempotent; the acknowledgement property is one
  resolved decision and one confirmed finalization, not one physical function call in the
  presence of adapter exceptions.
  Date: 2026-07-01

- Decision: On `AckHalt`, EP-18 does **not** throw. After fully finalizing the batch it sets a
  shared `IORef (Maybe HaltReason)` via `atomicWriteIORef` and lets the stream drain; the
  caller (EP-19's runner, or the test driver) reads the `IORef` after draining and throws
  `ProcessorHalt`.
  Rationale: Mirrors the single-message path (`processOne` in
  `shibuya-core/src/Shibuya/Runner/Supervised.hs`), which sets a halt flag rather than
  throwing so in-flight work completes cleanly before shutdown. Throwing mid-batch could
  abandon un-finalized messages.
  Date: 2026-07-01

- Decision: Batch metrics are added by extending `ProcessorMetrics` with a new
  Generic-derived `BatchStats` record (a `batch` field), not by editing the hand-written JSON
  for `ProcessorState`.
  Rationale: `ProcessorState` has hand-written `ToJSON`/`FromJSON` (a tagged sum), so adding
  data there would mean editing both directions by hand. `StreamStats`, `ProcessorMetrics`,
  and the new `BatchStats` derive their JSON via `Generic`, so the field/record additions add
  a JSON key automatically — no hand-written instance to keep in sync.
  Date: 2026-07-01

- Decision: `partialFailures` counts **batches** (not individual messages): it increments by 1
  for each emitted batch in which the handler returned normally *and* at least one message's
  resolved decision came from the per-message `decisions` map (not the fallback) and was a
  failing decision (`AckDeadLetter` or `AckRetry`).
  Rationale: A "partial failure" is the event of a batch that was not uniformly acknowledged —
  the handler singled out some records to fail while acking the rest (via `ackExcept` /
  `failMessages`). Counting per batch keeps this a distinct operational signal (how often do
  batches partially fail) that does not double-count against the per-message `processed` /
  `failed` counters in `StreamStats`. Whole-batch failures driven by the fallback (including
  the exception-substituted retry) are *not* partial failures and do not increment this
  counter.
  Date: 2026-07-01

- Decision: A handler exception marks each message `failed` in per-message stats but does
  **not** put the processor into the `Failed` state; only `AckHalt` sets `Failed`.
  Rationale: An exception triggers a recoverable whole-batch redeliver, so the processor keeps
  running; leaving it in `Idle`/`Processing` reflects reality. `AckHalt` is an intentional,
  terminal stop and is surfaced as `Failed` with the halt reason, matching
  `decrementAndUpdate` in the single-message path.
  Date: 2026-07-01

- Decision: Place `Shibuya.Runner.BatchProcessor` in the library `exposed-modules`, not
  `other-modules`.
  Rationale: The in-package HSpec test-suite cannot import a library `other-modules` module.
  Exposing it (like `Shibuya.Runner.Supervised` and `Shibuya.Runner.Metrics`, which are also
  exposed and imported by tests) lets `BatchProcessorSpec` import `runBatchesWithMetrics`
  directly. EP-19 may import it directly too.
  Date: 2026-07-01

- Decision: `processBatchesUntilDrained` uses a keyed scheduler rather than raw
  `StreamP.parMapM` over the ready-batch stream.
  Rationale: Raw global concurrency can overlap two batches with the same `BatchKey`, which
  reorders tenant/partition-local downstream writes. The scheduler must preserve FIFO
  execution for each key while allowing different keys to run concurrently up to the
  existing `Concurrency` bound.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare
the result against the original purpose.

Completed 2026-07-01. Both milestones landed as designed. `Shibuya.Runner.BatchProcessor`
(exposed) provides `processOneBatch`, `processBatchesUntilDrained`, `runBatchesWithMetrics`,
and the internal `finalizeWithRetry` plus the keyed STM scheduler
(`runKeyedBatchScheduler`). `Shibuya.Runner.Metrics` gained the Generic-JSON `BatchStats`
record, a `batch` field on `ProcessorMetrics`, and six increment helpers;
`Shibuya.Telemetry.Semantic` gained three batch attribute keys and two batch event names.
All exported signatures match the frozen ones in the MasterPlan Surprises & Discoveries, so
EP-19 can mount `processBatchesUntilDrained` and expose `BatchStats` unchanged.

The reliability contract is proven by six scenario tests (all green, 147 examples total, no
warnings): (M1) a 5-message batch with two per-message dead-letters finalizes each id exactly
once with the right decision and correct metrics (`batchesEmitted=1`, `batchedMessages=5`,
`partialFailures=1`, `sizeTriggered=1`, `processed=3`, `failed=2`); (M1) a flaky finalizer
that throws twice records exactly one successful finalization, proving retry does not
recompute or duplicate the resolved decision; (M2) a throwing handler finalizes all five with
`AckRetry (RetryDelay 0)` (`failed=5`, `partialFailures=0`); (M2) a per-message `AckHalt`
finalizes the whole batch, sets the flag, and the driver raises
`ProcessorHalt (HaltFatal ...)`; (M2) a permanently failing finalizer exhausts the
`[10ms,50ms,250ms]` retry schedule, names the failed `MessageId` in the fatal halt, and still
finalizes the batch's other message; (M2) under `Async 3` same-key batches never overlap
while different keys may.

No deviations from the plan's design or the emitted-batch type. The only surprises were
mechanical (the mis-indented top-level helpers, two redundant imports, the `BatchKey` import
origin, and the `(:>)` test import) recorded above. Deferred, as the plan states: EP-18 does
not throw on halt or stop batch emission — the caller (EP-19) reads `haltRef` after draining
and throws; halting *emission* is EP-17/EP-19 flow control.


## Context and Orientation

This section assumes no prior knowledge of the repository. Everything you need to implement
EP-18 is spelled out here or in the code you are told to read.

Shibuya is a Cabal project rooted at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. The library package is
`shibuya-core`, with sources under `shibuya-core/src/Shibuya/` and tests under
`shibuya-core/test/`. The Cabal file is `shibuya-core/shibuya-core.cabal` (`cabal-version:
3.12`, `default-language: GHC2024`, package version `0.7.1.0`). All commands in this plan run
from the repository root.

The default GHC extensions for both the library and the test suite (from the cabal
`default-extensions` stanzas) are: `DeriveAnyClass`, `DerivingStrategies`,
`DuplicateRecordFields`, `LambdaCase`, `NoFieldSelectors`, `OverloadedLabels`,
`OverloadedRecordDot`, `OverloadedStrings`, `QuasiQuotes`. Two consequences matter here.
First, `NoFieldSelectors` means record fields do **not** generate accessor functions; you read
a field with dot syntax, e.g. `ingested.envelope.messageId`. Second, `DerivingStrategies`
means every `deriving` clause must name a strategy — `stock`, `newtype`, or `anyclass`.

Build, test, and format commands:

```bash
cabal build shibuya-core
cabal test shibuya-core-test
nix fmt
```

`nix fmt` runs the tree formatter (Fourmolu with 2-space indent, trailing commas in
import/export lists); the pre-commit hook rejects unformatted commits, so run it before
committing.

### Terms used in this plan

- **Batch**: a non-empty group of ingested messages handed to a batch handler together.
- **Emitted / ready batch**: a batch the accumulation engine (EP-17) has decided is complete
  and hands downstream as the pair `(BatchInfo, NonEmpty (Ingested es msg))`.
- **Decision resolution**: choosing one `AckDecision` for a retained message by looking its
  `MessageId` up in `BatchAck.decisions` and falling back to `BatchAck.fallback`.
- **Finalize**: to call a message's own acknowledgement function
  (`ingested.ack.finalize :: AckDecision -> Eff es ()`) with the resolved decision. Because
  this is an adapter effect and can throw, EP-18 retries it using the bounded schedule
  documented in the Decision Log.
- **Exactly-once acknowledgement outcome**: every message that enters a batch has exactly
  one resolved decision and either one confirmed successful finalization with that decision
  or a loud processor failure that names the message after finalization retries are
  exhausted.
- **Span**: an OpenTelemetry unit of traced work with a name, timing, attributes (key/value
  metadata), and events. Shibuya wraps this behind a `Tracing` effect so it is a no-op when
  tracing is disabled (which it is in tests).
- **Halt**: a request from a handler to stop the processor. It is signalled by an
  `AckHalt reason` decision, propagated as a shared flag, and eventually surfaced as a
  `ProcessorHalt` exception by the caller.
- **`Eff es`**: the effect-system monad this codebase uses (`effectful` library). Read
  `(IOE :> es, Tracing :> es) => ... Eff es a` as "a computation that can do IO and tracing".

### EP-16 types you consume (from `shibuya-core/src/Shibuya/Batch.hs`)

EP-16 (`docs/plans/16-batch-api-and-configuration-types.md`) is checked in and defines the
public batch vocabulary. Import these; do not redefine them. The ones EP-18 depends on, quoted
verbatim:

```haskell
newtype BatchKey = BatchKey {unBatchKey :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (IsString)
  deriving anyclass (NFData)

data BatchTrigger = TriggerSize | TriggerTimeout | TriggerFlush
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

data BatchInfo = BatchInfo
  { batchKey  :: !BatchKey
  , size      :: !Int
  , trigger   :: !BatchTrigger
  , partition :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

type BatchHandler es msg = BatchInfo -> NonEmpty (Ingested es msg) -> Eff es BatchAck

data BatchAck = BatchAck
  { decisions :: !(Map MessageId AckDecision)
  , fallback  :: !AckDecision
  }
  deriving stock (Show, Generic)

ackAll :: AckDecision -> BatchAck    -- BatchAck Map.empty d  (every message gets d)
```

`AckDecision` (from `shibuya-core/src/Shibuya/Core/Ack.hs`), which the decisions carry:

```haskell
newtype RetryDelay = RetryDelay {unRetryDelay :: NominalDiffTime}
data DeadLetterReason = PoisonPill !Text | InvalidPayload !Text | MaxRetriesExceeded
data HaltReason = HaltOrderedStream !Text | HaltFatal !Text
data AckDecision = AckOk | AckRetry !RetryDelay | AckDeadLetter !DeadLetterReason | AckHalt !HaltReason
```

### THE ACKNOWLEDGEMENT CONTRACT (quoted verbatim; it is the whole point)

The following is the normative contract, copied verbatim from the MasterPlan and EP-16. This
plan's entire job is to implement it. Read it, then re-read it:

> Given an emitted batch and the `BatchAck` a `BatchHandler` returns, the framework resolves
> one `AckDecision` for EVERY message in its OWN retained batch list. For each retained
> `Ingested`, it computes `Data.Map.Strict.findWithDefault batchAck.fallback
> ingested.envelope.messageId batchAck.decisions`. The handler's return value ONLY supplies
> decisions; it never drives WHICH messages are acked. Thus acknowledgement decision
> resolution is complete regardless of handler behavior (wrong length / reordered / missing
> ids degrade to fallback). Requires unique `MessageId` per batch (true for all adapters +
> mock). The execution stage then applies each resolved decision to the message's idempotent
> `AckHandle.finalize` with bounded retries; exhausted finalization retries fail the
> processor loudly with the affected ids.

Say it plainly: the loop that resolves decisions and finalizes is `for each ingested in ourOwnRetainedList`. It is
**never** `for each entry in the handler's map`. The handler's map is consulted only via
`findWithDefault` to *choose the decision* for a message we are already committed to
finalizing. This is why the failure modes below are all safe.

The failure modes this defends against, and why each is safe:

- **Handler returns a wrong-length / reordered / partial map** (it names ids that are not in
  the batch, or omits some that are): every retained message still gets one resolved
  decision; omitted ids fall back to `batchAck.fallback`; bogus ids in the map are simply
  never looked up. No message is skipped or misassigned.
- **Handler returns an empty `BatchAck` (`ackAllOk`)**: every message falls back to `AckOk`
  and is finalized with bounded retry. This is the common "everything succeeded" case.
- **Handler throws an exception**: the whole batch is finalized with the substituted default
  `ackAll (AckRetry (RetryDelay 0))`, so every message is resolved to immediate retry and
  finalized with bounded retry. No message is skipped because the handler crashed.
- **Handler returns `AckHalt` for some or all messages**: those messages are finalized once
  with `AckHalt` (others with whatever the map/fallback says), then the halt flag is set so
  the caller stops the processor after the batch drains.
- **Adapter finalizer throws**: the finalizer is retried using the bounded schedule. If it
  still throws, the span records the exception, metrics move to `Failed`, the message id is
  included in the fatal halt reason, and the batch processor still attempts to finalize the
  remaining retained messages before surfacing the failure.

### The single-message path you mirror (`shibuya-core/src/Shibuya/Runner/Supervised.hs`)

Read `processOne` (around line 372), `processUntilDrained` (line 308), and `decrementAndUpdate`
(line 491) before writing any code. EP-18 mirrors these for batches:

- `processOne` opens a Consumer span named `processSpanName pidText` (which yields
  `"<processorId> process"`), layers the framework `messaging.*` attributes under the
  envelope's own attributes, increments an in-flight counter into `ProcessorMetrics`, runs the
  handler under `catchAny` (turning an exception into a `Left HandlerException`), finalizes,
  sets the span status from the decision, decrements in-flight and updates stats via
  `decrementAndUpdate`, and — critically — on `AckHalt` does
  `atomicWriteIORef haltRef (Just reason)` **without throwing**, letting the stream drain.
- `processUntilDrained` chooses a streamly combinator by `Concurrency`:

  ```haskell
  let maxConc = case concurrency of
        Serial  -> 1
        Ahead n -> n
        Async n -> n

  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
    let processAction = runInIO . processOne metricsVar procId maxConc haltRef handler
    case concurrency of
      Serial  -> Stream.fold Fold.drain $ Stream.mapM processAction inboxStream
      Ahead n -> Stream.fold Fold.drain $ StreamP.parMapM (StreamP.maxBuffer n . StreamP.ordered True) processAction inboxStream
      Async n -> Stream.fold Fold.drain $ StreamP.parMapM (StreamP.maxBuffer n) processAction inboxStream
    maybeHalt <- readIORef haltRef
    case maybeHalt of
      Just reason -> throwIO $ ProcessorHalt reason
      Nothing -> pure ()
  ```

  The `withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> ...` idiom is how you run
  `Eff es` actions inside streamly's `IO`-based stream. `withEffToIO` hands you a `runInIO`
  function that lowers `Eff es a` to `IO a`; `ConcUnlift Persistent Unlimited` says the lowered
  actions may run on other threads persistently and without a concurrency cap, which is
  required because streamly's `parMapM` runs actions on worker threads. You compose
  `runInIO . processOneBatch ...` so each stream element is processed as an `IO` action.
- `decrementAndUpdate` maps a per-message outcome to stats: `AckOk`/`AckRetry` →
  `incProcessed`; `AckDeadLetter` → `incFailed`; `AckHalt` → stats unchanged (state becomes
  `Failed`); a handler exception (`Left`) → `incFailed` + state `Failed`. EP-18's per-message
  stat mapping matches this, with one addition: when the *whole batch* was
  exception-substituted, each message counts as `incFailed` even though the applied decision is
  `AckRetry`.

### The metrics you extend (`shibuya-core/src/Shibuya/Runner/Metrics.hs`)

This module is `exposed-modules`. Today it has `StreamStats` (fields `received`, `dropped`,
`processed`, `failed`, Generic-derived `ToJSON`/`FromJSON`), a hand-written-JSON
`ProcessorState` sum (`Idle | Processing InFlightInfo UTCTime | Failed Text UTCTime |
Stopped`), `InFlightInfo { inFlight, maxConcurrency }`, and `ProcessorMetrics { state, stats,
startedAt }` (Generic-derived JSON), plus increment helpers `incReceived`, `incDropped`,
`incProcessed`, `incFailed` (each `StreamStats -> StreamStats`, written with lens labels like
`#received %~ (+ 1)`). You will add a `BatchStats` record and a `batch` field on
`ProcessorMetrics`. Because `ProcessorMetrics` derives JSON via `Generic`, adding the field
just adds a `"batch"` object to the JSON — no hand-written instance to touch. The pre-existing
but unused `dropped` counter in `StreamStats` remains available for batch-drop accounting but
is not used by EP-18.

### The tracing helpers you reuse (`shibuya-core/src/Shibuya/Telemetry/`)

`Shibuya.Telemetry.Effect` exports the `Tracing` effect and the span operations you need:
`withSpan'` (open a span and get its handle), `withExtractedContext` (make the new span a child
of a parent context extracted from message headers), `addAttribute`, `addAttributes`,
`addEvent`, `recordException`, `setStatus`, and re-exports `OTel.SpanStatus (..)` /
`toAttribute`. In tests we run under `runTracingNoop`, so all of these are no-ops and no
tracing backend is needed. `Shibuya.Telemetry.Semantic` exports span names (`processSpanName`),
the framework `messaging.*` attribute keys, Shibuya-specific keys
(`attrShibuyaInflightCount`, `attrShibuyaInflightMax`, `attrShibuyaPartition`,
`attrShibuyaAckDecision`), `consumerSpanArgs` (a `SpanArguments` with `kind = Consumer`), event
names, and `mkEvent`. You will add three batch attribute keys and two batch event names here.
`Shibuya.Telemetry.Propagation` exports `extractTraceContext` for turning a message's
`traceContext` into a parent span context.

### The emitted-batch type from EP-17 (dependency note)

EP-17 (`docs/plans/17-batch-accumulation-engine.md`) is the accumulation engine and produces
the stream this plan consumes. **At the time of writing, EP-17 is only a skeleton** — its
concrete module and function names are not final. This plan therefore depends only on the
*emitted-batch type* agreed in the MasterPlan Integration Points ("The emitted-batch type"):

```haskell
-- Produced by EP-17, consumed read-only by EP-18:
(BatchInfo, NonEmpty (Ingested es msg))
```

carried as a `Streamly.Data.Stream.Stream IO (BatchInfo, NonEmpty (Ingested es msg))`. EP-18
takes this stream as a function argument and never constructs it from an inbox itself, so it
does not need EP-17 to be implemented to compile or to be unit-tested — the tests build the
stream from an in-memory list. **Coordination note for EP-17:** if EP-17 enriches the emitted
value (for example threading an internal batch sequence number for metrics), it must update the
MasterPlan Integration Points section and this plan's `processBatchesUntilDrained` signature.
As of now the agreed type is exactly `(BatchInfo, NonEmpty (Ingested es msg))`.

A related note about flow control: EP-18 processes **every** batch the stream hands it,
finalizing each one fully; it does not skip batches after a halt. Stopping the *emission* of
new batches once a halt has been requested is upstream flow control that belongs to EP-17
(whose inbox-driven stream ends when the shared halt flag is set) and EP-19 (which wires it).
For EP-18's isolated tests the stream is a finite `fromList`, so all batches are processed and
halt merely sets the flag; that is exactly what we assert.

### The mock test helpers you use (`shibuya-core/src/Shibuya/Adapter/Mock.hs`)

`TrackingAck { trackedDecisions :: IORef [(MessageId, AckDecision)] }` with `newTrackingAck`,
`trackingAckHandle :: TrackingAck -> MessageId -> AckHandle es` (its handle *prepends*
`(msgId, decision)` to the list on every successful finalize), and `getTrackedDecisions`.
Because it records a **list** and never deduplicates, it captures duplicate successful
finalizations. EP-18 also needs two local test handles: a flaky handle that throws for the
first N attempts and then records success, and a permanently failing handle that always
throws. Those prove retry and fail-loud behavior separately from the normal successful path.


## Plan of Work

The work is one deliverable — a batch-execution module plus its metrics and tracing support —
split into two verifiable milestones. Milestone 1 delivers one-decision-per-message
resolution, resilient finalization over a single batch, and the metrics extension.
Milestone 2 adds exception fallback, halt handling, keyed concurrency, and the
concurrency-bounded driver, with tests proving each.

Throughout, remember the golden rule (Decision Log #1): the decision/finalization loop
iterates **our own retained `NonEmpty (Ingested es msg)`**, and consults the handler's `BatchAck` only via
`findWithDefault batchAck.fallback ingested.envelope.messageId batchAck.decisions`.

### Milestone 1 — One decision and resilient finalize over a single batch

Scope: extend `Shibuya.Runner.Metrics` with `BatchStats`; add batch tracing keys to
`Shibuya.Telemetry.Semantic`; create `Shibuya.Runner.BatchProcessor` with `processOneBatch`
(the per-batch worker) wired to open a span, run the handler, resolve each retained
message's decision once, and finalize each retained message through bounded retry; and add
`processBatchesUntilDrained` (Serial path) plus the
`runBatchesWithMetrics` test driver. At the end of this milestone the M1 test passes: a batch
of five messages, a handler returning
`ackExcept [(m2, AckDeadLetter MaxRetriesExceeded), (m4, AckDeadLetter (PoisonPill "x"))]`, and
the tracking ack shows m1/m3/m5 finalized `AckOk` once each, m2/m4 finalized `AckDeadLetter`
once each — five entries total, each id exactly once — and `batchesEmitted = 1`,
`batchedMessages = 5`, `partialFailures = 1`, `sizeTriggered = 1`, `processed = 3`,
`failed = 2`. A second M1 test uses a flaky finalizer that throws twice and then succeeds;
the final tracked success list still has exactly one entry for that message, proving retry
does not recompute or change the resolved decision.

Commands: `cabal build shibuya-core` then `cabal test shibuya-core-test`. Acceptance: the
`BatchProcessor` describe block passes; the successful-finalization assertion (each id once)
and the flaky-finalizer retry assertion are the key ones.

### Milestone 2 — Exception fallback, halt, fail-loud finalization, metrics, and keyed concurrency

Scope: complete `processOneBatch`'s exception path (`catchAny` around the handler →
`ackAll (AckRetry (RetryDelay 0))`, record exception on span, per-message stats → `incFailed`)
and its halt path (`atomicWriteIORef haltRef` after the batch is fully attempted; state →
`Failed`; caller throws); complete `processBatchesUntilDrained`'s `Ahead`/`Async` keyed
concurrency cases; add the permanent-finalizer-failure path; and finish
`runBatchesWithMetrics` so it throws `ProcessorHalt` after draining if the halt flag is set.
At the end, the M2 tests pass: (a) a handler that throws finalizes all five messages
`AckRetry` once each, with `failed = 5` and `partialFailures = 0`; (b) a handler that returns
`withFallback AckOk [(m3, AckHalt (HaltFatal "halt on 3"))]` finalizes all five successfully
(m3 with `AckHalt`), sets the halt flag, drives the state to `Failed`, and the driver raises
`ProcessorHalt (HaltFatal "halt on 3")`, which the test catches with `try`; (c) a permanently
failing finalizer exhausts retries, names the failed `MessageId`, marks metrics `Failed`,
and still attempts the other messages; (d) two batches for the same `BatchKey` never overlap
under `Async 2`, while different keys can overlap.

Commands: `cabal test shibuya-core-test`. Acceptance: all M2 scenarios pass; the halt test
catches `ProcessorHalt`, the permanent-finalizer test catches the fatal finalization halt,
and the keyed-concurrency test proves per-key FIFO under global concurrency.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

### Step 1 — Extend `Shibuya.Runner.Metrics`

Open `shibuya-core/src/Shibuya/Runner/Metrics.hs`. Add a new export section:

```haskell
    -- * Batch Statistics
    BatchStats (..),
    emptyBatchStats,
    incBatchesEmitted,
    addBatchedMessages,
    incPartialFailures,
    incSizeTriggered,
    incTimeoutTriggered,
    incFlushTriggered,
```

After the `StreamStats` definition (and `emptyStreamStats`), add the record. It derives its
JSON via `Generic` (`anyclass`), so it nests safely inside `ProcessorMetrics` with no
hand-written instance:

```haskell
-- | Batch-processing statistics, tracked alongside per-message 'StreamStats'.
data BatchStats = BatchStats
  { -- | Number of batches emitted and executed.
    batchesEmitted :: !Int,
    -- | Total messages across all emitted batches.
    batchedMessages :: !Int,
    -- | Batches with a genuine partial failure: the handler returned normally
    -- and named at least one message in its decision map with a failing
    -- decision (dead-letter or retry) while acking the rest. Counted per batch,
    -- not per message, so it does not double-count the per-message 'failed'
    -- counter.
    partialFailures :: !Int,
    -- | Batches emitted because they reached the configured size.
    sizeTriggered :: !Int,
    -- | Batches emitted because their timeout elapsed.
    timeoutTriggered :: !Int,
    -- | Batches emitted because the processor was draining (flush).
    flushTriggered :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Empty batch stats (all zero).
emptyBatchStats :: BatchStats
emptyBatchStats = BatchStats 0 0 0 0 0 0
```

Add the `batch` field to `ProcessorMetrics` (which already derives Generic JSON):

```haskell
data ProcessorMetrics = ProcessorMetrics
  { -- | Current state
    state :: !ProcessorState,
    -- | Per-message statistics
    stats :: !StreamStats,
    -- | Batch statistics
    batch :: !BatchStats,
    -- | When the processor started
    startedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
```

Initialize the new field in `emptyProcessorMetrics`:

```haskell
emptyProcessorMetrics :: UTCTime -> ProcessorMetrics
emptyProcessorMetrics now =
  ProcessorMetrics
    { state = Idle,
      stats = emptyStreamStats,
      batch = emptyBatchStats,
      startedAt = now
    }
```

Add the increment helpers near the existing `incReceived`/`incProcessed`, in the same
lens-label style:

```haskell
-- | Increment the emitted-batch counter.
incBatchesEmitted :: BatchStats -> BatchStats
incBatchesEmitted = #batchesEmitted %~ (+ 1)

-- | Add to the total batched-messages counter.
addBatchedMessages :: Int -> BatchStats -> BatchStats
addBatchedMessages n = #batchedMessages %~ (+ n)

-- | Increment the partial-failure batch counter.
incPartialFailures :: BatchStats -> BatchStats
incPartialFailures = #partialFailures %~ (+ 1)

-- | Increment the size-trigger counter.
incSizeTriggered :: BatchStats -> BatchStats
incSizeTriggered = #sizeTriggered %~ (+ 1)

-- | Increment the timeout-trigger counter.
incTimeoutTriggered :: BatchStats -> BatchStats
incTimeoutTriggered = #timeoutTriggered %~ (+ 1)

-- | Increment the flush-trigger counter.
incFlushTriggered :: BatchStats -> BatchStats
incFlushTriggered = #flushTriggered %~ (+ 1)
```

JSON caveat, restated: `ProcessorState` is a **hand-written** tagged JSON instance — do not add
batch data there. `StreamStats`, `BatchStats`, and `ProcessorMetrics` are Generic-derived, so
the field/record additions above need no instance edits.

### Step 2 — Extend `Shibuya.Telemetry.Semantic`

Open `shibuya-core/src/Shibuya/Telemetry/Semantic.hs`. Add to the export list — under the
Shibuya-specific keys and under the event names respectively:

```haskell
    attrShibuyaBatchKey,
    attrShibuyaBatchSize,
    attrShibuyaBatchTrigger,
```

```haskell
    eventBatchStarted,
    eventBatchCompleted,
```

Add the definitions near the other `attrShibuya*` and `event*` values:

```haskell
-- | The batch grouping key (@shibuya.batch.key@).
attrShibuyaBatchKey :: Text
attrShibuyaBatchKey = "shibuya.batch.key"

-- | The number of messages in the batch (@shibuya.batch.size@).
attrShibuyaBatchSize :: Text
attrShibuyaBatchSize = "shibuya.batch.size"

-- | Why the batch was emitted: size, timeout, or flush (@shibuya.batch.trigger@).
attrShibuyaBatchTrigger :: Text
attrShibuyaBatchTrigger = "shibuya.batch.trigger"

-- | Event recorded when batch-handler execution starts (@shibuya.batch.started@).
eventBatchStarted :: Text
eventBatchStarted = "shibuya.batch.started"

-- | Event recorded when a batch has been fully finalized (@shibuya.batch.completed@).
eventBatchCompleted :: Text
eventBatchCompleted = "shibuya.batch.completed"
```

### Step 3 — Create `Shibuya.Runner.BatchProcessor`

Create `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`. The full module follows; read the
inline comments, which mark each reliability point. The three public functions are
`processOneBatch` (per-batch worker), `processBatchesUntilDrained` (the concurrency-bounded
fold, mirroring `processUntilDrained`), and `runBatchesWithMetrics` (a self-contained test
driver mirroring `runWithMetrics`).

```haskell
-- | Batch execution stage: run a batch handler over an emitted batch, resolve
-- one acknowledgement decision per retained message, and finalize resiliently.
--
-- This is the reliability heart of batch processing. For each ready batch it:
--
--   1. Opens an OpenTelemetry span scoped to the whole batch.
--   2. Runs the user's 'BatchHandler' under exception isolation.
--   3. On success, uses the returned 'BatchAck'; on exception, substitutes the
--      framework default @ackAll (AckRetry (RetryDelay 0))@ (redeliver the whole
--      batch, no data loss).
--   4. Resolves EVERY message in its OWN retained 'NonEmpty' list to one
--      decision, looking each decision up by 'MessageId' with a fallback.
--   5. Calls each message's idempotent finalizer with bounded retry. If retry
--      is exhausted, records the message id and fails the processor loudly.
--   6. On 'AckHalt', sets a shared halt flag (does not throw); the caller drains
--      then throws 'ProcessorHalt'.
--   7. Records batch metrics.
--
-- The decision loop iterates the framework's retained list, never the handler's
-- output, so handler bugs cannot skip or misassign retained messages.
module Shibuya.Runner.BatchProcessor
  ( -- * Batch execution
    processOneBatch,
    processBatchesUntilDrained,

    -- * Standalone driver (for tests / finite batch lists)
    runBatchesWithMetrics,
  )
where

import Control.Concurrent.STM
  ( STM,
    TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    readTVarIO,
    retry,
    writeTVar,
  )
import Data.Foldable (for_)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, withEffToIO, (:>))
import Effectful.Internal.Unlift (Limit (..), Persistence (..), UnliftStrategy (..))
import OpenTelemetry.Attributes (toAttribute)
import OpenTelemetry.Trace.Core qualified as OTel
import Shibuya.Batch
  ( BatchAck (..),
    BatchHandler,
    BatchInfo (..),
    BatchKey (..),
    BatchTrigger (..),
    ackAll,
  )
import Shibuya.Core.Ack
  ( AckDecision (..),
    HaltReason (..),
    RetryDelay (..),
  )
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId)
import Shibuya.Policy (Concurrency (..))
import Shibuya.Prelude
import Shibuya.Runner.Halt (ProcessorHalt (..))
import Shibuya.Runner.Metrics
  ( InFlightInfo (..),
    ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    StreamStats,
    addBatchedMessages,
    emptyProcessorMetrics,
    incBatchesEmitted,
    incFailed,
    incFlushTriggered,
    incPartialFailures,
    incProcessed,
    incSizeTriggered,
    incTimeoutTriggered,
  )
import Shibuya.Telemetry.Effect
  ( Tracing,
    addAttribute,
    addAttributes,
    addEvent,
    recordException,
    setStatus,
    withExtractedContext,
    withSpan',
  )
import Shibuya.Telemetry.Propagation (extractTraceContext)
import Shibuya.Telemetry.Semantic
  ( attrMessagingDestinationName,
    attrMessagingOperation,
    attrMessagingSystem,
    attrShibuyaBatchKey,
    attrShibuyaBatchSize,
    attrShibuyaBatchTrigger,
    attrShibuyaInflightCount,
    attrShibuyaInflightMax,
    consumerSpanArgs,
    eventBatchCompleted,
    eventBatchStarted,
    mkEvent,
    processSpanName,
  )
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import UnliftIO (SomeException, catchAny, throwIO)
import UnliftIO.Async (async)
import UnliftIO.Concurrent (threadDelay)

-- | Execute one emitted batch and finalize every retained message resiliently.
--
-- @maxConc@ is the batch-concurrency limit (reported on the span). @haltRef@ is
-- the shared halt flag: on 'AckHalt' this sets it via 'atomicWriteIORef' and
-- returns normally, letting the stream drain.
processOneBatch ::
  (IOE :> es, Tracing :> es) =>
  TVar ProcessorMetrics ->
  ProcessorId ->
  Int ->
  IORef (Maybe HaltReason) ->
  BatchHandler es msg ->
  (BatchInfo, NonEmpty (Ingested es msg)) ->
  Eff es ()
processOneBatch metricsVar procId maxConc haltRef handler (info, batch) = do
  -- Use the first message's trace context as the batch span's parent. A batch
  -- may span several traces; picking the first is a pragmatic single parent
  -- (full fan-in links are a later refinement).
  let firstMsg = NE.head batch
      parentCtx = firstMsg.envelope.traceContext >>= extractTraceContext
      ProcessorId pidText = procId

  withExtractedContext parentCtx $
    withSpan' (processSpanName pidText) consumerSpanArgs $ \traceSpan -> do
      -- Framework messaging.* attributes plus batch-scoped attributes.
      let BatchKey keyText = info.batchKey
          frameworkAttrs =
            HashMap.fromList
              [ (attrMessagingSystem, toAttribute ("shibuya" :: Text)),
                (attrMessagingDestinationName, toAttribute pidText),
                (attrMessagingOperation, toAttribute ("process" :: Text)),
                (attrShibuyaBatchKey, toAttribute keyText),
                (attrShibuyaBatchSize, toAttribute info.size),
                (attrShibuyaBatchTrigger, toAttribute (triggerText info.trigger))
              ]
      addAttributes traceSpan frameworkAttrs

      -- Increment in-flight (a batch counts as one in-flight unit) and report it.
      now <- liftIO getCurrentTime
      currentInflight <- liftIO $ atomically $ do
        modifyTVar' metricsVar $ \m ->
          let current = case m.state of
                Processing i _ -> i.inFlight
                _ -> 0
           in m & #state .~ Processing (InFlightInfo (current + 1) maxConc) now
        m <- readTVar metricsVar
        pure $ case m.state of
          Processing i _ -> i.inFlight
          _ -> 1
      addAttribute traceSpan attrShibuyaInflightCount currentInflight
      addAttribute traceSpan attrShibuyaInflightMax maxConc

      addEvent traceSpan (mkEvent eventBatchStarted [])

      -- Run the handler under exception isolation. On any exception, record it
      -- on the span and substitute the whole-batch retry default.
      handlerResult <-
        catchAny
          (Right <$> handler info batch)
          ( \ex -> do
              recordException traceSpan ex
              pure (Left ())
          )
      let (resolvedAck, handlerThrew) = case handlerResult of
            Right a -> (a, False)
            Left () -> (ackAll (AckRetry (RetryDelay 0)), True)

      -- RELIABLE FINALIZATION: iterate OUR OWN retained list, never the
      -- handler's output. For each retained message, choose its decision once
      -- via findWithDefault, then call the idempotent adapter finalizer with
      -- bounded retry. Do not let one adapter failure prevent attempts for the
      -- rest of the batch.
      results <-
        mapM
          ( \ingested -> do
              let d =
                    Map.findWithDefault
                      resolvedAck.fallback
                      ingested.envelope.messageId
                      resolvedAck.decisions
              finalResult <- finalizeWithRetry traceSpan ingested d
              pure (ingested.envelope.messageId, d, finalResult)
          )
          (NE.toList batch)
      let decisions = [d | (_, d, _) <- results]
          finalizeFailures = [(mid, ex) | (mid, _, Left ex) <- results]

      -- Compute halt and partial-failure signals from the resolved decisions.
      let finalizationHalt =
            case finalizeFailures of
              [] -> Nothing
              failed ->
                Just $
                  HaltFatal $
                    "batch finalization failed for message ids: "
                      <> Text.intercalate ", " [tshow mid | (mid, _) <- failed]
          firstHalt = finalizationHalt <|> listToMaybe [r | AckHalt r <- decisions]
          overrideFailures =
            [ ()
            | ingested <- NE.toList batch,
              Just d <- [Map.lookup ingested.envelope.messageId resolvedAck.decisions],
              isFailing d
            ]
          partialInc = not handlerThrew && not (null overrideFailures)

      -- Span status: error on halt or exception, otherwise Ok.
      addEvent traceSpan (mkEvent eventBatchCompleted [])
      case firstHalt of
        Just reason -> setStatus traceSpan (OTel.Error (haltReasonText reason))
        Nothing ->
          if handlerThrew
            then setStatus traceSpan (OTel.Error "batch handler exception")
            else setStatus traceSpan OTel.Ok

      traverse_ (recordException traceSpan . snd) finalizeFailures

      -- Record metrics: decrement in-flight, fold per-message stats, advance
      -- batch counters, set Failed state on halt or exhausted finalization retry.
      now' <- liftIO getCurrentTime
      liftIO $
        atomically $
          modifyTVar' metricsVar $
            recordBatchOutcome info handlerThrew partialInc decisions firstHalt now'

      -- Halt: set the shared flag; do NOT throw (let the stream drain).
      for_ firstHalt $ \reason ->
        liftIO $ atomicWriteIORef haltRef (Just reason)
  where
    isFailing :: AckDecision -> Bool
    isFailing (AckDeadLetter _) = True
    isFailing (AckRetry _) = True
    isFailing _ = False

-- | Pure metrics update applied after a batch is fully finalized.
recordBatchOutcome ::
  BatchInfo ->
  -- | whether the handler threw (exception-substituted whole batch)
  Bool ->
  -- | whether to count a partial failure
  Bool ->
  -- | resolved decisions, in retained order
  [AckDecision] ->
  -- | first halt reason, if any
  Maybe HaltReason ->
  UTCTime ->
  ProcessorMetrics ->
  ProcessorMetrics
recordBatchOutcome info handlerThrew partialInc decisions firstHalt now m =
  m {state = finalState, stats = newStats, batch = newBatch}
  where
    decremented = case m.state of
      Processing i _ ->
        if i.inFlight <= 1
          then Idle
          else Processing (i {inFlight = i.inFlight - 1}) now
      other -> other
    -- Halt is terminal -> Failed; exception is recoverable -> keep normal state.
    finalState = case firstHalt of
      Just reason -> Failed (haltReasonText reason) now
      Nothing -> decremented
    newStats = foldl' (\s d -> perMsgStat handlerThrew d s) m.stats decisions
    newBatch =
      incTrigger info.trigger
        . (if partialInc then incPartialFailures else id)
        . addBatchedMessages info.size
        . incBatchesEmitted
        $ m.batch

-- | Map one message's outcome to a stats update. If the handler threw, every
-- message counts failed regardless of the substituted retry decision.
perMsgStat :: Bool -> AckDecision -> StreamStats -> StreamStats
perMsgStat True _ = incFailed
perMsgStat False AckOk = incProcessed
perMsgStat False (AckRetry _) = incProcessed
perMsgStat False (AckDeadLetter _) = incFailed
perMsgStat False (AckHalt _) = id

incTrigger :: BatchTrigger -> BatchStats -> BatchStats
incTrigger TriggerSize = incSizeTriggered
incTrigger TriggerTimeout = incTimeoutTriggered
incTrigger TriggerFlush = incFlushTriggered

triggerText :: BatchTrigger -> Text
triggerText TriggerSize = "size"
triggerText TriggerTimeout = "timeout"
triggerText TriggerFlush = "flush"

haltReasonText :: HaltReason -> Text
    haltReasonText (HaltOrderedStream t) = t
    haltReasonText (HaltFatal t) = t

    tshow :: (Show a) => a -> Text
    tshow = Text.pack . show

finalizeRetryDelaysMicros :: [Int]
finalizeRetryDelaysMicros = [10_000, 50_000, 250_000]

-- | Call a message finalizer until it succeeds or the bounded retry budget is
-- exhausted. The resolved decision is never recomputed between attempts.
finalizeWithRetry ::
  (IOE :> es, Tracing :> es) =>
  OTel.Span ->
  Ingested es msg ->
  AckDecision ->
  Eff es (Either SomeException ())
finalizeWithRetry traceSpan ingested decision = go finalizeRetryDelaysMicros
  where
    go delays =
      catchAny
        (Right <$> ingested.ack.finalize decision)
        ( \ex -> do
            recordException traceSpan ex
            case delays of
              [] -> pure (Left ex)
              delay : rest -> do
                liftIO $ threadDelay delay
                go rest
        )

-- | Fold the ready-batch stream, running each batch under the batch-concurrency
-- policy. Batches with the same 'BatchKey' are always serialized in emission
-- order; different keys may run concurrently up to the configured bound. This
-- does NOT throw on halt; after draining, the caller inspects @haltRef@ and
-- throws 'ProcessorHalt' (see 'runBatchesWithMetrics').
processBatchesUntilDrained ::
  (IOE :> es, Tracing :> es) =>
  TVar ProcessorMetrics ->
  ProcessorId ->
  Concurrency ->
  BatchHandler es msg ->
  Stream IO (BatchInfo, NonEmpty (Ingested es msg)) ->
  IORef (Maybe HaltReason) ->
  Eff es ()
processBatchesUntilDrained metricsVar procId concurrency handler batchStream haltRef = do
  let maxConc = case concurrency of
        Serial -> 1
        Ahead n -> n
        Async n -> n

  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
    let batchAction = runInIO . processOneBatch metricsVar procId maxConc haltRef handler
    case concurrency of
      Serial ->
        Stream.fold Fold.drain $
          Stream.mapM batchAction batchStream
      Ahead n ->
        runKeyedBatchScheduler n batchAction batchStream
      Async n ->
        runKeyedBatchScheduler n batchAction batchStream

-- | Run ready batches with a global concurrency bound and a per-key FIFO lock.
data KeyedSchedulerState es msg = KeyedSchedulerState
  { inputDone :: !Bool,
    activeKeys :: !(Set.Set BatchKey),
    running :: !Int,
    pending :: !(Seq (BatchInfo, NonEmpty (Ingested es msg))),
    firstFailure :: !(Maybe SomeException)
  }

data SchedulerStep es msg
  = StartBatch !(BatchInfo, NonEmpty (Ingested es msg))
  | SchedulerDone !(Maybe SomeException)

emptyKeyedSchedulerState :: KeyedSchedulerState es msg
emptyKeyedSchedulerState =
  KeyedSchedulerState
    { inputDone = False,
      activeKeys = Set.empty,
      running = 0,
      pending = Seq.empty,
      firstFailure = Nothing
    }

runKeyedBatchScheduler ::
  Int ->
  ((BatchInfo, NonEmpty (Ingested es msg)) -> IO ()) ->
  Stream IO (BatchInfo, NonEmpty (Ingested es msg)) ->
  IO ()
runKeyedBatchScheduler requestedConcurrency batchAction batchStream = do
  scheduler <- newTVarIO emptyKeyedSchedulerState
  let maxConcurrency = max 1 requestedConcurrency

  _reader <-
    async $
      ( do
          Stream.fold Fold.drain $
            Stream.mapM (enqueueBatch scheduler) batchStream
          atomically $ markInputDone scheduler Nothing
      )
        `catchAny` \ex ->
          atomically $ markInputDone scheduler (Just ex)

  let loop = do
        step <- atomically $ nextSchedulerStep maxConcurrency scheduler
        case step of
          SchedulerDone Nothing -> pure ()
          SchedulerDone (Just ex) -> throwIO ex
          StartBatch batch -> do
            _worker <-
              async $
                (batchAction batch >> pure Nothing)
                  `catchAny` (pure . Just)
                  >>= atomically . finishBatch scheduler batch
            loop

  loop

enqueueBatch ::
  TVar (KeyedSchedulerState es msg) ->
  (BatchInfo, NonEmpty (Ingested es msg)) ->
  IO ()
enqueueBatch scheduler batch =
  atomically $
    modifyTVar' scheduler $ \s ->
      s {pending = s.pending Seq.|> batch}

markInputDone ::
  TVar (KeyedSchedulerState es msg) ->
  Maybe SomeException ->
  STM ()
markInputDone scheduler failure =
  modifyTVar' scheduler $ \s ->
    s
      { inputDone = True,
        firstFailure = s.firstFailure <|> failure
      }

nextSchedulerStep ::
  Int ->
  TVar (KeyedSchedulerState es msg) ->
  STM (SchedulerStep es msg)
nextSchedulerStep maxConcurrency scheduler = do
  s <- readTVar scheduler
  case (s.running < maxConcurrency, popStartable s.activeKeys s.pending) of
    (True, Just (batch@(info, _), rest)) -> do
      writeTVar
        scheduler
        s
          { activeKeys = Set.insert info.batchKey s.activeKeys,
            running = s.running + 1,
            pending = rest
          }
      pure (StartBatch batch)
    _
      | s.inputDone && Seq.null s.pending && s.running == 0 ->
          pure (SchedulerDone s.firstFailure)
      | otherwise ->
          retry

finishBatch ::
  TVar (KeyedSchedulerState es msg) ->
  (BatchInfo, NonEmpty (Ingested es msg)) ->
  Maybe SomeException ->
  STM ()
finishBatch scheduler (info, _) failure =
  modifyTVar' scheduler $ \s ->
    s
      { activeKeys = Set.delete info.batchKey s.activeKeys,
        running = s.running - 1,
        firstFailure = s.firstFailure <|> failure
      }

popStartable ::
  Set.Set BatchKey ->
  Seq (BatchInfo, NonEmpty (Ingested es msg)) ->
  Maybe ((BatchInfo, NonEmpty (Ingested es msg)), Seq (BatchInfo, NonEmpty (Ingested es msg)))
popStartable active = go Seq.empty
  where
    go skipped batches =
      case Seq.viewl batches of
        Seq.EmptyL ->
          Nothing
        batch@(info, _) Seq.:< rest
          | info.batchKey `Set.member` active ->
              go (skipped Seq.|> batch) rest
          | otherwise ->
              Just (batch, skipped <> rest)

-- | Self-contained driver for finite batch lists (tests / simple setups).
-- Mirrors 'Shibuya.Runner.Supervised.runWithMetrics': creates its own metrics
-- TVar and halt flag, runs execution to completion, and — after draining —
-- throws 'ProcessorHalt' if a batch requested a halt. Returns the final metrics.
runBatchesWithMetrics ::
  (IOE :> es, Tracing :> es) =>
  ProcessorId ->
  Concurrency ->
  BatchHandler es msg ->
  [(BatchInfo, NonEmpty (Ingested es msg))] ->
  Eff es ProcessorMetrics
runBatchesWithMetrics procId concurrency handler batches = do
  now <- liftIO getCurrentTime
  metricsVar <- liftIO $ newTVarIO (emptyProcessorMetrics now)
  haltRef <- liftIO $ newIORef Nothing

  let batchStream = Stream.fromList batches
  processBatchesUntilDrained metricsVar procId concurrency handler batchStream haltRef

  maybeHalt <- liftIO $ readIORef haltRef
  case maybeHalt of
    Just reason -> throwIO (ProcessorHalt reason)
    Nothing -> liftIO $ readTVarIO metricsVar
```

Note on the `MessageId` import: it appears only inside type-level positions (via `Envelope`
and `Map`), so `import Shibuya.Core.Types (Envelope (..), MessageId)` imports the type without
the constructor. If `-Wall` reports it unused, drop `MessageId` from the import. Keep the
import lists trimmed until the build is warning-free.

### Step 4 — Register the module in cabal

Edit `shibuya-core/shibuya-core.cabal`. In the library stanza, add
`Shibuya.Runner.BatchProcessor` to **`exposed-modules`**, alphabetically between
`Shibuya.Runner.Master` and `Shibuya.Runner.Metrics` (it is exposed, not internal, so the
in-package test can import it — see Decision Log):

```text
  exposed-modules:
    ...
    Shibuya.Runner.BatchProcessor
    Shibuya.Runner.Master
    Shibuya.Runner.Metrics
    Shibuya.Runner.Supervised
    ...
```

No new `build-depends` are needed: `containers`, `stm`, `streamly`, `streamly-core`,
`effectful`, `text`, `unliftio`, `unordered-containers`, and `hs-opentelemetry-api` already
cover everything used.

### Step 5 — Create the test module

Create `shibuya-core/test/Shibuya/Runner/BatchProcessorSpec.hs`. It builds batches from
in-memory messages whose `AckHandle` is a `TrackingAck` (recording a list of every finalize
call), runs execution via `runBatchesWithMetrics`, and asserts normal-path successful
finalization by checking each `MessageId` appears exactly once in the tracked list.

```haskell
module Shibuya.Runner.BatchProcessorSpec (spec) where

import Data.HashMap.Strict qualified as HashMap
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, runEff)
import Shibuya.Adapter.Mock
  ( TrackingAck,
    getTrackedDecisions,
    newTrackingAck,
    trackingAckHandle,
  )
import Shibuya.Batch
  ( BatchInfo (..),
    BatchTrigger (..),
    ackExcept,
    defaultBatchKey,
    withFallback,
  )
import Shibuya.Core (ProcessorHalt (..))
import Shibuya.Core.Ack
  ( AckDecision (..),
    DeadLetterReason (..),
    HaltReason (..),
    RetryDelay (..),
  )
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Policy (Concurrency (..))
import Shibuya.Runner.BatchProcessor (runBatchesWithMetrics)
import Shibuya.Runner.Metrics
  ( BatchStats (..),
    ProcessorId (..),
    ProcessorMetrics (..),
    StreamStats (..),
  )
import Shibuya.Telemetry.Effect (runTracingNoop)
import Test.Hspec
import UnliftIO (try)

spec :: Spec
spec = describe "Shibuya.Runner.BatchProcessor" $ do
  describe "decision resolution and finalization (M1)" $ do
    it "finalizes each of 5 messages successfully with per-message decisions" $ do
      (tracked, metrics) <- runEff $ runTracingNoop $ do
        tracking <- newTrackingAck
        batch <- buildBatch tracking 5 TriggerSize
        let handler _info _msgs =
              pure $
                ackExcept
                  [ (MessageId "msg-2", AckDeadLetter MaxRetriesExceeded),
                    (MessageId "msg-4", AckDeadLetter (PoisonPill "x"))
                  ]
        m <- runBatchesWithMetrics (ProcessorId "m1") Serial handler [batch]
        t <- getTrackedDecisions tracking
        pure (t, m)

      -- Each id appears exactly once in the successful-finalization list.
      map fst (sort tracked) `shouldBe` expectedIds
      lookup (MessageId "msg-1") tracked `shouldBe` Just AckOk
      lookup (MessageId "msg-2") tracked `shouldBe` Just (AckDeadLetter MaxRetriesExceeded)
      lookup (MessageId "msg-3") tracked `shouldBe` Just AckOk
      lookup (MessageId "msg-4") tracked `shouldBe` Just (AckDeadLetter (PoisonPill "x"))
      lookup (MessageId "msg-5") tracked `shouldBe` Just AckOk

      metrics.batch.batchesEmitted `shouldBe` 1
      metrics.batch.batchedMessages `shouldBe` 5
      metrics.batch.partialFailures `shouldBe` 1
      metrics.batch.sizeTriggered `shouldBe` 1
      metrics.stats.processed `shouldBe` 3
      metrics.stats.failed `shouldBe` 2

  describe "exception fallback (M2)" $ do
    it "finalizes all 5 with AckRetry when the handler throws" $ do
      (tracked, metrics) <- runEff $ runTracingNoop $ do
        tracking <- newTrackingAck
        batch <- buildBatch tracking 5 TriggerTimeout
        let handler _info _msgs = error "boom"
        m <- runBatchesWithMetrics (ProcessorId "m2-exc") Serial handler [batch]
        t <- getTrackedDecisions tracking
        pure (t, m)

      length tracked `shouldBe` 5
      map fst (sort tracked) `shouldBe` expectedIds
      all ((== AckRetry (RetryDelay 0)) . snd) tracked `shouldBe` True
      metrics.stats.failed `shouldBe` 5
      metrics.batch.partialFailures `shouldBe` 0
      metrics.batch.timeoutTriggered `shouldBe` 1

  describe "halt (M2)" $ do
    it "finalizes all 5, sets halt, and the driver throws ProcessorHalt" $ do
      -- Build the tracking ack OUTSIDE the aborted action so it survives the throw.
      tracking <- runEff $ runTracingNoop newTrackingAck
      result <- try $ runEff $ runTracingNoop $ do
        batch <- buildBatch tracking 5 TriggerFlush
        let handler _info _msgs =
              pure $
                withFallback
                  AckOk
                  [(MessageId "msg-3", AckHalt (HaltFatal "halt on 3"))]
        _ <- runBatchesWithMetrics (ProcessorId "m2-halt") Serial handler [batch]
        pure ()

      case result of
        Left (ProcessorHalt reason) -> reason `shouldBe` HaltFatal "halt on 3"
        Right () -> expectationFailure "expected ProcessorHalt"

      tracked <- runEff $ runTracingNoop $ getTrackedDecisions tracking
      map fst (sort tracked) `shouldBe` expectedIds
      lookup (MessageId "msg-3") tracked `shouldBe` Just (AckHalt (HaltFatal "halt on 3"))

  -- Also add the two resilience specs described in the milestone text:
  -- one flaky finalizer that throws for the first two attempts and then records
  -- one successful finalization, and one permanently failing finalizer that
  -- exhausts retries, names the failed MessageId in ProcessorHalt, and still
  -- attempts the remaining messages. Add the keyed-concurrency spec described
  -- in Validation and Acceptance to prove same-key batches do not overlap under
  -- Async.

expectedIds :: [MessageId]
expectedIds = [MessageId ("msg-" <> tshow i) | i <- [1 .. 5 :: Int]]

-- Build a batch of n messages whose acks record into the given TrackingAck.
buildBatch ::
  (IOE :> es) =>
  TrackingAck ->
  Int ->
  BatchTrigger ->
  Eff es (BatchInfo, NonEmpty (Ingested es String))
buildBatch tracking n trig = do
  let mk i =
        let mid = MessageId ("msg-" <> tshow i)
            env =
              Envelope
                { messageId = mid,
                  cursor = Nothing,
                  partition = Nothing,
                  enqueuedAt = Just testTime,
                  traceContext = Nothing,
                  headers = Nothing,
                  attempt = Nothing,
                  attributes = HashMap.empty,
                  payload = "payload-" <> show i
                }
         in Ingested
              { envelope = env,
                ack = trackingAckHandle tracking mid,
                lease = Nothing
              }
      msgs = map mk [1 .. n]
      info =
        BatchInfo
          { batchKey = defaultBatchKey,
            size = n,
            trigger = trig,
            partition = Nothing
          }
  pure (info, NE.fromList msgs)

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2026 1 1) 0

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
```

Two things to know while getting this to compile. First, `sort` on `[(MessageId,
AckDecision)]` requires `Ord` on the tuple; `MessageId` derives `Ord` but `AckDecision` does
not, so instead compare only the ids: the code above already does `map fst (sort tracked)` —
if `sort` still needs `Ord AckDecision`, change it to `sort (map fst tracked)`, which sorts a
`[MessageId]` and needs no `Ord AckDecision`. Prefer `sort (map fst tracked)` to avoid the
issue. Second, `expectedIds` and `lookup` are enough to prove normal-path finalization:
five entries, five distinct ids, each looked up to the right decision; a double-finalize would add a sixth
entry with a duplicate id and fail `map fst (sort ...) == expectedIds`.

Register the test module: add `Shibuya.Runner.BatchProcessorSpec` to the test-suite
`other-modules` in `shibuya-core/shibuya-core.cabal` (place it in the `Shibuya.Runner.*`
group, e.g. right after `Shibuya.Runner.SupervisedSpec`), and wire it into
`shibuya-core/test/Main.hs`:

```haskell
import Shibuya.Runner.BatchProcessorSpec qualified
...
  Shibuya.Runner.BatchProcessorSpec.spec
```

Follow the existing bare-`spec` convention in `Main.hs` (the newest entries call
`SomeSpec.spec` directly, since each spec opens with its own `describe`).

### Step 6 — Build, test, format

```bash
cabal build shibuya-core
cabal test shibuya-core-test
nix fmt
```

Expected `cabal test` transcript (abridged):

```text
Shibuya.Runner.BatchProcessor
  decision resolution and finalization (M1)
    finalizes each of 5 messages successfully with per-message decisions
    retries a transient finalizer failure and records one successful finalization
  exception fallback (M2)
    finalizes all 5 with AckRetry when the handler throws
  halt (M2)
    finalizes all 5, sets halt, and the driver throws ProcessorHalt
  finalizer failure (M2)
    exhausts retries, records the failed MessageId, and halts loudly
  keyed concurrency (M2)
    does not overlap batches with the same BatchKey under Async
```

with the overall run ending in `0 failures`.


## Validation and Acceptance

Acceptance is behavioral and proven by the new tests plus a REPL check.

1. `cabal build shibuya-core` compiles cleanly under `-Wall` (the `warnings` common stanza).
   Fix any unused-import warnings by trimming import lists.

2. `cabal test shibuya-core-test` passes, specifically the `Shibuya.Runner.BatchProcessor`
   block. The load-bearing assertions:
   - **M1 decision/finalization**: `sort (map fst tracked)` equals the five distinct ids,
     proving each message reached one successful finalization in the normal path (a duplicate
     success produces six entries with a duplicate id; a skip produces four). The per-id
     `lookup` checks the correct decision was applied. A separate flaky-finalizer test proves
     transient adapter failures are retried without changing the resolved decision.
     Metrics show `batchesEmitted = 1`, `batchedMessages = 5`, `partialFailures = 1`,
     `sizeTriggered = 1`, `processed = 3`, `failed = 2`.
   - **M2 exception fallback**: with a throwing handler, all five ids appear once with
     `AckRetry (RetryDelay 0)`, `failed = 5`, `partialFailures = 0`, `timeoutTriggered = 1`.
     This proves a handler crash cannot skip a message.
   - **M2 halt**: with one message resolved to `AckHalt`, the driver raises
     `ProcessorHalt (HaltFatal "halt on 3")` (caught by `try`), yet all five ids were still
     successfully finalized, with msg-3 carrying `AckHalt`. This proves halt does not abandon
     the batch.
   - **M2 finalizer failure**: a permanently throwing `AckHandle` is attempted through the full
     retry schedule, the final error is recorded on the span, the failed `MessageId` appears in
     the fatal halt reason, metrics enter `Failed`, and other messages in the batch are still
     attempted.
   - **M2 keyed concurrency**: with `Async 2`, two batches with different `BatchKey`s can overlap,
     but two batches with the same key cannot overlap. The assertion should use `MVar`s or
     `TVar`s to record start/end events and fail if a same-key start occurs before the previous
     same-key end.

3. REPL sanity check that the driver runs and metrics advance:

```bash
cabal repl shibuya-core
```

```haskell
ghci> :set -XOverloadedStrings
ghci> import Effectful (runEff)
ghci> import Shibuya.Telemetry.Effect (runTracingNoop)
ghci> import Shibuya.Runner.BatchProcessor (runBatchesWithMetrics)
ghci> import Shibuya.Batch (ackAllOk)
ghci> -- build a batch by hand (or reuse the spec helper), then:
ghci> -- runEff $ runTracingNoop $ runBatchesWithMetrics "p" Serial (\_ _ -> pure ackAllOk) [batch]
```

4. `nix fmt` leaves the tree clean, so the pre-commit hook accepts the change.

The change is complete when items 1, 2, and 4 all hold.


## Idempotence and Recovery

Every step is additive and safe to re-run. Editing `Shibuya.Runner.Metrics` adds a record, a
field, and helpers; re-applying is a no-op if the names already exist (do not add them twice).
Editing `Shibuya.Telemetry.Semantic` adds constants and exports similarly. Creating
`Shibuya/Runner/BatchProcessor.hs` and `test/Shibuya/Runner/BatchProcessorSpec.hs` are new
files; re-running the writes overwrites them with identical content. The cabal and `Main.hs`
insertions are idempotent list additions.

Most likely failure causes and fixes: a missing deriving strategy (every `deriving` must name
`stock`/`newtype`/`anyclass`); forgetting to add the `batch` field to `emptyProcessorMetrics`
(the only place that constructs `ProcessorMetrics` directly; existing record-update sites keep
working because they use named-field syntax); an unused import under `-Wall` (trim it);
`sort` requiring `Ord AckDecision` (use `sort (map fst tracked)` instead); or the test failing
to import `BatchProcessor` because it was left in `other-modules` (it must be in
`exposed-modules`). To roll back entirely, delete the two new files and revert the metrics,
semantic, cabal, and `Main.hs` insertions; nothing else changes behavior.


## Interfaces and Dependencies

Libraries used and why: `containers` (`Data.Map.Strict.findWithDefault`/`lookup`) to resolve
each retained message's decision; `stm` for the metrics `TVar`; `streamly`/`streamly-core` for
the batch stream and the `Serial`/`Ahead`/`Async` combinators; `effectful` for `Eff` and
`withEffToIO`; `unliftio` for `catchAny`/`throwIO`; `hs-opentelemetry-api` (via the `Tracing`
effect) for spans; `text` for the halt/trigger strings. All are existing dependencies.

At the end of this plan the following exist.

In `Shibuya.Runner.Metrics` (`shibuya-core/src/Shibuya/Runner/Metrics.hs`), exported:

```haskell
data BatchStats = BatchStats
  { batchesEmitted   :: !Int
  , batchedMessages  :: !Int
  , partialFailures  :: !Int
  , sizeTriggered    :: !Int
  , timeoutTriggered :: !Int
  , flushTriggered   :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

emptyBatchStats     :: BatchStats
incBatchesEmitted   :: BatchStats -> BatchStats
addBatchedMessages  :: Int -> BatchStats -> BatchStats
incPartialFailures  :: BatchStats -> BatchStats
incSizeTriggered    :: BatchStats -> BatchStats
incTimeoutTriggered :: BatchStats -> BatchStats
incFlushTriggered   :: BatchStats -> BatchStats

-- and 'ProcessorMetrics' gains: batch :: !BatchStats
```

In `Shibuya.Telemetry.Semantic` (`shibuya-core/src/Shibuya/Telemetry/Semantic.hs`), exported:

```haskell
attrShibuyaBatchKey     :: Text  -- "shibuya.batch.key"
attrShibuyaBatchSize    :: Text  -- "shibuya.batch.size"
attrShibuyaBatchTrigger :: Text  -- "shibuya.batch.trigger"
eventBatchStarted       :: Text  -- "shibuya.batch.started"
eventBatchCompleted     :: Text  -- "shibuya.batch.completed"
```

In `Shibuya.Runner.BatchProcessor`
(`shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`), exported:

```haskell
processOneBatch ::
  (IOE :> es, Tracing :> es) =>
  TVar ProcessorMetrics ->
  ProcessorId ->
  Int ->
  IORef (Maybe HaltReason) ->
  BatchHandler es msg ->
  (BatchInfo, NonEmpty (Ingested es msg)) ->
  Eff es ()

processBatchesUntilDrained ::
  (IOE :> es, Tracing :> es) =>
  TVar ProcessorMetrics ->
  ProcessorId ->
  Concurrency ->
  BatchHandler es msg ->
  Stream IO (BatchInfo, NonEmpty (Ingested es msg)) ->
  IORef (Maybe HaltReason) ->
  Eff es ()

runBatchesWithMetrics ::
  (IOE :> es, Tracing :> es) =>
  ProcessorId ->
  Concurrency ->
  BatchHandler es msg ->
  [(BatchInfo, NonEmpty (Ingested es msg))] ->
  Eff es ProcessorMetrics
```

Also implement the internal helper `finalizeWithRetry` in the same module. It does not need
to be exported, but its behavior is part of the reliability contract: resolve the decision
before calling it, call the idempotent `AckHandle.finalize`, retry after `[10ms, 50ms,
250ms]` on exceptions, and return the final exception to `processOneBatch` if all attempts
fail. `processBatchesUntilDrained` must use a keyed scheduler internally so same-key
batches never overlap under `Ahead` or `Async`.

Downstream consumers: `docs/plans/19-batch-runner-and-app-integration.md` ("EP-19") mounts
`processBatchesUntilDrained` inside a supervised runner analogous to
`runIngesterAndProcessor`, creating the `haltRef` and, after draining, reading it and throwing
`ProcessorHalt` exactly as `processUntilDrained` does for single messages; it also exposes the
new `BatchStats` counters through `getAppMetrics`.
`docs/plans/20-batch-reliability-test-suite.md` ("EP-20") asserts the same decision,
finalization retry, fail-loud, and per-key FIFO properties end-to-end through `runApp`.
Both depend on the signatures above being exactly as written; keep field and function names
stable.

Coordination note for EP-17: the emitted-batch type consumed here is exactly
`(BatchInfo, NonEmpty (Ingested es msg))` carried as `Stream IO (...)`. If EP-17 changes it,
update the MasterPlan Integration Points and this section together. EP-17 also owns halting the
*emission* of new batches once the shared halt flag is set (EP-18 keeps finalizing whatever it
is handed).

Coordination note for EP-19: because this plan places `Shibuya.Runner.BatchProcessor` in the
library `exposed-modules`, EP-19 may import it directly. EP-19 creates the shared
`IORef (Maybe HaltReason)`, threads it into `processBatchesUntilDrained`, and — after the
stream drains — reads it and throws `ProcessorHalt reason` (the supervised runner already
catches `ProcessorHalt` and converts it to a graceful exit, so no new exception handling is
needed).


## Revision Note

- 2026-07-01: Initial authoring of EP-18. Recorded the decision (in the Decision Log and
  reflected in Step 4 and the Interfaces section) to place `Shibuya.Runner.BatchProcessor` in
  the library `exposed-modules` rather than `other-modules`, because the in-package HSpec
  test-suite cannot import a library `other-modules` module; exposing it matches
  `Shibuya.Runner.Supervised`/`Shibuya.Runner.Metrics`, which are already exposed and imported
  by tests. All other design choices follow the MasterPlan
  (`docs/masterplans/3-first-class-batch-processing.md`) and EP-16
  (`docs/plans/16-batch-api-and-configuration-types.md`); this plan embeds the concrete types
  it depends on so it stands alone.

- 2026-07-01: Strengthened EP-18 after architecture validation. The plan now distinguishes
  one-time `BatchAck` decision resolution from idempotent finalization attempts, requires
  bounded retry plus fail-loud behavior for adapter finalizer failures, and replaces raw
  global `parMapM` batch execution with a keyed scheduler that preserves FIFO execution for
  each `BatchKey`.

- 2026-07-01: Replaced the keyed scheduler placeholder with a concrete STM dispatcher shape:
  stream reader, pending FIFO queue, active-key set, bounded worker count, first-failure
  capture, and drain-before-throw semantics. This prevents the implementation plan from
  copying a latent `error` path into production code.
