---
id: 17
slug: batch-accumulation-engine
title: "Batch Accumulation Engine"
kind: exec-plan
created_at: 2026-07-01T15:34:31Z
intention: "intention_01kwf4q2bke2js9t0js53dwh5a"
master_plan: "docs/masterplans/3-first-class-batch-processing.md"
---

# Batch Accumulation Engine

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the second child of the MasterPlan at
`docs/masterplans/3-first-class-batch-processing.md` ("First-Class Batch Processing"). It
hard-depends on the first child, `docs/plans/16-batch-api-and-configuration-types.md`
("Batch API and Configuration Types", "EP-16"), which introduces the module
`Shibuya.Batch`. Everything from EP-16 that this plan relies on is quoted verbatim below,
so you do not need to open that file to follow this one.


## Purpose / Big Picture

Shibuya is a Haskell framework for consuming messages off a queue. Today it processes one
message at a time: an internal loop pulls one `Ingested es msg` value out of a bounded
in-memory mailbox and hands it to a handler. "Batching" means grouping many of those
messages together so a consumer can, for example, write 500 rows to a database in one
statement instead of 500 separate statements. Before batching can run a user's batch
handler, something has to *collect* the messages into groups and decide *when* a group is
finished. That collector is what this plan builds.

Concretely, after this plan there is a new module,
`shibuya-core/src/Shibuya/Runner/Batcher.hs` (module name `Shibuya.Runner.Batcher`, exposed
alongside the existing `Shibuya.Runner.Supervised`/`Master`/`Metrics`), that takes a stream
of individual messages and turns it into a stream of *batches*. A batch is
emitted the moment any one of three things happens: the group reaches a configured maximum
size (we call this the **size trigger**), a configured amount of time passes since the
group's first message arrived (the **timeout trigger**), or the input runs out / the
processor is shutting down and we flush whatever is left (the **flush trigger**). Messages
can optionally be split into independent groups by a **batch key** — a plain function from
a message's envelope to a `Text`-wrapped key — so, for instance, messages for different
tenants accumulate separately and time out separately.

This module does one job and one job only: **regroup messages**. It deliberately does
**not** run any user handler and does **not** acknowledge, retry, dead-letter, or
otherwise touch any message's acknowledgement handle. It is a pure stream transformer from
the outside: individual messages in, groups of the same messages out. That narrow scope is
what makes it possible to prove the single most important property of this plan, stated
next.

The reliability property this plan exists to guarantee, and which the tests enforce, is
**message conservation**: across an entire run, every message that goes in comes out in
**exactly one** emitted batch — never dropped, never duplicated — and within a single batch
key the messages keep their arrival order (first in, first out). You can see this working
by running the new test module, which feeds thousands of randomized message sequences
through the engine and checks that the multiset of message identifiers coming out is
identical to the multiset going in, with no losses and no duplicates.

You can also see it working end to end at the `IO` level: the test suite feeds a small real
stream through the running engine (with its background timeout thread) and observes batches
coming out grouped by size, and — with a deliberately slow stream — observes a batch coming
out on the timeout trigger before the stream has even finished.


## Progress

Milestone 1 — pure accumulation core (no threads, no timing):

- [x] Create `shibuya-core/src/Shibuya/Runner/Batcher.hs` with the pure types `Accum`, `BatcherState`, `ReadyBatch`, and `emptyBatcherState`. (2026-07-01)
- [x] Implement the pure step functions `stepArrival`, `stepTick`, `stepFlush` and the helper `emitAccum`. (2026-07-01)
- [x] Add `Shibuya.Runner.Batcher` to the library `exposed-modules` in `shibuya-core/shibuya-core.cabal`. (2026-07-01)
- [x] `cabal build shibuya-core` compiles the new module with no warnings. (2026-07-01)
- [x] Create `shibuya-core/test/Shibuya/Runner/BatcherSpec.hs` with the pure-core unit tests and the message-conservation / FIFO / size-trigger QuickCheck properties. (2026-07-01)
- [x] Add `Shibuya.Runner.BatcherSpec` to the test suite `other-modules` in the cabal file (it imports `Shibuya.Runner.Batcher` like any exposed module); wire `Shibuya.Runner.BatcherSpec` into `shibuya-core/test/Main.hs`. (2026-07-01)
- [x] `cabal test shibuya-core-test` green: the `Shibuya.Runner.Batcher` describe block passes, including the property tests. (2026-07-01)

Milestone 2 — `IO` wrapper with ticker, bounded output, and EOF flush:

- [x] Implement `runBatcher` (background consumer + ticker threads, bounded `TBQueue` output, EOF flush, `Stream.bracketIO` lifetime management). (2026-07-01)
- [x] Add the `IO`-level tests: finite-stream conservation, size-trigger shape, and slow-stream timeout observation. (2026-07-01)
- [x] `cabal test shibuya-core-test` green including the new `IO`-level examples (141 examples, 0 failures). (2026-07-01)
- [x] `nix fmt` clean (no formatting diff). (2026-07-01)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The bracket callback name `use` shadows `Control.Lens.use`, which `Shibuya.Prelude`
  re-exports (`module Control.Lens`). With `-Wall` this is a `-Wname-shadowing` warning that
  fails the "no warnings" acceptance criterion. Renamed the `where`-bound helper from `use`
  to `consume`. Evidence: `cabal build shibuya-core` initially reported
  `[GHC-63397] [-Wname-shadowing] This binding for 'use' shadows ... Control.Lens.Getter`;
  after the rename the library builds with `NO WARNINGS`.

- The test needed the empty effect stack's kind pinned. Writing top-level signatures like
  `runEvents :: BatchConfig '[] String -> ...` makes GHC kind-generalize the `'[]` to a fresh
  kind variable `[a]`, which then fails to unify with the `[Effect]`-kinded `'[]` that
  `mkIng :: Ingested '[] String` forces (via `AckHandle`'s `Eff es`). Fixed by importing
  `Effectful (Effect)` and defining `type E = ('[] :: [Effect])`, used in every test
  signature. EP-16's `BatchSpec` did not hit this because its `cfg :: BatchConfig '[] Int`
  never meets an `Ingested`, so nothing constrains the kind. EP-18/EP-20 specs that build
  `Ingested` values will need the same `type E = ('[] :: [Effect])` alias.

- `Ev` (the synthetic event type driving the pure-core property tests) needs a `Show`
  instance because `forAll genSchedule` returns it inside the generated tuple and QuickCheck
  requires `Show` to print counterexamples. Added `deriving stock (Show)`.


## Decision Log

Record every decision made while working on the plan.

- Decision: The accumulation logic is a **pure, deterministic core** — a state value plus
  three step functions (`stepArrival`, `stepTick`, `stepFlush`) that take the current time
  as an explicit argument and return the next state together with the batches to emit — and
  the concurrent `IO` machinery (`runBatcher`) is a thin wrapper around it.
  Rationale: This is the MasterPlan's decision #8 ("EP-17 MUST expose a PURE, deterministic
  accumulation core ... so accumulation correctness is property-tested WITHOUT
  threads/timing; the IO `runBatcher` is a thin wrapper. This is the key reliability
  lever."). Testing message conservation against a synthetic list of arrival/tick/flush
  events is fully deterministic and reproducible; testing it against real threads and wall
  clocks would be flaky and would not prove the invariant. See MasterPlan Decision Log,
  2026-07-01.
  Date: 2026-07-01

- Decision: A **single background "ticker" thread** scans all accumulators on a fixed
  interval and emits every group whose timeout has elapsed, rather than arming one timer per
  batch key.
  Rationale: This is the MasterPlan's decision #5 ("Single timeout TICKER thread scanning
  accumulators ... rather than one timer per key"). Flush latency is then bounded by the
  tick interval (default: the batch timeout itself), which satisfies the timeout contract,
  and one thread scanning a `Map` is far simpler to make correct than dynamically selecting
  over N per-key timers. See MasterPlan Decision Log, 2026-07-01.
  Date: 2026-07-01

- Decision: The "move a completed group out of the accumulator state and hand it
  downstream" operation is protected by a **single serialization mutex** (`Control.Concurrent.MVar`)
  shared by the consumer thread and the ticker thread; under that mutex the state
  transition runs (atomically over an `IORef`) and then each ready batch is pushed onto the
  bounded output queue one at a time.
  Rationale: The MasterPlan (decision #5/#8) calls for the removal of a group from the map
  and its hand-off downstream to be indivisible so that a size-emit and a timeout-emit for
  the *same* key can never both fire (no double-emit). The obvious implementation — do the
  map removal and all the queue writes inside one `STM` transaction — has a latent deadlock:
  a single timeout scan can produce several ready batches at once, and a bounded queue with
  capacity `C` cannot hold `N > C` items *within one transaction* (the transaction only
  commits when every write succeeds, but the downstream cannot drain mid-transaction), so it
  would retry forever. Serializing "state transition + hand-off" under one mutex instead
  gives exactly the same no-double-emit guarantee (it rests solely on the *state map*
  removal being indivisible), preserves the global emission order (the queue receives
  batches in the order the critical sections run), avoids the multi-item deadlock (items are
  enqueued one at a time, each its own blocking `STM` write), and still delivers
  backpressure (a full queue blocks the write, hence blocks the critical section, while the
  downstream drains without needing the mutex).
  Date: 2026-07-01

- Decision: The output of the engine is a **bounded** `Control.Concurrent.STM.TBQueue` of
  ready batches, and `runBatcher` takes an explicit output-capacity argument.
  Rationale: MasterPlan decision #5 and the framework's existing backpressure design require
  that a slow downstream (the batch-execution stage, EP-18) must eventually stall the
  upstream. A bounded queue does this: when it fills, the enqueue blocks, the consumer stops
  pulling from the input stream, the input mailbox fills, and the ingester blocks — exactly
  the same backpressure chain Shibuya already uses for per-message processing. An unbounded
  queue would silently buffer and defeat backpressure, so we make the bound explicit rather
  than hidden.
  Date: 2026-07-01

- Decision: `runBatcher` is written in plain `IO` (not in `Eff es`) even though its inputs
  are parameterized by an effect stack `es`.
  Rationale: The engine never *runs* any effect; it only shuffles `Ingested es msg` values
  around. The `es` and `msg` type parameters are phantom from the engine's point of view
  (they appear only inside the opaque `Ingested`, whose `ack :: AckHandle es` we never
  invoke). Keeping the engine in `IO`/`STM` matches the type of the stream it consumes — the
  existing production loop produces a `Streamly.Data.Stream.Stream IO (Ingested es msg)` (see
  `inboxToStream` in `shibuya-core/src/Shibuya/Runner/Supervised.hs`) — and avoids dragging
  the effect system into what is a mechanical regrouping.
  Date: 2026-07-01

- Decision: `Shibuya.Runner.Batcher` goes in the library `exposed-modules`, and the test
  suite imports it directly (`import Shibuya.Runner.Batcher`) like any exposed module.
  Rationale: The runner engine modules `Shibuya.Runner.Supervised`, `Shibuya.Runner.Master`,
  and `Shibuya.Runner.Metrics` are already exposed, so exposing `Shibuya.Runner.Batcher` is
  consistent with how this package treats its runner internals and keeps the accumulation
  engine visible for direct unit testing without any special build machinery. It also matches
  the sibling plan `docs/plans/18-batch-execution-and-exactly-once-ack.md`, which exposes its
  `Shibuya.Runner.BatchProcessor` module for the same reason (its in-package test imports it
  directly). This avoids the alternative of recompiling a hidden module into the test binary
  by adding the library `src` directory to the test's `hs-source-dirs`, which is fussier and
  inconsistent with the rest of the package.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Completed 2026-07-01. Both milestones landed as designed. `Shibuya.Runner.Batcher` is an
exposed library module providing the pure accumulation core (`Accum`, `BatcherState`,
`emptyBatcherState`, `ReadyBatch`, `stepArrival`, `stepTick`, `stepFlush`) plus the `IO`
engine `runBatcher` (background consumer + single timeout ticker, `MVar`-serialized
state-transition-then-hand-off, bounded `TBQueue` output for backpressure, EOF flush,
`Stream.bracketIO` lifetime management). The signatures match the frozen ones in the
MasterPlan's Surprises & Discoveries verbatim, so EP-18 can consume
`Stream IO (ReadyBatch es msg)` unchanged.

The core reliability property — message conservation — is established by
`prop_conservation` (emitted id-multiset equals arrival id-multiset over ~60 randomized
arrivals with random keys, random `batchSize`, and randomly interleaved ticks), backed by
`prop_fifo` (per-key cursor ordering) and `prop_sizeTrigger` (size batches are exactly
`batchSize`). The `IO`-level examples confirm the concurrent wrapper faithfully drives the
same core: finite-stream conservation across two keys, `[(TriggerSize,3),(TriggerSize,3),
(TriggerFlush,1)]` shape for a single key, and an observed `TriggerTimeout` batch on a
deliberately slow stream before it ends. Full suite: 141 examples, 0 failures; library
builds with no warnings; `nix fmt` clean.

No scope changes and no deviations from the plan's design. The only surprises were two
mechanical compile fixes (the `use`/`Control.Lens.use` shadow and the `[Effect]` kind
pinning) recorded above; neither affected the engine's semantics or the emitted-batch type.
Gap deferred by design: `runBatcher` runs in plain `IO` and does not itself propagate a
consumer-thread failure to its caller (it only sets `doneVar` in a `finally`); surfacing
that failure is EP-19's integration concern, exactly as the per-message loop polls its
ingester async.


## Context and Orientation

This section assumes no prior knowledge of the repository. Everything you need is here.

### The project and how to build it

Shibuya is a Cabal project. The library package is `shibuya-core`, rooted at
`shibuya-core/` with sources under `shibuya-core/src/Shibuya/` and tests under
`shibuya-core/test/`. The Cabal file is `shibuya-core/shibuya-core.cabal` (`cabal-version:
3.12`, `version: 0.7.1.0`). The default language is `GHC2024`. The library and the test
suite both turn on these extensions by default (from each component's `default-extensions`
stanza): `DeriveAnyClass`, `DerivingStrategies`, `DuplicateRecordFields`, `LambdaCase`,
`NoFieldSelectors`, `OverloadedLabels`, `OverloadedRecordDot`, `OverloadedStrings`,
`QuasiQuotes`.

Two of those extensions matter constantly in this plan. `NoFieldSelectors` means a record
field does **not** create a top-level accessor function; you read a field with dot syntax
(`value.fieldName`, enabled by `OverloadedRecordDot`). Record *construction*
(`Accum {messages = ..., count = ...}`) and record *update* (`acc {count = acc.count + 1}`)
still work normally — only the standalone getter functions are suppressed.
`DerivingStrategies` means every `deriving` clause must name its strategy (`stock`,
`newtype`, or `anyclass`).

All commands below run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`:

```bash
cabal build shibuya-core
cabal test shibuya-core-test
nix fmt
```

`nix fmt` runs the project formatter (Fourmolu via treefmt); the pre-commit hook rejects
unformatted code, so always run it before committing.

### The types this plan builds on (quoted so you need no other file)

From EP-16's module `Shibuya.Batch` (`shibuya-core/src/Shibuya/Batch.hs`) — these already
exist once EP-16 is done; import them, do not redefine them:

```haskell
-- | Groups messages into independent sub-batches within one processor.
newtype BatchKey = BatchKey {unBatchKey :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (IsString)
  deriving anyclass (NFData)

-- | The key used when a configuration does not distinguish sub-batches.
defaultBatchKey :: BatchKey     -- ^ BatchKey "default"

-- | Why the framework emitted a batch.
data BatchTrigger
  = TriggerSize      -- ^ Reached the configured batchSize.
  | TriggerTimeout   -- ^ batchTimeout elapsed since the batch's first message arrived.
  | TriggerFlush     -- ^ The processor is draining/shutting down; a partial batch flushed.
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Metadata about an emitted batch, passed to the BatchHandler alongside the messages.
data BatchInfo = BatchInfo
  { batchKey  :: !BatchKey          -- ^ The key all messages in this batch share.
  , size      :: !Int               -- ^ How many messages are in this batch (always >= 1).
  , trigger   :: !BatchTrigger      -- ^ Why this batch was emitted.
  , partition :: !(Maybe Text)      -- ^ Partition of the batch's first message, if any.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Configuration for a batching processor.
--   es is the effect stack and msg the payload type.
data BatchConfig es msg = BatchConfig
  { batchSize    :: !Int                     -- ^ Emit once the group holds this many. >= 1.
  , batchTimeout :: !NominalDiffTime         -- ^ Emit this long after the first message. > 0.
  , batchKey     :: !(Envelope msg -> BatchKey) -- ^ Compute a message's sub-batch key.
  , tickInterval :: !(Maybe NominalDiffTime) -- ^ Ticker granularity; Nothing => use batchTimeout.
  }

defaultBatchConfig :: BatchConfig es msg   -- ^ size 100, timeout 1s, const defaultBatchKey, tick Nothing
```

`NominalDiffTime` is the standard `time` package type measuring a span of seconds; a
`BatchConfig` whose `batchTimeout` is `1` means one second. `Envelope msg` and the message
types come from the core, quoted next.

From `shibuya-core/src/Shibuya/Core/Types.hs`:

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

`Cursor` has a constructor `CursorInt :: Int -> Cursor` (also `CursorText`); the tests use
`CursorInt` to stamp a sequence number onto each synthetic message.

From `shibuya-core/src/Shibuya/Core/Ingested.hs`:

```haskell
data Ingested es msg = Ingested
  { envelope :: !(Envelope msg)
  , ack      :: !(AckHandle es)
  , lease    :: !(Maybe (Lease es))
  }
```

From `shibuya-core/src/Shibuya/Core/AckHandle.hs`:

```haskell
newtype AckHandle es = AckHandle { finalize :: AckDecision -> Eff es () }
```

This plan never calls `finalize`. When the tests need to build an `Ingested` value they use
a no-op handle, `AckHandle (\_ -> pure ())`, and `lease = Nothing`. That is legitimate here
precisely because the engine does not acknowledge anything — acknowledgement is the job of
the *next* plan, `docs/plans/18-batch-execution-and-exactly-once-ack.md`.

`Shibuya.Prelude` (`shibuya-core/src/Shibuya/Prelude.hs`) re-exports `Generic`, `Natural`,
`Text`, `UTCTime`, `NominalDiffTime`, `getCurrentTime`, and all of `Control.Lens`. Import it
and you get those without extra imports. It does **not** re-export `NFData` or
`diffUTCTime`; import those explicitly where needed (from `Control.DeepSeq` and `Data.Time`
respectively), following the pattern in `Shibuya.Core.Types`.

### The seam this engine plugs into

The production loop lives in `shibuya-core/src/Shibuya/Runner/Supervised.hs`. Two functions
there define the exact shape of the stream this engine will eventually consume (EP-18/EP-19
do the wiring; this plan only needs to match the type):

`inboxToStream` turns the bounded in-memory mailbox (an NQE `Inbox`) into a
`Streamly.Data.Stream.Stream IO (Ingested es msg)` — a lazy, pull-based stream of individual
messages in `IO`. It ends when the source stream is exhausted and the mailbox is drained (or
on a halt). This is the type `runBatcher` accepts: `Stream IO (Ingested es msg)`.

`processUntilDrained` consumes that stream today with `Streamly.Data.Stream.fold Fold.drain`
(possibly wrapped in the parallel combinators for concurrency modes). It uses these
streamly modules, all of which are already dependencies:

```haskell
import Streamly.Data.Stream qualified as Stream
import Streamly.Data.Fold qualified as Fold
```

We reuse the same two modules plus `Streamly.Data.Stream (Stream)` for the bare type.

### How halt interacts with the batcher (no direct handling needed)

"Halt" is Shibuya's mechanism for stopping a processor mid-stream: a handler can return an
`AckHalt` decision, which records a `HaltReason` in a shared `IORef (Maybe HaltReason)`. In
the existing per-message loop, `inboxToStream` (in
`shibuya-core/src/Shibuya/Runner/Supervised.hs`) checks that `IORef` at the top of every
pull and **stops yielding** as soon as a halt is set — the stream simply ends. The batcher
sits downstream of exactly that stream: it consumes the `Stream IO (Ingested es msg)` that
`inboxToStream` produces. Therefore the batcher needs **no direct halt handling of its own**.
When a halt fires upstream, its input stream just ends, the batcher's consumer hits
end-of-input, and its normal EOF path runs `stepFlush`, which flushes every accumulated
partial group as a `TriggerFlush` batch onto the output queue.

State this consequence explicitly, because it is a deliberate reliability choice:
**messages that were already pulled into accumulators before the halt WILL be flushed and
processed** — this is drain-on-halt, and it mirrors the single-message path, which likewise
lets already-ingested / in-flight messages finish rather than discarding them. It also aligns
with the execution stage in `docs/plans/18-batch-execution-and-exactly-once-ack.md`, which
finalizes every batch it is handed (including a `TriggerFlush` batch produced during a halt)
and does not skip acknowledgement on halt. So no message that reached an accumulator is lost
when a halt occurs; it leaves in a flush batch and is acknowledged exactly once downstream.

### Terms defined

- **Accumulator (`Accum`)**: the in-progress state for one batch key — the messages seen so
  far for that key that have not yet been emitted, how many there are, when the first one
  arrived, and the partition of that first message.
- **Batcher state (`BatcherState`)**: a `Map` from `BatchKey` to `Accum`; the whole
  engine's memory of every in-progress group.
- **Ready batch (`ReadyBatch`)**: a finished group about to be handed downstream, namely a
  pair of the `BatchInfo` metadata and the non-empty list of its messages in arrival order.
- **Step function**: a pure function `BatcherState -> (BatcherState, [ReadyBatch])` (some
  take extra inputs like the current time or an arriving message). It advances the state and
  returns whatever finished as a result. Because it is pure and takes time as data, tests
  drive it deterministically with no threads and no clock.
- **Tick**: one scan by the background timeout thread; `stepTick` models it.
- **Flush**: emit everything still buffered (used at end-of-input and on shutdown);
  `stepFlush` models it.
- **Message conservation**: across a whole run, the multiset of message ids emitted equals
  the multiset of message ids that arrived — each message appears in exactly one emitted
  batch, no losses, no duplicates.


## Plan of Work

The work is two milestones. Milestone 1 delivers the pure core and proves message
conservation with property tests that use no threads and no timing at all. Milestone 2 wraps
the core in the concurrent `IO` engine (`runBatcher`) with the timeout ticker, the bounded
output, and the end-of-input flush, and tests it against real (small) streams. Milestone 1
is where the reliability invariant is actually established; Milestone 2 shows the wrapper
faithfully drives the same core.

### Milestone 1 — the pure accumulation core

Scope: create `shibuya-core/src/Shibuya/Runner/Batcher.hs` containing the pure data types
and the three step functions, register it as an exposed module (consistent with the already
exposed `Shibuya.Runner.Supervised`/`Master`/`Metrics`), and write the unit and property
tests. At the end of this milestone `cabal build shibuya-core` compiles the module
and `cabal test shibuya-core-test` passes a new `Shibuya.Runner.Batcher` describe block that
includes the message-conservation, per-key-FIFO, and size-trigger properties over thousands
of randomized event sequences. No threads are involved anywhere in this milestone.

Create the file with this module header. The export list names everything the tests and the
later `IO` wrapper need. The module is part of the library's exposed runner surface (like
`Shibuya.Runner.Supervised`), so the in-package test can import it directly:

```haskell
-- | Batch accumulation engine.
--
-- Groups a stream of individual 'Ingested' messages into batches by batch key.
-- A batch is emitted when it reaches the configured size, when its per-key
-- timeout elapses, or when the input ends / the processor drains. This module
-- only /regroups/ messages: it never runs a handler and never touches an
-- 'AckHandle'. Its correctness property is message conservation — every input
-- message appears in exactly one emitted batch, and per batch key arrival order
-- is preserved.
--
-- The accumulation logic is a pure, deterministic core (see 'stepArrival',
-- 'stepTick', 'stepFlush') that takes the current time as an argument, so it is
-- property-tested with no threads or wall-clock. 'runBatcher' is a thin IO
-- wrapper that drives the core from a background consumer and a single timeout
-- ticker, buffering results in a bounded queue for backpressure.
module Shibuya.Runner.Batcher
  ( -- * Pure accumulation core
    Accum (..),
    BatcherState (..),
    emptyBatcherState,
    ReadyBatch,
    stepArrival,
    stepTick,
    stepFlush,

    -- * IO engine
    runBatcher,
  )
where
```

The imports:

```haskell
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
  ( TBQueue,
    TVar,
    atomically,
    isEmptyTBQueue,
    newTBQueueIO,
    newTVarIO,
    readTVar,
    readTVarIO,
    retry,
    tryReadTBQueue,
    writeTBQueue,
    writeTVar,
  )
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Time (diffUTCTime)
import Shibuya.Batch (BatchConfig (..), BatchInfo (..), BatchKey, BatchTrigger (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Prelude
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import UnliftIO.Async (async, cancel)
```

Now the pure types. An `Accum` keeps its messages **reversed** (newest first) so that
appending a new arrival is an O(1) cons rather than an O(n) append; we reverse once at
emission time to restore arrival order:

```haskell
-- | In-progress state for one batch key.
data Accum es msg = Accum
  { -- | Messages accumulated so far, newest first (reversed arrival order).
    messages :: ![Ingested es msg],
    -- | How many messages are buffered (== length of 'messages'). Always >= 1.
    count :: !Int,
    -- | When the first message for this key arrived (drives the timeout).
    firstArrivalAt :: !UTCTime,
    -- | Partition of the first message, copied into the emitted 'BatchInfo'.
    partition0 :: !(Maybe Text)
  }

-- | The engine's memory: one 'Accum' per active batch key.
newtype BatcherState es msg = BatcherState
  { accums :: Map BatchKey (Accum es msg)
  }

-- | An empty state with no groups in progress.
emptyBatcherState :: BatcherState es msg
emptyBatcherState = BatcherState Map.empty

-- | A finished group ready to hand downstream: metadata plus its messages in
-- arrival order. This is the exact value the execution stage (EP-18) consumes.
type ReadyBatch es msg = (BatchInfo, NonEmpty (Ingested es msg))
```

A small helper turns a completed `Accum` into a `ReadyBatch`, reversing the messages back
to arrival order and stamping the `BatchInfo`. `NE.fromList` is safe here because an `Accum`
only ever exists with `count >= 1`, so `messages` is non-empty:

```haskell
-- | Build a ReadyBatch from a completed accumulator. Reverses the buffered
-- messages back into arrival order; safe because count >= 1.
emitAccum :: BatchKey -> BatchTrigger -> Accum es msg -> ReadyBatch es msg
emitAccum key trig acc =
  ( BatchInfo
      { batchKey = key,
        size = acc.count,
        trigger = trig,
        partition = acc.partition0
      },
    NE.fromList (reverse acc.messages)
  )
```

`stepArrival` handles one arriving message. It computes the key with the configured
`batchKey` function, appends the message to that key's accumulator (creating one if this is
the key's first message), and — if the accumulator has now reached `batchSize` — removes it
from the state and emits it with `TriggerSize`. Note the corner case `batchSize <= 1`: a
single message already satisfies the size, so a brand-new accumulator emits immediately:

```haskell
-- | Fold one arriving message into the state. Emits a size-triggered batch iff
-- the message fills its key's accumulator to batchSize.
stepArrival ::
  BatchConfig es msg ->
  UTCTime ->
  Ingested es msg ->
  BatcherState es msg ->
  (BatcherState es msg, [ReadyBatch es msg])
stepArrival cfg now ing (BatcherState accums) =
  let key = cfg.batchKey ing.envelope
   in case Map.lookup key accums of
        Nothing ->
          let acc =
                Accum
                  { messages = [ing],
                    count = 1,
                    firstArrivalAt = now,
                    partition0 = ing.envelope.partition
                  }
           in if cfg.batchSize <= 1
                then (BatcherState (Map.delete key accums), [emitAccum key TriggerSize acc])
                else (BatcherState (Map.insert key acc accums), [])
        Just acc ->
          let acc' = acc {messages = ing : acc.messages, count = acc.count + 1}
           in if acc'.count >= cfg.batchSize
                then (BatcherState (Map.delete key accums), [emitAccum key TriggerSize acc'])
                else (BatcherState (Map.insert key acc' accums), [])
```

`stepTick` models one scan by the ticker. It splits the accumulators into those whose
timeout has elapsed and those still waiting (`Map.partition` tests each value with the
predicate), emits the timed-out ones with `TriggerTimeout`, and keeps the rest. Emission
order is the ascending-key order of `Map.toList`, which is deterministic:

```haskell
-- | Emit every accumulator whose timeout has elapsed as of 'now'.
stepTick ::
  BatchConfig es msg ->
  UTCTime ->
  BatcherState es msg ->
  (BatcherState es msg, [ReadyBatch es msg])
stepTick cfg now (BatcherState accums) =
  let timedOut (acc :: Accum es msg) = diffUTCTime now acc.firstArrivalAt >= cfg.batchTimeout
      (ripe, keep) = Map.partition timedOut accums
      ready = [emitAccum k TriggerTimeout acc | (k, acc) <- Map.toList ripe]
   in (BatcherState keep, ready)
```

`stepFlush` empties the state, emitting every remaining accumulator with `TriggerFlush`.
It is used at end-of-input and (later, in EP-19) on graceful shutdown:

```haskell
-- | Emit all remaining accumulators (end-of-input / drain). Leaves the state empty.
stepFlush ::
  BatcherState es msg ->
  (BatcherState es msg, [ReadyBatch es msg])
stepFlush (BatcherState accums) =
  (emptyBatcherState, [emitAccum k TriggerFlush acc | (k, acc) <- Map.toList accums])
```

That is the entire pure core. Note the `ScopedTypeVariables`-style annotation
`(acc :: Accum es msg)` in `stepTick` needs the `es`/`msg` type variables to be in scope;
`GHC2024` includes `ScopedTypeVariables`, and the enclosing signature already binds `es` and
`msg`, so this compiles. If GHC complains, drop the annotation — it is only there for
readability and the predicate type-checks without it.

Register the module: in `shibuya-core/shibuya-core.cabal`, under the library's
`exposed-modules`, add `Shibuya.Runner.Batcher` (keep the list sorted: it goes between
`Shibuya.Runner.Master` and `Shibuya.Runner.Metrics`). This sits alongside the already
exposed `Shibuya.Runner.Master`, `Shibuya.Runner.Metrics`, and `Shibuya.Runner.Supervised`,
so the in-package test can import it like any other exposed module. No new `build-depends`
are needed: `containers`, `stm`, `time`, `base` (`Data.List.NonEmpty`, `Data.Maybe`,
`Control.Concurrent.MVar`), `streamly`/`streamly-core`, and `unliftio` are all already
dependencies.

Then create the test module (its full contents are in Concrete Steps), add its spec module to
the test suite `other-modules`, and wire the spec into the test driver. Build and test.

### Milestone 2 — the `IO` engine

Scope: add `runBatcher` to the same module and add `IO`-level tests. At the end,
`cabal test shibuya-core-test` also exercises the real concurrent engine on small finite
streams (conservation + size-trigger shape) and on a deliberately slow stream (observing a
timeout-triggered batch), and `nix fmt` is clean.

`runBatcher` launches two background threads that share one `MVar` mutex, one `IORef` of
`BatcherState`, and one bounded `TBQueue` of ready batches, and returns a streamly stream
that reads finished batches out of that queue. The mutex-protected helper does the "state
transition then hand off" critical section (see the Decision Log for why a mutex rather than
one big `STM` transaction):

```haskell
-- | Run one pure step under the shared mutex, then push each emitted batch onto
-- the bounded output queue (blocking when it is full, which is how backpressure
-- propagates). Serializing state-transition + hand-off keeps a size-emit and a
-- timeout-emit for the same key from both firing (no double-emit) and preserves
-- the order in which batches reach the queue.
emitStep ::
  MVar () ->
  IORef (BatcherState es msg) ->
  TBQueue (ReadyBatch es msg) ->
  (BatcherState es msg -> (BatcherState es msg, [ReadyBatch es msg])) ->
  IO ()
emitStep lock stateRef outQ step =
  withMVar lock $ \_ -> do
    ready <- atomicModifyIORef' stateRef step
    mapM_ (atomically . writeTBQueue outQ) ready
```

Convert a `NominalDiffTime` (seconds) into whole microseconds for `threadDelay`, clamped to
at least 1 so a misconfiguration cannot spin:

```haskell
nominalToMicros :: NominalDiffTime -> Int
nominalToMicros d = max 1 (round (realToFrac d * 1e6 :: Double))
```

Now `runBatcher`. It takes the output-queue capacity (a `Natural`, must be `>= 1`), the
`BatchConfig`, and the input stream, and returns the output stream. `Stream.bracketIO`
ties the two background threads' lifetimes to the consumption of the returned stream:
`bracketIO acquire release use` runs `acquire` when the stream starts being consumed,
`release` when it finishes or is abandoned, and streams whatever `use` produces in between.
Its type is `(MonadIO m, MonadCatch m) => IO b -> (b -> IO c) -> (b -> Stream m a) -> Stream
m a`, and `IO` satisfies both constraints:

```haskell
-- | Group a stream of individual messages into a stream of batches.
--
-- @outputCapacity@ bounds how many finished batches may sit un-consumed (>= 1);
-- when full, the engine stalls, propagating backpressure upstream. @cfg@ carries
-- the size, timeout, key function, and tick interval. The @es@/@msg@ parameters
-- are phantom to the engine (it never runs an effect or acks a message).
runBatcher ::
  Natural ->
  BatchConfig es msg ->
  Stream IO (Ingested es msg) ->
  Stream IO (ReadyBatch es msg)
runBatcher outputCapacity cfg input =
  Stream.bracketIO acquire release use
  where
    tickMicros = nominalToMicros (fromMaybe cfg.batchTimeout cfg.tickInterval)

    acquire = do
      lock <- newMVar ()
      stateRef <- newIORef emptyBatcherState
      outQ <- newTBQueueIO outputCapacity
      doneVar <- newTVarIO False

      let onArrival ing = do
            now <- getCurrentTime
            emitStep lock stateRef outQ (stepArrival cfg now ing)

          -- Consume the whole input, flush the remainder, then mark done.
          -- 'finally' guarantees doneVar is set even if the input stream throws,
          -- so the output stream below always terminates. Propagating a consumer
          -- failure to the caller is the integration plan's concern (EP-19), just
          -- as the per-message loop polls its ingester async.
          consumer =
            ( do
                Stream.fold Fold.drain (Stream.mapM onArrival input)
                emitStep lock stateRef outQ stepFlush
            )
              `finallyIO` atomically (writeTVar doneVar True)

          tickerLoop = do
            threadDelay tickMicros
            done <- readTVarIO doneVar
            if done
              then pure ()
              else do
                now <- getCurrentTime
                emitStep lock stateRef outQ (stepTick cfg now)
                tickerLoop

      consumerA <- async consumer
      tickerA <- async tickerLoop
      pure (outQ, doneVar, consumerA, tickerA)

    release (_outQ, _doneVar, consumerA, tickerA) = do
      cancel tickerA
      cancel consumerA

    use (outQ, doneVar, _consumerA, _tickerA) = drainQueue outQ doneVar
```

Use `UnliftIO.finally` for `finallyIO` — import it as `finally` from `UnliftIO` (already a
dependency) and either rename in the `where` (`finallyIO = UIO.finally`) or just call
`UIO.finally` directly. Whichever you choose, ensure exactly one import name is used; the
simplest is `import UnliftIO (finally)` and write ``... `finally` atomically (...)``. (The
listing above spells it `finallyIO` only to flag that it is the bracket-style finally, not
streamly's.)

The returned stream reads batches out of the bounded queue. It mirrors `inboxToStream`
exactly: try to take a batch; if none is available, check whether the consumer has signalled
done *and* the queue is empty (end of output) — otherwise `retry` (block) until a batch
appears or done flips:

```haskell
-- | Stream finished batches out of the bounded queue, ending when the consumer
-- has flushed everything (doneVar) and the queue has drained.
drainQueue ::
  TBQueue (ReadyBatch es msg) ->
  TVar Bool ->
  Stream IO (ReadyBatch es msg)
drainQueue outQ doneVar = Stream.unfoldrM step ()
  where
    step _ = atomically $ do
      mReady <- tryReadTBQueue outQ
      case mReady of
        Just rb -> pure (Just (rb, ()))
        Nothing -> do
          done <- readTVar doneVar
          qEmpty <- isEmptyTBQueue outQ
          if done && qEmpty
            then pure Nothing
            else retry
```

Why this is correct and backpressured. The consumer thread pulls from `input` one message
at a time; each pull runs `onArrival`, which under the mutex updates the state and, on a size
completion, writes one batch to `outQ`. If `outQ` is full, `writeTBQueue` blocks inside the
critical section, so the consumer stops pulling `input`, so upstream stalls — backpressure.
The ticker independently wakes every `tickMicros`, and under the *same* mutex runs
`stepTick` and writes any timed-out batches. Because both threads take the same mutex and
the state lives behind it, a key is removed from the `Map` by exactly one critical section;
whichever of "size fills it" or "timeout fires" runs first removes it, and the other then
finds nothing for that key — so no batch is ever emitted twice. When `input` is exhausted the
consumer runs `stepFlush` (emitting all leftovers with `TriggerFlush`) and sets `doneVar`;
`drainQueue` then delivers the last queued batches and ends. `Stream.bracketIO`'s `release`
cancels both threads (a no-op if they already finished).


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

### 1. Create the engine module (Milestone 1 portion)

Create `shibuya-core/src/Shibuya/Runner/Batcher.hs` with the module header, the imports, and
the pure types and step functions exactly as shown in Plan of Work (the `runBatcher`/`IO`
parts can be added now or in Milestone 2; if you add only the pure core first, temporarily
trim the export list and imports to what the pure core needs so the module compiles with
`-Wall` and no unused-import warnings).

### 2. Register the module as exposed

Edit `shibuya-core/shibuya-core.cabal`. In the library stanza's `exposed-modules`, add
`Shibuya.Runner.Batcher` (keep the list sorted — it goes between `Shibuya.Runner.Master` and
`Shibuya.Runner.Metrics`):

```text
    Shibuya.Runner.Master
    Shibuya.Runner.Batcher
    Shibuya.Runner.Metrics
    Shibuya.Runner.Supervised
```

(After sorting, the exposed runner block reads `Shibuya.Runner.Batcher`,
`Shibuya.Runner.Master`, `Shibuya.Runner.Metrics`, `Shibuya.Runner.Supervised`; the exact
alphabetical position is not load-bearing, but keep the file tidy.) Do **not** touch the
library `other-modules`.

### 3. Add the spec to the test suite

Still in `shibuya-core/shibuya-core.cabal`, in the `test-suite shibuya-core-test` stanza,
add `Shibuya.Runner.BatcherSpec` to the test suite's `other-modules` (leave
`hs-source-dirs: test` unchanged — the spec imports `Shibuya.Runner.Batcher` from the
`shibuya-core` dependency now that it is exposed):

```text
  other-modules:
    Shibuya.Core.AckSpec
    Shibuya.Core.RetrySpec
    Shibuya.Core.TypesSpec
    Shibuya.PolicySpec
    Shibuya.Runner.BatcherSpec
    Shibuya.Runner.SupervisedSpec
    Shibuya.RunnerSpec
    Shibuya.Telemetry.EffectSpec
    Shibuya.Telemetry.PropagationSpec
    Shibuya.Telemetry.SemanticSpec
```

The spec's `import Shibuya.Runner.Batcher` resolves from the exposed library, exactly like
`Shibuya.Runner.SupervisedSpec` imports `Shibuya.Runner.Supervised` today. No change to
`hs-source-dirs` is required.

### 4. Create the test module

Create `shibuya-core/test/Shibuya/Runner/BatcherSpec.hs`:

```haskell
module Shibuya.Runner.BatcherSpec (spec) where

import Data.List (sort)
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Shibuya.Batch
  ( BatchConfig (..),
    BatchInfo (..),
    BatchKey (..),
    BatchTrigger (..),
  )
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Runner.Batcher
  ( ReadyBatch,
    emptyBatcherState,
    runBatcher,
    stepArrival,
    stepFlush,
    stepTick,
  )
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Test.Hspec
import Test.QuickCheck

-- The engine is parameterized by an effect stack and payload; the pure core
-- treats them as phantom. We pick es = '[] and msg = String for the tests.

-- | Build a no-op-ack Ingested with a unique id, a sequence cursor, and a
-- partition equal to its batch key.
mkIng :: Int -> BatchKey -> Ingested '[] String
mkIng i (BatchKey k) =
  Ingested
    { envelope =
        Envelope
          { messageId = MessageId ("m-" <> tshow i),
            cursor = Just (CursorInt i),
            partition = Just k,
            enqueuedAt = Nothing,
            traceContext = Nothing,
            headers = Nothing,
            attempt = Nothing,
            attributes = mempty,
            payload = "payload-" <> show i
          },
      ack = AckHandle (\_ -> pure ()),
      lease = Nothing
    }
  where
    tshow = pack . show
    pack = \s -> foldr (const id) id s `seq` textFromString s
    textFromString = \s -> read (show s) -- placeholder; replaced below

-- Key the config on the message's partition (Just k -> BatchKey k).
partitionKeyConfig :: Int -> BatchConfig '[] String
partitionKeyConfig sz =
  BatchConfig
    { batchSize = sz,
      batchTimeout = 5,
      batchKey = \env -> BatchKey (fromMaybe "default" env.partition),
      tickInterval = Nothing
    }

baseTime :: UTCTime
baseTime = UTCTime (fromGregorian 2026 1 1) 0

-- | Run a synthetic event list through the pure core and collect emitted batches.
-- Events carry their own virtual time; a final flush drains the remainder so the
-- conservation property can compare the full input against the full output.
data Ev
  = EvArr Int BatchKey -- an arrival: unique id, key
  | EvTick -- a ticker scan

runEvents :: BatchConfig '[] String -> [(Double, Ev)] -> [ReadyBatch '[] String]
runEvents cfg = go emptyBatcherState
  where
    go st [] = snd (stepFlush st)
    go st ((secs, ev) : rest) =
      let now = addUTCTime (realToFrac secs) baseTime
          (st', out) = case ev of
            EvArr i k -> stepArrival cfg now (mkIng i k) st
            EvTick -> stepTick cfg now st
       in out ++ go st' rest

batchIds :: [ReadyBatch '[] String] -> [MessageId]
batchIds bs = [ing.envelope.messageId | (_, ne) <- bs, ing <- NE.toList ne]

batchCursors :: NE.NonEmpty (Ingested '[] String) -> [Int]
batchCursors ne = [c | ing <- NE.toList ne, Just (CursorInt c) <- [ing.envelope.cursor]]

spec :: Spec
spec = describe "Shibuya.Runner.Batcher" $ do
  describe "pure core (deterministic, no threads)" $ do
    it "emits a size-triggered batch of exactly batchSize" $ do
      let cfg = partitionKeyConfig 2
          evs = [(0, EvArr 0 "a"), (0, EvArr 1 "a")]
          out = runEvents cfg evs
      map (\(info, _) -> (info.trigger, info.size)) out
        `shouldBe` [(TriggerSize, 2)]
      batchIds out `shouldBe` [MessageId "m-0", MessageId "m-1"]

    it "keeps different keys in independent groups" $ do
      let cfg = partitionKeyConfig 2
          evs = [(0, EvArr 0 "a"), (0, EvArr 1 "b"), (0, EvArr 2 "a"), (0, EvArr 3 "b")]
          out = runEvents cfg evs
      -- Two size batches, one per key; both size 2.
      map (\(info, _) -> (info.batchKey, info.size, info.trigger)) out
        `shouldMatchList` [(BatchKey "a", 2, TriggerSize), (BatchKey "b", 2, TriggerSize)]

    it "flushes a partial group at end of input with TriggerFlush" $ do
      let cfg = partitionKeyConfig 10
          evs = [(0, EvArr 0 "a"), (0, EvArr 1 "a")]
          out = runEvents cfg evs
      map (\(info, _) -> (info.trigger, info.size)) out `shouldBe` [(TriggerFlush, 2)]

    it "emits a timeout batch once batchTimeout has elapsed" $ do
      let cfg = partitionKeyConfig 10 -- large size so only timeout fires
          -- first message at t=0, tick at t=5 (== batchTimeout) fires it
          evs = [(0, EvArr 0 "a"), (5, EvTick)]
          out = runEvents cfg evs
      map (\(info, _) -> (info.trigger, info.size)) out `shouldBe` [(TriggerTimeout, 1)]

    it "does not emit on a tick before the timeout has elapsed" $ do
      let cfg = partitionKeyConfig 10
          evs = [(0, EvArr 0 "a"), (4, EvTick)] -- 4s < 5s timeout
          -- only the final flush emits
          out = runEvents cfg evs
      map (\(info, _) -> info.trigger) out `shouldBe` [TriggerFlush]

    it "copies the first message's partition into BatchInfo" $ do
      let cfg = partitionKeyConfig 2
          out = runEvents cfg [(0, EvArr 0 "tenant-7"), (0, EvArr 1 "tenant-7")]
      map (\(info, _) -> info.partition) out `shouldBe` [Just "tenant-7"]

  describe "message conservation (property)" $ do
    it "every input message appears in exactly one emitted batch" $
      property prop_conservation

    it "within each emitted batch, cursors are strictly ascending (per-key FIFO)" $
      property prop_fifo

    it "every TriggerSize batch has size == batchSize" $
      property prop_sizeTrigger

  describe "IO engine runBatcher" $ do
    it "conserves messages over a finite stream" $ do
      let cfg = partitionKeyConfig 3
          ings = [mkIng i (BatchKey (if even i then "a" else "b")) | i <- [0 .. 19]]
      out <- Stream.fold Fold.toList (runBatcher 8 cfg (Stream.fromList ings))
      sort (batchIds out) `shouldBe` sort [ing.envelope.messageId | ing <- ings]

    it "emits full size-3 batches for a single key" $ do
      let cfg = partitionKeyConfig 3
          ings = [mkIng i "a" | i <- [0 .. 6]] -- 7 messages
      out <- Stream.fold Fold.toList (runBatcher 8 cfg (Stream.fromList ings))
      map (\(info, _) -> (info.trigger, info.size)) out
        `shouldBe` [(TriggerSize, 3), (TriggerSize, 3), (TriggerFlush, 1)]

    it "emits a timeout batch on a slow stream before it ends" $ do
      -- A stream that yields message 0, then stalls > batchTimeout before 1.
      let cfg =
            (partitionKeyConfig 100) -- big size => only timeout/flush can fire
              { batchTimeout = 0.1, -- 100 ms
                tickInterval = Just 0.02 -- scan every 20 ms
              }
          slow =
            Stream.unfoldrM
              ( \n ->
                  if n >= 2
                    then pure Nothing
                    else do
                      -- delay before the SECOND message so message 0 times out
                      if n == 1 then threadDelayIO 250000 else pure ()
                      pure (Just (mkIng n "a", n + 1))
              )
              (0 :: Int)
      out <- Stream.fold Fold.toList (runBatcher 8 cfg slow)
      any (\(info, _) -> info.trigger == TriggerTimeout) out `shouldBe` True
      sort (batchIds out) `shouldBe` [MessageId "m-0", MessageId "m-1"]

-- QuickCheck generators and properties -------------------------------------

-- | A random schedule: arrivals with unique ids and random keys, interspersed
-- with ticks, plus a random batchSize. Time advances 1s per event; batchTimeout
-- is fixed at 5s in partitionKeyConfig, so ticks can fire real timeout batches.
genSchedule :: Gen (Int, [(Double, Ev)])
genSchedule = do
  sz <- choose (1, 8)
  n <- choose (0, 60)
  keys <- vectorOf n (elements ["a", "b", "c"])
  let arrivals = zipWith EvArr [0 ..] (map BatchKey keys)
  -- Interleave ticks randomly.
  evs <- interleaveTicks arrivals
  let timed = zip (map fromIntegral [0 :: Int ..]) evs
  pure (sz, timed)
  where
    interleaveTicks [] = pure []
    interleaveTicks (a : as) = do
      addTick <- arbitrary
      rest <- interleaveTicks as
      pure (if addTick then a : EvTick : rest else a : rest)

arrivalIds :: [(Double, Ev)] -> [MessageId]
arrivalIds evs = [MessageId ("m-" <> tshow i) | (_, EvArr i _) <- evs]
  where
    tshow = read . show :: Int -> String -- see note; use a real Text/Show conversion

prop_conservation :: Property
prop_conservation = forAll genSchedule $ \(sz, evs) ->
  let cfg = partitionKeyConfig sz
      out = runEvents cfg evs
   in sort (batchIds out) === sort (arrivalIds evs)

prop_fifo :: Property
prop_fifo = forAll genSchedule $ \(sz, evs) ->
  let cfg = partitionKeyConfig sz
      out = runEvents cfg evs
   in conjoin [strictlyAscending (batchCursors ne) | (_, ne) <- out]
  where
    strictlyAscending xs = xs === sortUniqueAscending xs
    sortUniqueAscending = sort

prop_sizeTrigger :: Property
prop_sizeTrigger = forAll genSchedule $ \(sz, evs) ->
  let cfg = partitionKeyConfig sz
      out = runEvents cfg evs
   in conjoin
        [ info.size === sz
        | (info, _) <- out,
          info.trigger == TriggerSize
        ]
```

Two placeholders in that listing exist only to keep it self-contained without pinning exact
`Text` helper spellings; replace them with the obvious real code when you write the file:

- In `mkIng`, the `tshow`/`pack`/`textFromString` cruft is a stand-in — just write
  `MessageId (Text.pack ("m-" <> show i))` with `import Data.Text qualified as Text` and
  `import Data.Text (Text)`, matching how `SupervisedSpec` builds ids
  (`MessageId $ "msg-" <> Text.pack (show i)`).
- In `arrivalIds` / `prop_*`, use the same `Text.pack . show` for the id string. The
  conservation property compares the *set* of ids, so id spelling only has to match between
  `mkIng` and `arrivalIds`.
- `threadDelayIO` in the slow-stream test is `Control.Concurrent.threadDelay` (import it, or
  `UnliftIO.Concurrent.threadDelay`).

The intent of the three properties is what matters and must be preserved: `prop_conservation`
asserts the emitted id-multiset equals the arrival id-multiset (no loss, no duplication);
`prop_fifo` asserts each emitted batch's cursors are strictly ascending (per-key arrival
order preserved — cursors are the global arrival index, and one key's accumulator only ever
*appends*, so its cursors stay ordered); `prop_sizeTrigger` asserts a `TriggerSize` batch
always has exactly `batchSize` messages.

### 5. Wire the spec into the test driver

Edit `shibuya-core/test/Main.hs`. Add the qualified import and invoke the spec, following
the file's existing style (some entries wrap with `describe`, some call a spec that already
opens its own `describe` — `BatcherSpec.spec` already opens `describe
"Shibuya.Runner.Batcher"`, so call it bare, like `Shibuya.Runner.SupervisedSpec.spec`):

```haskell
import Shibuya.Runner.BatcherSpec qualified
...
main = hspec $ do
  ...
  Shibuya.Runner.BatcherSpec.spec
  Shibuya.Runner.SupervisedSpec.spec
  ...
```

### 6. Build and test

```bash
cabal build shibuya-core
cabal test shibuya-core-test
```

Expected: the build succeeds with no warnings, and the test output includes the new block
with every example and property passing, for example:

```text
Shibuya.Runner.Batcher
  pure core (deterministic, no threads)
    emits a size-triggered batch of exactly batchSize
    keeps different keys in independent groups
    flushes a partial group at end of input with TriggerFlush
    emits a timeout batch once batchTimeout has elapsed
    does not emit on a tick before the timeout has elapsed
    copies the first message's partition into BatchInfo
  message conservation (property)
    every input message appears in exactly one emitted batch
      +++ OK, passed 100 tests.
    within each emitted batch, cursors are strictly ascending (per-key FIFO)
      +++ OK, passed 100 tests.
    every TriggerSize batch has size == batchSize
      +++ OK, passed 100 tests.
  IO engine runBatcher
    conserves messages over a finite stream
    emits full size-3 batches for a single key
    emits a timeout batch on a slow stream before it ends
```

### 7. Format

```bash
nix fmt
```

Expected: no diff (or it reformats the two new files; re-`git add` them if so). The
pre-commit hook then accepts the change.


## Validation and Acceptance

Acceptance is behavioral and testable.

1. `cabal build shibuya-core` compiles `Shibuya.Runner.Batcher` with `-Wall` and no
   warnings. This proves the pure core and the `IO` engine type-check against the real EP-16
   types and the real streamly/stm APIs.

2. `cabal test shibuya-core-test` runs the `Shibuya.Runner.Batcher` block green. The
   deterministic unit tests prove each trigger fires at the right moment (size at exactly
   `batchSize`, timeout at exactly `batchTimeout`, flush at end of input) and that keys stay
   independent and partitions propagate. The property tests prove the plan's core invariant:

   - **Message conservation** — `prop_conservation` feeds up to sixty arrivals with random
     keys and a random `batchSize`, interleaved with random ticks, and asserts the multiset
     of emitted message ids equals the multiset of arrival ids. Passing means no message is
     ever lost and none is ever duplicated across all three triggers.
   - **Per-key FIFO** — `prop_fifo` asserts every emitted batch's cursors are strictly
     ascending, i.e. within a key messages keep arrival order.
   - **Size-trigger exactness** — `prop_sizeTrigger` asserts every size-triggered batch has
     exactly `batchSize` messages.

3. The `IO`-level examples prove the wrapper faithfully drives the same core through real
   threads: a finite stream of twenty messages across two keys comes out with its full
   id-set intact (conservation through the concurrent path); a single-key stream of seven
   with `batchSize 3` comes out as `[(TriggerSize,3),(TriggerSize,3),(TriggerFlush,1)]`
   (shape and ordering through the queue); and a deliberately slow stream produces at least
   one `TriggerTimeout` batch *before* the stream ends, demonstrating the ticker actually
   flushes on time.

To see a property fail deliberately (a good sanity check that the test really tests
something), temporarily change `emitAccum` to drop the last message
(`NE.fromList (drop 1 (reverse acc.messages))`) and re-run `cabal test shibuya-core-test`:
`prop_conservation` should fail with a shrunk counterexample showing an id present on input
but absent on output. Revert the change afterward.

The change is complete when items 1–3 hold and `nix fmt` leaves the tree clean.


## Idempotence and Recovery

Every step is additive and safe to repeat. `shibuya-core/src/Shibuya/Runner/Batcher.hs` and
`shibuya-core/test/Shibuya/Runner/BatcherSpec.hs` are new files; re-writing them overwrites
with identical content. The two cabal edits (adding `Shibuya.Runner.Batcher` to the library
`exposed-modules`; adding `Shibuya.Runner.BatcherSpec` to the test `other-modules`) and the
`Main.hs` edit are idempotent list insertions — if an entry is already present, do not add it
twice. Nothing here changes the behavior of any existing module, so rollback is just deleting
the two new files and reverting the cabal and `Main.hs` insertions.

Likely failure modes and fixes:

- Missing deriving strategy: not applicable here (the engine types derive nothing), but if
  you add a `deriving`, name its strategy (`DerivingStrategies` is on).
- "Could not find module `Shibuya.Runner.Batcher`" when building the test suite: you forgot
  to add `Shibuya.Runner.Batcher` to the library `exposed-modules` (step 2). The spec imports
  it from the `shibuya-core` dependency, so it must be exposed there; do not add the library
  `src` directory to the test `hs-source-dirs`.
- `-Wall` unused-import warnings while you have only the pure core: trim the imports to what
  the pure core uses, then restore the full import list when you add `runBatcher` in
  Milestone 2.
- Property test hangs: it should not — the pure core has no threads. If the `IO` slow-stream
  test hangs, check that `doneVar` is set in a `finally` around the consumer so `drainQueue`
  can terminate, and that `tickInterval` is positive (a zero interval is clamped to 1 µs by
  `nominalToMicros`, but a `batchTimeout`/`tickInterval` of `0` is rejected upstream by
  `validateBatchConfig` in the wired system).


## Interfaces and Dependencies

Libraries used and why: `containers` (`Data.Map.Strict`) for the per-key accumulator map,
keyed by the `Ord`-deriving `BatchKey` (no new instances needed); `base`
(`Data.List.NonEmpty` for the non-empty emitted batch, `Data.Maybe.fromMaybe` for the tick
interval default, `Control.Concurrent`/`Control.Concurrent.MVar` for the ticker delay and
the serialization mutex); `stm` (`Control.Concurrent.STM.TBQueue`/`TVar`) for the bounded,
blocking output queue and the done flag; `time` (`Data.Time.diffUTCTime`) for the timeout
comparison; `streamly`/`streamly-core` (`Streamly.Data.Stream`, `Streamly.Data.Fold`) for
the stream type, `bracketIO`, `unfoldrM`, `mapM`, and `fold`; `unliftio`
(`UnliftIO.Async.async`/`cancel`, `UnliftIO.finally`) for the background threads. All are
already dependencies of `shibuya-core`.

At the end of Milestone 1 the following must exist in the exposed module
`Shibuya.Runner.Batcher` (`shibuya-core/src/Shibuya/Runner/Batcher.hs`), exported:

```haskell
data Accum es msg = Accum
  { messages :: ![Ingested es msg]
  , count :: !Int
  , firstArrivalAt :: !UTCTime
  , partition0 :: !(Maybe Text)
  }

newtype BatcherState es msg = BatcherState { accums :: Map BatchKey (Accum es msg) }
emptyBatcherState :: BatcherState es msg

type ReadyBatch es msg = (BatchInfo, NonEmpty (Ingested es msg))

stepArrival :: BatchConfig es msg -> UTCTime -> Ingested es msg -> BatcherState es msg
            -> (BatcherState es msg, [ReadyBatch es msg])
stepTick    :: BatchConfig es msg -> UTCTime -> BatcherState es msg
            -> (BatcherState es msg, [ReadyBatch es msg])
stepFlush   :: BatcherState es msg -> (BatcherState es msg, [ReadyBatch es msg])
```

At the end of Milestone 2 the following also exists, exported:

```haskell
runBatcher :: Natural -> BatchConfig es msg
           -> Streamly.Data.Stream.Stream IO (Ingested es msg)
           -> Streamly.Data.Stream.Stream IO (ReadyBatch es msg)
```

Downstream consumer (do not implement here): the batch-execution stage,
`docs/plans/18-batch-execution-and-exactly-once-ack.md`, consumes the
`Stream IO (ReadyBatch es msg)` that `runBatcher` produces, runs the user's batch handler
over each `NonEmpty (Ingested es msg)`, and finalizes each message's `AckHandle` exactly
once. That plan treats `ReadyBatch` as read-only and relies on this plan's guarantee that
every source message appears in exactly one `ReadyBatch`. Keep the `ReadyBatch` type alias
and the three step-function signatures stable; EP-18 quotes them. If a future revision needs
to enrich `ReadyBatch` (for example a batch sequence number for metrics), update this section
and the MasterPlan's "emitted-batch type" Integration Point, and notify EP-18.
