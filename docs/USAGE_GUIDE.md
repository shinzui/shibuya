# Shibuya Usage Guide

This guide shows how to use Shibuya to process messages from queues.

## Quick Start

```haskell
module Main where

import Shibuya.App
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

  -- 2. Define your processor (adapter + handler)
  let ordersProcessor = QueueProcessor
        { adapter = postgresAdapter pool "orders_queue"
        , handler = handleOrder
        }

  -- 3. Run with supervision!
  result <- runApp IgnoreAll 100
    [ (ProcessorId "orders", ordersProcessor)
    ]

  case result of
    Left err -> liftIO $ print err
    Right appHandle -> waitApp appHandle
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

## Configuring runApp

### Basic Configuration

```haskell
-- runApp signature:
runApp
  :: Strategy                          -- Supervision strategy
  -> Int                               -- Inbox size for backpressure
  -> [(ProcessorId, QueueProcessor es)] -- Named processors
  -> Eff es (Either AppError (AppHandle es))
```

### Example: Single Processor

```haskell
result <- runApp IgnoreAll 100
  [ (ProcessorId "orders", ordersProcessor)
  ]
```

### Example: Multiple Processors

```haskell
result <- runApp IgnoreAll 500
  [ (ProcessorId "orders", ordersProcessor)
  , (ProcessorId "events", eventsProcessor)
  , (ProcessorId "notifications", notificationsProcessor)
  ]
```

### Inbox Size

The inbox size controls backpressure - how many messages are buffered between the adapter stream and the handler:

| Size | Use Case |
|------|----------|
| `100` | Default, good for most cases |
| `500-1000` | High throughput, bursty traffic |
| `50` | Memory-constrained environments |

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

Use `runApp` to run multiple processors concurrently with supervision:

```haskell
import Shibuya.App

main :: IO ()
main = runEff . runConcurrent $ do
  -- Define your processors
  let ordersProcessor = QueueProcessor
        { adapter = ordersAdapter
        , handler = handleOrders
        }
      notificationsProcessor = QueueProcessor
        { adapter = notificationsAdapter
        , handler = handleNotifications
        }
      analyticsProcessor = QueueProcessor
        { adapter = analyticsAdapter
        , handler = handleAnalytics
        }

  -- Run all processors under supervision
  result <- runApp IgnoreAll 100
    [ (ProcessorId "orders", ordersProcessor)
    , (ProcessorId "notifications", notificationsProcessor)
    , (ProcessorId "analytics", analyticsProcessor)
    ]

  case result of
    Left err -> print err
    Right appHandle -> do
      -- Monitor metrics periodically
      forever $ do
        liftIO $ threadDelay 10_000_000  -- 10 seconds
        metrics <- getAppMetrics appHandle
        liftIO $ printMetrics metrics
```

## Monitoring & Metrics

### Getting Processor Metrics

```haskell
-- Get all processor metrics from AppHandle
metrics <- getAppMetrics appHandle
-- metrics :: Map ProcessorId ProcessorMetrics
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

import Shibuya.App
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

  let ordersProcessor = QueueProcessor
        { adapter = postgresAdapter pool "order_events"
        , handler = handleOrder
        }

  liftIO $ putStrLn "Starting order processor..."

  result <- runApp IgnoreAll 200
    [ (ProcessorId "orders", ordersProcessor)
    ]

  case result of
    Left err ->
      liftIO $ putStrLn $ "Error: " <> show err
    Right appHandle -> do
      liftIO $ putStrLn "Processor running..."
      waitApp appHandle
      liftIO $ putStrLn "Processor stopped gracefully"
```

## Supervision Strategies

Choose a supervision strategy when calling `runApp`:

| Strategy | Behavior | Use Case |
|----------|----------|----------|
| `IgnoreAll` | Continue running, ignore failures | Independent processors |
| `IgnoreGraceful` | Continue unless exception thrown | Graceful shutdown handling |
| `KillAll` | Stop all processors on any failure | Coordinated shutdown |
| `OneForOne` | Restart only the failed processor | Default for most apps |

```haskell
-- Independent processors - failures don't affect each other
result <- runApp IgnoreAll 100 processors

-- All-or-nothing - if one fails, stop everything
result <- runApp KillAll 100 processors

-- Restart failed processors individually
result <- runApp OneForOne 100 processors
```
