---
id: 20
slug: batch-reliability-test-suite
title: "Batch Reliability Test Suite"
kind: exec-plan
created_at: 2026-07-01T15:34:32Z
intention: "intention_01kwf4q2bke2js9t0js53dwh5a"
master_plan: "docs/masterplans/3-first-class-batch-processing.md"
---

# Batch Reliability Test Suite

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the fifth child of the MasterPlan at
`docs/masterplans/3-first-class-batch-processing.md` ("First-Class Batch Processing").
It hard-depends on EP-19 (`docs/plans/19-batch-runner-and-app-integration.md`), which wires
batching through the public `runApp` path; the end-to-end reliability tests here only become
observable once that runner exists. EP-21 (the documentation and example plan,
`docs/plans/21-batch-documentation-and-example.md`) will cite the guarantees this suite
proves, so the phrasing of the invariant below is meant to be quotable verbatim.


## Purpose / Big Picture

Shibuya is a Haskell queue-processing framework. Until this batching initiative, a consumer
processed exactly one message at a time: a `Handler es msg` (a function
`Ingested es msg -> Eff es AckDecision`) received one message and returned one
acknowledgement decision, and the framework finalized exactly one acknowledgement per
message through that message's own `AckHandle` (`finalize :: AckDecision -> Eff es ()`). The
sibling plans EP-16 through EP-19 add *batching*: messages are accumulated into groups, a
`BatchHandler` runs once over the whole group, and every message in the group is
acknowledged according to the handler's per-message decision.

The user asked for this feature to be "super reliable" for an important production use case.
Reliability here is not a vibe; it is a precise, testable invariant. This plan delivers the
test suite that **proves** that invariant end-to-end, driving the real, fully-wired
`runApp` path (not a stub), under randomized inputs and adversarial handler behavior.

The headline invariant this plan proves is:

> For **any** input and **any** handler behavior, **every** message that enters a batch is
> assigned **exactly one** acknowledgement decision from the handler's override or the
> framework fallback, and that decision is either confirmed by one successful adapter
> finalization or surfaced as a loud processor failure after bounded finalization retries.
> This holds on batch-handler exceptions, transient adapter finalizer failures, timeout
> flushes, graceful-shutdown flushes, under concurrency, and across multiple batch keys.

After this plan, a developer can run one command,
`cabal test shibuya-core-test`, and watch a QuickCheck property fuzz hundreds of randomized
batch schedules (random message counts, batch sizes, timeouts, key partitionings, and
per-message success/failure choices) and assert that the multiset of successfully finalized
message identifiers equals the input set with each identifier appearing exactly once and
carrying the intended decision in normal paths. They can also watch a battery of named scenario tests —
timeout flush, partial failure, batch-handler exception, transient finalizer retry,
permanent finalizer failure, halt-in-batch, graceful drain flush, multiple batch keys,
per-key FIFO under concurrency, and a backpressure liveness check — each exercising a
specific failure surface. The suite also ships a small, reusable "mock batch harness" so
that downstream adapter packages (pgmq, kafka, kiroku) can write the same successful-
finalization assertions against their own adapters.

You can see it working by running the test command and reading the green `Shibuya.Batch`
describe blocks in the HSpec output (shown verbatim in Concrete Steps).


## Progress

Milestone 1 (mock harness + successful-finalization property):

- [ ] Add `mkTrackedIngested` and `trackedListAdapter` to `shibuya-core/src/Shibuya/Adapter/Mock.hs` and export them.
- [ ] Create the test helper module `shibuya-core/test/Shibuya/Batch/TestHarness.hs` (envelope builders, pure successful-finalization checker, `BatchScenario` type + generator).
- [ ] Create `shibuya-core/test/Shibuya/Batch/ReliabilitySpec.hs` with the QuickCheck successful-finalization property (scenario #1).
- [ ] Add `containers` to the test-suite `build-depends` and register both new test modules in `other-modules` in `shibuya-core/shibuya-core.cabal`.
- [ ] Wire `Shibuya.Batch.ReliabilitySpec` into `shibuya-core/test/Main.hs`.
- [ ] `cabal test shibuya-core-test` green with the successful-finalization property passing.

Milestone 2 (scenario tests):

- [ ] Timeout-flush scenario (#2) green.
- [ ] Partial-failure scenario (#3) green.
- [ ] Batch-handler exception scenario (#4) green.
- [ ] Transient finalizer retry scenario (#5) green.
- [ ] Permanent finalizer failure scenario (#6) green: retries exhaust, failed `MessageId` is reported, and the processor halts loudly.
- [ ] Halt-in-batch scenario (#7) green, including halt isolation of a second processor.
- [ ] Graceful drain flush scenario (#8) green.
- [ ] Multiple batch keys scenario (#9) green.
- [ ] Per-key FIFO under concurrency scenario (#10) green: same-key batches never overlap under `Async`; different keys can overlap.
- [ ] Backpressure liveness scenario (#11) green (marked as a limited check — see Decision Log).
- [ ] `nix fmt` clean; full `cabal test shibuya-core-test` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: The reusable, shippable harness pieces (`mkTrackedIngested`, `trackedListAdapter`)
  go into the **library** module `shibuya-core/src/Shibuya/Adapter/Mock.hs`, while the
  test-only pieces (envelope builders, the `BatchScenario` generator, and the pure
  successful-finalization checker) go into a **test** module
  `shibuya-core/test/Shibuya/Batch/TestHarness.hs`.
  Rationale: `Shibuya.Adapter.Mock` already exports `listAdapter`, `TrackingAck`,
  `newTrackingAck`, `trackingAckHandle`, and `getTrackedDecisions`; the two new functions
  extend that exact story and are directly useful to downstream adapter reliability tests
  (pgmq/kafka/kiroku want "build N tracked messages and an adapter that records every
  finalize"). Keeping them in the library means those packages get them for free without a
  test-only cabal dependency on `shibuya-core`'s test suite. The generator and the
  hspec/QuickCheck-flavored assertion helpers, by contrast, pull `QuickCheck` and encode
  test policy, so they stay in the test tree.
  Date: 2026-07-01

- Decision: The normal-path successful-finalization assertion is made against the `TrackingAck` list,
  not against batch boundaries or metrics. `TrackingAck` records a *list* of successful
  `(MessageId, AckDecision)` finalizations, so a duplicate successful finalization is
  visible as a repeated `MessageId`. The checker asserts each `MessageId` appears exactly
  once and with the expected decision. Separate finalizer-failure scenarios use deliberately
  flaky and permanently throwing ack handles to test retry and fail-loud behavior.
  Rationale: The whole point of the invariant is that it holds *regardless* of which
  messages land in which batch. Asserting on the tracked successful-finalize list decouples the proof
  from timing and batch-boundary nondeterminism, which is exactly what the MasterPlan's
  acknowledgement invariant demands.
  Date: 2026-07-01

- Decision: The primary test driver is `runApp IgnoreFailures ... [...]` followed by
  `stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app`, which flushes any pending
  partial batches on shutdown (EP-19's graceful-shutdown flush) so that *every* message is
  finalized before assertions run. If EP-18/EP-19 expose a deterministic, non-supervised,
  blocking `runWithMetricsBatch` (analogous to the existing `runWithMetrics`), scenario
  tests may use it for tighter determinism, but the suite must not *depend* on its
  existence.
  Rationale: `runApp` + `stopAppGracefully` is guaranteed to exist by EP-19 and is the same
  public path a user uses, so the tests exercise the real integration. Graceful shutdown
  guarantees the partial-batch flush, removing the need to wait on the timeout ticker for
  the tail of a run.
  Date: 2026-07-01

- Decision: Timing assertions are tolerant, following the style already used in
  `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs`: real `threadDelay`, `shouldSatisfy`
  with inequalities (`(>= n)`, `(< n)`), and catching linked async failures with
  `UnliftIO.withAsync (...) UnliftIO.waitCatch`. No test asserts an exact wall-clock time or
  an exact batch count that depends on scheduler timing.
  Rationale: The test suite runs `-threaded -with-rtsopts=-N`; exact-timing assertions are
  brittle under a real scheduler. `SupervisedSpec` already establishes this convention and
  is green in CI, so mirroring it keeps the suite stable.
  Date: 2026-07-01

- Decision: The per-key FIFO scenario uses `Async 2` and handler-controlled `MVar`s to prove
  that two batches for the same `BatchKey` cannot overlap, while different keys can overlap.
  Rationale: This is the behavioral guard for the EP-18 keyed scheduler. Without it, the
  implementation could accidentally use raw global `parMapM` and reorder same-key writes.
  Date: 2026-07-01

- Decision: The backpressure scenario (#11) is a **liveness / no-loss** check, not a memory
  measurement, and is explicitly marked as a limitation.
  Rationale: Deterministically asserting "memory stays bounded" from inside a unit test is
  not reliable (it depends on GC timing and RTS accounting). Instead the test uses a tiny
  inbox (size 2) with a slow batch handler and many messages and asserts that the run still
  successfully finalizes every message once and completes without deadlock — a proxy that a
  bounded inbox plus backpressure did not lose or drop messages. This is stated openly per
  the PLANS "no silent caps" guidance.
  Date: 2026-07-01

- Decision: The QuickCheck property caps at `withMaxSuccess 50` and uses small message
  counts (1..40), small batch sizes (1..N+5), and short timeouts (20..200 ms).
  Rationale: Each QuickCheck example spins up a full `runApp`/`stopAppGracefully` cycle;
  hundreds of examples with large inputs would make the suite slow. Fifty randomized
  schedules over these ranges cover the interesting boundaries (batchSize == 1, batchSize
  > N so nothing flushes by size, single key, many keys) while keeping the suite fast.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the repository. Everything needed to write and
run these tests is here.

Shibuya is a Cabal project rooted at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. The library package is
`shibuya-core` (sources under `shibuya-core/src/Shibuya/`, tests under
`shibuya-core/test/`, cabal file `shibuya-core/shibuya-core.cabal`, version 0.7.1.0,
`cabal-version: 3.12`, `default-language: GHC2024`). The test suite is `shibuya-core-test`,
an `exitcode-stdio-1.0` suite whose entry point is `shibuya-core/test/Main.hs`, built with
`-threaded -rtsopts -with-rtsopts=-N` and using HSpec (`hspec ^>=2.11`) and QuickCheck
(`QuickCheck ^>=2.15`). All library and test code turns on these extensions by default (from
the cabal `default-extensions` stanzas): `DeriveAnyClass`, `DerivingStrategies`,
`DuplicateRecordFields`, `LambdaCase`, `NoFieldSelectors`, `OverloadedLabels`,
`OverloadedRecordDot`, `OverloadedStrings`, `QuasiQuotes`. Two consequences bite constantly:
`NoFieldSelectors` means record fields generate **no** top-level accessor functions, so a
field is read with dot syntax (`value.fieldName`); and `DerivingStrategies` means every
`deriving` clause must name its strategy (`stock`, `newtype`, or `anyclass`).

Build, test, and format commands (run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`):

```bash
cabal build shibuya-core
cabal test shibuya-core-test
nix fmt
```

Definitions of the terms of art used throughout this plan:

- **Ingested message**: the framework's unit of work. `data Ingested es msg = Ingested
  { envelope :: !(Envelope msg), ack :: !(AckHandle es), lease :: !(Maybe (Lease es)) }`
  in `shibuya-core/src/Shibuya/Core/Ingested.hs`. It bundles the message envelope, an
  acknowledgement handle, and an optional lease.
- **Envelope**: metadata plus payload. `data Envelope msg` in
  `shibuya-core/src/Shibuya/Core/Types.hs` has fields `messageId :: !MessageId`,
  `cursor :: !(Maybe Cursor)`, `partition :: !(Maybe Text)`, `enqueuedAt :: !(Maybe UTCTime)`,
  `traceContext :: !(Maybe TraceHeaders)`, `headers :: !(Maybe Headers)`,
  `attempt :: !(Maybe Attempt)`, `attributes :: !(HashMap Text Attribute)`,
  `payload :: !msg`. `MessageId` is `newtype MessageId = MessageId {unMessageId :: Text}`
  deriving `Eq, Ord, Show, Generic` (stock), `IsString` (newtype), `NFData` (anyclass).
- **AckHandle**: how a message is finalized. `newtype AckHandle es = AckHandle
  { finalize :: AckDecision -> Eff es () }` in
  `shibuya-core/src/Shibuya/Core/AckHandle.hs`. Calling `finalize d` asks the adapter to
  acknowledge the message with decision `d`. In normal successful paths this suite expects
  one successful finalization per message. When a finalizer throws, EP-18 retries the
  idempotent finalizer and either records one eventual success or fails the processor
  loudly after exhausting retries.
- **AckDecision**: what to do with a message. In `shibuya-core/src/Shibuya/Core/Ack.hs`:
  `data AckDecision = AckOk | AckRetry !RetryDelay | AckDeadLetter !DeadLetterReason | AckHalt !HaltReason`
  deriving `Eq, Show, Generic` (stock). `RetryDelay` is
  `newtype RetryDelay = RetryDelay {unRetryDelay :: NominalDiffTime}` deriving `Eq, Show`.
  `DeadLetterReason = PoisonPill !Text | InvalidPayload !Text | MaxRetriesExceeded`.
  `HaltReason = HaltOrderedStream !Text | HaltFatal !Text`.
- **Batch**: a non-empty group of ingested messages handed to a batch handler together.
- **Batch key**: a `Text`-wrapped value computed per message; messages with the same key
  accumulate together into an independent sub-batch. `newtype BatchKey = BatchKey
  {unBatchKey :: Text}` deriving `Eq, Ord, Show, Generic` (stock), `IsString` (newtype),
  `NFData` (anyclass), from module `Shibuya.Batch` (`shibuya-core/src/Shibuya/Batch.hs`).
  `defaultBatchKey = BatchKey "default"`.
- **Batch trigger**: why a batch was emitted. `data BatchTrigger = TriggerSize | TriggerTimeout | TriggerFlush`
  (deriving `Eq, Show, Generic` stock; `NFData` anyclass). `TriggerSize` = it filled to
  `batchSize`; `TriggerTimeout` = its timeout elapsed; `TriggerFlush` = the processor is
  draining and a partial batch was flushed.
- **Batch metadata**: `data BatchInfo = BatchInfo { batchKey :: !BatchKey, size :: !Int,
  trigger :: !BatchTrigger, partition :: !(Maybe Text) }` (deriving `Eq, Show, Generic`
  stock; `NFData` anyclass), passed to the batch handler alongside the messages.
- **Batch handler**: `type BatchHandler es msg = BatchInfo -> NonEmpty (Ingested es msg) -> Eff es BatchAck`.
  It receives the metadata and every message in the batch and returns one `BatchAck`.
- **Batch configuration**: `data BatchConfig es msg = BatchConfig { batchSize :: !Int,
  batchTimeout :: !NominalDiffTime, batchKey :: !(Envelope msg -> BatchKey),
  tickInterval :: !(Maybe NominalDiffTime) }`. `defaultBatchConfig` is size 100, timeout
  1 second, `const defaultBatchKey`, tick `Nothing`. The `batchKey` field is a **pure**
  function of the envelope. Validation: `validateBatchConfig :: BatchConfig es msg -> Either BatchConfigError ()`
  rejects `batchSize < 1`, `batchTimeout <= 0`, or a `Just` `tickInterval <= 0`.
- **BatchAck** and the acknowledgement contract. `data BatchAck = BatchAck
  { decisions :: !(Map MessageId AckDecision), fallback :: !AckDecision }` (deriving `Show,
  Generic` stock). Smart constructors: `ackAllOk = BatchAck Map.empty AckOk`;
  `ackAll d = BatchAck Map.empty d`; `ackExcept overrides = BatchAck (Map.fromList overrides) AckOk`;
  `withFallback fb overrides = BatchAck (Map.fromList overrides) fb`;
  `failMessages fs = BatchAck (Map.fromList [(mid, AckDeadLetter r) | (mid, r) <- fs]) AckOk`.

  The normative contract, quoted verbatim from EP-16
  (`docs/plans/16-batch-api-and-configuration-types.md`) and the MasterPlan, is:

  > Given an emitted batch and the `BatchAck` a `BatchHandler` returns, the framework
  > resolves one `AckDecision` for every message in its own retained batch list. For each
  > retained `Ingested`, it computes
  > `Data.Map.Strict.findWithDefault batchAck.fallback ingested.envelope.messageId batchAck.decisions`.
  > The handler's return value only supplies decisions; it never drives which messages are
  > acked. Thus decision resolution is complete regardless of handler behavior (wrong length
  > / reordered / missing ids degrade to fallback). Requires unique `MessageId` per batch
  > (true for all adapters and the mock). EP-18 then applies each resolved decision through
  > the message's idempotent finalizer with bounded retries.

This plan's tests assert that decision-resolution contract, one successful finalization per
message in normal paths, retry on transient finalizer failures, and fail-loud behavior on
permanent finalizer failures.

### The adapter, the mock, and the tracking ack

`data Adapter es msg = Adapter { adapterName :: !Text, source :: Stream (Eff es) (Ingested es msg), shutdown :: Eff es () }`
lives in `shibuya-core/src/Shibuya/Adapter.hs` (`Stream` is
`Streamly.Data.Stream.Stream`). The mock adapter module
`shibuya-core/src/Shibuya/Adapter/Mock.hs` currently exports:

```haskell
listAdapter :: (IOE :> es) => [Ingested es msg] -> Adapter es msg
data TrackingAck = TrackingAck { trackedDecisions :: IORef [(MessageId, AckDecision)] }
newTrackingAck :: (IOE :> es) => Eff es TrackingAck
trackingAckHandle :: (IOE :> es) => TrackingAck -> MessageId -> AckHandle es
getTrackedDecisions :: (IOE :> es) => TrackingAck -> Eff es [(MessageId, AckDecision)]
```

`listAdapter msgs` builds an adapter whose `source = Stream.fromList msgs` and
`shutdown = pure ()`. `trackingAckHandle tracking msgId` returns an `AckHandle` whose
`finalize` does `liftIO $ modifyIORef' tracking.trackedDecisions ((msgId, decision) :)` —
i.e. it **prepends** one `(msgId, decision)` pair to a shared list per successful
`finalize` call. Because it records a list (not a set or a single value), a duplicate
successful finalization for the same `MessageId` shows up as two entries — which is how
this suite detects a duplicate-success bug in normal paths. `getTrackedDecisions` reads
the whole list back. Finalizer-failure scenarios use custom throwing `AckHandle`s in the
test module so retries are observable separately from successful finalization tracking.

### The runner and the public app API (what EP-19 wires)

The production per-message loop lives in
`shibuya-core/src/Shibuya/Runner/Supervised.hs`. The pieces relevant here:

- `data SupervisedProcessor = SupervisedProcessor { metrics :: !(TVar ProcessorMetrics),
  processorId :: !ProcessorId, done :: !(TVar Bool), child :: !(Maybe (Async ())) }`.
- `runWithMetrics :: (IOE :> es, Tracing :> es) => Natural -> ProcessorId -> Adapter es msg -> Handler es msg -> Eff es SupervisedProcessor`
  — the non-supervised, blocking, per-message runner used by finite-stream unit tests.
- Halt: `data ProcessorHalt = ProcessorHalt { reason :: HaltReason }` (an `Exception`), in
  `Shibuya.Runner.Halt`.

Metrics (module `Shibuya.Runner.Metrics`, exposed):
`data StreamStats = StreamStats { received, dropped, processed, failed :: !Int }`;
`data ProcessorState = Idle | Processing !InFlightInfo !UTCTime | Failed !Text !UTCTime | Stopped`;
`data ProcessorMetrics = ProcessorMetrics { state :: !ProcessorState, stats :: !StreamStats, startedAt :: !UTCTime }`;
`type MetricsMap = Map ProcessorId ProcessorMetrics`;
`newtype ProcessorId = ProcessorId { unProcessorId :: Text }`. In the per-message runner,
`AckOk`/`AckRetry` increment `processed`, `AckDeadLetter` increments `failed`, and `AckHalt`
or a handler exception sets the state to `Failed`. EP-18 adds a **new** `BatchStats` record to
`ProcessorMetrics` via a `batch :: !BatchStats` field (it does **not** extend `StreamStats`):
`data BatchStats = BatchStats { batchesEmitted, batchedMessages, partialFailures, sizeTriggered, timeoutTriggered, flushTriggered :: !Int }`.
This plan reads `metrics.batch.batchedMessages` for the total number of messages that passed
through batches. Crucially, per-message `processed` and `failed` stay on `StreamStats`
(`metrics.stats.processed` / `metrics.stats.failed`), consistent with the single-message path
(see "Interfaces and Dependencies" for the coordination note).

The public app API lives in `shibuya-core/src/Shibuya/App.hs`:

```haskell
data QueueProcessor es where
  QueueProcessor :: { adapter :: Adapter es msg, handler :: Handler es msg,
                      ordering :: Ordering, concurrency :: Concurrency } -> QueueProcessor es
mkProcessor :: Adapter es msg -> Handler es msg -> QueueProcessor es   -- Unordered Serial
runApp :: (IOE :> es, Tracing :> es) => SupervisionStrategy -> Int ->
          [(ProcessorId, QueueProcessor es)] -> Eff es (Either AppError (AppHandle es))
data AppHandle es = AppHandle { master :: !Master, processors :: !(Map ProcessorId (SupervisedProcessor, QueueProcessor es)) }
data SupervisionStrategy = IgnoreFailures | StopAllOnFailure
data ShutdownConfig = ShutdownConfig { drainTimeout :: !NominalDiffTime }
stopAppGracefully :: ShutdownConfig -> AppHandle es -> Eff es Bool
getAppMetrics :: AppHandle es -> Eff es MetricsMap
```

EP-19 adds a `BatchingProcessor` constructor to the existential GADT `QueueProcessor es`
and a smart constructor. This plan assumes the smart constructor
`mkBatchProcessor :: Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es`
(adapter first, config last, matching the existing `mkProcessor` argument convention, and
defaulting the ordering/concurrency policy the same way `mkProcessor` does, i.e. `Unordered`
`Serial`, meaning one batch at a time). The exact spelling is owned by EP-19; the
"Interfaces and Dependencies" section states what to change if EP-19 names things
differently, and this coordination risk is called out in the final cross-plan summary.

### How the tests are run

Every test runs the effectful code under `runEff $ runTracingNoop $ do ...`, where `runEff`
(from `Effectful`) discharges the `IOE` effect to `IO`, and `runTracingNoop` (from
`Shibuya.Telemetry.Effect`) discharges the `Tracing` effect with a no-op tracer. The effect
stack in tests is therefore `Eff '[Tracing, IOE]` and the whole thing yields an `IO`
action that HSpec runs. This is exactly the shape used throughout
`shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs`.


## Plan of Work

The work is two milestones. Milestone 1 builds the reusable mock batch harness and lands the
one property test that carries the normal-path invariant: a QuickCheck successful-finalization
property. If that is green, the framework provably records one successful finalization for
every randomized message with the intended decision. Milestone 2 adds the named scenario tests that pin down each specific
failure surface (timeout, partial failure, exception, halt, drain, multi-key, backpressure).

### Milestone 1 — Mock batch harness and the successful-finalization property

At the end of this milestone, `shibuya-core/src/Shibuya/Adapter/Mock.hs` exports two new
helpers, a new test module `Shibuya.Batch.TestHarness` provides message builders and a pure
successful-finalization checker plus a `BatchScenario` generator, and a new test module
`Shibuya.Batch.ReliabilitySpec` contains a QuickCheck property that runs randomized batch
schedules through `runApp`/`stopAppGracefully` and asserts one successful finalization with the intended
decisions. Run it with `cabal test shibuya-core-test`; acceptance is the `Shibuya.Batch
reliability` describe block reporting the property as passing (e.g. `+++ OK, passed 50
tests.`).

First, extend the library mock. Open `shibuya-core/src/Shibuya/Adapter/Mock.hs`. Add two
functions and export them. `mkTrackedIngested` turns an `Envelope` into an `Ingested` whose
`ack` is a tracking handle keyed by the envelope's own `MessageId`, and whose `lease` is
`Nothing`. `trackedListAdapter` builds a `listAdapter` over a list of envelopes, each wrapped
with `mkTrackedIngested`, so the resulting adapter records every `finalize` into one shared
`TrackingAck`.

The new exports (add to the export list, grouped under the existing "Test Helpers"
section):

```haskell
    -- * Test Helpers
    TrackingAck (..),
    newTrackingAck,
    trackingAckHandle,
    getTrackedDecisions,
    mkTrackedIngested,
    trackedListAdapter,
```

The new imports (the module currently imports `Ingested` abstractly and `MessageId (..)`;
you need the `Ingested` and `Envelope` constructors/fields):

```haskell
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
```

The new definitions:

```haskell
-- | Wrap an envelope into an 'Ingested' whose acknowledgement is recorded by the
-- given 'TrackingAck', keyed by the envelope's own 'MessageId'. The lease is
-- 'Nothing'. Every call to the resulting handle's 'finalize' appends one
-- @(messageId, decision)@ pair to the tracking list, so duplicate finalizes are
-- observable.
mkTrackedIngested :: (IOE :> es) => TrackingAck -> Envelope msg -> Ingested es msg
mkTrackedIngested tracking env =
  Ingested
    { envelope = env,
      ack = trackingAckHandle tracking env.messageId,
      lease = Nothing
    }

-- | Build an adapter from a list of envelopes where every message's acknowledgement
-- is recorded into one shared 'TrackingAck'. Combine with 'getTrackedDecisions' to
-- assert one successful finalization per message across a normal run.
trackedListAdapter :: (IOE :> es) => TrackingAck -> [Envelope msg] -> Adapter es msg
trackedListAdapter tracking envs =
  listAdapter (map (mkTrackedIngested tracking) envs)
```

Second, create the test harness module `shibuya-core/test/Shibuya/Batch/TestHarness.hs`. It
holds three things: envelope/message builders that mint distinct `MessageId`s and stamp a
`BatchKey` into the envelope's `partition` field (so the config's `batchKey` function can
recover the key purely from the envelope); the `BatchScenario` value plus its QuickCheck
generator; and a *pure* successful-finalization checker usable from both QuickCheck and HSpec.

Storing the batch key in `Envelope.partition` is deliberate: `BatchConfig.batchKey` is a pure
function `Envelope msg -> BatchKey`, and the simplest total such function that recovers the
key the generator chose is `\env -> BatchKey (fromMaybe "default" env.partition)`. It also
means the `BatchInfo.partition` the handler observes carries the same key, which the
multi-key scenario asserts on.

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Shibuya.Batch.TestHarness
  ( -- * Scenario model
    BatchScenario (..),
    genScenario,

    -- * Envelope builders
    mkEnvelope,
    scenarioEnvelopes,
    scenarioBatchKey,
    scenarioMsgIds,
    scenarioIntended,

    -- * Exactly-once checking
    finalizedExactlyOnce,
  )
where

import Data.HashMap.Strict qualified as HashMap
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Shibuya.Batch (BatchKey (..))
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Test.QuickCheck

-- | A randomized batch schedule. Each message index @i@ in @[1 .. msgCount]@ has a
-- distinct 'MessageId' @"msg-i"@, an assigned 'BatchKey' (@keyOf ! i@), and an
-- intended finalized decision (@outcomeOf ! i@, always 'AckOk' or an
-- 'AckDeadLetter'). @batchSize@ and @batchTimeoutMs@ configure the batcher.
data BatchScenario = BatchScenario
  { msgCount :: !Int,
    batchSize :: !Int,
    batchTimeoutMs :: !Int,
    keyOf :: !(Map Int BatchKey),
    outcomeOf :: !(Map Int AckDecision)
  }
  deriving stock (Show)

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

-- | Generate a randomized scenario: 1..40 messages, a batch size that may be
-- smaller than, equal to, or larger than the message count (so some runs never
-- flush by size), a short timeout, 1..4 batch keys, and a per-message outcome that
-- is mostly 'AckOk' with an occasional dead-letter.
genScenario :: Gen BatchScenario
genScenario = do
  n <- choose (1, 40)
  bs <- choose (1, n + 5)
  toMs <- choose (20, 200)
  numKeys <- choose (1, min 4 n)
  keys <- vectorOf n (chooseKey numKeys)
  outs <- vectorOf n genOutcome
  pure
    BatchScenario
      { msgCount = n,
        batchSize = bs,
        batchTimeoutMs = toMs,
        keyOf = Map.fromList (zip [1 ..] keys),
        outcomeOf = Map.fromList (zip [1 ..] outs)
      }
  where
    chooseKey k = do
      j <- choose (1, k)
      pure (BatchKey ("k" <> tshow (j :: Int)))
    genOutcome =
      frequency
        [ (3, pure AckOk),
          (1, AckDeadLetter <$> elements [MaxRetriesExceeded, PoisonPill "qc", InvalidPayload "qc"])
        ]

instance Arbitrary BatchScenario where
  arbitrary = genScenario

-- | Build one envelope carrying a payload, with the given id number and batch key
-- stamped into the 'partition' field (so a pure @batchKey@ config function can
-- recover it).
mkEnvelope :: Int -> BatchKey -> Int -> Envelope Int
mkEnvelope i key payload =
  Envelope
    { messageId = MessageId ("msg-" <> tshow i),
      cursor = Just (CursorInt i),
      partition = Just key.unBatchKey,
      enqueuedAt = Nothing,
      traceContext = Nothing,
      headers = Nothing,
      attempt = Nothing,
      attributes = HashMap.empty,
      payload = payload
    }

-- | The envelopes for a scenario, in index order, each carrying its assigned key.
scenarioEnvelopes :: BatchScenario -> [Envelope Int]
scenarioEnvelopes s =
  [ mkEnvelope i (keyFor i) i
    | i <- [1 .. s.msgCount]
  ]
  where
    keyFor i = fromMaybe (BatchKey "default") (Map.lookup i s.keyOf)

-- | The pure @batchKey@ function to hand to 'BatchConfig': recover the key from the
-- envelope's partition, defaulting to @"default"@.
scenarioBatchKey :: Envelope Int -> BatchKey
scenarioBatchKey env = BatchKey (fromMaybe "default" env.partition)

-- | The set of message ids a scenario produces.
scenarioMsgIds :: BatchScenario -> [MessageId]
scenarioMsgIds s = [MessageId ("msg-" <> tshow i) | i <- [1 .. s.msgCount]]

-- | The intended finalized decision per message id.
scenarioIntended :: BatchScenario -> Map MessageId AckDecision
scenarioIntended s =
  Map.fromList
    [ (MessageId ("msg-" <> tshow i), fromMaybe AckOk (Map.lookup i s.outcomeOf))
      | i <- [1 .. s.msgCount]
    ]

-- | The successful-finalization checker. Given the raw tracked list of @(messageId, decision)@
-- pairs (as recorded by a 'Shibuya.Adapter.Mock.TrackingAck', which appends one
-- entry per @finalize@ call) and the expected finalized decision per id, return
-- @Right ()@ iff every expected id appears exactly once and carries its expected
-- decision, and no unexpected id appears. Otherwise return a human-readable
-- explanation for use as a QuickCheck counterexample or an HSpec failure message.
finalizedExactlyOnce ::
  [(MessageId, AckDecision)] ->
  Map MessageId AckDecision ->
  Either String ()
finalizedExactlyOnce tracked expected
  | not (null dupes) =
      Left ("finalized more than once: " <> show dupes)
  | trackedIds /= expectedIds =
      Left
        ( "id set mismatch: missing="
            <> show (expectedIds `minus` trackedIds)
            <> " extra="
            <> show (trackedIds `minus` expectedIds)
        )
  | not (null wrong) =
      Left ("wrong decision: " <> show wrong)
  | otherwise = Right ()
  where
    counts :: Map MessageId Int
    counts = Map.fromListWith (+) [(mid, 1 :: Int) | (mid, _) <- tracked]
    dupes = [mid | (mid, c) <- Map.toList counts, c /= 1]
    trackedIds = sort (Map.keys counts)
    expectedIds = sort (Map.keys expected)
    minus xs ys = filter (`notElem` ys) xs
    -- Since each id appears exactly once (checked above via dupes), a simple
    -- lookup of the single decision is well-defined here.
    got = Map.fromList tracked
    wrong =
      [ (mid, want, Map.lookup mid got)
        | (mid, want) <- Map.toList expected,
          Map.lookup mid got /= Just want
      ]
```

Note two small correctness points in `finalizedExactlyOnce`. The `got = Map.fromList tracked`
keeps the *last-wins* entry, but the `dupes` guard already runs first and short-circuits on
any duplicate id, so by the time `wrong` is evaluated every id is known to appear exactly
once and `Map.fromList` is unambiguous. The checker is pure, so it is equally usable from the
QuickCheck property (mapped to `counterexample`) and from HSpec `it` blocks (mapped to
`expectationFailure`).

Third, create the property spec `shibuya-core/test/Shibuya/Batch/ReliabilitySpec.hs`. It
depends on the EP-19 public batch API (`mkBatchProcessor`) and on `Shibuya.Batch`. It builds
a batch handler that, for each batch, returns `ackExcept` with the intended dead-letter
overrides (leaving the `AckOk` messages to the `AckOk` fallback), runs the whole scenario
through `runApp`, forces a flush of the tail via `stopAppGracefully`, and asserts
`finalizedExactlyOnce`.

The driver function (place it among the spec's helpers) and the property:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Shibuya.Batch.ReliabilitySpec (spec) where

import Control.Monad (forM_)
import Data.Foldable (toList)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter.Mock
  ( TrackingAck,
    getTrackedDecisions,
    newTrackingAck,
    trackedListAdapter,
  )
import Shibuya.App
  ( ShutdownConfig (..),
    SupervisionStrategy (..),
    getAppMetrics,
    mkBatchProcessor,
    runApp,
    stopAppGracefully,
  )
import Shibuya.Batch
  ( BatchAck,
    BatchConfig (..),
    BatchHandler,
    BatchInfo (..),
    ackExcept,
    defaultBatchConfig,
  )
import Shibuya.Batch.TestHarness
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..), RetryDelay (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Runner.Metrics (BatchStats (..), ProcessorId (..), ProcessorMetrics (..), StreamStats (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Test.Hspec
import Test.QuickCheck
import Test.QuickCheck.Monadic (assert, monadicIO, monitor, run)

-- | Build a batch config for a scenario. The timeout is in seconds computed from
-- the scenario's millisecond value; @tickInterval@ is left 'Nothing' (use the
-- timeout).
scenarioConfig :: BatchScenario -> BatchConfig es Int
scenarioConfig s =
  defaultBatchConfig
    { batchSize = s.batchSize,
      batchTimeout = fromIntegral s.batchTimeoutMs / 1000,
      batchKey = scenarioBatchKey
    }

-- | A batch handler that finalizes each message with the intended per-message
-- decision. For every message in the batch whose intended decision is a
-- dead-letter, it emits an override; everything else falls back to 'AckOk'. This
-- exercises both the override path and the fallback path.
intendedHandler :: Map MessageId AckDecision -> BatchHandler es Int
intendedHandler intended _info msgs =
  pure $
    ackExcept
      [ (mid, d)
        | ing <- toList msgs,
          let mid = ing.envelope.messageId,
          Just d <- [Map.lookup mid intended],
          d /= AckOk
      ]

-- | Run a scenario end-to-end through the real @runApp@ path, flush the tail via a
-- graceful shutdown with a generous drain timeout, and return the tracked
-- acknowledgements plus the final processor metrics.
runScenario ::
  BatchScenario ->
  IO ([(MessageId, AckDecision)], ProcessorMetrics)
runScenario s = runEff $ runTracingNoop $ do
  tracking <- newTrackingAck
  let pid = ProcessorId "batch"
      adapter = trackedListAdapter tracking (scenarioEnvelopes s)
      proc = mkBatchProcessor adapter (intendedHandler (scenarioIntended s)) (scenarioConfig s)
  Right app <- runApp IgnoreFailures 100 [(pid, proc)]
  _drained <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
  metricsMap <- getAppMetrics app
  tracked <- getTrackedDecisions tracking
  let m = fromMaybe (error "no metrics for batch processor") (Map.lookup pid metricsMap)
  pure (tracked, m)

spec :: Spec
spec = describe "Shibuya.Batch reliability" $ do
  describe "successful finalization (property)" $ do
    it "records one successful finalization per message with the intended decision" $
      withMaxSuccess 50 $
        forAll genScenario $ \s -> monadicIO $ do
          (tracked, metrics) <- run (runScenario s)
          let expected = scenarioIntended s
          case finalizedExactlyOnce tracked expected of
            Left err -> do
              monitor (counterexample ("successful-finalization violated: " <> err))
              assert False
            Right () -> pure ()
          -- Every message is accounted for by processed + failed.
          monitor
            ( counterexample
                ( "accounting: processed="
                    <> show metrics.stats.processed
                    <> " failed="
                    <> show metrics.stats.failed
                    <> " n="
                    <> show s.msgCount
                )
            )
          assert (metrics.stats.processed + metrics.stats.failed == s.msgCount)
          -- The batch counter records every message that passed through a batch.
          assert (metrics.batch.batchedMessages == s.msgCount)
```

The property uses `Test.QuickCheck.Monadic` (`monadicIO`, `run`, `assert`, `monitor`) so the
`IO` action `runScenario` runs inside QuickCheck and a failure prints the counterexample plus
the checker's explanation. The two metric assertions (`processed + failed == n` and
`batchedMessages == n`) are secondary confirmations; the primary proof is
`finalizedExactlyOnce` against the tracked list, which is fully under this suite's control and
independent of batch boundaries.

Wire it in. Add to `shibuya-core/shibuya-core.cabal` under the test-suite `other-modules`:
`Shibuya.Batch.ReliabilitySpec` and `Shibuya.Batch.TestHarness`. Add `containers` to the
test-suite `build-depends` (the harness and spec use `Data.Map.Strict`; `QuickCheck` is
already a dependency). Then in `shibuya-core/test/Main.hs` add
`import Shibuya.Batch.ReliabilitySpec qualified` and, in the `main` do-block,
`Shibuya.Batch.ReliabilitySpec.spec` (the spec already opens with its own `describe`, so call
it bare, matching how `Shibuya.Runner.SupervisedSpec.spec` is invoked bare).

### Milestone 2 — Scenario tests

At the end of this milestone the same spec module `Shibuya.Batch.ReliabilitySpec` contains a
`describe "scenarios"` block with the seven named scenario tests. Each is a self-contained
`it` block using the same `runApp`/`stopAppGracefully` machinery, a small fixed input, and
tolerant assertions. Run with `cabal test shibuya-core-test`; acceptance is every scenario
reported as passing.

The scenarios reuse a couple of shared helpers. First, a *recording* batch handler that, in
addition to returning a `BatchAck`, appends each invocation's `BatchInfo` and the batch's
message ids to an `IORef`, so a test can assert on the observed triggers, per-batch keys, and
sizes:

```haskell
-- | An observed batch: the info the framework passed and the ids in the batch.
data ObservedBatch = ObservedBatch
  { info :: !BatchInfo,
    ids :: ![MessageId]
  }
  deriving stock (Show)

-- | A handler that records every batch it sees and then returns the given
-- 'BatchAck' (computed from the batch).
recordingHandler ::
  (IOE :> es) =>
  IORef [ObservedBatch] ->
  (BatchInfo -> NonEmpty (Ingested es Int) -> BatchAck) ->
  BatchHandler es Int
recordingHandler ref decide bi msgs = do
  let obs = ObservedBatch bi [ing.envelope.messageId | ing <- toList msgs]
  liftIO $ atomicModifyIORef' ref (\xs -> (obs : xs, ()))
  pure (decide bi msgs)
```

Second, a fixed-message builder that mints `n` envelopes on a single key `"default"` with a
chosen payload; and a variant that assigns keys round-robin from a supplied list. Reuse
`mkEnvelope` from the harness for both:

```haskell
fixedEnvelopes :: Int -> [Envelope Int]
fixedEnvelopes n = [mkEnvelope i (BatchKey "default") i | i <- [1 .. n]]

keyedEnvelopes :: [BatchKey] -> Int -> [Envelope Int]
keyedEnvelopes keys n =
  [mkEnvelope i (keys !! ((i - 1) `mod` length keys)) i | i <- [1 .. n]]
```

(Import `BatchKey (..)` from `Shibuya.Batch` in the spec for these.)

Now the seven scenarios, described one by one with exact inputs and asserted outputs.

**Scenario #2 — Timeout flush.** Configure a batch size larger than the input so nothing ever
flushes by size (e.g. `batchSize = 100`) and a short timeout (e.g. 100 ms). Send 3 messages,
then wait longer than the timeout (e.g. graceful shutdown after 400 ms, or simply
`stopAppGracefully` which flushes anyway). Assert all 3 record one successful finalization, all
`AckOk`, and that at least one observed batch was emitted. If the timeout ticker fired before
shutdown, the observed batch's `trigger` is `TriggerTimeout`; if graceful shutdown flushed it
first, the trigger is `TriggerFlush`. Because scheduler timing decides which happened, assert
tolerantly that the observed trigger is one of `TriggerTimeout` or `TriggerFlush` (both are
correct emissions of a partial batch), and — to actually exercise the *timeout* path — add a
variant that waits well beyond the timeout **before** shutting down and asserts the messages
were already acknowledged (so the flush must have come from the ticker, not shutdown).

```haskell
    it "flushes a partial batch on timeout" $ do
      observedRef <- newIORef ([] :: [ObservedBatch])
      tracking <- runEff $ runTracingNoop newTrackingAck
      (tracked, observed) <- runEff $ runTracingNoop $ do
        let pid = ProcessorId "timeout"
            cfg =
              (defaultBatchConfig @_ @Int)
                { batchSize = 100,
                  batchTimeout = 0.1, -- 100 ms
                  batchKey = scenarioBatchKey
                }
            adapter = trackedListAdapter tracking (fixedEnvelopes 3)
            handler = recordingHandler observedRef (\_ _ -> ackExcept [])
            proc = mkBatchProcessor adapter handler cfg
        Right app <- runApp IgnoreFailures 100 [(pid, proc)]
        -- Wait well beyond the timeout so the ticker flushes before we shut down.
        liftIO $ threadDelay 400000 -- 400 ms
        t0 <- getTrackedDecisions tracking
        _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
        o <- liftIO $ readIORef observedRef
        pure (t0, o)
      -- All three were acknowledged (by the ticker flush) before shutdown.
      finalizedExactlyOnce tracked (Map.fromList [(MessageId ("msg-" <> tshowT i), AckOk) | i <- [1 .. 3 :: Int]])
        `shouldBe` Right ()
      map (.info.trigger) observed `shouldSatisfy` any (`elem` [TriggerTimeout])
```

(Here `tshowT = Text.pack . show`; import `threadDelay` from `UnliftIO.Concurrent` and
`Text` as in `SupervisedSpec`. The `@_ @Int` type applications pin the phantom `msg` of
`defaultBatchConfig` to `Int`; `GHC2024` enables `TypeApplications`.)

**Scenario #3 — Partial failure.** Send 5 messages on one key with a batch size of 5 (so one
full batch). The handler dead-letters exactly two of them (say `msg-2` and `msg-4`) and acks
the rest OK. Assert exactly those two carry `AckDeadLetter` and the other three carry `AckOk`,
each exactly once, and metrics `failed == 2`, `processed == 3`.

```haskell
    it "acks a partial-failure batch: exactly the failed messages dead-letter" $ do
      tracking <- runEff $ runTracingNoop newTrackingAck
      (tracked, metrics) <- runEff $ runTracingNoop $ do
        let pid = ProcessorId "partial"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 5, batchTimeout = 0.1, batchKey = scenarioBatchKey}
            fails =
              [ (MessageId "msg-2", AckDeadLetter MaxRetriesExceeded),
                (MessageId "msg-4", AckDeadLetter (PoisonPill "bad"))
              ]
            handler _ _ = pure (ackExcept fails)
            adapter = trackedListAdapter tracking (fixedEnvelopes 5)
            proc = mkBatchProcessor adapter handler cfg
        Right app <- runApp IgnoreFailures 100 [(pid, proc)]
        _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
        mm <- getAppMetrics app
        t <- getTrackedDecisions tracking
        pure (t, fromMaybe (error "no metrics") (Map.lookup pid mm))
      let expected =
            Map.fromList
              [ (MessageId "msg-1", AckOk),
                (MessageId "msg-2", AckDeadLetter MaxRetriesExceeded),
                (MessageId "msg-3", AckOk),
                (MessageId "msg-4", AckDeadLetter (PoisonPill "bad")),
                (MessageId "msg-5", AckOk)
              ]
      finalizedExactlyOnce tracked expected `shouldBe` Right ()
      metrics.stats.failed `shouldBe` 2
      metrics.stats.processed `shouldBe` 3
```

**Scenario #4 — Batch-handler exception.** The handler throws. Per the framework default
(MasterPlan Decision Log), the whole batch is finalized with the fallback
`ackAll (AckRetry (RetryDelay 0))`, so every message in the batch gets `AckRetry` exactly
once, and the exception does **not** crash the whole app — the processor continues/drains.
Send 4 messages, batch size 4, handler = `\_ _ -> error "boom in batch"`. Because the app
runs under `IgnoreFailures`, `stopAppGracefully` still returns. Assert every message carries
`AckRetry (RetryDelay 0)` exactly once, and `stopAppGracefully` returned (the app did not
hang or throw out of `runScenario`).

```haskell
    it "on batch-handler exception, every message retries exactly once and the app survives" $ do
      tracking <- runEff $ runTracingNoop newTrackingAck
      (tracked, drained) <- runEff $ runTracingNoop $ do
        let pid = ProcessorId "exc"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 4, batchTimeout = 0.1, batchKey = scenarioBatchKey}
            handler _ _ = error "boom in batch"
            adapter = trackedListAdapter tracking (fixedEnvelopes 4)
            proc = mkBatchProcessor adapter handler cfg
        Right app <- runApp IgnoreFailures 100 [(pid, proc)]
        d <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
        t <- getTrackedDecisions tracking
        pure (t, d)
      let expected = Map.fromList [(MessageId ("msg-" <> tshowT i), AckRetry (RetryDelay 0)) | i <- [1 .. 4 :: Int]]
      finalizedExactlyOnce tracked expected `shouldBe` Right ()
      drained `shouldBe` True
```

If EP-18 chose a different fallback `RetryDelay` value, adjust the expected decision to match
whatever EP-18 documents; the invariant under test is "every message reaches one successful
finalization with the documented exception fallback," not the specific delay. Record any
such adjustment in the Decision Log.

**Scenario #5 — Transient finalizer retry.** Use a custom `AckHandle` for one message that
throws on the first two `finalize` attempts and records success on the third attempt. The
handler returns `ackAllOk`. Assert the final tracked successful-finalization list contains
the message exactly once with `AckOk`, and assert the attempt counter is exactly three. This
proves EP-18 retries adapter finalizer failures without recomputing the decision or
recording duplicate successful finalizations.

**Scenario #6 — Permanent finalizer failure.** Use a custom `AckHandle` for one message that
always throws. Include other messages with normal tracking handles in the same batch. Assert
`runApp`/`stopAppGracefully` returns without hanging under `IgnoreFailures`, the processor's
metrics enter `Failed`, the failure text or `ProcessorHalt` reason contains the failed
`MessageId`, the permanent-failure message does not appear in the successful-finalization
list, and the other messages are still attempted and successfully finalized. This proves the
framework fails loudly after bounded retries instead of silently treating an unconfirmed ack
as successful.

**Scenario #7 — Halt in a batch, with isolation.** A handler returns a `BatchAck` that
resolves to `AckHalt` for at least one message. Assert the whole batch records one successful
finalization per message, the halting processor stops (its metrics state becomes `Failed` / it is done), and a
*second* processor running under the same app is unaffected (halt isolation, mirroring
`SupervisedSpec`'s "halt in one supervised processor doesn't affect others"). Run two
batching processors under one `runApp`: processor A's handler emits an `AckHalt` override for
one of its messages; processor B's handler acks everything OK. Give it time, then read
metrics.

```haskell
    it "halt in one batch finalizes that batch once, halts its processor, and spares others" $ do
      trackingA <- runEff $ runTracingNoop newTrackingAck
      trackingB <- runEff $ runTracingNoop newTrackingAck
      (trackedA, trackedB, mA, mB) <- runEff $ runTracingNoop $ do
        let pidA = ProcessorId "halt-A"
            pidB = ProcessorId "ok-B"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 3, batchTimeout = 0.1, batchKey = scenarioBatchKey}
            handlerA _ _ = pure (ackExcept [(MessageId "msg-2", AckHalt (HaltFatal "halt in batch"))])
            handlerB _ _ = pure (ackExcept [])
            adapterA = trackedListAdapter trackingA (fixedEnvelopes 3)
            adapterB = trackedListAdapter trackingB (fixedEnvelopes 3)
            procA = mkBatchProcessor adapterA handlerA cfg
            procB = mkBatchProcessor adapterB handlerB cfg
        Right app <- runApp IgnoreFailures 100 [(pidA, procA), (pidB, procB)]
        liftIO $ threadDelay 300000 -- 300 ms
        mm <- getAppMetrics app
        _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
        tA <- getTrackedDecisions trackingA
        tB <- getTrackedDecisions trackingB
        pure
          ( tA,
            tB,
            fromMaybe (error "no A") (Map.lookup pidA mm),
            fromMaybe (error "no B") (Map.lookup pidB mm)
          )
      -- A's whole batch records one successful finalization per message (msg-2 halts, others OK).
      finalizedExactlyOnce
        trackedA
        ( Map.fromList
            [ (MessageId "msg-1", AckOk),
              (MessageId "msg-2", AckHalt (HaltFatal "halt in batch")),
              (MessageId "msg-3", AckOk)
            ]
        )
        `shouldBe` Right ()
      -- A halted.
      case mA.state of
        Failed msg _ -> msg `shouldSatisfy` Text.isInfixOf "halt in batch"
        other -> expectationFailure ("expected A Failed, got: " <> show other)
      -- B was unaffected: all three acked OK exactly once.
      finalizedExactlyOnce
        trackedB
        (Map.fromList [(MessageId ("msg-" <> tshowT i), AckOk) | i <- [1 .. 3 :: Int]])
        `shouldBe` Right ()
```

**Scenario #8 — Graceful drain flush.** Enqueue a partial batch (fewer messages than the
batch size) with a long timeout so it would not flush on its own within the test window, then
call `stopAppGracefully`, and assert the partial batch was flushed and every message was
successfully finalized once before `done`. Send 3 messages, batch size 100, timeout 30 s (so no
size or timeout flush happens in-window), shut down gracefully with a generous drain timeout.
Assert all 3 are successfully finalized once and the observed batch's trigger is `TriggerFlush`.

```haskell
    it "flushes a pending partial batch on graceful shutdown" $ do
      observedRef <- newIORef ([] :: [ObservedBatch])
      tracking <- runEff $ runTracingNoop newTrackingAck
      (tracked, drained, observed) <- runEff $ runTracingNoop $ do
        let pid = ProcessorId "drain"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 100, batchTimeout = 30, batchKey = scenarioBatchKey}
            handler = recordingHandler observedRef (\_ _ -> ackExcept [])
            adapter = trackedListAdapter tracking (fixedEnvelopes 3)
            proc = mkBatchProcessor adapter handler cfg
        Right app <- runApp IgnoreFailures 100 [(pid, proc)]
        liftIO $ threadDelay 100000 -- 100 ms, let messages accumulate (no size/timeout flush)
        d <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
        t <- getTrackedDecisions tracking
        o <- liftIO $ readIORef observedRef
        pure (t, d, o)
      finalizedExactlyOnce tracked (Map.fromList [(MessageId ("msg-" <> tshowT i), AckOk) | i <- [1 .. 3 :: Int]])
        `shouldBe` Right ()
      drained `shouldBe` True
      map (.info.trigger) observed `shouldSatisfy` elem TriggerFlush
```

**Scenario #9 — Multiple batch keys.** Messages with two or more keys accumulate
independently. Send 6 messages assigned round-robin to keys `["ka", "kb"]` (so `ka` gets
`msg-1,3,5` and `kb` gets `msg-2,4,6`), with a batch size of 3 so each key flushes its own
full batch by size. Assert every observed batch is single-key (every id in the batch shares
the `BatchInfo.batchKey`), that both keys `ka` and `kb` appear among the observed batches, and
that all 6 messages are acked exactly once overall.

```haskell
    it "accumulates independent per-key batches and acks all exactly once" $ do
      observedRef <- newIORef ([] :: [ObservedBatch])
      tracking <- runEff $ runTracingNoop newTrackingAck
      (tracked, observed) <- runEff $ runTracingNoop $ do
        let pid = ProcessorId "multi-key"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 3, batchTimeout = 0.1, batchKey = scenarioBatchKey}
            handler = recordingHandler observedRef (\_ _ -> ackExcept [])
            adapter = trackedListAdapter tracking (keyedEnvelopes [BatchKey "ka", BatchKey "kb"] 6)
            proc = mkBatchProcessor adapter handler cfg
        Right app <- runApp IgnoreFailures 100 [(pid, proc)]
        _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
        t <- getTrackedDecisions tracking
        o <- liftIO $ readIORef observedRef
        pure (t, o)
      -- Every observed batch is single-key: all its message ids belong to its key.
      forM_ observed $ \ob ->
        all (idBelongsToKey ob.info.batchKey) ob.ids `shouldBe` True
      -- Both keys were observed.
      map (.info.batchKey) observed `shouldSatisfy` (\ks -> BatchKey "ka" `elem` ks && BatchKey "kb" `elem` ks)
      -- All six acked exactly once.
      finalizedExactlyOnce tracked (Map.fromList [(MessageId ("msg-" <> tshowT i), AckOk) | i <- [1 .. 6 :: Int]])
        `shouldBe` Right ()
      where
        -- msg-1,3,5 belong to ka; msg-2,4,6 belong to kb, by round-robin.
        idBelongsToKey (BatchKey "ka") (MessageId t) = odd (msgNum t)
        idBelongsToKey (BatchKey "kb") (MessageId t) = even (msgNum t)
        idBelongsToKey _ _ = True
        msgNum t = read (drop 4 (Text.unpack t)) :: Int -- "msg-<n>"
```

**Scenario #10 — Per-key FIFO under concurrency.** Run with `Async 2` and feed at least three
batches: two for `BatchKey "same"` and one for `BatchKey "other"`. Use handler-controlled
`MVar`s or `TVar`s to record `(key, started|finished, batchNumber)` events. Make the first
`"same"` batch block briefly, then ensure the second `"same"` batch does not start until the
first records `finished`, while the `"other"` batch is allowed to start before the first
`"same"` batch finishes. This proves EP-18's keyed scheduler preserves same-key FIFO while
still allowing useful cross-key concurrency.

**Scenario #11 — Backpressure liveness (limited).** With a tiny inbox (size 2) and a slow
batch handler, run many messages and assert the run still records one successful finalization
per message and completes without deadlock. This is a *liveness / no-loss* proxy, not a memory
measurement: deterministically asserting bounded memory from a unit test is not reliable, so
per the PLANS "no silent caps" guidance this test is explicitly a weaker check and is marked
as such in the Decision Log. Send 20 messages, inbox size 2, batch size 4, handler sleeps
5 ms per batch, shut down gracefully, assert one successful finalization per message.

```haskell
    it "under a tiny inbox and a slow handler, loses no messages (backpressure liveness; see limitation)" $ do
      tracking <- runEff $ runTracingNoop newTrackingAck
      tracked <- runEff $ runTracingNoop $ do
        let pid = ProcessorId "backpressure"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 4, batchTimeout = 0.05, batchKey = scenarioBatchKey}
            handler _ _ = do
              liftIO $ threadDelay 5000 -- 5 ms per batch
              pure (ackExcept [])
            adapter = trackedListAdapter tracking (fixedEnvelopes 20)
            proc = mkBatchProcessor adapter handler cfg
        Right app <- runApp IgnoreFailures 2 [(pid, proc)] -- inbox size 2
        _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 10}) app
        getTrackedDecisions tracking
      finalizedExactlyOnce tracked (Map.fromList [(MessageId ("msg-" <> tshowT i), AckOk) | i <- [1 .. 20 :: Int]])
        `shouldBe` Right ()
```

All scenario `it` blocks use tolerant timing (`threadDelay` + `shouldSatisfy` / set-equality
via `finalizedExactlyOnce`) and never assert an exact scheduler-dependent count. Where a test
spins up under `UnliftIO.withAsync` to catch a linked async failure would be needed (as in the
`SupervisedSpec` adapter-source-exception test), none of these scenarios provoke an *ingester*
failure, so the simpler `runApp` + `stopAppGracefully` shape suffices; keep the
`UnliftIO.withAsync (...) UnliftIO.waitCatch` pattern in reserve only if a future scenario
must observe a propagated crash.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

1. Edit `shibuya-core/src/Shibuya/Adapter/Mock.hs`: add `mkTrackedIngested` and
   `trackedListAdapter` (with the two new imports and the two new export-list entries) exactly
   as shown in Milestone 1.

2. Create `shibuya-core/test/Shibuya/Batch/TestHarness.hs` with the full contents shown in
   Milestone 1 (scenario model, generator, envelope builders, pure checker).

3. Create `shibuya-core/test/Shibuya/Batch/ReliabilitySpec.hs` with the successful-finalization property
   from Milestone 1 and the seven scenario `it` blocks from Milestone 2, plus the shared
   helpers (`scenarioConfig`, `intendedHandler`, `runScenario`, `ObservedBatch`,
   `recordingHandler`, `fixedEnvelopes`, `keyedEnvelopes`, and a local `tshowT`). Add the
   extra imports the scenarios need: `Shibuya.Batch (BatchKey (..), ackAll)`, `Data.Text qualified as Text`,
   and `UnliftIO.Concurrent (threadDelay)`.

4. Edit `shibuya-core/shibuya-core.cabal`. Under the test-suite `other-modules`, add
   (keeping the list readable — placement near the other specs is fine):

```text
    Shibuya.Batch.ReliabilitySpec
    Shibuya.Batch.TestHarness
```

   Under the test-suite `build-depends`, add `containers` (used by `Data.Map.Strict` in the
   harness and spec):

```text
    containers,
```

5. Edit `shibuya-core/test/Main.hs`: add `import Shibuya.Batch.ReliabilitySpec qualified` with
   the other imports, and add `Shibuya.Batch.ReliabilitySpec.spec` to the `main` do-block
   (bare, since the spec opens with its own `describe "Shibuya.Batch reliability"`).

6. Build and run:

```bash
cabal build shibuya-core
cabal test shibuya-core-test
```

7. Format:

```bash
nix fmt
```

Expected `cabal test shibuya-core-test` output includes the existing suites plus the new
batch reliability block. The QuickCheck line reports the number of tests it ran; the scenario
lines each report a passing example:

```text
Shibuya.Batch reliability
  successful-finalization property
    finalizes every normal-path message once with the intended decision
      +++ OK, passed 50 tests.
  scenarios
    flushes a partial batch on timeout
    acks a partial-failure batch: exactly the failed messages dead-letter
    on batch-handler exception, every message retries and the app survives
    retries a transient finalizer failure and records one success
    exhausts permanent finalizer failures and halts loudly with the failed MessageId
    halt in one batch finalizes that batch, halts its processor, and spares others
    flushes a pending partial batch on graceful shutdown
    accumulates independent per-key batches and acks all exactly once
    preserves per-key FIFO while allowing cross-key concurrency
    under a tiny inbox and a slow handler, loses no messages (backpressure liveness; see limitation)

Finished in N.NNNN seconds
MM examples, 0 failures
```

If a compile error mentions an unknown `mkBatchProcessor`, `BatchingProcessor`,
`batchedMessages`, or a mismatched argument order, that is the EP-19/EP-18 coordination point:
reconcile the names against the finalized EP-19/EP-18 modules and record the reconciliation in
the Decision Log (see "Interfaces and Dependencies").


## Validation and Acceptance

Acceptance is behavioral and observable through the test runner.

The headline acceptance is the successful-finalization property. Running
`cabal test shibuya-core-test` executes 50 randomized batch schedules, each spun up through
the real `runApp` path and flushed via `stopAppGracefully`, and for each asserts (a) the
multiset of successfully finalized `MessageId`s equals the input set with each id appearing
exactly once in the normal path, (b) each id's single finalized decision equals the handler's intended decision (an `AckOk`
fallback or an `AckDeadLetter` override), and (c) the metric accounting
`processed + failed == n` and `batchedMessages == n`. A pass prints
`+++ OK, passed 50 tests.`; a failure prints a shrunk counterexample scenario plus the
checker's explanation string (for example
`successful-finalization violated: finalized more than once: [MessageId "msg-7"]`), which pinpoints
whether the bug is a duplicate successful ack, a missing ack, or a wrong decision.

The resilience acceptance is the trio of targeted failure scenarios: a transient finalizer
failure must retry and then record one successful finalization; a permanent finalizer
failure must exhaust the retry schedule, report the failed `MessageId`, mark the processor
failed, and still attempt the other messages; and `Async` execution must preserve FIFO for
batches with the same `BatchKey` while allowing different keys to overlap.

To prove the tests actually exercise the invariant (i.e. they can fail), temporarily perturb
the framework and observe a red suite. For example, if EP-18's finalizer is temporarily made
to call `finalize` twice successfully for the first message of each batch, the successful-finalization property fails
with a `finalized more than once` counterexample and the partial-failure scenario fails on the
id-set/duplicate check. Revert the perturbation and the suite goes green again. This
"fails-before, passes-after" demonstration is the strongest evidence the suite is not
vacuous; note the observed red output in Surprises & Discoveries when you perform it.

The scenario acceptances are: timeout-flush proves a partial batch is emitted and acked
once via `TriggerTimeout` (ticker) before shutdown; partial-failure proves exactly the two
chosen messages dead-letter (metrics `failed == 2`, `processed == 3`) while the rest ack OK,
each once; batch-exception proves every message in the batch is assigned the documented
exception fallback and then successfully finalized, and the app survives
(`stopAppGracefully` returns `True`); halt-in-batch proves the halting batch records one
successful finalization per message, its processor's state becomes `Failed`, and a
co-resident processor completes untouched (halt isolation); drain-flush proves a pending
partial batch is flushed on graceful shutdown (`trigger == TriggerFlush`) with every message
successfully finalized once; multi-key proves each
emitted batch is single-key, both keys are observed, and all messages ack exactly once;
backpressure-liveness proves that even with a size-2 inbox and a slow handler no message is
lost or double-acked (the limited memory-boundedness caveat is documented, not asserted).


## Idempotence and Recovery

Every step is additive and safe to repeat. The two library helpers in
`shibuya-core/src/Shibuya/Adapter/Mock.hs` are new top-level bindings and new export-list
entries; if they already exist, do not add them twice (a duplicate binding or export is a
compile error, so the compiler will tell you). The two test files
`shibuya-core/test/Shibuya/Batch/TestHarness.hs` and
`shibuya-core/test/Shibuya/Batch/ReliabilitySpec.hs` are new; re-running the writes overwrites
them with the same content. The cabal `other-modules`/`build-depends` insertions and the
`Main.hs` import/`describe` line are idempotent list edits — if an entry is present, leave it.

If the build fails, the likely causes and fixes are: a missing deriving strategy (every
`deriving` must name `stock`/`newtype`/`anyclass` because `DerivingStrategies` is on); a
missing `containers` dependency in the test suite (add it as in Concrete Steps); reading a
record field with a generated accessor (there are none under `NoFieldSelectors`; use dot
syntax `value.field`); or a mismatch with the EP-19/EP-18 public API (see the next section).
None of these steps change existing runtime behavior — the only production edit is *adding*
two functions to `Mock.hs` — so recovery is simply deleting the two new test files and
reverting the small `Mock.hs`, cabal, and `Main.hs` additions.

The tests themselves are safe to re-run any number of times: they allocate fresh `IORef`s and
`TrackingAck`s per example, spin up an isolated `runApp` with unique `ProcessorId`s, and tear
it down with `stopAppGracefully`, leaking no global state between runs. They touch no
filesystem, socket, or database.


## Interfaces and Dependencies

New library code (module `Shibuya.Adapter.Mock`,
`shibuya-core/src/Shibuya/Adapter/Mock.hs`), exported:

```haskell
mkTrackedIngested :: (IOE :> es) => TrackingAck -> Envelope msg -> Ingested es msg
trackedListAdapter :: (IOE :> es) => TrackingAck -> [Envelope msg] -> Adapter es msg
```

New test module `Shibuya.Batch.TestHarness`
(`shibuya-core/test/Shibuya/Batch/TestHarness.hs`), exporting:

```haskell
data BatchScenario = BatchScenario
  { msgCount :: !Int, batchSize :: !Int, batchTimeoutMs :: !Int
  , keyOf :: !(Map Int BatchKey), outcomeOf :: !(Map Int AckDecision) }
genScenario :: Gen BatchScenario
instance Arbitrary BatchScenario
mkEnvelope :: Int -> BatchKey -> Int -> Envelope Int
scenarioEnvelopes :: BatchScenario -> [Envelope Int]
scenarioBatchKey :: Envelope Int -> BatchKey
scenarioMsgIds :: BatchScenario -> [MessageId]
scenarioIntended :: BatchScenario -> Map MessageId AckDecision
finalizedExactlyOnce :: [(MessageId, AckDecision)] -> Map MessageId AckDecision -> Either String ()
```

New test module `Shibuya.Batch.ReliabilitySpec`
(`shibuya-core/test/Shibuya/Batch/ReliabilitySpec.hs`), exporting `spec :: Spec` and holding
the internal helpers `scenarioConfig`, `intendedHandler`, `runScenario`, `ObservedBatch`,
`recordingHandler`, `fixedEnvelopes`, `keyedEnvelopes`, `tshowT`.

Cabal edits (`shibuya-core/shibuya-core.cabal`): test-suite `other-modules` gains
`Shibuya.Batch.ReliabilitySpec` and `Shibuya.Batch.TestHarness`; test-suite `build-depends`
gains `containers`. Driver edit (`shibuya-core/test/Main.hs`): import and invoke
`Shibuya.Batch.ReliabilitySpec.spec`.

Existing types/functions this plan consumes and relies on being exactly as written:
`Shibuya.Adapter.Mock` (`listAdapter`, `TrackingAck (..)`, `newTrackingAck`,
`trackingAckHandle`, `getTrackedDecisions`); `Shibuya.Core.Types`
(`Envelope (..)`, `MessageId (..)`, `Cursor (..)`); `Shibuya.Core.Ingested (Ingested (..))`;
`Shibuya.Core.Ack` (`AckDecision (..)`, `DeadLetterReason (..)`, `HaltReason (..)`,
`RetryDelay (..)`); `Shibuya.Batch` (`BatchKey (..)`, `BatchConfig (..)`, `BatchInfo (..)`,
`BatchHandler`, `BatchAck`, `defaultBatchConfig`, `ackExcept`, `ackAll`);
`Shibuya.Runner.Metrics` (`ProcessorId (..)`, `ProcessorMetrics (..)`, `StreamStats (..)`,
`BatchStats (..)`, `ProcessorState (..)`); `Shibuya.Telemetry.Effect (runTracingNoop)`;
`Shibuya.App` (`runApp`, `stopAppGracefully`, `getAppMetrics`, `SupervisionStrategy (..)`,
`ShutdownConfig (..)`).

Frozen EP-19/EP-18 API — the coordination surface. This plan is written against the
following public shapes, which the sibling plans EP-18 and EP-19 have frozen. They match the
existing `mkProcessor`/`runWithMetrics` conventions (adapter first, config last for the smart
constructor; adapter before handler for the runner):

```haskell
-- From Shibuya.App (EP-19): a smart constructor building a batching QueueProcessor.
-- Adapter first, config last, matching mkProcessor.
mkBatchProcessor :: Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es

-- From Shibuya.Runner.Metrics (EP-18): a NEW BatchStats record, attached to
-- ProcessorMetrics via a `batch` field. Per-message processed/failed stay on
-- StreamStats; only the batch-specific counters live here.
data BatchStats = BatchStats
  { batchesEmitted :: !Int
  , batchedMessages :: !Int
  , partialFailures :: !Int
  , sizeTriggered :: !Int
  , timeoutTriggered :: !Int
  , flushTriggered :: !Int
  }

data ProcessorMetrics = ProcessorMetrics
  { state :: !ProcessorState
  , stats :: !StreamStats   -- ^ received/dropped/processed/failed, unchanged
  , batch :: !BatchStats    -- ^ added by EP-18
  , startedAt :: !UTCTime
  }
```

Accordingly, this plan reads the total batched-message count as
`metrics.batch.batchedMessages` and keeps per-message accounting on
`metrics.stats.processed` / `metrics.stats.failed`.

One coordination convenience to flag for EP-18/EP-19 (also surfaced in this plan's final
summary): a **deterministic batch runner hook**. This suite drives batching through
`runApp` + `stopAppGracefully`, which is robust but relies on graceful shutdown to flush the
tail. If EP-18/EP-19 expose a non-supervised, blocking, finite-stream batch runner analogous
to the existing per-message `runWithMetrics`, the frozen signature is

```haskell
runWithMetricsBatch ::
  (IOE :> es, Tracing :> es) =>
  Natural -> ProcessorId -> Concurrency -> BatchConfig es msg -> Adapter es msg -> BatchHandler es msg -> Eff es SupervisedProcessor
```

(adapter before handler, mirroring `runWithMetrics`). The scenario tests can use it for
tighter determinism (no `threadDelay` needed to let a finite stream drain). The property test
should still prefer the public `runApp` path so it exercises real integration;
`runWithMetricsBatch` is a convenience, not a requirement.

Observability of the batch trigger is already covered: the timeout-flush (#2) and drain-flush
(#6) scenarios observe *why* a batch was emitted by having the batch handler record the
`BatchInfo` (which carries `trigger :: BatchTrigger` per EP-16). The frozen `BatchStats` above
additionally exposes per-trigger counters (`sizeTriggered`, `timeoutTriggered`,
`flushTriggered`), so those scenarios may also assert on `metrics.batch.timeoutTriggered` /
`metrics.batch.flushTriggered` directly; where the recording-handler assertion and the metric
assertion are both cheap, prefer keeping both.


## Revision Note

Initial authoring (2026-07-01): created the full EP-20 plan from the skeleton, filling every
section. Seeded the Decision Log with the harness placement (library `Mock.hs` for shippable
helpers, test-only `TestHarness` for the generator/checker), the assertion strategy (against
the `TrackingAck` list, not batch boundaries), the tolerant-timing approach mirrored from
`SupervisedSpec`, the `runApp` + `stopAppGracefully` primary driver, and the backpressure
scenario's explicit limitation. Recorded the EP-19/EP-18 coordination surface and two
cross-plan requests (a `runWithMetricsBatch` determinism hook and per-trigger metric
observability). Left Surprises & Discoveries and Outcomes & Retrospective as not-yet-filled
per the ExecPlan spec.

Consistency pass (2026-07-01): reconciled EP-20 with three signatures frozen by the sibling
plans. (1) `mkBatchProcessor` is `Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es`
(adapter first, config last, matching `mkProcessor`); updated the two signature lines and all
nine call sites from the old `mkBatchProcessor cfg handler adapter` order to
`mkBatchProcessor adapter handler cfg`. (2) `runWithMetricsBatch` takes `Adapter` before
`BatchHandler` (mirroring `runWithMetrics`); swapped them. (3) Batch counters live on a new
`ProcessorMetrics.batch :: BatchStats` record — `BatchStats { batchesEmitted, batchedMessages,
partialFailures, sizeTriggered, timeoutTriggered, flushTriggered }` — not on `StreamStats`;
changed the property assertion to `metrics.batch.batchedMessages`, imported `BatchStats (..)`
from `Shibuya.Runner.Metrics`, and corrected the Context/Interfaces prose. Per-message
`processed`/`failed` deliberately remain on `metrics.stats` (unchanged from the single-message
path).

Reliability strengthening pass (2026-07-01): updated the invariant and scenarios after
MasterPlan validation. EP-20 now distinguishes normal-path one-successful-finalization checks
from adapter-finalizer failure handling; adds transient-finalizer retry and permanent
finalizer fail-loud scenarios; and adds a per-key FIFO concurrency scenario so EP-18 cannot
accidentally use raw global concurrency that overlaps two batches with the same `BatchKey`.
