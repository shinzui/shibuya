# Shibuya Usage Guide

This guide shows how to use Shibuya to process messages from a queue.

## Quick Start

```haskell
module Main where

import Shibuya.Core  -- Everything you need!
import Shibuya.Adapter.Postgres (postgresAdapter)  -- hypothetical adapter
import Effectful
import Effectful.Concurrent (runConcurrent)

-- Your domain type
data OrderEvent = OrderEvent
  { orderId :: Text
  , amount  :: Int
  }
  deriving (Generic, FromJSON)

-- Your handler
handleOrder :: Handler '[IOE] OrderEvent
handleOrder ingested = do
  let order = payload (envelope ingested)
  liftIO $ putStrLn $ "Processing order: " <> show (orderId order)

  -- Do your business logic here
  result <- processOrder order

  case result of
    Right ()  -> pure AckOk
    Left err  -> pure $ AckRetry (RetryDelay 5)

main :: IO ()
main = runEff . runConcurrent $ do
  -- 1. Create your adapter
  pool <- createConnectionPool "postgresql://localhost/mydb"
  let adapter = postgresAdapter pool "orders_queue"

  -- 2. Configure the runner
  let config = defaultRunnerConfig adapter handleOrder

  -- 3. Run!
  result <- runApp config
  case result of
    Left err -> liftIO $ print err
    Right () -> pure ()
```

## Writing Handlers

A handler receives an `Ingested` message and returns an `AckDecision`:

```haskell
type Handler es msg = Ingested es msg -> Eff es AckDecision
```

### The Ingested Type

```haskell
data Ingested es msg = Ingested
  { envelope :: Envelope msg   -- The message with metadata
  , ack      :: AckHandle es   -- Internal, don't use directly
  , lease    :: Maybe (Lease es) -- For extending visibility timeout
  }
```

### Accessing Message Data

```haskell
handleMessage :: Handler '[IOE] MyEvent
handleMessage ingested = do
  -- Get the payload
  let event = payload (envelope ingested)

  -- Access metadata
  let msgId = messageId (envelope ingested)
  let maybeCursor = cursor (envelope ingested)
  let maybePartition = partition (envelope ingested)
  let maybeEnqueuedAt = enqueuedAt (envelope ingested)

  -- Process...
  pure AckOk
```

### Ack Decisions

Return one of these to indicate what should happen:

```haskell
-- Success - message is acknowledged
pure AckOk

-- Retry after delay
pure $ AckRetry (RetryDelay 30)  -- 30 seconds

-- Send to dead-letter queue
pure $ AckDeadLetter (InvalidPayload "missing required field")
pure $ AckDeadLetter (PoisonPill "causes crash")
pure $ AckDeadLetter MaxRetriesExceeded

-- Stop processing entirely (for ordered streams)
pure $ AckHalt (HaltOrderedStream "dependency unavailable")
pure $ AckHalt (HaltFatal "unrecoverable error")
```

### Example: Robust Handler with Error Handling

```haskell
handleEvent :: Handler '[IOE, Log] MyEvent
handleEvent ingested = do
  let event = payload (envelope ingested)
  let msgId = unMessageId $ messageId (envelope ingested)

  log Info $ "Processing message: " <> msgId

  result <- tryAny $ processEvent event

  case result of
    Right () -> do
      log Info $ "Success: " <> msgId
      pure AckOk

    Left (SomeException e)
      | isTransient e -> do
          log Warn $ "Transient error, retrying: " <> show e
          pure $ AckRetry (RetryDelay 10)

      | isPoisonPill e -> do
          log Error $ "Poison pill detected: " <> show e
          pure $ AckDeadLetter (PoisonPill $ pack $ show e)

      | otherwise -> do
          log Error $ "Unknown error: " <> show e
          pure $ AckRetry (RetryDelay 60)
```

## Configuring the Runner

### Basic Configuration

```haskell
let config = defaultRunnerConfig adapter handler
-- Defaults: Unordered, Serial, inboxSize = 100
```

### Custom Configuration

```haskell
let config = RunnerConfig
      { adapter     = myAdapter
      , handler     = myHandler
      , ordering    = Unordered       -- No ordering guarantees
      , concurrency = Async 10        -- Process 10 messages concurrently
      , inboxSize   = 500             -- Buffer up to 500 messages
      }
```

### Ordering Policies

| Policy | Use Case | Concurrency Allowed |
|--------|----------|---------------------|
| `StrictInOrder` | Event sourcing, must process in exact order | `Serial` only |
| `PartitionedInOrder` | Kafka-style, order within partition | `Async` across partitions |
| `Unordered` | Independent messages, max throughput | Any |

### Concurrency Modes

| Mode | Behavior |
|------|----------|
| `Serial` | One message at a time |
| `Ahead n` | Prefetch n messages, process in order |
| `Async n` | Process up to n messages concurrently |

### Example: High-Throughput Worker

```haskell
let config = RunnerConfig
      { adapter     = sqsAdapter
      , handler     = handleNotification
      , ordering    = Unordered
      , concurrency = Async 50      -- 50 concurrent handlers
      , inboxSize   = 1000          -- Large buffer for bursts
      }
```

### Example: Ordered Event Processing

```haskell
let config = RunnerConfig
      { adapter     = kafkaAdapter
      , handler     = handleDomainEvent
      , ordering    = StrictInOrder
      , concurrency = Serial        -- Required for StrictInOrder
      , inboxSize   = 100
      }
```

## Using Lease Extension

For queues with visibility timeouts (SQS, some Postgres implementations), extend the lease for long-running operations:

```haskell
handleLongRunning :: Handler '[IOE] BigJob
handleLongRunning ingested = do
  let job = payload (envelope ingested)

  -- Extend lease for long operations
  case lease ingested of
    Nothing -> pure ()  -- Adapter doesn't support leases
    Just l  -> do
      -- Extend by 5 minutes before starting
      leaseExtend l 300

  -- Long running operation
  result <- runExpensiveJob job

  pure $ case result of
    Right () -> AckOk
    Left err -> AckRetry (RetryDelay 60)
```

## Running Multiple Processors

Use the Master for running multiple processors with supervision:

```haskell
import Shibuya.Core  -- Includes Master, runSupervised, Strategy, etc.

main :: IO ()
main = runEff . runConcurrent $ do
  -- Start the master with a supervision strategy
  master <- startMaster KillAll  -- Strategy is re-exported from Shibuya.Core

  -- Start multiple processors
  proc1 <- runSupervised master 100
             (ProcessorId "orders")
             ordersAdapter
             handleOrders

  proc2 <- runSupervised master 100
             (ProcessorId "notifications")
             notificationsAdapter
             handleNotifications

  proc3 <- runSupervised master 100
             (ProcessorId "analytics")
             analyticsAdapter
             handleAnalytics

  -- Monitor metrics
  forever $ do
    liftIO $ threadDelay 10_000_000  -- 10 seconds
    metrics <- getAllMetrics master
    liftIO $ printMetrics metrics

  -- Cleanup
  stopMaster master
```

## Monitoring & Metrics

### Getting Processor Metrics

```haskell
-- Get all processor metrics
metrics <- getAllMetrics master
-- metrics :: Map ProcessorId ProcessorMetrics

-- Get specific processor metrics
maybeMetrics <- getProcessorMetrics master (ProcessorId "orders")
```

### ProcessorMetrics Structure

```haskell
data ProcessorMetrics = ProcessorMetrics
  { state     :: ProcessorState  -- Current state
  , stats     :: StreamStats     -- Cumulative statistics
  , startedAt :: UTCTime         -- When processor started
  }

data ProcessorState
  = Idle                      -- Waiting for messages
  | Processing Int UTCTime    -- (active count, last activity)
  | Failed Text UTCTime       -- (error message, when)
  | Stopped

data StreamStats = StreamStats
  { received  :: Int  -- Total messages received
  , dropped   :: Int  -- Dropped due to backpressure
  , processed :: Int  -- Successfully processed
  , failed    :: Int  -- Failed processing
  }
```

### Example: Metrics Dashboard

```haskell
printMetrics :: MetricsMap -> IO ()
printMetrics metrics = do
  forM_ (Map.toList metrics) $ \(ProcessorId name, pm) -> do
    putStrLn $ "Processor: " <> unpack name
    putStrLn $ "  State: " <> show pm.state
    putStrLn $ "  Received: " <> show pm.stats.received
    putStrLn $ "  Processed: " <> show pm.stats.processed
    putStrLn $ "  Failed: " <> show pm.stats.failed
    putStrLn ""
```

## Complete Example: Order Processing Service

```haskell
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeOperators #-}

module Main where

import Shibuya.Core
import Shibuya.Adapter.Postgres (postgresAdapter)  -- hypothetical adapter
import Effectful
import Effectful.Concurrent
import Data.Aeson (FromJSON)
import GHC.Generics (Generic)

-- Domain types
data OrderEvent
  = OrderCreated { orderId :: Text, items :: [Text], total :: Int }
  | OrderPaid { orderId :: Text, paymentId :: Text }
  | OrderShipped { orderId :: Text, trackingNumber :: Text }
  deriving (Generic, Show)

instance FromJSON OrderEvent

-- Handler
handleOrder :: Handler '[IOE] OrderEvent
handleOrder ingested = do
  let event = payload (envelope ingested)
  let msgId = unMessageId $ messageId (envelope ingested)

  liftIO $ putStrLn $ "[" <> unpack msgId <> "] Processing: " <> show event

  result <- liftIO $ tryProcess event

  pure $ case result of
    Right () -> AckOk
    Left TransientError -> AckRetry (RetryDelay 30)
    Left PermanentError -> AckDeadLetter (InvalidPayload "permanent failure")

tryProcess :: OrderEvent -> IO (Either ProcessError ())
tryProcess = \case
  OrderCreated{..} -> do
    -- Create order in database
    pure $ Right ()

  OrderPaid{..} -> do
    -- Update payment status
    pure $ Right ()

  OrderShipped{..} -> do
    -- Update shipping status
    pure $ Right ()

data ProcessError = TransientError | PermanentError

-- Main
main :: IO ()
main = runEff . runConcurrent $ do
  pool <- liftIO $ createConnectionPool "postgresql://localhost/orders"

  let adapter = postgresAdapter pool "order_events"

  let config = RunnerConfig
        { adapter     = adapter
        , handler     = handleOrder
        , ordering    = PartitionedInOrder  -- Order by orderId
        , concurrency = Async 5
        , inboxSize   = 200
        }

  liftIO $ putStrLn "Starting order processor..."

  result <- runApp config

  case result of
    Left (PolicyValidationError err) ->
      liftIO $ putStrLn $ "Config error: " <> unpack err
    Left (AdapterError err) ->
      liftIO $ putStrLn $ "Adapter error: " <> unpack err
    Left (HandlerError err) ->
      liftIO $ putStrLn $ "Handler error: " <> unpack err
    Right () ->
      liftIO $ putStrLn "Processor stopped gracefully"
```

## Supervision Strategies

When using the Master, choose a strategy for child failures:

| Strategy | Behavior | Use Case |
|----------|----------|----------|
| `IgnoreAll` | Continue running, ignore failures | Independent processors |
| `IgnoreGraceful` | Continue unless exception thrown | Graceful shutdown handling |
| `KillAll` | Stop all processors on any failure | Coordinated shutdown |
| `Notify inbox` | Send death notification to inbox | Custom failure handling |

```haskell
-- Independent processors - failures don't affect each other
master <- startMaster IgnoreAll

-- All-or-nothing - if one fails, stop everything
master <- startMaster KillAll

-- Custom handling
deathNotices <- newInbox
master <- startMaster (Notify deathNotices)

-- Monitor deaths in separate thread
async $ forever $ do
  notice <- receive deathNotices
  handleProcessorDeath notice
```
