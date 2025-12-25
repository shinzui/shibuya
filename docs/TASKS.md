# Shibuya Implementation Tasks

This document breaks down the Shibuya framework into atomic, testable tasks. Each task is designed to be completed independently with its own tests.

## Progress Summary

| Phase | Status | Tests |
|-------|--------|-------|
| Phase 1: Core Types | ✅ Complete | 9 tests |
| Phase 2: Effectful Types | ✅ Complete | - |
| Phase 3: Handler Type | ✅ Complete | - |
| Phase 4: Policy Types | ✅ Complete | 12 tests |
| Phase 5: Adapter Interface | ✅ Complete | - |
| Phase 6: Runner Configuration | ✅ Complete | - |
| Phase 7: Stream Utilities | ✅ Complete | - |
| Phase 8: Core Runner Logic | ✅ Complete | 3 tests |
| Phase 8.5: Master & Supervision | ✅ Complete | 5 tests |
| Phase 9: Application Entry Point | ✅ Complete | 3 tests |
| Phase 10: Re-export Module | ✅ Complete | - |
| Phase 11: Postgres Adapter | ⏳ Pending | - |
| Phase 12: Kafka Adapter | ⏳ Pending | - |

**Total: 42 tests passing**

## Phase 1: Core Types (No Dependencies) ✅

These are pure data types with no effects or external dependencies.

### Task 1.1: MessageId Type ✅
**Module:** `Shibuya.Core.Types`
**File:** `src/Shibuya/Core/Types.hs`

```haskell
newtype MessageId = MessageId { unMessageId :: Text }
  deriving stock (Eq, Ord, Show)
  deriving newtype (IsString)
```

**Tests:**
- Eq instance works correctly
- Ord instance for Map keys
- IsString for OverloadedStrings convenience
- Show roundtrips

**Definition of Done:** `cabal test` passes with MessageId tests

---

### Task 1.2: Cursor Type
**Module:** `Shibuya.Core.Types`
**File:** `src/Shibuya/Core/Types.hs`

```haskell
data Cursor
  = CursorInt !Int
  | CursorText !Text
  deriving stock (Eq, Ord, Show)
```

**Tests:**
- Eq works for both constructors
- Ord: CursorInt values compare numerically, CursorText lexicographically
- Pattern matching exhaustive

**Definition of Done:** `cabal test` passes with Cursor tests

---

### Task 1.3: Envelope Type
**Module:** `Shibuya.Core.Types`
**File:** `src/Shibuya/Core/Types.hs`

```haskell
data Envelope msg = Envelope
  { envId         :: !MessageId
  , envCursor     :: !(Maybe Cursor)
  , envPartition  :: !(Maybe Text)
  , envEnqueuedAt :: !(Maybe UTCTime)
  , envPayload    :: !msg
  }
  deriving stock (Show, Functor)
```

**Tests:**
- Functor law: `fmap id == id`
- Functor law: `fmap (f . g) == fmap f . fmap g`
- Field accessors work
- Show instance

**Definition of Done:** `cabal test` passes with Envelope tests

---

### Task 1.4: Ack Decision Types
**Module:** `Shibuya.Core.Ack`
**File:** `src/Shibuya/Core/Ack.hs`

```haskell
newtype RetryDelay = RetryDelay { unRetryDelay :: NominalDiffTime }
  deriving stock (Eq, Show)

data DeadLetterReason
  = PoisonPill !Text
  | InvalidPayload !Text
  | MaxRetriesExceeded
  deriving stock (Eq, Show)

data HaltReason
  = HaltOrderedStream !Text
  | HaltFatal !Text
  deriving stock (Eq, Show)

data AckDecision
  = AckOk
  | AckRetry !RetryDelay
  | AckDeadLetter !DeadLetterReason
  | AckHalt !HaltReason
  deriving stock (Eq, Show)
```

**Tests:**
- All constructors distinguishable
- Pattern matching coverage
- RetryDelay from NominalDiffTime

**Definition of Done:** `cabal test` passes with Ack tests

---

## Phase 2: Effectful Types

Types that involve the `Eff` monad but no complex behavior.

### Task 2.1: Lease Type
**Module:** `Shibuya.Core.Lease`
**File:** `src/Shibuya/Core/Lease.hs`

```haskell
data Lease es = Lease
  { leaseId     :: !Text
  , leaseExtend :: NominalDiffTime -> Eff es ()
  }
```

**Tests:**
- Can construct with mock extend function
- leaseId accessor works

**Definition of Done:** `cabal test` passes with Lease tests

---

### Task 2.2: AckHandle Type
**Module:** `Shibuya.Core.AckHandle`
**File:** `src/Shibuya/Core/AckHandle.hs`

```haskell
newtype AckHandle es = AckHandle
  { finalize :: AckDecision -> Eff es ()
  }
```

**Tests:**
- Can construct with mock finalize
- finalize can be called with each AckDecision variant

**Definition of Done:** `cabal test` passes with AckHandle tests

---

### Task 2.3: Ingested Type
**Module:** `Shibuya.Core.Ingested`
**File:** `src/Shibuya/Core/Ingested.hs`

```haskell
data Ingested es msg = Ingested
  { envelope :: !(Envelope msg)
  , ack      :: !(AckHandle es)
  , lease    :: !(Maybe (Lease es))
  }
```

**Tests:**
- Can construct with all fields
- Can construct without lease (Nothing)
- Field accessors work

**Definition of Done:** `cabal test` passes with Ingested tests

---

## Phase 3: Handler Type

### Task 3.1: Handler Type Alias
**Module:** `Shibuya.Handler`
**File:** `src/Shibuya/Handler.hs`

```haskell
type Handler es msg = Ingested es msg -> Eff es AckDecision
```

**Tests:**
- Can define a handler that returns AckOk
- Can define a handler that returns AckRetry
- Can define a handler that inspects envelope

**Definition of Done:** `cabal test` passes with Handler tests

---

## Phase 4: Policy Types

### Task 4.1: Ordering Type
**Module:** `Shibuya.Policy`
**File:** `src/Shibuya/Policy.hs`

```haskell
data Ordering
  = StrictInOrder
  | PartitionedInOrder
  | Unordered
  deriving stock (Eq, Show)
```

**Tests:**
- All constructors distinguishable
- Eq works

**Definition of Done:** `cabal test` passes

---

### Task 4.2: Concurrency Type
**Module:** `Shibuya.Policy`
**File:** `src/Shibuya/Policy.hs`

```haskell
data Concurrency
  = Serial
  | Ahead !Int
  | Async !Int
  deriving stock (Eq, Show)
```

**Tests:**
- All constructors distinguishable
- Ahead/Async preserve Int value

**Definition of Done:** `cabal test` passes

---

### Task 4.3: Policy Validation
**Module:** `Shibuya.Policy`
**File:** `src/Shibuya/Policy.hs`

```haskell
validatePolicy :: Ordering -> Concurrency -> Either Text ()
```

**Tests:**
- `StrictInOrder + Serial` -> Right ()
- `StrictInOrder + Ahead n` -> Left error
- `StrictInOrder + Async n` -> Left error
- `PartitionedInOrder + Async n` -> Right ()
- `Unordered + Async n` -> Right ()

**Definition of Done:** `cabal test` passes with all validation cases

---

## Phase 5: Adapter Interface

### Task 5.1: Adapter Type
**Module:** `Shibuya.Adapter`
**File:** `src/Shibuya/Adapter.hs`

```haskell
data Adapter es msg = Adapter
  { adapterName :: !Text
  , source      :: Stream (Eff es) (Ingested es msg)
  , shutdown    :: Eff es ()
  }
```

**Tests:**
- Can construct with mock stream source
- adapterName accessor works
- shutdown can be called

**Definition of Done:** `cabal test` passes

---

### Task 5.2: Mock Adapter for Testing
**Module:** `Shibuya.Adapter.Mock`
**File:** `src/Shibuya/Adapter/Mock.hs`

```haskell
mockAdapter :: [msg] -> Adapter es msg
listAdapter :: [Ingested es msg] -> Adapter es msg
```

**Tests:**
- mockAdapter produces N messages then completes
- listAdapter produces exact messages provided
- shutdown is idempotent

**Definition of Done:** `cabal test` passes with mock adapter tests

---

## Phase 6: Runner Configuration

### Task 6.1: RunnerConfig Type
**Module:** `Shibuya.Runner`
**File:** `src/Shibuya/Runner.hs`

```haskell
data RunnerConfig es msg = RunnerConfig
  { adapter     :: !(Adapter es msg)
  , handler     :: !(Handler es msg)
  , ordering    :: !Ordering
  , concurrency :: !Concurrency
  , inboxSize   :: !Int
  }

defaultRunnerConfig :: Adapter es msg -> Handler es msg -> RunnerConfig es msg
```

**Tests:**
- defaultRunnerConfig sets Unordered, Serial, inboxSize 100
- All fields accessible

**Definition of Done:** `cabal test` passes

---

## Phase 7: Stream Utilities

### Task 7.1: Polling Stream
**Module:** `Shibuya.Stream`
**File:** `src/Shibuya/Stream.hs`

```haskell
pollingStream
  :: (IOE :> es)
  => Int                    -- ^ Poll interval (microseconds)
  -> Eff es (Maybe msg)     -- ^ Poll action
  -> Stream (Eff es) msg
```

**Tests:**
- Produces messages when poll returns Just
- Waits interval when poll returns Nothing
- Stream completes when poll always returns Nothing (with take)

**Definition of Done:** `cabal test` passes

---

### Task 7.2: Batch Stream
**Module:** `Shibuya.Stream`
**File:** `src/Shibuya/Stream.hs`

```haskell
batchStream :: Int -> Stream m msg -> Stream m [msg]
```

**Tests:**
- 10 messages with batch size 3 -> [[1,2,3], [4,5,6], [7,8,9], [10]]
- Empty stream -> empty stream
- Batch size 1 -> singleton lists

**Definition of Done:** `cabal test` passes

---

### Task 7.3: Filter Stream
**Module:** `Shibuya.Stream`
**File:** `src/Shibuya/Stream.hs`

```haskell
filterStream :: (msg -> Bool) -> Stream m msg -> Stream m msg
```

**Tests:**
- Filters out messages not matching predicate
- Preserves order
- Identity with `const True`

**Definition of Done:** `cabal test` passes

---

## Phase 8: Core Runner Logic

### Task 8.1: Ingester (Stream -> Inbox)
**Module:** `Shibuya.Runner.Ingester`
**File:** `src/Shibuya/Runner/Ingester.hs`

```haskell
runIngester
  :: (IOE :> es)
  => Stream (Eff es) (Ingested es msg)
  -> BoundedInbox (Ingested es msg)
  -> Eff es ()
```

**Tests:**
- Messages from stream appear in inbox
- Backpressure: stream blocks when inbox full
- Ingester completes when stream completes

**Definition of Done:** `cabal test` passes with ingester tests

---

### Task 8.2: Processor (Inbox -> Handler -> Ack)
**Module:** `Shibuya.Runner.Processor`
**File:** `src/Shibuya/Runner/Processor.hs`

```haskell
runProcessor
  :: (IOE :> es)
  => Handler es msg
  -> BoundedInbox (Ingested es msg)
  -> Eff es ()
```

**Tests:**
- Handler called for each message
- AckHandle.finalize called with handler's decision
- Processor continues after AckOk
- Processor handles AckRetry (logs, continues)

**Definition of Done:** `cabal test` passes with processor tests

---

### Task 8.3: Serial Runner
**Module:** `Shibuya.Runner.Serial`
**File:** `src/Shibuya/Runner/Serial.hs`

```haskell
runSerial
  :: (IOE :> es)
  => RunnerConfig es msg
  -> Eff es ()
```

**Tests:**
- Processes messages in order
- Calls handler for each message
- Calls finalize for each message
- Completes when adapter stream completes

**Definition of Done:** `cabal test` passes with serial runner tests

---

## Phase 8.5: Master & Supervision (NQE Integration)

### Task 8.5.1: Metrics Types ✅
**Module:** `Shibuya.Runner.Metrics`
**File:** `src/Shibuya/Runner/Metrics.hs`

```haskell
data ProcessorState = Idle | Processing !Int !UTCTime | Failed !Text !UTCTime | Stopped
data StreamStats = StreamStats { ssReceived, ssDropped, ssProcessed, ssFailed :: !Int }
data ProcessorMetrics = ProcessorMetrics { pmState, pmStats, pmStartedAt }
type MetricsMap = Map ProcessorId ProcessorMetrics
```

**Tests:**
- ProcessorState distinguishable
- StreamStats counters increment correctly
- MetricsMap operations work

**Status:** ✅ Completed

---

### Task 8.5.2: Master Process ✅
**Module:** `Shibuya.Runner.Master`
**File:** `src/Shibuya/Runner/Master.hs`

```haskell
data Master = Master { masterAsync, masterState, masterInbox }
startMaster :: (IOE :> es) => Strategy -> Eff es Master
stopMaster :: (IOE :> es) => Master -> Eff es ()
getAllMetrics :: (IOE :> es) => Master -> Eff es MetricsMap
registerProcessor :: (IOE :> es) => Master -> ProcessorId -> TVar ProcessorMetrics -> Eff es ()
```

**Tests:**
- startMaster/stopMaster lifecycle
- getAllMetrics returns empty initially
- Processor registration works

**Status:** ✅ Completed

---

### Task 8.5.3: Supervised Runner ✅
**Module:** `Shibuya.Runner.Supervised`
**File:** `src/Shibuya/Runner/Supervised.hs`

```haskell
runSupervised :: Master -> Natural -> ProcessorId -> Adapter es msg -> Handler es msg -> Eff es SupervisedProcessor
runWithMetrics :: Natural -> ProcessorId -> Adapter es msg -> Handler es msg -> Eff es SupervisedProcessor
getMetrics :: SupervisedProcessor -> Eff es ProcessorMetrics
isDone :: SupervisedProcessor -> Eff es Bool
```

**Tests:**
- Processes messages and tracks metrics
- Tracks failed messages
- Marks processor as done when stream exhausted

**Status:** ✅ Completed

---

## Phase 9: Application Entry Point

### Task 9.1: AppError Type
**Module:** `Shibuya.App`
**File:** `src/Shibuya/App.hs`

```haskell
data AppError
  = PolicyValidationError !Text
  | AdapterError !Text
  | HandlerError !Text
  deriving stock (Eq, Show)
```

**Tests:**
- All constructors distinguishable
- Show instance works

**Definition of Done:** `cabal test` passes

---

### Task 9.2: runApp Entry Point
**Module:** `Shibuya.App`
**File:** `src/Shibuya/App.hs`

```haskell
runApp
  :: (IOE :> es)
  => RunnerConfig es msg
  -> Eff es (Either AppError ())
```

**Tests:**
- Returns PolicyValidationError for invalid policy
- Returns Right () on successful completion
- Uses Serial runner when configured

**Definition of Done:** `cabal test` passes with full integration test

---

## Phase 10: Re-export Module

### Task 10.1: Shibuya.Core Re-exports
**Module:** `Shibuya.Core`
**File:** `src/Shibuya/Core.hs`

```haskell
module Shibuya.Core
  ( -- * Message Types
    MessageId(..)
  , Cursor(..)
  , Envelope(..)
    -- * Ack Semantics
  , AckDecision(..)
  , RetryDelay(..)
  , DeadLetterReason(..)
  , HaltReason(..)
    -- * Handler Types
  , AckHandle(..)
  , Lease(..)
  , Ingested(..)
    -- * Handler
  , Handler
    -- * Adapter
  , Adapter(..)
    -- * Policy
  , Ordering(..)
  , Concurrency(..)
  , validatePolicy
    -- * Runner
  , RunnerConfig(..)
  , defaultRunnerConfig
    -- * App
  , runApp
  , AppError(..)
  ) where
```

**Tests:**
- All types accessible from Shibuya.Core
- Example program compiles using only Shibuya.Core

**Definition of Done:** `cabal test` passes, example compiles

---

## Phase 11: Postgres Adapter (First Real Adapter)

### Task 11.1: Postgres Job Schema Types
**Module:** `Shibuya.Adapter.Postgres.Types`
**Separate Package:** `shibuya-postgres`

**Tests:**
- Job type round-trips to/from database
- Status enum matches DB values

---

### Task 11.2: Postgres Polling
**Module:** `Shibuya.Adapter.Postgres.Poll`

**Tests:**
- Fetches pending jobs
- Marks jobs as processing
- Handles empty queue

---

### Task 11.3: Postgres Ack Implementation
**Module:** `Shibuya.Adapter.Postgres.Ack`

**Tests:**
- AckOk marks job complete
- AckRetry schedules retry with delay
- AckDeadLetter moves to DLQ table

---

### Task 11.4: Complete Postgres Adapter
**Module:** `Shibuya.Adapter.Postgres`

**Tests:**
- Full integration test with test database
- Processes N jobs correctly
- Retry behavior works
- DLQ routing works

---

## Phase 12: Kafka Adapter (Second Adapter)

### Task 12.1: Kafka Consumer Stream
### Task 12.2: Kafka Offset Commit
### Task 12.3: Complete Kafka Adapter

(Similar breakdown to Postgres)

---

## Implementation Order

Recommended order for maximum testability:

1. **Task 1.1-1.4**: Core types (no dependencies, pure)
2. **Task 4.1-4.3**: Policy types (pure, needed for validation)
3. **Task 2.1-2.3**: Effectful types (simple effect wrappers)
4. **Task 3.1**: Handler type (depends on above)
5. **Task 5.1-5.2**: Adapter interface + mock (enables testing)
6. **Task 6.1**: Runner config (combines above)
7. **Task 7.1-7.3**: Stream utilities (independent)
8. **Task 8.1-8.3**: Runner logic (integration)
9. **Task 9.1-9.2**: App entry point (top-level)
10. **Task 10.1**: Re-exports (final polish)
11. **Phase 11-12**: Real adapters (separate packages)

## Running Tests

```bash
# Run all tests
cabal test

# Run specific test module
cabal test --test-option=--match --test-option="/Core.Types/"

# Run with coverage
cabal test --enable-coverage
```

## Test Dependencies to Add

```yaml
# In shibuya-core.cabal test-suite section
build-depends:
  base,
  shibuya-core,
  hspec >= 2.11,
  QuickCheck >= 2.14,
  effectful,
  streamly,
```
