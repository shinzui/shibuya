# Getting Started with Shibuya

Shibuya is a supervised queue processing framework for Haskell. This guide covers the core concepts that apply regardless of which queue adapter you use.

## Writing Handlers

A handler receives a read-only `Message` and returns an `AckDecision`:

```haskell
type Handler es msg = Message es msg -> Eff es AckDecision
```

### The Message Type

```haskell
data Message es msg = Message
  { envelope :: Envelope msg       -- The message with metadata
  , lease    :: Maybe (Lease es)   -- For extending visibility timeout
  }
```

Adapters construct the internal `Ingested` value, which also carries the
adapter's `AckHandle`. Application handlers do not receive that handle; the
framework owns finalization and calls it after the handler returns.

### Accessing Message Data

```haskell
handleMessage :: Handler '[IOE] MyEvent
handleMessage msg = do
  -- Get the payload
  let event = payload (envelope msg)

  -- Access metadata
  let msgId = messageId (envelope msg)
  let maybeCursor = cursor (envelope msg)
  let maybePartition = partition (envelope msg)
  let maybeEnqueuedAt = enqueuedAt (envelope msg)
  let maybeHeaders = headers (envelope msg)      -- All broker headers, if surfaced
  let maybeAttempt = attempt (envelope msg)  -- Just (Attempt 0) on first delivery

  -- Process...
  pure AckOk
```

The envelope also carries `traceContext` (incoming W3C trace headers)
and `attributes` (adapter-supplied OTel span labels). `headers` is the
lossless broker header view, while `traceContext` is only the parsed W3C
projection used to parent the per-message Consumer span. See
[OpenTelemetry Tracing](./opentelemetry.md) for details.

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
pure $ AckDeadLetter (ApplicationFailure recipientOverflowCode "selected 101 recipients; configured limit is 100")

-- Stop processing entirely (for ordered streams)
pure $ AckHalt (HaltOrderedStream "dependency unavailable")
pure $ AckHalt (HaltFatal "unrecoverable error")
```

Choose the reason that truthfully describes the permanent outcome:

- `InvalidPayload detail` means parsing or structural payload validation failed.
- `PoisonPill detail` means the message is permanently unprocessable, for
  example because processing it deterministically crashes an otherwise healthy
  handler.
- `MaxRetriesExceeded` means the retry budget was exhausted.
- `ApplicationFailure code detail` means the payload is valid but a permanent
  application rule rejects it.

Application codes are stable machine-facing identifiers. Validate the finite set
your application uses once during startup, then pass the opaque values into
handlers. Do not call `mkDeadLetterCode` for every message:

```haskell
startRouter :: IO ()
startRouter =
  case mkDeadLetterCode "keiro.router.selection.recipient_overflow" of
    Left err -> fail ("invalid dead-letter configuration: " <> unpack err)
    Right recipientOverflowCode ->
      runRouterApp (mkRouterHandler recipientOverflowCode)

mkRouterHandler :: DeadLetterCode -> Handler es RouterMessage
mkRouterHandler recipientOverflowCode message =
  if selectedRecipientCount message > 100
    then
      pure $
        AckDeadLetter $
          ApplicationFailure
            recipientOverflowCode
            "selected 101 recipients; configured limit is 100"
    else processRouterMessage message
```

A code contains at least two dot-separated lowercase ASCII segments, each
matching `[a-z][a-z0-9_]*`, and is at most 128 characters. The first segment
`shibuya` is reserved. Keep the code taxonomy small and stable. Detail is
transported verbatim for operators, so keep it bounded and do not include
secrets, full payloads, raw SQL, or unrestricted backend error text.

### Example: Robust Handler with Error Handling

```haskell
handleEvent :: Handler '[IOE, Log] MyEvent
handleEvent msg = do
  let event = payload (envelope msg)
  let msgId = unMessageId $ messageId (envelope msg)

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
  => AppConfig                         -- Supervision and inbox size
  -> [(ProcessorId, QueueProcessor es)] -- Named processors
  -> Eff es (Either AppError (AppHandle es))
```

### Single Processor

```haskell
result <- runApp defaultAppConfig
  [ (ProcessorId "orders", ordersProcessor)
  ]
```

### Multiple Processors

```haskell
let config = defaultAppConfig { inboxSize = 500 }

result <- runApp config
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
result <- runApp defaultAppConfig processors

-- All-or-nothing - if one fails, stop everything
result <- runApp defaultAppConfig { strategy = StopAllOnFailure } processors
```

## Batch Processing

Use `mkBatchProcessor` when downstream work is naturally bulk-oriented. The
adapter still emits individual messages; Shibuya groups them by `BatchKey` and
emits a batch on size, timeout, or shutdown flush.

```haskell
batchCfg :: BatchConfig es Order
batchCfg =
  defaultBatchConfig
    { batchSize = 100
    , batchTimeout = 1
    , batchKey = \env -> BatchKey env.payload.customerId
    }

handleBatch :: (IOE :> es) => BatchHandler es Order
handleBatch info messages = do
  result <- liftIO $ bulkInsert (fmap (.envelope.payload) messages)
  pure $ case result of
    Right () -> ackAllOk
    Left failedIds -> failMessages [(mid, InvalidPayload "bulk insert failed") | mid <- failedIds]

let ordersProcessor = mkBatchProcessor ordersAdapter handleBatch batchCfg
```

`BatchHandler` receives `NonEmpty (Message es msg)` and returns `BatchAck`.
`ackAllOk`, `ackAll`, `ackExcept`, `withFallback`, and `failMessages` cover the
common acknowledgement shapes.

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
  , batch     :: !BatchStats      -- Batch counters, zero for non-batching processors
  , startedAt :: !UTCTime         -- When processor started
  }

data ProcessorState
  = Idle                            -- Waiting for messages
  | Processing !InFlightInfo !UTCTime -- (in-flight info, last activity)
  | Failed !Text !UTCTime           -- (error message, when)
  | Stopped

data StreamStats = StreamStats
  { received  :: !Int  -- Total messages received
  , processed :: !Int  -- Successfully processed
  , failed    :: !Int  -- Failed processing
  }

data BatchStats = BatchStats
  { batchesEmitted  :: !Int
  , batchedMessages :: !Int
  , partialFailures :: !Int
  , sizeTriggered   :: !Int
  , timeoutTriggered :: !Int
  , flushTriggered  :: !Int
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
  | AppHandlerError !HandlerError    -- Handler exception
  | AppRuntimeError !RuntimeError    -- Supervisor failure
  | AppBatchConfigError !BatchConfigError
  | AppConfigInvalid !ConfigError
```

## Current Limitations

### Restart Semantics

Failed processors are not automatically restarted. With `IgnoreFailures`, other processors continue running but the failed processor stays stopped. Implement application-level restart logic if needed.
