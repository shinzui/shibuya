---
id: 21
slug: batch-documentation-and-example
title: "Batch Documentation and Example"
kind: exec-plan
created_at: 2026-07-01T15:34:32Z
intention: "intention_01kwf4q2bke2js9t0js53dwh5a"
master_plan: "docs/masterplans/3-first-class-batch-processing.md"
---

# Batch Documentation and Example

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the final child of the MasterPlan at
`docs/masterplans/3-first-class-batch-processing.md` ("First-Class Batch Processing"). It
makes the batching feature — built by the sibling plans EP-16 through EP-20 — discoverable
and demonstrably runnable. It hard-depends on
`docs/plans/19-batch-runner-and-app-integration.md` (EP-19), which finalizes the public
API this plan documents and demonstrates, and soft-depends on
`docs/plans/20-batch-reliability-test-suite.md` (EP-20), whose reliability guarantees this
plan cites but does not require to be green before drafting.


## Purpose / Big Picture

Shibuya is a Haskell queue-processing framework. Until the batch initiative it processed
exactly one message at a time: a `Handler es msg` (a function
`Ingested es msg -> Eff es AckDecision`) received one message and returned one
acknowledgement decision, which the framework applied via that one message's own
acknowledgement handle. Many real workloads want to process messages in *groups* — insert
500 rows in a single `INSERT ... VALUES`, upload many objects in one S3 multipart call,
send one batched HTTP request — because per-message round trips to a downstream system are
slow and expensive. The sibling plans (EP-16 through EP-19) add first-class batching: a
processor can accumulate messages into batches, emit a batch when it reaches a configured
size or a configured timeout elapses (whichever comes first), route messages into
independent sub-batches by a *batch key*, run a *batch handler* once over the whole batch,
and then acknowledge every message in the batch exactly once.

After this plan a user can do two concrete things that they cannot do today. First, they
can run `cabal run shibuya-batch-example` from the repository root and watch a batching
processor group five sample orders into batches, print a line for each emitted batch, flush
the final partial batch on shutdown, and report batch-level metrics — a working,
self-contained demonstration they can copy from. Second, they can open the architecture
documentation (`docs/architecture/MESSAGE_FLOW.md`, `docs/architecture/CORE_TYPES.md`,
`docs/architecture/METRICS.md`) and the Broadway comparison
(`docs/BROADWAY_COMPARISON.md`) and find batching described as an implemented,
first-class feature rather than a "major gap" — including the batching pipeline stage, the
`Shibuya.Batch` public types, the batch metrics fields, and the acknowledgement
decision/finalization contract.

This plan writes no framework code. It adds one runnable example program and updates four
(optionally five) documentation files. Its acceptance is entirely behavioral: the example
builds and prints a specific transcript, and the documentation accurately describes the
shipped API. Because this plan is authored *before* EP-18 and EP-19 are implemented, it
quotes the intended public API and instructs the implementer to verify the exact spellings
against the then-current source before finalizing the docs, recording any drift in the
Decision Log.


## Progress

- [ ] Verify the shipped public API: read `shibuya-core/src/Shibuya/Batch.hs`, `shibuya-core/src/Shibuya/App.hs`, and `shibuya-core/src/Shibuya/Runner/Metrics.hs`, and record in the Decision Log any name/shape drift from the signatures quoted in this plan.
- [ ] M1: Add the `shibuya-batch-example` executable stanza to `shibuya-example/shibuya-example.cabal`.
- [ ] M1: Create `shibuya-example/app-batch/Main.hs` (the runnable batching example).
- [ ] M1: `cabal run shibuya-batch-example` builds and prints the documented transcript; reconcile the transcript in this plan with any drift.
- [ ] M2: Update `docs/architecture/MESSAGE_FLOW.md` (batching stage in the pipeline diagram; batch metrics/state transitions; size vs timeout vs flush triggers).
- [ ] M2: Update `docs/architecture/CORE_TYPES.md` (the `Shibuya.Batch` public types, `BatchingProcessor`/`mkBatchProcessor`, acknowledgement decision/finalization contract).
- [ ] M2: Update `docs/architecture/METRICS.md` (the `BatchStats` fields on `ProcessorMetrics`).
- [ ] M2: Update `docs/BROADWAY_COMPARISON.md` (flip the Batching gap to done; update Feature Matrix and the "Priority 1: First-Class Batching" roadmap section).
- [ ] M2: Optionally update `README.md` feature list / status table if it enumerates features.
- [ ] `nix fmt` clean; `cabal build all` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Ship the runnable example as a **new executable target**
  `shibuya-batch-example` (new source directory `shibuya-example/app-batch/`, new stanza in
  `shibuya-example/shibuya-example.cabal`) rather than adding a batching processor to the
  existing `shibuya-example/app/Main.hs`.
  Rationale: The existing example (`shibuya-example/app/Main.hs`) wires two *infinite*
  counter adapters, starts a metrics web server, and loops printing metrics for five
  seconds. Splicing a batching processor into that program would entangle the batch
  demonstration with an infinite stream (making message counts and therefore the
  transcript non-deterministic) and with the metrics-server lifecycle. A dedicated,
  finite, single-processor program yields a short, deterministic transcript a reader can
  compare line-for-line, which is the whole point of the deliverable. The two examples
  coexist; neither imports the other. If a future maintainer prefers a single example,
  merging is a mechanical follow-up.
  Date: 2026-07-01

- Decision: The example uses a **five-message finite order set** with `batchSize = 2`, a
  deliberately large `batchTimeout` (60 s) so the timeout never fires during the short run,
  and a `batchKey` that routes by the order's region. The message set is chosen so that two
  batches emit by size (`us` = [10, 11], `eu` = [20, 21]) and exactly one single-key
  leftover (`apac` = [30]) remains to be flushed on shutdown.
  Rationale: A large timeout removes the timeout trigger from the picture, so emission is
  driven purely by size and by the shutdown flush — both deterministic. Making every
  size-triggered key an exact multiple of `batchSize` and leaving exactly one leftover of a
  *distinct* key means the shutdown flush produces exactly one batch, so the transcript is
  independent of the (implementation-defined) order in which multiple pending keys would
  flush. This still demonstrates batch-key routing (three distinct keys) and a partial
  failure (one poison order dead-lettered inside an otherwise-successful batch).
  Date: 2026-07-01

- Decision: The example's adapter emits the five orders and then **blocks** (it does not end
  its own stream) until `shutdown` is called, using
  `Streamly.Data.Stream.nilM (liftIO (readMVar stopVar))` appended after the order stream.
  Rationale: The deliverable must show that `stopApp` flushes the final partial batch. If
  the adapter's stream ended on its own (a plain finite `listAdapter`), the batcher would
  flush the leftover at end-of-stream *before* the reader ever calls `stopApp`, and the
  "shutdown flushes" narrative would not be observable. Blocking after the orders keeps the
  leftover batch pending (visible in metrics as "not yet emitted") until `shutdown` fills
  the `MVar`, at which point the stream ends, the batcher flushes the leftover as
  `TriggerFlush`, and each message is acknowledged. This mirrors a real queue that is
  momentarily empty but not closed.
  Date: 2026-07-01

- Decision: Documentation files changed in M2 are exactly
  `docs/architecture/MESSAGE_FLOW.md`, `docs/architecture/CORE_TYPES.md`,
  `docs/architecture/METRICS.md`, and `docs/BROADWAY_COMPARISON.md`, with `README.md` as an
  optional fifth (its feature/status list is updated only if it still enumerates features
  when this plan runs).
  Rationale: These are the four architecture/comparison documents that describe the
  pipeline, the core types, the metrics, and the Broadway feature gap that the batch
  initiative closes. Keeping the set explicit prevents doc drift from being scattered.
  Date: 2026-07-01

- Decision: The intended public API (`BatchingProcessor`/`mkBatchProcessor` and the
  `BatchStats` metrics) is quoted from the sibling plans and treated as a *target* to be
  verified. The implementer must read the shipped source first and update both the example
  and the docs to whatever names actually shipped, recording drift here.
  Rationale: EP-18 (`docs/plans/18-batch-execution-and-exactly-once-ack.md`) and EP-19
  (`docs/plans/19-batch-runner-and-app-integration.md`) are still skeletons when this plan
  is authored, so the exact field names of `BatchStats` and the exact constructor shape of
  `BatchingProcessor` are not yet frozen in code. This plan cannot invent them
  authoritatively; it can only pin the contract (per MasterPlan Integration Points) and
  require reconciliation.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the repository. Everything you need to write the
example and the documentation is here, including the concrete type signatures the example
depends on.

Shibuya is a Cabal project rooted at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. The core library package is
`shibuya-core` (sources under `shibuya-core/src/Shibuya/`). There is a separate example
package `shibuya-example` (`shibuya-example/shibuya-example.cabal`) whose single executable
lives in `shibuya-example/app/Main.hs`. The default language is `GHC2024` and these
extensions are on by default for the example package (from its cabal `default-extensions`):
`DeriveAnyClass`, `DerivingStrategies`, `DuplicateRecordFields`, `LambdaCase`,
`NoFieldSelectors`, `OverloadedLabels`, `OverloadedRecordDot`, `OverloadedStrings`,
`QuasiQuotes`. Two consequences matter for the example. Because `NoFieldSelectors` is on,
record fields do not generate top-level accessor functions; you read a field with dot
syntax (`value.field`, from `OverloadedRecordDot`) — for example `ingested.envelope.payload`
or `info.batchKey.unBatchKey`. Because `DerivingStrategies` is on, every `deriving` clause
must name its strategy (`stock`, `newtype`, or `anyclass`).

Build, run, and format commands (run from the repository root):

```bash
cabal build all
cabal run shibuya-example
cabal run shibuya-batch-example
nix fmt
```

`nix fmt` runs `treefmt` (Fourmolu for Haskell); the pre-commit hook rejects unformatted
files, so always run it before committing.

### Terms of art used in this plan

- **Batch**: a non-empty group of ingested messages handed to a batch handler together.
- **Batch key**: a value (wrapped `Text`) computed from each message's envelope that
  decides which sub-batch the message accumulates into. Messages sharing a key accumulate
  together and emit together; different keys accumulate independently, each with its own
  size counter and timeout.
- **Batch trigger**: the reason a batch was emitted — it filled to the configured size
  (`TriggerSize`), its timeout elapsed (`TriggerTimeout`), or the processor is draining and
  flushed a partial batch (`TriggerFlush`).
- **Batch acknowledgement decision/finalization**: every message retained in an emitted
  batch receives exactly one `AckDecision`; that decision is applied through the message's
  idempotent finalizer with bounded retry and loud failure on permanent adapter errors.
- **Ingested message**: the single value that flows through the pipeline, pairing a
  message envelope with its acknowledgement handle.
- **Adapter**: a queue-specific source of ingested messages plus a shutdown action.

### The pipeline, before and after batching

Today's pipeline (one processor) is two stages:
`Adapter.source (stream) -> Ingester (async, bounded inbox) -> Processor -> Ack`. The
adapter produces a Streamly stream of `Ingested es msg`; the ingester pulls from it and
sends into a bounded in-memory queue (the "inbox") that blocks the ingester when full
(backpressure); the processor pulls one message from the inbox, runs the `Handler`, and
finalizes that one message's acknowledgement. Batching inserts one stage between the inbox
and acknowledgement: a **batcher** that accumulates inbox messages by batch key and emits a
batch on the size, timeout, or flush trigger; the emitted batch is run by a **batch
handler**, each retained message receives one acknowledgement decision, and those decisions
are applied through per-message finalizers with bounded retry/fail-loud behavior. The batcher
sits entirely on the consumer side of the existing per-message acknowledgement handle, so no
adapter changes.

### Concrete existing types the example imports

`AckDecision` and friends live in `shibuya-core/src/Shibuya/Core/Ack.hs`:

```haskell
newtype RetryDelay = RetryDelay {unRetryDelay :: NominalDiffTime}

data DeadLetterReason = PoisonPill !Text | InvalidPayload !Text | MaxRetriesExceeded

data HaltReason = HaltOrderedStream !Text | HaltFatal !Text

data AckDecision
  = AckOk
  | AckRetry !RetryDelay
  | AckDeadLetter !DeadLetterReason
  | AckHalt !HaltReason
```

`MessageId` and `Envelope` live in `shibuya-core/src/Shibuya/Core/Types.hs`. Note that
`Envelope` has more fields than the (slightly out-of-date) `CORE_TYPES.md` shows; the real
record includes `headers`, `attempt`, and `attributes`. When you construct an `Envelope`
by hand you must fill every field:

```haskell
newtype MessageId = MessageId {unMessageId :: Text}

data Envelope msg = Envelope
  { messageId    :: !MessageId
  , cursor       :: !(Maybe Cursor)
  , partition    :: !(Maybe Text)
  , enqueuedAt   :: !(Maybe UTCTime)
  , traceContext :: !(Maybe TraceHeaders)
  , headers      :: !(Maybe Headers)          -- [(ByteString, ByteString)] or Nothing
  , attempt      :: !(Maybe Attempt)
  , attributes   :: !(HashMap Text Attribute)
  , payload      :: !msg
  }
```

`Ingested` lives in `shibuya-core/src/Shibuya/Core/Ingested.hs`:

```haskell
data Ingested es msg = Ingested
  { envelope :: !(Envelope msg)
  , ack      :: !(AckHandle es)
  , lease    :: !(Maybe (Lease es))
  }
```

The mock helpers for building test/example messages live in
`shibuya-core/src/Shibuya/Adapter/Mock.hs`. The example uses `TrackingAck` (an in-memory
acknowledgement recorder), `newTrackingAck`, and
`trackingAckHandle :: TrackingAck -> MessageId -> AckHandle es` (records each `finalize`
into an `IORef`). The existing `shibuya-example/app/Main.hs` already imports and uses these
exactly this way, so follow that file as a reference for envelope construction.

The `Adapter` type is in `shibuya-core/src/Shibuya/Adapter.hs`:

```haskell
data Adapter es msg = Adapter
  { adapterName :: !Text
  , source      :: Stream (Eff es) (Ingested es msg)   -- Streamly.Data.Stream.Stream
  , shutdown    :: Eff es ()
  }
```

The public application API is `Shibuya.App` (`shibuya-core/src/Shibuya/App.hs`). Today it
exposes an existential GADT and its smart constructor:

```haskell
data QueueProcessor es where
  QueueProcessor ::
    { adapter     :: Adapter es msg
    , handler     :: Handler es msg
    , ordering    :: Ordering
    , concurrency :: Concurrency
    } -> QueueProcessor es

mkProcessor :: Adapter es msg -> Handler es msg -> QueueProcessor es   -- Unordered Serial

runApp ::
  (IOE :> es, Tracing :> es) =>
  SupervisionStrategy -> Int -> [(ProcessorId, QueueProcessor es)] ->
  Eff es (Either AppError (AppHandle es))

data SupervisionStrategy = IgnoreFailures | StopAllOnFailure

getAppMetrics :: AppHandle es -> Eff es (Map ProcessorId ProcessorMetrics)
stopApp       :: AppHandle es -> Eff es Bool          -- flushes and drains, then stops
```

`Ordering` (`StrictInOrder | PartitionedInOrder | Unordered`) and `Concurrency`
(`Serial | Ahead Int | Async Int`) live in `shibuya-core/src/Shibuya/Policy.hs`; the
existential `QueueProcessor` hides the message type `msg`, which is why `runApp` takes a
list of them.

### The `Shibuya.Batch` public vocabulary (from EP-16, already frozen)

The module `Shibuya.Batch` (`shibuya-core/src/Shibuya/Batch.hs`, defined by
`docs/plans/16-batch-api-and-configuration-types.md` and frozen there) exports the types
below. The example imports these directly; do not redefine them. They are reproduced
verbatim so this plan stands alone:

```haskell
newtype BatchKey = BatchKey {unBatchKey :: Text}     -- Eq, Ord, Show, Generic; IsString; NFData
defaultBatchKey :: BatchKey                          -- BatchKey "default"

data BatchTrigger = TriggerSize | TriggerTimeout | TriggerFlush   -- Eq, Show, Generic; NFData

data BatchInfo = BatchInfo
  { batchKey  :: !BatchKey
  , size      :: !Int
  , trigger   :: !BatchTrigger
  , partition :: !(Maybe Text)
  }

data BatchConfig es msg = BatchConfig
  { batchSize    :: !Int
  , batchTimeout :: !NominalDiffTime
  , batchKey     :: !(Envelope msg -> BatchKey)
  , tickInterval :: !(Maybe NominalDiffTime)         -- Nothing => use batchTimeout
  }
defaultBatchConfig :: BatchConfig es msg             -- size 100, timeout 1s, const defaultBatchKey, tick Nothing

data BatchConfigError
  = BatchSizeNotPositive !Int
  | BatchTimeoutNotPositive !NominalDiffTime
  | TickIntervalNotPositive !NominalDiffTime
validateBatchConfig :: BatchConfig es msg -> Either BatchConfigError ()

type BatchHandler es msg = BatchInfo -> NonEmpty (Ingested es msg) -> Eff es BatchAck

data BatchAck = BatchAck
  { decisions :: !(Map MessageId AckDecision)
  , fallback  :: !AckDecision
  }
ackAllOk     :: BatchAck                                  -- BatchAck empty AckOk
ackAll       :: AckDecision -> BatchAck                   -- BatchAck empty d
ackExcept    :: [(MessageId, AckDecision)] -> BatchAck    -- overrides, fallback AckOk
withFallback :: AckDecision -> [(MessageId, AckDecision)] -> BatchAck
failMessages :: [(MessageId, DeadLetterReason)] -> BatchAck
```

The **batch acknowledgement decision and finalization contract**, which the documentation must
state verbatim (it is the normative spec, defined in EP-16 and consumed by EP-18/EP-20):

> Given an emitted batch and the `BatchAck` a `BatchHandler` returns, the framework
> resolves exactly one `AckDecision` for every message in its own retained batch list. For
> each retained message it looks the message's `MessageId` up in `decisions`; if the id is
> absent it uses `fallback`. The handler's return value only supplies decisions — it never
> drives which messages are acked. The execution stage then applies those decisions through
> each message's idempotent finalizer with bounded retries. A permanently failing finalizer
> is surfaced as a loud processor failure with the affected `MessageId`; it is not swallowed.
> This requires `MessageId`s to be unique within a batch, which holds for every real adapter
> and the mock adapter.

### The intended public API added by EP-19 and EP-18 (VERIFY before use)

The example and the documentation depend on two additions the sibling plans make. Because
those plans are skeletons at authoring time, the exact spellings below are a **target**;
the first implementation step is to read the shipped source and reconcile.

EP-19 (`docs/plans/19-batch-runner-and-app-integration.md`, MasterPlan Integration Point
"The QueueProcessor / App public API") adds a `BatchingProcessor` constructor to the
existential GADT `QueueProcessor es` in `shibuya-core/src/Shibuya/App.hs`, plus a
`mkBatchProcessor` smart constructor. The intended shape:

```haskell
data QueueProcessor es where
  QueueProcessor ::
    { adapter     :: Adapter es msg
    , handler     :: Handler es msg
    , ordering    :: Ordering
    , concurrency :: Concurrency
    } -> QueueProcessor es
  BatchingProcessor ::
    { adapter      :: Adapter es msg
    , batchHandler :: BatchHandler es msg
    , batchConfig  :: BatchConfig es msg
    , ordering     :: Ordering
    , concurrency  :: Concurrency
    } -> QueueProcessor es

-- Defaults to Unordered ordering and Serial concurrency (one batch at a time,
-- in emission order), matching mkProcessor's defaults.
mkBatchProcessor ::
  Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es
```

(`DuplicateRecordFields` lets `adapter`, `ordering`, and `concurrency` repeat across the two
constructors.) The example uses only `mkBatchProcessor`, so even if the exact
`BatchingProcessor` field names drift, the example is insulated as long as
`mkBatchProcessor`'s three-argument shape holds. Verify the smart-constructor arity and
argument order against the shipped `Shibuya.App`.

EP-18 (`docs/plans/18-batch-execution-and-exactly-once-ack.md`, MasterPlan Integration
Point "Processor metrics") extends `ProcessorMetrics` in
`shibuya-core/src/Shibuya/Runner/Metrics.hs` with batch counters. The intended shape is a
`BatchStats` record reached through a new field on `ProcessorMetrics`:

```haskell
data BatchStats = BatchStats
  { batchesEmitted     :: !Int   -- number of batches handed to the batch handler
  , batchedMessages    :: !Int   -- total messages across all emitted batches
  , partialFailures    :: !Int   -- batches where at least one message was not AckOk
  , triggeredBySize    :: !Int   -- batches emitted because they reached batchSize
  , triggeredByTimeout :: !Int   -- batches emitted because batchTimeout elapsed
  , triggeredByFlush   :: !Int   -- batches emitted by a drain/shutdown flush
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ProcessorMetrics = ProcessorMetrics
  { state     :: !ProcessorState
  , stats     :: !StreamStats
  , batch     :: !BatchStats       -- NEW field added by EP-18
  , startedAt :: !UTCTime
  }
```

The existing `StreamStats` (in the same module) is unchanged and continues to count
per-message outcomes: `received` (messages the ingester sent to the inbox), `processed`
(each message finalized with `AckOk` or `AckRetry`), and `failed` (each message finalized
with `AckDeadLetter`, plus handler exceptions). Batch acknowledgements flow through the same
per-message finalize path, so a batch of two `AckOk` messages increments `processed` by two.
Verify the exact field names of `BatchStats` and the exact name of the `ProcessorMetrics`
field (this plan assumes `batch`) against the shipped `Shibuya.Runner.Metrics`, and adjust
both the example's `printMetrics` and the `docs/architecture/METRICS.md` update to match.


## Plan of Work

The work is two milestones. **Milestone 1 (M1)** delivers the runnable example: a new
executable target that a reader can run to watch batching happen and see the exact
transcript. **Milestone 2 (M2)** updates the four architecture/comparison documents (and,
optionally, the README) so batching is documented as a shipped feature and the Broadway
"major gap" is closed. M2 depends only on the finalized public API, not on M1, but doing M1
first surfaces any API drift that must then be reflected in M2.

Before either milestone, perform the **verification step**: open
`shibuya-core/src/Shibuya/Batch.hs`, `shibuya-core/src/Shibuya/App.hs`, and
`shibuya-core/src/Shibuya/Runner/Metrics.hs`, and confirm the signatures in "Context and
Orientation" match what shipped. If `mkBatchProcessor` has a different arity or argument
order, if the `BatchStats` fields are named differently, or if the `ProcessorMetrics` batch
field is not called `batch`, note the drift in the Decision Log and carry the real names
through both milestones.

### Milestone 1: runnable batching example with an exact transcript

Scope: add a second executable, `shibuya-batch-example`, to the `shibuya-example` package.
At the end, `cabal run shibuya-batch-example` builds and prints a deterministic transcript
that shows two size-triggered batches, a partial failure (one dead-lettered order), the
batch metrics, and a final partial batch flushed on shutdown. Acceptance: the transcript
matches (line-for-line except for the documented non-determinism caveat) the "Concrete
Steps" transcript.

First, add the executable stanza to `shibuya-example/shibuya-example.cabal`. Append it
after the existing `executable shibuya-example` stanza. It reuses the same
`default-language`, `default-extensions`, and `warnings` common stanza, but a different
`main-is` source directory (`app-batch`) so the two `Main` modules do not collide. It needs
fewer dependencies than the existing example: no metrics server and no OpenTelemetry SDK
(the batch example runs the tracing effect in no-op mode, provided by `shibuya-core`). The
stanza:

```cabal
executable shibuya-batch-example
  import: warnings
  ghc-options:
    -threaded
    -rtsopts

  main-is: Main.hs
  hs-source-dirs: app-batch
  default-language: GHC2024
  default-extensions:
    DeriveAnyClass
    DerivingStrategies
    DuplicateRecordFields
    LambdaCase
    NoFieldSelectors
    OverloadedLabels
    OverloadedRecordDot
    OverloadedStrings
    QuasiQuotes

  build-depends:
    base ^>=4.21.0.0,
    containers,
    effectful ^>=2.6.1.0,
    shibuya-core,
    streamly-core ^>=0.3,
    text ^>=2.1.3,
    unordered-containers ^>=0.2,
```

Second, create `shibuya-example/app-batch/Main.hs` with the program shown in full in
"Concrete Steps". Its structure, in prose: it defines a small `Order` payload type
(`orderId`, `region`, `poison`); a `sampleOrders` list of five orders; a `mkIngested`
helper that wraps an `Order` in an `Envelope` (region goes into the envelope's `partition`
field, message id is `"order-" <> show orderId`) with a `trackingAckHandle`; an
`ordersAdapter` that streams the five ingested orders and then blocks on an `MVar` until
`shutdown` fills it (so the leftover batch stays pending until `stopApp`); a `batchCfg`
(`batchSize = 2`, `batchTimeout = 60`, `batchKey` routing by region); a `batchHandler` that
prints one line per emitted batch (`flushed batch of N messages (key=..., trigger=...)`),
dead-letters any poison order in the batch (and prints a note), and otherwise returns
`ackAllOk`; a `printMetrics` that reads `getAppMetrics` and prints the per-message and batch
counters; and a `main`/`app` that starts one batching processor via `mkBatchProcessor` +
`runApp`, waits for the two size batches to settle, prints metrics, then `stopApp`s (which
flushes the final partial batch).

Third, build and run it, comparing the transcript. If the shipped API differed from the
target, update `Main.hs` accordingly and then update the transcript in this plan so it
stays accurate.

### Milestone 2: documentation updates and Broadway gap closure

Scope: update `docs/architecture/MESSAGE_FLOW.md`, `docs/architecture/CORE_TYPES.md`,
`docs/architecture/METRICS.md`, and `docs/BROADWAY_COMPARISON.md`, and optionally
`README.md`. At the end, the docs describe batching as a shipped, first-class feature. Each
edit is described concretely below in "Concrete Steps". Acceptance: each file contains the
new batching content and no longer describes batching as missing; a reader following the
docs can find the `Shibuya.Batch` types, the batch metrics, and the batching pipeline
stage.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

### Step 0 — verify the shipped API

```bash
sed -n '1,60p' shibuya-core/src/Shibuya/Batch.hs
grep -nE 'mkBatchProcessor|BatchingProcessor|batchHandler|batchConfig' shibuya-core/src/Shibuya/App.hs
grep -nE 'BatchStats|batchesEmitted|triggeredBy|data ProcessorMetrics' shibuya-core/src/Shibuya/Runner/Metrics.hs
```

Confirm the signatures match "Context and Orientation". Record any drift in the Decision
Log and carry the real names forward.

### Step 1 (M1) — add the executable stanza

Edit `shibuya-example/shibuya-example.cabal` and append the `executable shibuya-batch-example`
stanza shown in "Plan of Work" after the existing `executable shibuya-example` stanza.

### Step 2 (M1) — create the example program

Create `shibuya-example/app-batch/Main.hs` with the following contents. If Step 0 found
drift, adjust the imports/field accesses accordingly.

```haskell
-- | Runnable example of first-class batch processing in Shibuya.
--
-- Feeds five sample orders through one batching processor. Orders are grouped
-- into sub-batches by region (the batch key). With batchSize = 2, the "us" and
-- "eu" regions each fill a batch of two (emitted by TriggerSize); the single
-- "apac" order is left partial and is flushed on shutdown (TriggerFlush). One
-- order is a "poison" order that the batch handler dead-letters, demonstrating
-- a partial failure inside an otherwise-successful batch.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar)
import Control.Monad (forM_, void)
import Data.Function ((&))
import Data.HashMap.Strict qualified as HashMap
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Mock (TrackingAck, newTrackingAck, trackingAckHandle)
import Shibuya.App
  ( AppHandle,
    ProcessorId (..),
    ProcessorMetrics (..),
    SupervisionStrategy (..),
    getAppMetrics,
    mkBatchProcessor,
    runApp,
    stopApp,
  )
import Shibuya.Batch
  ( BatchAck,
    BatchConfig (..),
    BatchHandler,
    BatchInfo (..),
    BatchKey (..),
    ackAllOk,
    defaultBatchConfig,
    failMessages,
  )
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Runner.Metrics (BatchStats (..), StreamStats (..))
import Shibuya.Telemetry.Effect (Tracing, runTracingNoop)
import Streamly.Data.Stream qualified as Stream

-- | The example payload. 'region' becomes the batch key; 'poison' orders are
-- dead-lettered by the batch handler.
data Order = Order
  { orderId :: !Int,
    region :: !Text,
    poison :: !Bool
  }
  deriving stock (Eq, Show)

-- | Five orders: "us" = [10,11], "eu" = [20,21], "apac" = [30].
-- Order 21 is poison. With batchSize = 2 the us and eu batches fill by size;
-- the single apac order stays partial until the shutdown flush.
sampleOrders :: [Order]
sampleOrders =
  [ Order 10 "us" False,
    Order 11 "us" False,
    Order 20 "eu" False,
    Order 21 "eu" True,
    Order 30 "apac" False
  ]

-- | Wrap an 'Order' in an 'Ingested' message with a tracking ack handle.
mkIngested :: (IOE :> es) => TrackingAck -> Order -> Eff es (Ingested es Order)
mkIngested tracking o = do
  let msgId = MessageId ("order-" <> Text.pack (show o.orderId))
  pure
    Ingested
      { envelope =
          Envelope
            { messageId = msgId,
              cursor = Nothing,
              partition = Just o.region,
              enqueuedAt = Nothing,
              traceContext = Nothing,
              headers = Nothing,
              attempt = Nothing,
              attributes = HashMap.empty,
              payload = o
            },
        ack = trackingAckHandle tracking msgId,
        lease = Nothing
      }

-- | Adapter that emits the five orders and then blocks until 'shutdown' fills
-- the MVar. Blocking (rather than ending the stream) keeps the partial "apac"
-- batch pending so that 'stopApp' is what flushes it.
ordersAdapter :: (IOE :> es) => TrackingAck -> MVar () -> [Order] -> Adapter es Order
ordersAdapter tracking stopVar orders =
  Adapter
    { adapterName = "orders",
      source =
        Stream.append
          (Stream.fromList orders & Stream.mapM (mkIngested tracking))
          (Stream.nilM (liftIO (readMVar stopVar))),
      shutdown = do
        liftIO $ Text.putStrLn "Shutting down orders adapter"
        liftIO $ void (tryPutMVar stopVar ())
    }

-- | Batch configuration: group by region, two per batch, a long timeout so the
-- timeout trigger never fires during this short run.
batchCfg :: BatchConfig es Order
batchCfg =
  defaultBatchConfig
    { batchSize = 2,
      batchTimeout = 60,
      batchKey = \env -> BatchKey env.payload.region
    }

-- | Simulate a bulk downstream write: print one line per emitted batch, then
-- dead-letter any poison order and ack the rest OK.
batchHandler :: (IOE :> es) => BatchHandler es Order
batchHandler info msgs = do
  liftIO $
    Text.putStrLn $
      "flushed batch of "
        <> Text.pack (show info.size)
        <> " messages (key="
        <> info.batchKey.unBatchKey
        <> ", trigger="
        <> Text.pack (show info.trigger)
        <> ")"
  let poisoned =
        [ (ing.envelope.messageId, PoisonPill "poison order")
        | ing <- NonEmpty.toList msgs,
          ing.envelope.payload.poison
        ]
  case poisoned of
    [] -> pure ackAllOk
    ps -> do
      forM_ ps $ \(MessageId m, _) ->
        liftIO $ Text.putStrLn $ "  -> dead-lettered " <> m
      pure (failMessages ps) :: Eff es BatchAck

-- | Print per-message and batch counters for every processor.
printMetrics :: (IOE :> es) => Text -> AppHandle es -> Eff es ()
printMetrics label appHandle = do
  metrics <- getAppMetrics appHandle
  liftIO $ Text.putStrLn ("--- Metrics " <> label <> " ---")
  liftIO $ forM_ (Map.toList metrics) $ \(ProcessorId name, pm) -> do
    Text.putStrLn $
      name
        <> ": received="
        <> Text.pack (show pm.stats.received)
        <> " processed="
        <> Text.pack (show pm.stats.processed)
        <> " failed="
        <> Text.pack (show pm.stats.failed)
    Text.putStrLn $
      "  batches="
        <> Text.pack (show pm.batch.batchesEmitted)
        <> " batchedMessages="
        <> Text.pack (show pm.batch.batchedMessages)
        <> " partialFailures="
        <> Text.pack (show pm.batch.partialFailures)
        <> " bySize="
        <> Text.pack (show pm.batch.triggeredBySize)
        <> " byTimeout="
        <> Text.pack (show pm.batch.triggeredByTimeout)
        <> " byFlush="
        <> Text.pack (show pm.batch.triggeredByFlush)

main :: IO ()
main = runEff $ runTracingNoop app

app :: Eff '[Tracing, IOE] ()
app = do
  liftIO $ Text.putStrLn "=== Shibuya batch processing example ==="
  liftIO $ Text.putStrLn "Feeding 5 orders (batchSize=2, batched by region) through a batching processor."

  tracking <- newTrackingAck
  stopVar <- liftIO newEmptyMVar
  let adapter = ordersAdapter tracking stopVar sampleOrders
      processor = mkBatchProcessor adapter batchHandler batchCfg

  result <-
    runApp
      IgnoreFailures
      100 -- inbox size
      [(ProcessorId "orders", processor)]

  case result of
    Left err ->
      liftIO $ Text.putStrLn $ "Startup error: " <> Text.pack (show err)
    Right appHandle -> do
      -- Give the two size-triggered batches time to emit and print.
      liftIO $ threadDelay 500_000
      printMetrics "after size-triggered batches" appHandle

      liftIO $ Text.putStrLn "Stopping (flushes the final partial batch)..."
      _ <- stopApp appHandle
      liftIO $ Text.putStrLn "Done!"
```

Notes on tricky spots. The stream tail `Stream.nilM (liftIO (readMVar stopVar))` runs the
`readMVar` effect (which blocks until `shutdown` calls `tryPutMVar`) and then yields no
elements — that is exactly what `nilM :: Applicative m => m b -> Stream m a` does
(confirmed in `streamly-core`'s `Streamly.Internal.Data.Stream.Type`). `Stream.append`
concatenates the order stream with that blocking-then-empty tail. `info.batchKey.unBatchKey`
reads the emitted batch's key (a `BatchKey`) and unwraps it to `Text`; `BatchKey (..)` is
exported so the `unBatchKey` field is in scope for `OverloadedRecordDot`. The
`:: Eff es BatchAck` annotation on the `failMessages ps` branch is only there to make the
two `case` branches share an inferred type cleanly under the polymorphic `BatchHandler`
synonym; drop it if the compiler does not need it.

### Step 3 (M1) — build and run, and compare the transcript

```bash
cabal run shibuya-batch-example
```

Expected transcript (the two `flushed batch of 2` lines are emitted from the processor
thread and are guaranteed by the 0.5 s settle delay to appear before the metrics block; the
`TriggerFlush` line is guaranteed to appear after the `Stopping...` line because the
adapter's `shutdown` prints `Shutting down orders adapter` before it unblocks the stream):

```text
=== Shibuya batch processing example ===
Feeding 5 orders (batchSize=2, batched by region) through a batching processor.
flushed batch of 2 messages (key=us, trigger=TriggerSize)
flushed batch of 2 messages (key=eu, trigger=TriggerSize)
  -> dead-lettered order-21
--- Metrics after size-triggered batches ---
orders: received=5 processed=3 failed=1
  batches=2 batchedMessages=4 partialFailures=1 bySize=2 byTimeout=0 byFlush=0
Stopping (flushes the final partial batch)...
Shutting down orders adapter
flushed batch of 1 messages (key=apac, trigger=TriggerFlush)
Done!
```

How to read the numbers. Five orders were received (`received=5`). The two size-triggered
batches acknowledged four messages: `order-10`, `order-11`, and `order-20` as `AckOk`
(`processed=3`) and `order-21` as `AckDeadLetter` (`failed=1`). Batch counters at this
point: two batches emitted (`batches=2`) covering four messages (`batchedMessages=4`), one
of which had a partial failure (`partialFailures=1`), both emitted by size (`bySize=2`).
Then `stopApp` shuts the adapter down, the blocked stream ends, and the batcher flushes the
one remaining `apac` order as a partial batch (`TriggerFlush`). That final flush
acknowledges `order-30` as `AckOk` and increments the batch counters to
`batches=3, batchedMessages=5, byFlush=1`; because the processor unregisters its metrics as
it stops, those post-flush counters are not read back here — the `flushed batch of 1 ...
TriggerFlush` line is the observable proof that the final partial batch was flushed on
shutdown. (If you want to see the post-flush counters, read `getAppMetrics` from a
`stopAppGracefully` variant that reads metrics before unregistering, or add a metrics read
inside the drain; this is out of scope for the example.)

If the shipped `BatchStats` field names or the `Show BatchTrigger` rendering differ from the
above, update `Main.hs` and this transcript together, and record the drift in the Decision
Log.

### Step 4 (M2) — update `docs/architecture/MESSAGE_FLOW.md`

Add the batching stage to the single-processor pipeline diagram and add a batch
metrics/state note. Insert, after the existing "Single Queue Processor Flow" diagram and
before "Multi-Queue Architecture", a new subsection "Batching Stage (optional)" containing
the following diagram and prose:

```text
Adapter.source (stream)
        │
        ▼
   Ingester (async)  ──►  [ bounded inbox ]  (backpressure)
                                │
                                ▼
                          Batcher
        accumulate by batch key; emit a batch when:
          • it reaches batchSize            → TriggerSize
          • batchTimeout elapses since its  → TriggerTimeout
            first message arrived
          • the processor is draining       → TriggerFlush
            (shutdown flushes partial batches)
                                │
                                ▼
                      Batch handler (runs once over the whole batch)
                                │
                                ▼
                BatchAck: one decision per retained message,
                then idempotent finalization with bounded retry
```

Explain in prose immediately below the diagram: a processor built with `mkBatchProcessor`
inserts a **batcher** between the bounded inbox and acknowledgement. The batcher groups
inbox messages by **batch key** (a pure function `Envelope msg -> BatchKey`; messages with
the same key accumulate together, different keys accumulate independently). A batch is
emitted on the **first** of three triggers: **size** (the sub-batch reached `batchSize`),
**timeout** (`batchTimeout` elapsed since that sub-batch's first message arrived — a single
ticker thread scans accumulators, so flush latency is bounded by `tickInterval`), or
**flush** (the processor is draining on shutdown and flushes every pending partial batch).
The emitted batch runs the user's **batch handler** once; the handler returns a `BatchAck`,
and the framework resolves exactly one acknowledgement decision for **each** message in its
own retained batch list, then applies those decisions through idempotent finalizers with
bounded retries. Permanent finalizer failures are surfaced loudly with the affected
`MessageId`; they are not swallowed.

Then extend the "Metrics Updates" table (currently at lines ~191–199) with the batch events.
Add rows:

```text
| Batch emitted (size)        | batch.batchesEmitted++, batch.batchedMessages += N, batch.triggeredBySize++    | Processing → Idle |
| Batch emitted (timeout)     | batch.batchesEmitted++, batch.batchedMessages += N, batch.triggeredByTimeout++ | Processing → Idle |
| Batch flushed on drain      | batch.batchesEmitted++, batch.batchedMessages += N, batch.triggeredByFlush++   | Processing → Idle |
| Batch had a partial failure | batch.partialFailures++                                                       | -                 |
| Per-message ack in a batch  | stats.processed++ or stats.failed++ (per message, as for single messages)     | -                 |
```

Add a sentence noting that a batching processor's per-message counters (`received`,
`processed`, `failed`) are updated exactly as for a single-message processor — each message
in a batch is finalized individually — while the `batch.*` counters summarize batch-level
activity.

### Step 5 (M2) — update `docs/architecture/CORE_TYPES.md`

Add a new top-level section "## Batch Processing" after the "Handler Type" / "Adapter Type"
sections. Document the `Shibuya.Batch` public types with the acknowledgement decision and
resilient finalization contract, and the `BatchingProcessor`/`mkBatchProcessor` additions.
Concretely, include:

- The `BatchKey`, `BatchTrigger`, `BatchInfo`, `BatchConfig`, `BatchHandler`, and `BatchAck`
  definitions (copy the verbatim block from "Context and Orientation" of this plan), each
  with a one-line explanation and a small table of the record fields where helpful, matching
  the existing document's style (it uses `haskell` fenced blocks followed by field tables).
- The acknowledgement decision and finalization contract quoted verbatim (the block-quote
  from "Context and Orientation").
- The smart constructors `ackAllOk`, `ackAll`, `ackExcept`, `withFallback`, `failMessages`
  with a one-line description of each, and a note that the common cases are `ackAllOk`
  (succeed everything) and `failMessages` (dead-letter a few, ack the rest).
- The `BatchingProcessor` constructor and `mkBatchProcessor` smart constructor (copy the
  verbatim block from "The intended public API added by EP-19 and EP-18"), noting that
  `mkBatchProcessor` defaults to `Unordered` ordering and `Serial` concurrency, and that
  `Concurrency` (`Serial | Ahead n | Async n`) is reused to bound how many *batches* run at
  once (`Serial` = one batch at a time in emission order; `Ahead n` = ordered concurrent;
  `Async n` = unordered concurrent).

Ensure the exact names used match Step 0's findings.

### Step 6 (M2) — update `docs/architecture/METRICS.md`

After the existing `StreamStats` subsection, add a `BatchStats` subsection and update
`ProcessorMetrics`. Insert:

```haskell
data BatchStats = BatchStats
  { batchesEmitted     :: !Int  -- Batches handed to the batch handler
  , batchedMessages    :: !Int  -- Total messages across all emitted batches
  , partialFailures    :: !Int  -- Batches with >= 1 non-AckOk message
  , triggeredBySize    :: !Int  -- Batches emitted at batchSize
  , triggeredByTimeout :: !Int  -- Batches emitted at batchTimeout
  , triggeredByFlush   :: !Int  -- Batches emitted by a drain/shutdown flush
  }
```

with a counter table analogous to the existing `StreamStats` table, and update the
`ProcessorMetrics` block to include the new `batch :: !BatchStats` field:

```haskell
data ProcessorMetrics = ProcessorMetrics
  { state     :: !ProcessorState
  , stats     :: !StreamStats
  , batch     :: !BatchStats
  , startedAt :: !UTCTime
  }
```

Add a sentence: for a non-batching processor these counters are all zero; for a batching
processor they summarize batch-level activity while `stats` continues to count per-message
outcomes. Reconcile the field names with Step 0.

### Step 7 (M2) — update `docs/BROADWAY_COMPARISON.md`

Three edits close the gap.

First, in the **Feature Matrix** table (lines ~9–33), change the two rows that call
batching a gap. The **Core Pipeline** row's Gap cell currently reads "Batching stage
missing"; change the Shibuya cell to
`Adapter → Ingester → Processor → (optional Batcher → BatchHandler) → Ack` and the Gap cell
to `Closed`. The **Batching** row currently reads
`| **Batching** | First-class: batch_size, batch_timeout, batch_key, dynamic sizing | Not built-in | **Major gap** |`;
change it to
`| **Batching** | First-class: batch_size, batch_timeout, batch_key, dynamic sizing | First-class: batchSize, batchTimeout, batchKey, BatchAck with resilient finalization | ✅ Closed (v1; no dynamic sizing) |`.

Second, in the **Detailed Comparison** section "### 3. Batching" (lines ~63–72), replace the
"Shibuya: No batching stage ..." paragraph with a description of the shipped design:
Shibuya now has first-class batching via `Shibuya.Batch` and `mkBatchProcessor`. A batching
processor accumulates inbox messages by a pure `batchKey :: Envelope msg -> BatchKey`, emits
a batch on the first of `batchSize`, `batchTimeout`, or a shutdown flush, runs a
`BatchHandler es msg` once over the whole batch, resolves one acknowledgement decision per
retained message via `BatchAck` (a per-`MessageId` decision map plus a fallback), and applies
those decisions through idempotent finalizers with bounded retries. Permanent finalizer
failure halts loudly with the affected `MessageId`. The existing `Concurrency` policy
(`Serial | Ahead n | Async n`) is reused to bound how many batches run at once while
preserving FIFO execution within each `BatchKey`. Note the deliberate v1 scope boundary:
there is **no** Broadway-style pre-batch `handle_message` + `put_batcher` transform/routing
stage (routing is purely by `batchKey`), and **no** dynamic runtime reconfiguration of batch
size/timeout.

Third, in the **Improvement Roadmap** section "### Priority 1: First-Class Batching" (lines
~160–186), mark it implemented. Add a leading line `**Status:** ✅ Implemented.` and a short
paragraph noting the shipped module `Shibuya.Batch`, the `mkBatchProcessor` constructor,
size/timeout/flush triggers, `batchKey` routing, `BatchAck` decision resolution, bounded
finalization retries, per-key FIFO execution, and reuse of `Concurrency`; and that the
"Design sketch" positional `[AckDecision]` return in that section was superseded by
`BatchAck` so decisions are keyed by `MessageId` instead of list position. Keep the
historical design sketch but annotate it as superseded. Finally, update the closing
"## Summary" bullet list (lines ~347–356) so batching is no longer listed as the "single
largest feature gap" (reword to note it is now closed, leaving enforced partitioning, rate
limiting, and richer supervision as the remaining top gaps).

### Step 8 (M2, optional) — update `README.md`

`README.md` has a "## Features" bullet list (line 16) and a "Current Status" feature/status
table (lines ~28–38). Add a features bullet, e.g.
`- **First-Class Batching** - Accumulate by key with size/timeout/flush triggers, BatchAck decisions, and resilient finalization`,
and add a table row
`| First-Class Batching (size/timeout/key) | ✅ Implemented |`. If the version banner is
bumped for the batch release, update it too; otherwise leave the version text alone.

### Step 9 — format and build everything

```bash
nix fmt
cabal build all
cabal run shibuya-batch-example
```

`nix fmt` must leave the tree clean (the pre-commit hook runs `treefmt`). `cabal build all`
must be green. The final `cabal run` must reproduce the transcript from Step 3.


## Validation and Acceptance

Acceptance is behavioral and file-content-based.

M1 acceptance. Running `cabal run shibuya-batch-example` from the repository root builds the
new executable and prints the transcript in Step 3: two `flushed batch of 2 messages
(... TriggerSize)` lines, a `-> dead-lettered order-21` line, a metrics block reading
`received=5 processed=3 failed=1` and `batches=2 batchedMessages=4 partialFailures=1
bySize=2 byTimeout=0 byFlush=0`, and — after the `Stopping...` line — a
`flushed batch of 1 messages (key=apac, trigger=TriggerFlush)` line followed by `Done!`.
This proves, end-to-end, that a batching processor accumulates by key, emits on the size
trigger, dead-letters a message inside a batch (partial failure) while acking the rest,
reports batch metrics, and flushes the final partial batch on shutdown. The single
documented non-determinism is that the two `TriggerSize` lines originate from the processor
thread; the 0.5 s settle delay guarantees they precede the metrics block, and the adapter's
`shutdown` printing `Shutting down orders adapter` before it unblocks the stream guarantees
the `TriggerFlush` line follows `Stopping...`.

M2 acceptance. Each of the four (or five) documentation files contains the new batching
content and no longer describes batching as missing. Specifically: `MESSAGE_FLOW.md` shows a
batching stage in the pipeline and lists batch metric transitions;
`CORE_TYPES.md` documents `BatchKey`/`BatchTrigger`/`BatchInfo`/`BatchConfig`/`BatchHandler`/`BatchAck`,
the one-decision-per-retained-message contract, bounded finalization retry/fail-loud
behavior, per-key FIFO execution, and `BatchingProcessor`/`mkBatchProcessor`; `METRICS.md`
documents `BatchStats` and the `batch` field on `ProcessorMetrics`; and
`BROADWAY_COMPARISON.md`'s Feature Matrix, "### 3. Batching", "### Priority 1", and
"## Summary" no longer call batching a gap. A quick grep confirms the gap language is gone
and the new names are present:

```bash
grep -n "Major gap" docs/BROADWAY_COMPARISON.md            # Batching row must no longer match
grep -n "mkBatchProcessor\|BatchAck\|BatchStats" docs/architecture/CORE_TYPES.md docs/architecture/METRICS.md
grep -n "Batcher\|TriggerFlush" docs/architecture/MESSAGE_FLOW.md
```

Whole-project acceptance: `cabal build all` is green and `nix fmt` leaves no diff.


## Idempotence and Recovery

Every step is additive and safe to repeat. Creating `shibuya-example/app-batch/Main.hs` and
appending the cabal stanza are one-time additions; re-running the file write overwrites with
the same content, and the cabal stanza should be added once (if `executable
shibuya-batch-example` already exists, do not add it again). The documentation edits are
in-place text edits to existing files; re-applying them when the target text is already
present is a no-op — check before editing. Nothing in this plan deletes framework code or
changes runtime behavior, so there is nothing to roll back beyond removing the new example
files and reverting the doc edits.

If `cabal run shibuya-batch-example` fails to build, the most likely causes are: (1) API
drift — `mkBatchProcessor`, `BatchStats`, or a field name differs from what shipped (fix by
re-reading the source per Step 0 and adjusting imports/accessors); (2) a missing
`streamly-core` primitive — `Stream.append`, `Stream.fromList`, and `Stream.nilM` are all
exported from `Streamly.Data.Stream` in `streamly-core ^>=0.3` (verified against the
`streamly-core` source), so a failure here usually means a version mismatch; (3) an
`Envelope` field omitted — the real record has `headers`, `attempt`, and `attributes`, all
of which must be supplied (`Nothing`/`HashMap.empty`). If the transcript differs from Step 3
in the batch counter names or the `TriggerX` rendering, that is expected API drift: update
`Main.hs` and the transcript together and record it in the Decision Log.

If `nix fmt` reports changes, re-stage the reformatted files and re-run; the hook
auto-formats.


## Interfaces and Dependencies

New files and targets. This plan adds one source file
`shibuya-example/app-batch/Main.hs` (module `Main`) and one executable stanza
`executable shibuya-batch-example` in `shibuya-example/shibuya-example.cabal`. The
executable's `build-depends` are `base`, `containers` (`Data.Map.Strict` for the metrics
map), `effectful` (`Eff`, `IOE`, `runEff`), `shibuya-core` (all the Shibuya modules),
`streamly-core` (`Streamly.Data.Stream`), `text`, and `unordered-containers`
(`Data.HashMap.Strict` for the envelope's `attributes`). It intentionally does **not**
depend on `shibuya-metrics` or the OpenTelemetry packages, because it runs the tracing
effect in no-op mode via `runTracingNoop` from `shibuya-core`'s `Shibuya.Telemetry.Effect`.

Modules the example imports and why. `Shibuya.App` for `mkBatchProcessor`, `runApp`,
`getAppMetrics`, `stopApp`, `SupervisionStrategy`, `ProcessorId`, `ProcessorMetrics`,
`AppHandle`; `Shibuya.Batch` for `BatchConfig`, `BatchHandler`, `BatchInfo`, `BatchKey`,
`BatchAck`, `defaultBatchConfig`, `ackAllOk`, `failMessages`; `Shibuya.Adapter` for the
`Adapter` record; `Shibuya.Adapter.Mock` for `TrackingAck`, `newTrackingAck`,
`trackingAckHandle`; `Shibuya.Core.Ack` for `AckDecision`, `DeadLetterReason`;
`Shibuya.Core.Ingested` for `Ingested`; `Shibuya.Core.Types` for `Envelope`, `MessageId`;
`Shibuya.Runner.Metrics` for `BatchStats`, `StreamStats`; `Shibuya.Telemetry.Effect` for
`Tracing`, `runTracingNoop`; `Streamly.Data.Stream` for `append`, `fromList`, `mapM`,
`nilM`.

Documentation files edited (by full path): `docs/architecture/MESSAGE_FLOW.md`,
`docs/architecture/CORE_TYPES.md`, `docs/architecture/METRICS.md`,
`docs/BROADWAY_COMPARISON.md`, and optionally `README.md`.

Signatures this plan depends on existing at the start (from sibling plans; verify per Step 0):

```haskell
-- Shibuya.App (added by EP-19)
mkBatchProcessor :: Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es

-- Shibuya.Runner.Metrics (added by EP-18)
data BatchStats = BatchStats
  { batchesEmitted, batchedMessages, partialFailures
  , triggeredBySize, triggeredByTimeout, triggeredByFlush :: !Int }
-- ProcessorMetrics gains: batch :: !BatchStats

-- Shibuya.Batch (from EP-16, already frozen)
type BatchHandler es msg = BatchInfo -> NonEmpty (Ingested es msg) -> Eff es BatchAck
defaultBatchConfig :: BatchConfig es msg
ackAllOk     :: BatchAck
failMessages :: [(MessageId, DeadLetterReason)] -> BatchAck
```

At the end of this plan the following are true: `cabal run shibuya-batch-example` prints the
Step 3 transcript; `docs/architecture/MESSAGE_FLOW.md`, `docs/architecture/CORE_TYPES.md`,
`docs/architecture/METRICS.md`, and `docs/BROADWAY_COMPARISON.md` describe batching as a
shipped first-class feature; and `cabal build all` and `nix fmt` are clean.


## Revision Notes

- 2026-07-01: Initial authoring of EP-21. Filled every section from the skeleton. Chose a
  new `shibuya-batch-example` executable over splicing into the existing example (Decision
  Log), designed a deterministic five-order / `batchSize = 2` scenario with a blocking
  adapter so `stopApp` is what flushes the final partial batch, and specified the four doc
  updates plus the optional README update. The public-API signatures for
  `mkBatchProcessor`/`BatchingProcessor` (EP-19) and `BatchStats`/`ProcessorMetrics.batch`
  (EP-18) are quoted as targets to be verified against shipped source, because those sibling
  plans were still skeletons at authoring time. Reason: EP-21 is the Phase-4 docs/example
  deliverable and must remain accurate to whatever public API EP-18/EP-19 finalize.

- 2026-07-01: Reconciled the documentation plan with the reliability-strengthened batch
  contract. Public docs must now describe one `BatchAck` decision per retained message,
  bounded retry plus fail-loud behavior for adapter finalizer failures, and per-key FIFO
  execution under global batch concurrency.
