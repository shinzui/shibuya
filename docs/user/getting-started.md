# Getting Started with Shibuya

Shibuya is a supervised queue processing framework for Haskell. This guide covers the core concepts that apply regardless of which queue adapter you use.

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

## Running Processors

### Basic Configuration

```haskell
runApp
  :: (IOE :> es, Tracing :> es)
  => SupervisionStrategy               -- How to handle processor failures
  -> Int                               -- Inbox size for backpressure
  -> [(ProcessorId, QueueProcessor es)] -- Named processors
  -> Eff es (Either AppError (AppHandle es))
```

### Single Processor

```haskell
result <- runApp IgnoreFailures 100
  [ (ProcessorId "orders", ordersProcessor)
  ]
```

### Multiple Processors

```haskell
result <- runApp IgnoreFailures 500
  [ (ProcessorId "orders", ordersProcessor)
  , (ProcessorId "events", eventsProcessor)
  , (ProcessorId "notifications", notificationsProcessor)
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

### Inbox Size

The inbox size controls backpressure - how many messages are buffered between the adapter stream and the handler:

| Size | Use Case |
|------|----------|
| `100` | Default, good for most cases |
| `500-1000` | High throughput, bursty traffic |
| `50` | Memory-constrained environments |

## Supervision Strategies

| Strategy | Behavior | Use Case |
|----------|----------|----------|
| `IgnoreFailures` | Continue running if a processor fails | Independent processors |
| `StopAllOnFailure` | Stop all processors on any failure | Coordinated shutdown |

```haskell
-- Independent processors - failures don't affect each other
result <- runApp IgnoreFailures 100 processors

-- All-or-nothing - if one fails, stop everything
result <- runApp StopAllOnFailure 100 processors
```

## Monitoring & Metrics

### Getting Processor Metrics

```haskell
metrics <- getAppMetrics appHandle
-- metrics :: Map ProcessorId ProcessorMetrics
```

### ProcessorMetrics Structure

```haskell
data ProcessorMetrics = ProcessorMetrics
  { state     :: !ProcessorState  -- Current state
  , stats     :: !StreamStats     -- Cumulative statistics
  , startedAt :: !UTCTime         -- When processor started
  }

data ProcessorState
  = Idle                            -- Waiting for messages
  | Processing !InFlightInfo !UTCTime -- (in-flight info, last activity)
  | Failed !Text !UTCTime           -- (error message, when)
  | Stopped

data StreamStats = StreamStats
  { received  :: !Int  -- Total messages received
  , dropped   :: !Int  -- Dropped due to backpressure
  , processed :: !Int  -- Successfully processed
  , failed    :: !Int  -- Failed processing
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

## Graceful Shutdown

Use `ShutdownConfig` and `stopAppGracefully` for controlled shutdown with drain timeout:

```haskell
data ShutdownConfig = ShutdownConfig
  { drainTimeout :: !NominalDiffTime
  }

defaultShutdownConfig :: ShutdownConfig  -- 30 second drain timeout

-- Returns True if shutdown completed within the timeout
stopAppGracefully :: (IOE :> es) => ShutdownConfig -> AppHandle es -> Eff es Bool
```

Example:

```haskell
let config = ShutdownConfig { drainTimeout = 60 }  -- 60 seconds
success <- stopAppGracefully config appHandle
unless success $
  liftIO $ putStrLn "Warning: shutdown timed out, some messages may not have been processed"
```

## Error Handling

### AppError

```haskell
data AppError
  = AppPolicyError !PolicyError      -- Invalid ordering/concurrency combination
  | AppHandlerError !HandlerError    -- Handler exception or timeout
  | AppRuntimeError !RuntimeError    -- Supervisor failure or inbox overflow
```

## Current Limitations (v0.1.0-alpha)

### Restart Semantics

Failed processors are not automatically restarted. With `IgnoreFailures`, other processors continue running but the failed processor stays stopped. Implement application-level restart logic if needed.
