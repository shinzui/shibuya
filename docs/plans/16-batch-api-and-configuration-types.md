---
id: 16
slug: batch-api-and-configuration-types
title: "Batch API and Configuration Types"
kind: exec-plan
created_at: 2026-07-01T15:34:31Z
intention: "intention_01kwf4q2bke2js9t0js53dwh5a"
master_plan: "docs/masterplans/3-first-class-batch-processing.md"
---

# Batch API and Configuration Types

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the first child of the MasterPlan at
`docs/masterplans/3-first-class-batch-processing.md` ("First-Class Batch Processing").
It defines the pure, dependency-free foundation that every later batch plan builds on.


## Purpose / Big Picture

Shibuya is a Haskell queue-processing framework. Today a consumer processes exactly one
message at a time: a `Handler es msg` (a function `Ingested es msg -> Eff es AckDecision`)
receives one message and returns one acknowledgement decision. Many real workloads want to
process messages in *groups* — insert 500 rows in one database statement, upload many
objects in one S3 multipart call, send one batched HTTP request — because per-message
round trips are slow and expensive. There is no first-class way to do that today, so users
hand-roll accumulation inside their handler, which does not integrate with backpressure
and easily loses or double-acknowledges messages.

This plan does not add any runtime behavior. It adds the **public vocabulary** for
batching: a new module `Shibuya.Batch` containing the batch handler type, the batch
configuration record, the batch grouping key, the reason a batch was emitted, the metadata
handed to a batch handler, and — most importantly — the `BatchAck` result type that
encodes the framework's **one-decision-per-retained-message acknowledgement contract**.
After this plan, a
developer can write and type-check a batch handler and a batch configuration, and the
smart constructors and validation for them exist and are unit-tested. Nothing runs a batch
yet (that is later plans), but the types that make the whole feature reliable are pinned
down here so that the accumulation engine (`docs/plans/17-batch-accumulation-engine.md`),
the execution stage (`docs/plans/18-batch-execution-and-exactly-once-ack.md`), and the
runner wiring (`docs/plans/19-batch-runner-and-app-integration.md`) all agree on one
contract.

You can see this working by loading the new module in GHCi and constructing values, and by
running the new unit-test module, which asserts the smart constructors and the config
validator behave as specified.


## Progress

- [x] Create `shibuya-core/src/Shibuya/Batch.hs` with `BatchKey`, `BatchTrigger`, `BatchInfo`, `BatchConfig`, `BatchHandler`, `BatchAck`, `BatchConfigError`. (2026-07-01)
- [x] Add smart constructors: `defaultBatchKey`, `defaultBatchConfig`, `ackAllOk`, `ackAll`, `ackExcept`, `withFallback`, `failMessages`. (2026-07-01)
- [x] Add `validateBatchConfig`. (2026-07-01)
- [x] Add `Shibuya.Batch` to `exposed-modules` in `shibuya-core/shibuya-core.cabal`. (2026-07-01)
- [x] Create `shibuya-core/test/Shibuya/BatchSpec.hs` and register it in the cabal `other-modules` and in `test/Main.hs`. (2026-07-01)
- [x] `cabal build shibuya-core` and `cabal test shibuya-core-test` both green. (2026-07-01; 129 examples, 0 failures — 12 new Batch examples)
- [x] `nix fmt` clean. (2026-07-01; 0 files changed)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `IsString` is not re-exported by `Shibuya.Prelude`. The first build failed with
  `Not in scope: type constructor or class 'IsString'` for the `deriving newtype
  (IsString)` clause on `BatchKey`. Fixed by importing `Data.String (IsString)`
  explicitly, mirroring `shibuya-core/src/Shibuya/Core/Types.hs:28`.
- The test suite did not depend on `containers`. Building `BatchSpec` (which imports
  `Data.Map.Strict`) failed with `Could not load module 'Data.Map.Strict' ... hidden
  package 'containers-0.7'`. Fixed by adding `containers` to the test suite
  `build-depends` in `shibuya-core/shibuya-core.cabal`.
- The plan's draft test used `ackAll (AckRetry undefined)`, which throws at construction
  time: `AckRetry` has a strict `RetryDelay` field and `BatchAck.fallback` is strict, so
  building the value forces `undefined` to WHNF. Fixed by using a concrete
  `AckRetry (RetryDelay 5)` and additionally asserting the fallback round-trips. This is
  evidence the strictness annotations on `AckDecision`/`BatchAck` behave as intended.
- The polymorphic `defaultBatchConfig :: BatchConfig es msg` cannot have its fields read
  directly in a test (e.g. `defaultBatchConfig.batchSize`) because `es` is a phantom
  parameter of `BatchConfig` and would be ambiguous. Resolved by a concrete top-level
  helper `cfg :: BatchConfig '[] Int = defaultBatchConfig` (needs `DataKinds`); see the
  Decision Log entry.


## Decision Log

Record every decision made while working on the plan.

- Decision: `BatchAck` keys per-message decisions by `MessageId` using a
  `Data.Map.Strict.Map MessageId AckDecision` plus a `fallback :: AckDecision`, rather than
  a positional `[AckDecision]` aligned to the input order.
  Rationale: The MasterPlan Integration Points require the framework to resolve one
  acknowledgement decision for each message in *its own* retained list, not from the
  handler's output shape. A `Map` keyed by identity lets the framework look up each
  retained message and apply a fallback for any the handler did not mention, so no message
  is dropped or misassigned even if the handler returns a wrong-length or reordered
  result. The later execution plan is responsible for driving the adapter's idempotent
  `AckHandle.finalize` with bounded retries. `MessageId` already derives `Ord`
  (`shibuya-core/src/Shibuya/Core/Types.hs:34-37`), so a `Map` needs no new instances and
  does not touch the stable `Core.Types` module (a `HashMap` would have required adding a
  `Hashable MessageId` instance and the `hashable` dependency).
  Date: 2026-07-01

- Decision: `BatchKey` is a `newtype` over `Text` deriving `Ord`, not an arbitrary type.
  Rationale: Keys are used as `Map` keys in the accumulation engine
  (`docs/plans/17-batch-accumulation-engine.md`); `Ord Text` is free and total. `IsString`
  deriving lets users write `"orders" :: BatchKey` with `OverloadedStrings` (already a
  default extension).
  Date: 2026-07-01

- Decision: `batchKey` in `BatchConfig` is a **pure** function `Envelope msg -> BatchKey`,
  not effectful.
  Rationale: Routing must be cheap, deterministic, and side-effect-free so the engine can
  call it while holding the accumulator without entering `Eff`. Any effectful decision
  belongs in the batch handler.
  Date: 2026-07-01

- Decision: `BatchConfigError` lives in `Shibuya.Batch`, not in
  `shibuya-core/src/Shibuya/Core/Error.hs`.
  Rationale: Keeps this plan free of edits to shared error types. The runner-integration
  plan (`docs/plans/19-batch-runner-and-app-integration.md`) is responsible for wrapping
  `BatchConfigError` into the top-level `AppError` when it validates processors.
  Date: 2026-07-01

- Decision: The test module uses a concrete top-level helper
  `cfg :: BatchConfig '[] Int; cfg = defaultBatchConfig` (with `DataKinds` added to the
  test suite `default-extensions`) rather than sprinkling `@'[] @Int` `TypeApplications`
  at each use site. The plan offered both approaches.
  Rationale: `es` is a phantom parameter of `BatchConfig`, so reading a field off the
  polymorphic `defaultBatchConfig` is ambiguous; one concrete binding fixes `es`/`msg`
  once, keeps every call site readable, and confines the extra extension to a single
  `DataKinds` for the `'[]` empty-effect-list literal. `GHC2024` does not enable
  `DataKinds`, so it is added explicitly to the test suite only.
  Date: 2026-07-01

- Decision: Placed `Shibuya.Batch` in `exposed-modules` after `Shibuya.App` (i.e.
  App < Batch < Core), not literally "between `Shibuya.Adapter.Mock` and `Shibuya.App`"
  as the prose suggested.
  Rationale: The list is kept alphabetical; `App` sorts before `Batch`. The prose's
  ordinal hint was imprecise, but its intent (alphabetical placement) is honored.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Complete (2026-07-01). The single milestone landed exactly as scoped: the new pure module
`shibuya-core/src/Shibuya/Batch.hs` defines and exports `BatchKey`, `BatchTrigger`,
`BatchInfo`, `BatchConfig`, `BatchHandler`, `BatchAck`, and `BatchConfigError`, plus the
smart constructors (`defaultBatchKey`, `defaultBatchConfig`, `ackAllOk`, `ackAll`,
`ackExcept`, `withFallback`, `failMessages`) and `validateBatchConfig`. The module haddock
records the one-decision-per-retained-message acknowledgement contract verbatim as the
normative spec that EP-18/EP-20 must match.

Every acceptance criterion holds: `cabal build shibuya-core` compiles the new module with
no warnings under `-Wall`; `cabal test shibuya-core-test` is green (129 examples, 0
failures, 12 of them the new `Shibuya.Batch` block); `nix fmt` leaves the tree clean (0
files changed). No runtime behavior was added, as intended — the reliability-critical
types are pinned down for the downstream plans.

Signatures match the MasterPlan's frozen public/shared signatures section: `BatchHandler
es msg = BatchInfo -> NonEmpty (Ingested es msg) -> Eff es BatchAck`, and `BatchAck`
carries `decisions :: Map MessageId AckDecision` + `fallback :: AckDecision`, exactly as
EP-17/EP-18/EP-19/EP-20 quote.

Lessons for downstream plans: (1) `Shibuya.Prelude` does not re-export `IsString` — import
it explicitly where deriving it. (2) The test suite needed `containers` added to its
`build-depends`; later batch specs that touch `Data.Map`/`Data.List.NonEmpty` inherit that
now. (3) `AckDecision` and `BatchAck` fields are strict, so test fixtures must use concrete
`RetryDelay`/decision values rather than `undefined`. (4) `BatchConfig`'s `es` is a phantom
parameter — code that reads its fields needs a concrete type binding to avoid ambiguity.


## Context and Orientation

This section assumes no prior knowledge of the repository. Everything you need is here.

Shibuya is a Cabal project. The library package is `shibuya-core`, rooted at
`shibuya-core/` with sources under `shibuya-core/src/Shibuya/` and tests under
`shibuya-core/test/`. The Cabal file is `shibuya-core/shibuya-core.cabal`. The default
language is `GHC2024` and these extensions are on by default for both the library and the
test suite (from the cabal `default-extensions` stanza): `DeriveAnyClass`,
`DerivingStrategies`, `DuplicateRecordFields`, `LambdaCase`, `NoFieldSelectors`,
`OverloadedLabels`, `OverloadedRecordDot`, `OverloadedStrings`, `QuasiQuotes`. Because
`NoFieldSelectors` is on, record fields do **not** generate top-level accessor functions;
you read a field with dot syntax (`value.fieldName`, from `OverloadedRecordDot`). Because
`DerivingStrategies` is on, every `deriving` clause must name its strategy (`stock`,
`newtype`, or `anyclass`).

Build and test commands (run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`):

```bash
cabal build shibuya-core
cabal test shibuya-core-test
nix fmt
```

The existing types you will reference are these (do not re-define them; import them):

`AckDecision` and friends live in `shibuya-core/src/Shibuya/Core/Ack.hs`:

```haskell
newtype RetryDelay = RetryDelay {unRetryDelay :: NominalDiffTime}
  deriving stock (Eq, Show)

data DeadLetterReason
  = PoisonPill !Text
  | InvalidPayload !Text
  | MaxRetriesExceeded
  deriving stock (Eq, Show, Generic)

data HaltReason
  = HaltOrderedStream !Text
  | HaltFatal !Text
  deriving stock (Eq, Show, Generic)

data AckDecision
  = AckOk
  | AckRetry !RetryDelay
  | AckDeadLetter !DeadLetterReason
  | AckHalt !HaltReason
  deriving stock (Eq, Show, Generic)
```

`MessageId` and `Envelope` live in `shibuya-core/src/Shibuya/Core/Types.hs`:

```haskell
newtype MessageId = MessageId {unMessageId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (IsString)
  deriving anyclass (NFData)

data Envelope msg = Envelope
  { messageId    :: !MessageId
  , cursor       :: !(Maybe Cursor)
  , partition    :: !(Maybe Text)
  , enqueuedAt   :: !(Maybe UTCTime)
  , traceContext :: !(Maybe TraceHeaders)
  , headers      :: !(Maybe Headers)
  , attempt      :: !(Maybe Attempt)
  , attributes   :: !(HashMap Text Attribute)
  , payload      :: !msg
  }
  deriving stock (Eq, Show, Functor, Generic)
```

`Ingested` lives in `shibuya-core/src/Shibuya/Core/Ingested.hs`:

```haskell
data Ingested es msg = Ingested
  { envelope :: !(Envelope msg)
  , ack      :: !(AckHandle es)
  , lease    :: !(Maybe (Lease es))
  }
```

`AckHandle` lives in `shibuya-core/src/Shibuya/Core/AckHandle.hs`:

```haskell
newtype AckHandle es = AckHandle
  { finalize :: AckDecision -> Eff es () }
```

The project's `Shibuya.Prelude` (`shibuya-core/src/Shibuya/Prelude.hs`) re-exports
`Generic`, `MonadIO`, `Natural`, `Text`, `UTCTime`, `NominalDiffTime`, `getCurrentTime`,
all of `Control.Lens`, `Data.Generics.Labels` orphans (so `#field` labels work), and
`Vector`. It re-exports `NFData` transitively? No — `NFData` comes from `Control.DeepSeq`;
look at `Core/Types.hs`, which imports `Control.DeepSeq (NFData (..))` explicitly. Follow
that pattern and import `NFData` explicitly where you derive it.

Term definitions used in this plan:

- **Batch**: a non-empty group of ingested messages handed to a batch handler together.
- **Batch key**: a value (wrapped `Text`) computed from each message's envelope that
  decides which sub-batch the message accumulates into. Messages with the same key
  accumulate together and are emitted together; different keys accumulate independently.
- **Batch trigger**: the reason a batch was emitted — it filled to the configured size, its
  timeout elapsed, or the processor is draining and flushed a partial batch.
- **One-decision acknowledgement contract**: every message that enters a batch has exactly
  one `AckDecision` resolved from `BatchAck` by the framework's retained message list. The
  runtime execution stage then calls that message's idempotent `AckHandle.finalize` with
  bounded retries and fails loudly if the adapter never confirms finalization.
- **Smart constructor**: an ordinary function that builds a value in a convenient or
  safe way (e.g. `ackAllOk` builds the common "succeed everything" `BatchAck`).


## Plan of Work

There is a single milestone: create the `Shibuya.Batch` module and its unit tests. It is
small and self-contained (pure code, no runtime), so it is one wave of work with a clear
acceptance: the module compiles, is exported, and the new spec passes.

Create the new file `shibuya-core/src/Shibuya/Batch.hs`. Its module header and export list
should be exactly:

```haskell
-- | Public vocabulary for batch processing.
--
-- This module defines the types a user needs to opt a processor into batching:
-- the batch handler, its configuration, the grouping key, and the batch
-- acknowledgement result. It adds no runtime behavior; the accumulation engine
-- and execution stage live in the internal @Shibuya.Runner.*@ modules.
--
  -- == Acknowledgement decision contract
  --
  -- Given an emitted batch and the 'BatchAck' a 'BatchHandler' returns, the
  -- framework resolves one 'AckDecision' for /every/ message in its own
  -- retained batch list. For each retained message it looks the message's
  -- 'MessageId' up in 'decisions'; if the id is absent it uses 'fallback'. The
  -- handler's return value only /supplies decisions/ — it never drives which
  -- messages are acked. Consequently decision resolution is complete and
  -- deterministic regardless of what the handler returns (wrong length,
  -- reordered, missing ids all degrade gracefully to the fallback). This
  -- requires 'MessageId's to be unique within a batch, which holds for every
  -- real adapter and the mock adapter. The runtime execution stage applies each
  -- resolved decision through the message's idempotent 'AckHandle.finalize' with
  -- bounded retries.
module Shibuya.Batch
  ( -- * Grouping key
    BatchKey (..),
    defaultBatchKey,

    -- * Emission trigger
    BatchTrigger (..),

    -- * Batch metadata
    BatchInfo (..),

    -- * Configuration
    BatchConfig (..),
    defaultBatchConfig,
    BatchConfigError (..),
    validateBatchConfig,

    -- * Handler
    BatchHandler,

    -- * Acknowledgement result
    BatchAck (..),
    ackAllOk,
    ackAll,
    ackExcept,
    withFallback,
    failMessages,
  )
where
```

The imports needed:

```haskell
import Control.DeepSeq (NFData)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Effectful (Eff)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason)
import Shibuya.Core.Ingested (Ingested)
import Shibuya.Core.Types (Envelope, MessageId)
import Shibuya.Prelude
```

Now the type definitions, in order.

`BatchKey` — a grouping key; `Ord` so it can key a `Map` in the engine, `IsString` for
`OverloadedStrings` ergonomics:

```haskell
-- | Groups messages into independent sub-batches within one processor.
-- Messages sharing a key accumulate together; each key has its own size
-- counter and timeout. Compute one per message via 'BatchConfig'\'s 'batchKey'.
newtype BatchKey = BatchKey {unBatchKey :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (IsString)
  deriving anyclass (NFData)

-- | The key used when a configuration does not distinguish sub-batches.
defaultBatchKey :: BatchKey
defaultBatchKey = BatchKey "default"
```

`BatchTrigger`:

```haskell
-- | Why the framework emitted a batch.
data BatchTrigger
  = -- | Reached the configured 'batchSize'.
    TriggerSize
  | -- | 'batchTimeout' elapsed since the batch's first message arrived.
    TriggerTimeout
  | -- | The processor is draining/shutting down; a partial batch was flushed.
    TriggerFlush
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)
```

`BatchInfo`:

```haskell
-- | Metadata about an emitted batch, passed to the 'BatchHandler' alongside
-- the messages.
data BatchInfo = BatchInfo
  { -- | The key all messages in this batch share.
    batchKey :: !BatchKey,
    -- | How many messages are in this batch (always >= 1).
    size :: !Int,
    -- | Why this batch was emitted.
    trigger :: !BatchTrigger,
    -- | Partition of the batch's first message, if the envelope had one.
    partition :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)
```

`BatchConfig` and its default. Note the phantom `es`/`msg` type parameters: `batchKey`
mentions `Envelope msg`, and `es`/`msg` line up with the eventual `BatchHandler es msg` so
a processor's config and handler share the same parameters:

```haskell
-- | Configuration for a batching processor.
--
-- @es@ is the effect stack and @msg@ the payload type, matching the
-- 'BatchHandler' this config is paired with.
data BatchConfig es msg = BatchConfig
  { -- | Emit a batch once it holds this many messages. Must be >= 1.
    batchSize :: !Int,
    -- | Emit a batch this long after its first message arrives, even if it
    -- has not reached 'batchSize'. Must be > 0.
    batchTimeout :: !NominalDiffTime,
    -- | Compute a message's sub-batch key from its envelope. Use
    -- @const 'defaultBatchKey'@ for a single undivided batch.
    batchKey :: !(Envelope msg -> BatchKey),
    -- | How often the timeout ticker scans for timed-out batches. 'Nothing'
    -- means "use 'batchTimeout'". Flush latency is bounded by this interval.
    -- Must be > 0 when 'Just'.
    tickInterval :: !(Maybe NominalDiffTime)
  }

-- | Batch of at most 100, flushed after 1 second, one undivided sub-batch,
-- ticker granularity equal to the timeout. Matches Broadway's defaults
-- (@batch_size: 100@, @batch_timeout: 1000@ ms).
defaultBatchConfig :: BatchConfig es msg
defaultBatchConfig =
  BatchConfig
    { batchSize = 100,
      batchTimeout = 1,
      batchKey = const defaultBatchKey,
      tickInterval = Nothing
    }
```

`BatchHandler`:

```haskell
-- | A batch handler processes a whole batch at once and returns how to
-- acknowledge it. Unlike 'Shibuya.Handler.Handler' (one message -> one
-- decision), a batch handler receives every message in the batch plus its
-- 'BatchInfo', and returns a single 'BatchAck' describing per-message
-- outcomes. See the module haddock for the acknowledgement decision contract.
type BatchHandler es msg = BatchInfo -> NonEmpty (Ingested es msg) -> Eff es BatchAck
```

`BatchAck` and its smart constructors:

```haskell
-- | How to acknowledge every message in a batch. The framework resolves each
-- retained message's decision by looking its 'MessageId' up in 'decisions', or
-- by using 'fallback' if absent. The execution stage applies those decisions to
-- the messages' idempotent finalizers. See the module haddock.
data BatchAck = BatchAck
  { -- | Per-message overrides, keyed by 'MessageId'.
    decisions :: !(Map MessageId AckDecision),
    -- | Decision for any message not present in 'decisions'.
    fallback :: !AckDecision
  }
  deriving stock (Show, Generic)

-- | Acknowledge every message as successfully processed. The common case.
ackAllOk :: BatchAck
ackAllOk = BatchAck Map.empty AckOk

-- | Apply one decision to every message in the batch.
ackAll :: AckDecision -> BatchAck
ackAll = BatchAck Map.empty

-- | Acknowledge everything 'AckOk' except the listed messages, which get their
-- given decisions. Use for partial failure within an otherwise-successful batch.
ackExcept :: [(MessageId, AckDecision)] -> BatchAck
ackExcept overrides = BatchAck (Map.fromList overrides) AckOk

-- | Give the listed messages their decisions and everything else @fb@.
withFallback :: AckDecision -> [(MessageId, AckDecision)] -> BatchAck
withFallback fb overrides = BatchAck (Map.fromList overrides) fb

-- | Dead-letter the listed messages (with reasons) and acknowledge the rest OK.
failMessages :: [(MessageId, DeadLetterReason)] -> BatchAck
failMessages fs =
  BatchAck (Map.fromList [(mid, AckDeadLetter r) | (mid, r) <- fs]) AckOk
```

`BatchConfigError` and the validator:

```haskell
-- | Why a 'BatchConfig' is invalid.
data BatchConfigError
  = BatchSizeNotPositive !Int
  | BatchTimeoutNotPositive !NominalDiffTime
  | TickIntervalNotPositive !NominalDiffTime
  deriving stock (Eq, Show, Generic)

-- | Validate a batch configuration. 'batchSize' must be >= 1, 'batchTimeout'
-- must be > 0, and 'tickInterval' (when set) must be > 0.
validateBatchConfig :: BatchConfig es msg -> Either BatchConfigError ()
validateBatchConfig cfg
  | cfg.batchSize < 1 = Left (BatchSizeNotPositive cfg.batchSize)
  | cfg.batchTimeout <= 0 = Left (BatchTimeoutNotPositive cfg.batchTimeout)
  | Just t <- cfg.tickInterval, t <= 0 = Left (TickIntervalNotPositive t)
  | otherwise = Right ()
```

After writing the module, register it. In `shibuya-core/shibuya-core.cabal`, add
`Shibuya.Batch` to the library `exposed-modules` list (keep the list alphabetical: it goes
between `Shibuya.Adapter.Mock` and `Shibuya.App`). No new build-depends are required —
`containers`, `deepseq`, `effectful`, `text`, and `time` are already dependencies, and
`base` provides `Data.List.NonEmpty`.

Then create the unit test module `shibuya-core/test/Shibuya/BatchSpec.hs` (see Concrete
Steps for its contents), add `Shibuya.BatchSpec` to the test suite `other-modules` in the
cabal file (alphabetical: after `Shibuya.Adapter...` — there is no existing Adapter spec,
so place it before `Shibuya.Core.AckSpec`), and wire it into `shibuya-core/test/Main.hs`.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

1. Create `shibuya-core/src/Shibuya/Batch.hs` with the module shown in Plan of Work
   (header + exports + imports + all type definitions and functions).

2. Edit `shibuya-core/shibuya-core.cabal`: add `Shibuya.Batch` to the library
   `exposed-modules`.

3. Create the test module `shibuya-core/test/Shibuya/BatchSpec.hs`:

```haskell
module Shibuya.BatchSpec (spec) where

import Data.Map.Strict qualified as Map
import Shibuya.Batch
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..))
import Shibuya.Core.Types (MessageId (..))
import Test.Hspec

spec :: Spec
spec = describe "Shibuya.Batch" $ do
  describe "defaultBatchConfig" $ do
    it "has size 100 and 1s timeout" $ do
      defaultBatchConfig.batchSize `shouldBe` 100
      defaultBatchConfig.batchTimeout `shouldBe` 1
    it "routes every message to the default key" $
      defaultBatchConfig.batchKey undefined `shouldBe` defaultBatchKey

  describe "validateBatchConfig" $ do
    it "accepts the default config" $
      validateBatchConfig (defaultBatchConfig @'[] @Int) `shouldBe` Right ()
    it "rejects size 0" $
      validateBatchConfig (defaultBatchConfig @'[] @Int) {batchSize = 0}
        `shouldBe` Left (BatchSizeNotPositive 0)
    it "rejects non-positive timeout" $
      validateBatchConfig (defaultBatchConfig @'[] @Int) {batchTimeout = 0}
        `shouldBe` Left (BatchTimeoutNotPositive 0)
    it "rejects non-positive tick interval" $
      validateBatchConfig (defaultBatchConfig @'[] @Int) {tickInterval = Just 0}
        `shouldBe` Left (TickIntervalNotPositive 0)

  describe "BatchAck smart constructors" $ do
    it "ackAllOk falls back to AckOk with no overrides" $ do
      ackAllOk.fallback `shouldBe` AckOk
      Map.null ackAllOk.decisions `shouldBe` True
    it "ackAll sets the fallback for everything" $ do
      let a = ackAll (AckRetry undefined)
      Map.null a.decisions `shouldBe` True
    it "ackExcept keeps AckOk fallback and records overrides" $ do
      let a = ackExcept [(MessageId "m1", AckDeadLetter MaxRetriesExceeded)]
      a.fallback `shouldBe` AckOk
      Map.lookup (MessageId "m1") a.decisions
        `shouldBe` Just (AckDeadLetter MaxRetriesExceeded)
    it "failMessages dead-letters the listed ids" $ do
      let a = failMessages [(MessageId "bad", PoisonPill "nope")]
      a.fallback `shouldBe` AckOk
      Map.lookup (MessageId "bad") a.decisions
        `shouldBe` Just (AckDeadLetter (PoisonPill "nope"))
    it "withFallback uses the given fallback" $ do
      let a = withFallback (AckDeadLetter MaxRetriesExceeded) [(MessageId "ok", AckOk)]
      a.fallback `shouldBe` AckDeadLetter MaxRetriesExceeded
      Map.lookup (MessageId "ok") a.decisions `shouldBe` Just AckOk
```

   Note: this test module uses `TypeApplications` (the `@'[] @Int` annotations pick a
   concrete `es`/`msg` so the polymorphic `defaultBatchConfig` resolves). `GHC2024`
   enables `TypeApplications`, and it needs `DataKinds` for the `'[]` empty effect list —
   add `DataKinds` to the test suite's `default-extensions` in the cabal file if it is not
   already present. (Check first: `GHC2024` does **not** include `DataKinds`, so you will
   need to add it.) Alternatively, avoid the annotations by giving a top-level helper
   `cfg :: BatchConfig '[] Int; cfg = defaultBatchConfig` — either approach is fine; pick
   whichever keeps the extension surface smallest and record the choice in the Decision
   Log.

4. Edit `shibuya-core/shibuya-core.cabal`: add `Shibuya.BatchSpec` to the test suite
   `other-modules`.

5. Edit `shibuya-core/test/Main.hs`: add `import qualified Shibuya.BatchSpec` and a line
   `describe "Shibuya.Batch" Shibuya.BatchSpec.spec` in the hspec driver (match the
   surrounding style — some specs are invoked with an explicit `describe`, some bare; use
   an explicit `describe` here since `BatchSpec.spec` already opens with
   `describe "Shibuya.Batch"`, so invoking it bare is cleaner — read `test/Main.hs` and
   follow whichever convention its newest entries use, recording the choice).

6. Build and test:

```bash
cabal build shibuya-core
cabal test shibuya-core-test
nix fmt
```

Expected: the build succeeds; the test output includes the `Shibuya.Batch` describe block
with all examples passing, for example:

```text
Shibuya.Batch
  defaultBatchConfig
    has size 100 and 1s timeout
    routes every message to the default key
  validateBatchConfig
    accepts the default config
    rejects size 0
    ...
  BatchAck smart constructors
    ackAllOk falls back to AckOk with no overrides
    ...
```


## Validation and Acceptance

Acceptance is behavioral and testable even though this plan adds no runtime:

1. `cabal build shibuya-core` compiles the new `Shibuya.Batch` module with no warnings
   (the library uses `-Wall` via the `warnings` common stanza; fix any unused-import or
   missing-signature warnings).

2. `cabal test shibuya-core-test` runs and the `Shibuya.Batch` examples all pass. This
   proves the smart constructors and the validator behave as specified (fallback
   decisions, override maps, and each rejection case).

3. In GHCi you can construct and inspect the values, demonstrating the API is usable:

```bash
cabal repl shibuya-core
```

```haskell
ghci> import Shibuya.Batch
ghci> import Shibuya.Core.Ack
ghci> :type ackExcept [(undefined, AckOk)]
ackExcept [(undefined, AckOk)] :: BatchAck
ghci> (defaultBatchConfig @'[] @Int).batchSize
100
ghci> validateBatchConfig ((defaultBatchConfig @'[] @Int) {batchSize = -1})
Left (BatchSizeNotPositive (-1))
```

4. `nix fmt` leaves the tree clean (no formatting diff), so the pre-commit hook will accept
   the change.

The change is complete when all four hold. There is no user-facing runtime behavior yet;
that is delivered by later child plans that import these types.


## Idempotence and Recovery

Every step is additive and safe to repeat. Creating `Shibuya/Batch.hs` and
`test/Shibuya/BatchSpec.hs` are new files; re-running the writes overwrites them with the
same content. The cabal edits are idempotent list insertions — if `Shibuya.Batch` is
already listed, do not add it twice. If the build fails, the most likely causes are: a
missing deriving strategy (every `deriving` must say `stock`/`newtype`/`anyclass` because
`DerivingStrategies` is on), a missing `DataKinds` extension in the test suite (needed only
if you use the `@'[]` annotation style), or importing `NFData` — import it explicitly from
`Control.DeepSeq` as `Core/Types.hs` does. None of these steps touch existing modules'
behavior, so there is nothing to roll back beyond deleting the two new files and reverting
the three cabal/`Main.hs` insertions.


## Interfaces and Dependencies

Libraries/modules used and why: `containers` (`Data.Map.Strict`) for the per-message
decision map keyed by `MessageId` (`Ord`-keyed, no new instances); `base`
(`Data.List.NonEmpty`) for the non-empty batch the handler receives; `deepseq` for `NFData`
on the metadata types (consistent with the rest of `Core`); `effectful` for `Eff` in the
handler type; `text`/`time` for `Text`/`NominalDiffTime`. All are existing dependencies of
`shibuya-core`.

At the end of this plan the following must exist in module `Shibuya.Batch`
(`shibuya-core/src/Shibuya/Batch.hs`), exported:

```haskell
newtype BatchKey = BatchKey {unBatchKey :: Text}
defaultBatchKey :: BatchKey

data BatchTrigger = TriggerSize | TriggerTimeout | TriggerFlush

data BatchInfo = BatchInfo
  { batchKey :: !BatchKey, size :: !Int, trigger :: !BatchTrigger, partition :: !(Maybe Text) }

data BatchConfig es msg = BatchConfig
  { batchSize :: !Int
  , batchTimeout :: !NominalDiffTime
  , batchKey :: !(Envelope msg -> BatchKey)
  , tickInterval :: !(Maybe NominalDiffTime)
  }
defaultBatchConfig :: BatchConfig es msg

data BatchConfigError
  = BatchSizeNotPositive !Int | BatchTimeoutNotPositive !NominalDiffTime | TickIntervalNotPositive !NominalDiffTime
validateBatchConfig :: BatchConfig es msg -> Either BatchConfigError ()

type BatchHandler es msg = BatchInfo -> NonEmpty (Ingested es msg) -> Eff es BatchAck

data BatchAck = BatchAck { decisions :: !(Map MessageId AckDecision), fallback :: !AckDecision }
ackAllOk     :: BatchAck
ackAll       :: AckDecision -> BatchAck
ackExcept    :: [(MessageId, AckDecision)] -> BatchAck
withFallback :: AckDecision -> [(MessageId, AckDecision)] -> BatchAck
failMessages :: [(MessageId, DeadLetterReason)] -> BatchAck
```

Downstream consumers (do not implement here, but they depend on the above being exactly as
written): `docs/plans/17-batch-accumulation-engine.md` imports `BatchKey`, `BatchConfig`,
`BatchInfo`, `BatchTrigger`; `docs/plans/18-batch-execution-and-exactly-once-ack.md`
imports `BatchAck`, `BatchInfo`, `BatchHandler`, resolves one decision for every retained
message by iterating its own retained message list, and applies those decisions through
bounded idempotent finalization retries;
`docs/plans/19-batch-runner-and-app-integration.md` wraps `BatchConfigError` into the
top-level `AppError`. Keep the field names and constructor names stable; later plans quote
them verbatim.


## Revision Note

- 2026-07-01: Revised the `BatchAck` contract after MasterPlan architecture validation.
  `BatchAck` now normatively owns one-decision-per-retained-message resolution; EP-18 owns
  bounded, idempotent finalization retry and fail-loud behavior. This keeps the public type
  stable while making the runtime reliability contract explicit.
