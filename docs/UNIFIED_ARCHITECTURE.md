# Shibuya Framework Architecture

Shibuya is a supervised queue processing framework for Haskell, inspired by [Broadway](https://github.com/dashbitco/broadway) from Elixir. It provides a unified abstraction over various message queue backends (Kafka, PostgreSQL queues, SQS, Redis) with built-in supervision, backpressure, and composable stream transformations.

## Design Principles

1. **Separation of Concerns**: Streamly handles I/O, polling, batching, and backpressure. NQE handles concurrency, supervision, and state management.
2. **Explicit Semantics**: Handlers express intent (ack, retry, dead-letter, halt) - the framework handles mechanics.
3. **Adapter Abstraction**: Queue-specific logic lives in adapters, not the core framework.
4. **Composable Transformations**: Stream pipelines are composable and testable in isolation.
5. **Effectful by Default**: All effects are tracked via the Effectful library.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Master Process                                  │
│                                                                             │
│  ┌─────────────────┐    ┌────────────────────────────────────────────────┐ │
│  │  MetricsMap     │    │              NQE Supervisor                    │ │
│  │  (TVar)         │    │                                                │ │
│  │                 │    │  ┌────────────────────────────────────────┐   │ │
│  │  proc-1 ──────────────►│         Supervised Processor 1          │───────► Kafka Topic A
│  │  proc-2 ───┐    │    │  │                                        │   │ │
│  │  ...       │    │    │  │  Adapter ──► Stream ──► Handler        │   │ │
│  └────────────│────┘    │  │             (Streamly)   │             │   │ │
│               │         │  │                          ▼             │   │ │
│               │         │  │                    AckHandle.finalize  │   │ │
│               │         │  │                          │             │   │ │
│               └─────────│──│──────────── Metrics ◄────┘             │   │ │
│                         │  └────────────────────────────────────────┘   │ │
│                         │                                                │ │
│                         │  ┌────────────────────────────────────────┐   │ │
│                         │  │         Supervised Processor 2         │───────► PostgreSQL Queue
│                         │  │         (postgres adapter)             │   │ │
│                         │  └────────────────────────────────────────┘   │ │
│                         │                                                │ │
│                         │  ┌────────────────────────────────────────┐   │ │
│                         │  │         Supervised Processor 3         │───────► SQS Queue
│                         │  │         (sqs adapter)                  │   │ │
│                         │  └────────────────────────────────────────┘   │ │
│                         └────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | Responsibility |
|-----------|----------------|
| **Master** | Central coordinator, holds MetricsMap, spawns Supervisor |
| **NQE Supervisor** | Manages child processor lifecycles, applies restart strategy |
| **Supervised Processor** | Runs adapter stream, calls handler, updates metrics |
| **MetricsMap** | TVar-based map for O(1) introspection of all processors |

## Module Structure

```
Shibuya/
├── Core.hs                 -- Re-exports public API
├── Core/
│   ├── Types.hs           -- MessageId, Cursor, Envelope
│   ├── Ack.hs             -- AckDecision, RetryDelay, DeadLetterReason
│   ├── Lease.hs           -- Optional lease for visibility timeout
│   ├── AckHandle.hs       -- Effectful ack finalization
│   └── Ingested.hs        -- Complete message bundle for handlers
├── Handler.hs             -- Handler type alias
├── Adapter.hs             -- Adapter interface
├── Adapter/
│   └── Mock.hs            -- Mock adapter for testing
├── Policy.hs              -- Ordering and Concurrency policies
├── Runner.hs              -- RunnerConfig and execution
├── Runner/
│   ├── Metrics.hs         -- ProcessorState, StreamStats, ProcessorMetrics
│   ├── Master.hs          -- Master process (NQE supervision + metrics)
│   ├── Supervised.hs      -- Supervised processor runner
│   ├── Serial.hs          -- Simple sequential runner
│   ├── Ingester.hs        -- Stream to inbox bridge
│   └── Processor.hs       -- Inbox to handler bridge
├── Stream.hs              -- Stream utilities
└── App.hs                 -- Top-level entry point (runApp)
```

---

## Layer 1: Core Types

These types exist everywhere and should be extremely stable. No behavior, no effects, no policy.

### Shibuya.Core.Types

```haskell
module Shibuya.Core.Types
  ( MessageId(..)
  , Cursor(..)
  , Envelope(..)
  ) where

import Data.Text (Text)
import Data.Time (UTCTime)

-- | Stable identity for idempotency & observability
newtype MessageId = MessageId { unMessageId :: Text }
  deriving stock (Eq, Ord, Show)

-- | Optional cursor / offset / global position
data Cursor
  = CursorInt !Int
  | CursorText !Text
  deriving stock (Eq, Ord, Show)

-- | Normalized message envelope (Broadway.Message equivalent)
data Envelope msg = Envelope
  { messageId  :: !MessageId
  , cursor     :: !(Maybe Cursor)
  , partition  :: !(Maybe Text)
  , enqueuedAt :: !(Maybe UTCTime)
  , payload    :: !msg
  }
  deriving stock (Eq, Show, Functor, Generic)
```

---

## Layer 2: Ack Semantics

Handlers decide meaning, not mechanics. This is explicit to support halt-on-error for ordered streams.

### Shibuya.Core.Ack

```haskell
module Shibuya.Core.Ack
  ( RetryDelay(..)
  , DeadLetterReason(..)
  , HaltReason(..)
  , AckDecision(..)
  ) where

import Data.Text (Text)
import Data.Time (NominalDiffTime)

-- | Delay before retry
newtype RetryDelay = RetryDelay { unRetryDelay :: NominalDiffTime }
  deriving stock (Eq, Show)

-- | Why a message is being dead-lettered
data DeadLetterReason
  = PoisonPill !Text
  | InvalidPayload !Text
  | MaxRetriesExceeded
  deriving stock (Eq, Show)

-- | Why processing should halt
data HaltReason
  = HaltOrderedStream !Text  -- Must stop to preserve ordering
  | HaltFatal !Text          -- Unrecoverable error
  deriving stock (Eq, Show)

-- | Handler outcome (semantic, not mechanical)
data AckDecision
  = AckOk                          -- Processed successfully
  | AckRetry !RetryDelay           -- Retry after delay
  | AckDeadLetter !DeadLetterReason -- Move to DLQ
  | AckHalt !HaltReason            -- Stop processing
  deriving stock (Eq, Show)
```

---

## Layer 3: Lease (Optional)

Lease exists only to model temporary ownership (SQS visibility timeout, DB locks). Kafka adapters won't use this.

### Shibuya.Core.Lease

```haskell
module Shibuya.Core.Lease
  ( Lease(..)
  ) where

import Data.Text (Text)
import Data.Time (NominalDiffTime)
import Effectful (Eff)

-- | Optional capability for sources with visibility/ownership
data Lease es = Lease
  { leaseId     :: !Text
  , leaseExtend :: NominalDiffTime -> Eff es ()
  }
```

---

## Layer 4: AckHandle

This is the Broadway.Acknowledger equivalent, but typed. Must be called exactly once.

### Shibuya.Core.AckHandle

```haskell
module Shibuya.Core.AckHandle
  ( AckHandle(..)
  ) where

import Shibuya.Core.Ack (AckDecision)
import Effectful (Eff)

-- | Mechanical ack interface (adapter-provided)
newtype AckHandle es = AckHandle
  { finalize :: AckDecision -> Eff es ()
  }
```

---

## Layer 5: Ingested Message

What flows through the runner into handlers. Broadway.Message + Acknowledger + optional lease.

### Shibuya.Core.Ingested

```haskell
module Shibuya.Core.Ingested
  ( Ingested(..)
  ) where

import Shibuya.Core.Types (Envelope)
import Shibuya.Core.Lease (Lease)
import Shibuya.Core.AckHandle (AckHandle)

-- | What handlers receive
data Ingested es msg = Ingested
  { envelope :: !(Envelope msg)
  , ack      :: !(AckHandle es)
  , lease    :: !(Maybe (Lease es))
  }
```

---

## Layer 6: Handler API

This is all application authors need to know. Handlers cannot ack directly, cannot influence concurrency, and express intent only.

### Shibuya.Handler

```haskell
module Shibuya.Handler
  ( Handler
  ) where

import Shibuya.Core.Ingested (Ingested)
import Shibuya.Core.Ack (AckDecision)
import Effectful (Eff)

-- | Handler function type
type Handler es msg = Ingested es msg -> Eff es AckDecision
```

---

## Layer 7: Adapter API

Adapters bridge external systems to the framework. Adapter owns queue semantics; runner never touches offsets directly.

### Shibuya.Adapter

```haskell
module Shibuya.Adapter
  ( Adapter(..)
  ) where

import Data.Text (Text)
import Shibuya.Core.Ingested (Ingested)
import Effectful (Eff)
import Streamly.Data.Stream (Stream)

-- | Queue adapter interface
data Adapter es msg = Adapter
  { adapterName :: !Text

  -- | Stream of leased messages
  , source :: Stream (Eff es) (Ingested es msg)

  -- | Stop polling, release resources
  , shutdown :: Eff es ()
  }
```

---

## Layer 8: Ordering & Concurrency Policy

Runner policy that maps ordering guarantees to concurrency constraints.

### Shibuya.Policy

```haskell
module Shibuya.Policy
  ( Ordering(..)
  , Concurrency(..)
  , validatePolicy
  ) where

-- | Message ordering guarantees
data Ordering
  = StrictInOrder      -- Event-sourced subscriptions (must be Serial)
  | PartitionedInOrder -- Kafka-style (parallel across partitions)
  | Unordered          -- No ordering guarantees
  deriving stock (Eq, Show)

-- | Concurrency mode
data Concurrency
  = Serial            -- One message at a time
  | Ahead !Int        -- Prefetch N, process in order
  | Async !Int        -- Process N concurrently
  deriving stock (Eq, Show)

-- | Validate policy combinations
-- Invariant: StrictInOrder => Serial
validatePolicy :: Ordering -> Concurrency -> Either Text ()
validatePolicy StrictInOrder (Ahead _) = Left "StrictInOrder requires Serial concurrency"
validatePolicy StrictInOrder (Async _) = Left "StrictInOrder requires Serial concurrency"
validatePolicy _ _ = Right ()
```

---

## Layer 9: Runner Configuration

User-facing configuration combining adapter, handler, and policies.

### Shibuya.Runner

```haskell
module Shibuya.Runner
  ( RunnerConfig(..)
  , defaultRunnerConfig
  ) where

import Shibuya.Adapter (Adapter)
import Shibuya.Handler (Handler)
import Shibuya.Policy (Ordering(..), Concurrency(..))

-- | Complete runner configuration
data RunnerConfig es msg = RunnerConfig
  { adapter     :: !(Adapter es msg)
  , handler     :: !(Handler es msg)
  , ordering    :: !Ordering
  , concurrency :: !Concurrency
  , inboxSize   :: !Int
  }

-- | Default configuration (unordered, serial, inbox size 100)
defaultRunnerConfig :: Adapter es msg -> Handler es msg -> RunnerConfig es msg
defaultRunnerConfig adapter handler = RunnerConfig
  { adapter     = adapter
  , handler     = handler
  , ordering    = Unordered
  , concurrency = Serial
  , inboxSize   = 100
  }
```

---

## Layer 10: Application Entry Point

Where Streamly wiring, supervision, ack lifecycle, and halt semantics are applied.

### Shibuya.App

```haskell
module Shibuya.App
  ( runApp
  , AppError(..)
  ) where

import Shibuya.Runner (RunnerConfig)
import Shibuya.Policy (validatePolicy)
import Effectful (Eff, IOE)

data AppError
  = PolicyValidationError !Text
  | AdapterError !Text
  | HandlerError !Text
  deriving stock (Eq, Show)

-- | Run the message processing application
runApp
  :: (IOE :> es)
  => RunnerConfig es msg
  -> Eff es (Either AppError ())
runApp config = do
  case validatePolicy (ordering config) (concurrency config) of
    Left err -> pure $ Left $ PolicyValidationError err
    Right () -> do
      -- Implementation:
      -- 1. Create bounded inbox
      -- 2. Start ingester (adapter.source -> inbox)
      -- 3. Start processor (inbox -> handler -> ack)
      -- 4. Supervise both
      undefined
```

---

## Master Process & Supervision

The Master process provides centralized supervision and introspection for all processors.

### Shibuya.Runner.Metrics

```haskell
module Shibuya.Runner.Metrics
  ( ProcessorState(..)
  , ProcessorId(..)
  , StreamStats(..)
  , ProcessorMetrics(..)
  , MetricsMap
  ) where

-- | Processor identifier
newtype ProcessorId = ProcessorId { unProcessorId :: Text }
  deriving stock (Eq, Ord, Show, Generic)

-- | Processor runtime state
data ProcessorState
  = Idle                        -- Waiting for messages
  | Processing !Int !UTCTime    -- Currently processing (count, last activity)
  | Failed !Text !UTCTime       -- Failed with error
  | Stopped                     -- Processor has been stopped
  deriving stock (Eq, Show, Generic)

-- | Stream statistics
data StreamStats = StreamStats
  { ssReceived  :: !Int   -- Messages received from stream
  , ssDropped   :: !Int   -- Messages dropped (backpressure)
  , ssProcessed :: !Int   -- Messages successfully processed
  , ssFailed    :: !Int   -- Messages that failed processing
  }
  deriving stock (Eq, Show, Generic)

-- | Combined processor metrics
data ProcessorMetrics = ProcessorMetrics
  { pmState     :: !ProcessorState
  , pmStats     :: !StreamStats
  , pmStartedAt :: !UTCTime
  }
  deriving stock (Show, Generic)

-- | Map of processor IDs to their metrics
type MetricsMap = Map ProcessorId ProcessorMetrics
```

### Shibuya.Runner.Master

The Master is an NQE process that:
- Creates and manages an NQE Supervisor for child processors
- Maintains a `TVar (Map ProcessorId (TVar ProcessorMetrics))` for introspection
- Handles control messages via message-passing

```haskell
module Shibuya.Runner.Master
  ( Master(..)
  , MasterState(..)
  , MasterMessage(..)
  , startMaster
  , stopMaster
  , getAllMetrics
  , getProcessorMetrics
  , registerProcessor
  , unregisterProcessor
  ) where

-- | Messages for the master process
data MasterMessage
  = GetAllMetrics (Listen MetricsMap)
  | GetProcessorMetrics ProcessorId (Listen (Maybe ProcessorMetrics))
  | RegisterProcessor ProcessorId (TVar ProcessorMetrics) (Listen ())
  | UnregisterProcessor ProcessorId (Listen ())
  | Shutdown (Listen ())

-- | Master handle
data Master = Master
  { masterAsync :: Async ()
  , masterState :: MasterState
  , masterInbox :: Inbox MasterMessage
  }

-- | Start the master process
startMaster :: (IOE :> es) => Strategy -> Eff es Master

-- | Stop the master and all child processors
stopMaster :: (IOE :> es) => Master -> Eff es ()

-- | Get metrics for all processors
getAllMetrics :: (IOE :> es) => Master -> Eff es MetricsMap
```

### Shibuya.Runner.Supervised

Runs processors under the Master's supervision with metrics tracking:

```haskell
module Shibuya.Runner.Supervised
  ( SupervisedProcessor(..)
  , runSupervised
  , runWithMetrics
  , getMetrics
  , getProcessorState
  , isDone
  ) where

-- | Handle for a supervised processor
data SupervisedProcessor = SupervisedProcessor
  { spMetrics     :: TVar ProcessorMetrics
  , spProcessorId :: ProcessorId
  , spDone        :: TVar Bool
  , spChild       :: Maybe (Async ())
  }

-- | Run processor under Master's supervision
runSupervised
  :: (IOE :> es)
  => Master
  -> Natural           -- Inbox size
  -> ProcessorId
  -> Adapter es msg
  -> Handler es msg
  -> Eff es SupervisedProcessor

-- | Run with metrics but without supervision (for testing)
runWithMetrics
  :: (IOE :> es)
  => Natural
  -> ProcessorId
  -> Adapter es msg
  -> Handler es msg
  -> Eff es SupervisedProcessor
```

### Supervision Strategies

NQE provides supervision strategies that control behavior when a child dies:

| Strategy | Behavior |
|----------|----------|
| `IgnoreAll` | Keep running, ignore dead children |
| `IgnoreGraceful` | Keep running unless child threw exception |
| `KillAll` | Stop all children and propagate exception |
| `Notify mailbox` | Send notification to mailbox when child dies |

---

## Data Flow

```
External Queue (Kafka/Postgres/SQS)
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Adapter.source                              │
│  (Stream (Eff es) (Ingested es msg))                           │
│                                                                 │
│  Produces: Envelope + AckHandle + Maybe Lease                  │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼ (optional transformations: filter, batch, rate-limit)
┌─────────────────────────────────────────────────────────────────┐
│                     Bounded Inbox                               │
│  (backpressure via NQE mailbox)                                │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Handler                                  │
│  (Ingested es msg -> Eff es AckDecision)                       │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│                    AckHandle.finalize                           │
│  (Commits offset, schedules retry, routes to DLQ, or halts)    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Stream Utilities (Shibuya.Stream)

Common stream transformations for use with adapters.

```haskell
module Shibuya.Stream
  ( pollingStream
  , batchStream
  , filterStream
  , rateLimitStream
  ) where

import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import Streamly.Data.Fold qualified as Fold
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, liftIO)
import Control.Concurrent (threadDelay)

-- | Create a polling stream from a poll action
pollingStream
  :: (IOE :> es)
  => Int                    -- ^ Poll interval (microseconds)
  -> Eff es (Maybe msg)     -- ^ Poll action
  -> Stream (Eff es) msg
pollingStream interval poll =
  Stream.catMaybes $
    Stream.repeatM $ do
      mmsg <- poll
      case mmsg of
        Nothing -> liftIO (threadDelay interval) >> pure Nothing
        Just msg -> pure (Just msg)

-- | Batch messages into chunks
batchStream :: Int -> Stream m msg -> Stream m [msg]
batchStream n = Stream.foldMany (Fold.take n Fold.toList)

-- | Filter messages
filterStream :: (msg -> Bool) -> Stream m msg -> Stream m msg
filterStream = Stream.filter

-- | Rate limit (messages per second)
rateLimitStream
  :: (IOE :> es)
  => Int                     -- ^ Max messages per second
  -> Stream (Eff es) msg
  -> Stream (Eff es) msg
rateLimitStream msgsPerSec = undefined -- Implementation uses IORef for timing
```

---

## Testing Strategy

Each layer can be tested independently:

| Layer | Test Approach |
|-------|---------------|
| Core.Types | Unit tests for Eq, Ord, Show, Functor laws |
| Core.Ack | Unit tests for pattern matching |
| Core.Lease | Mock lease extension |
| Core.AckHandle | Track finalize calls |
| Core.Ingested | Construction tests |
| Handler | Property tests with mock Ingested |
| Adapter | Mock streams, verify Ingested production |
| Policy | Unit tests for validatePolicy |
| Runner.Metrics | Unit tests for metric updates |
| Runner.Master | Start/stop, metrics registration |
| Runner.Supervised | Metrics tracking, processor state |
| Runner | Integration with mock adapter |
| App | Full integration tests |

Current test count: **42 tests passing**

---

## Adapter Implementation Guide

To implement a new adapter:

1. **Create the stream source** that polls your queue
2. **Wrap messages in Envelope** with appropriate metadata
3. **Create AckHandle** that commits/retries/dead-letters based on decision
4. **Optionally create Lease** for visibility timeout extension
5. **Bundle into Ingested** and yield from stream

Example skeleton:

```haskell
postgresAdapter
  :: (IOE :> es)
  => ConnectionPool
  -> Text           -- ^ Queue name
  -> Adapter es JobPayload
postgresAdapter pool queueName = Adapter
  { adapterName = "postgres:" <> queueName
  , source = postgresStream pool queueName
  , shutdown = pure ()
  }

postgresStream
  :: (IOE :> es)
  => ConnectionPool
  -> Text
  -> Stream (Eff es) (Ingested es JobPayload)
postgresStream pool queueName = pollingStream 100_000 $ do
  mJob <- liftIO $ pollJob pool queueName
  pure $ fmap (jobToIngested pool) mJob

jobToIngested :: ConnectionPool -> Job -> Ingested es JobPayload
jobToIngested pool job = Ingested
  { envelope = Envelope
      { messageId  = MessageId (jobId job)
      , cursor     = Just (CursorInt (jobPosition job))
      , partition  = Nothing
      , enqueuedAt = Just (jobCreatedAt job)
      , payload    = jobPayload job
      }
  , ack = AckHandle $ \decision -> case decision of
      AckOk -> liftIO $ markComplete pool (jobId job)
      AckRetry delay -> liftIO $ scheduleRetry pool (jobId job) delay
      AckDeadLetter reason -> liftIO $ moveToDLQ pool (jobId job) reason
      AckHalt _ -> pure () -- Runner handles halt
  , lease = Nothing -- Postgres uses row locks, not visibility timeout
  }
```

---

## References

- [Broadway (Elixir)](https://github.com/dashbitco/broadway) - Primary inspiration
- [Streamly](https://hackage.haskell.org/package/streamly) - Stream processing
- [Effectful](https://hackage.haskell.org/package/effectful) - Effect system
- [NQE](https://hackage.haskell.org/package/nqe) - Actor supervision
