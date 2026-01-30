# PGMQ Adapter Internals

This document provides detailed implementation information for developers auditing or extending the shibuya-pgmq-adapter code.

## Table of Contents

- [Module Overview](#module-overview)
- [Public API (Pgmq.hs)](#public-api-pgmqhs)
- [Configuration (Config.hs)](#configuration-confighs)
- [Type Conversions (Convert.hs)](#type-conversions-converths)
- [Stream Implementation (Internal.hs)](#stream-implementation-internalhs)
- [pgmq-effectful Integration](#pgmq-effectful-integration)
- [Error Handling](#error-handling)
- [Thread Safety](#thread-safety)
- [Performance Considerations](#performance-considerations)
- [Test Coverage](#test-coverage)

## Module Overview

```
Shibuya.Adapter.Pgmq (Public API)
       │
       ├─► Shibuya.Adapter.Pgmq.Config (Configuration types)
       │
       ├─► Shibuya.Adapter.Pgmq.Convert (Type conversions)
       │
       └─► Shibuya.Adapter.Pgmq.Internal (Stream + ack implementation)
                     │
                     └─► Uses: pgmq-effectful, streamly, shibuya-core
```

### Dependency Flow

```haskell
-- Config.hs: No internal dependencies
import Pgmq.Types (QueueName)

-- Convert.hs: No internal dependencies
import Pgmq.Types qualified as Pgmq
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))

-- Internal.hs: Depends on Config and Convert
import Shibuya.Adapter.Pgmq.Config
import Shibuya.Adapter.Pgmq.Convert

-- Pgmq.hs: Depends on Config and Internal
import Shibuya.Adapter.Pgmq.Config
import Shibuya.Adapter.Pgmq.Internal
```

## Public API (Pgmq.hs)

**Location**: `src/Shibuya/Adapter/Pgmq.hs`

### pgmqAdapter

```haskell
pgmqAdapter ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Eff es (Adapter es Value)
```

**Implementation details**:

1. Creates a shutdown TVar for graceful termination
2. Selects stream source based on prefetch configuration
3. Wraps source with shutdown checking
4. Returns Adapter record

```haskell
pgmqAdapter config = do
  -- Shutdown signal: TVar Bool, starts False
  shutdownVar <- liftIO $ newTVarIO False

  -- Select source based on prefetch config
  let messageSource = case config.prefetchConfig of
        Nothing ->
          pgmqSource config  -- Sequential polling
        Just prefetch ->
          let prefetchSettings = StreamP.maxBuffer (fromIntegral prefetch.bufferSize)
           in pgmqSourceWithPrefetch prefetchSettings config  -- Concurrent

  pure Adapter
    { adapterName = "pgmq:" <> queueNameToText config.queueName,
      source = takeUntilShutdown shutdownVar messageSource,
      shutdown = liftIO $ atomically $ writeTVar shutdownVar True
    }
```

### takeUntilShutdown

```haskell
takeUntilShutdown ::
  (IOE :> es) =>
  TVar Bool ->
  Stream (Eff es) a ->
  Stream (Eff es) a
takeUntilShutdown shutdownVar =
  Stream.takeWhileM $ \_ -> do
    isShutdown <- liftIO $ atomically $ readTVar shutdownVar
    pure (not isShutdown)
```

**Behavior**: Checks the shutdown flag after each element. When `True`, the stream terminates.

**Note**: Uses `takeWhileM` not `takeWhile` because the predicate runs in `Eff es`.

## Configuration (Config.hs)

**Location**: `src/Shibuya/Adapter/Pgmq/Config.hs`

All configuration types are pure data with `Generic` deriving:

```haskell
data PgmqAdapterConfig = PgmqAdapterConfig { ... }
  deriving stock (Show, Eq, Generic)

data PollingConfig = StandardPolling { ... } | LongPolling { ... }
  deriving stock (Show, Eq, Generic)

data DeadLetterConfig = DeadLetterConfig { ... }
  deriving stock (Show, Eq, Generic)

data FifoConfig = FifoConfig { ... }
  deriving stock (Show, Eq, Generic)

data FifoReadStrategy = ThroughputOptimized | RoundRobin
  deriving stock (Show, Eq, Generic)

data PrefetchConfig = PrefetchConfig { ... }
  deriving stock (Show, Eq, Generic)
```

### Type Choices

| Field | Type | Rationale |
|-------|------|-----------|
| `visibilityTimeout` | `Int32` | Matches pgmq SQL parameter type |
| `batchSize` | `Int32` | Matches pgmq SQL parameter type |
| `maxRetries` | `Int64` | Matches pgmq `readCount` type |
| `pollInterval` | `NominalDiffTime` | Standard Haskell time difference |
| `bufferSize` | `Natural` | Non-negative, arbitrary precision |

## Type Conversions (Convert.hs)

**Location**: `src/Shibuya/Adapter/Pgmq/Convert.hs`

### messageIdToShibuya

```haskell
messageIdToShibuya :: Pgmq.MessageId -> MessageId
messageIdToShibuya (Pgmq.MessageId i) = MessageId (Text.pack (show i))
```

Converts Int64 to Text. Lossless for all Int64 values.

### messageIdToPgmq

```haskell
messageIdToPgmq :: MessageId -> Maybe Pgmq.MessageId
messageIdToPgmq (MessageId t) = Pgmq.MessageId <$> readMaybe (Text.unpack t)
  where
    readMaybe :: String -> Maybe Int64
    readMaybe s = case reads s of
      [(x, "")] -> Just x  -- Must consume entire string
      _ -> Nothing
```

Uses `reads` with empty-string check to ensure complete parse. Returns `Nothing` for:
- Non-numeric text
- Overflow values
- Trailing characters

### pgmqMessageIdToCursor

```haskell
pgmqMessageIdToCursor :: Pgmq.MessageId -> Cursor
pgmqMessageIdToCursor (Pgmq.MessageId i) = CursorInt (fromIntegral i)
```

Uses `CursorInt` variant since pgmq message IDs are sequential integers.

### extractPartition

```haskell
extractPartition :: Maybe Value -> Maybe Text
extractPartition headers = do
  Object obj <- headers      -- Pattern match on Object
  value <- KeyMap.lookup (Key.fromText "x-pgmq-group") obj
  case value of
    String group -> Just group
    _ -> Nothing             -- Non-string values ignored
```

FIFO partition comes from the `x-pgmq-group` header. Returns `Nothing` if:
- Headers are `Nothing`
- Headers are not a JSON Object
- Key is missing
- Value is not a String

### pgmqMessageToEnvelope

```haskell
pgmqMessageToEnvelope :: Pgmq.Message -> Envelope Value
pgmqMessageToEnvelope msg =
  Envelope
    { messageId = messageIdToShibuya msg.messageId,
      cursor = Just (pgmqMessageIdToCursor msg.messageId),
      partition = extractPartition msg.headers,
      enqueuedAt = Just msg.enqueuedAt,
      payload = Pgmq.unMessageBody msg.body
    }
```

All fields are populated. The payload is the raw JSON `Value` from pgmq.

### mkDlqPayload

```haskell
mkDlqPayload :: Pgmq.Message -> DeadLetterReason -> Bool -> Pgmq.MessageBody
mkDlqPayload msg reason includeMetadata =
  Pgmq.MessageBody $
    object $
      [ "original_message" .= Pgmq.unMessageBody msg.body,
        "dead_letter_reason" .= reasonToText reason
      ]
        ++ metadataFields
  where
    metadataFields
      | includeMetadata =
          [ "original_message_id" .= Pgmq.unMessageId msg.messageId,
            "original_enqueued_at" .= msg.enqueuedAt,
            "read_count" .= msg.readCount,
            "original_headers" .= msg.headers
          ]
      | otherwise = []

    reasonToText :: DeadLetterReason -> Text
    reasonToText = \case
      PoisonPill t -> "poison_pill: " <> t
      InvalidPayload t -> "invalid_payload: " <> t
      MaxRetriesExceeded -> "max_retries_exceeded"
```

Constructs JSON object for DLQ. Metadata fields are conditionally included.

## Stream Implementation (Internal.hs)

**Location**: `src/Shibuya/Adapter/Pgmq/Internal.hs`

### Query Constructors

Four functions create pgmq query types:

```haskell
mkReadMessage :: PgmqAdapterConfig -> ReadMessage
mkReadMessage config =
  ReadMessage
    { queueName = config.queueName,
      delay = config.visibilityTimeout,  -- VT in seconds
      batchSize = Just config.batchSize,
      conditional = Nothing              -- No conditional reads
    }

mkReadWithPoll :: PgmqAdapterConfig -> Int32 -> Int32 -> ReadWithPollMessage
mkReadWithPoll config maxSec intervalMs =
  ReadWithPollMessage
    { queueName = config.queueName,
      delay = config.visibilityTimeout,
      batchSize = Just config.batchSize,
      maxPollSeconds = maxSec,
      pollIntervalMs = intervalMs,
      conditional = Nothing
    }

mkReadGrouped :: PgmqAdapterConfig -> ReadGrouped
mkReadGrouped config =
  ReadGrouped
    { queueName = config.queueName,
      visibilityTimeout = config.visibilityTimeout,
      qty = config.batchSize
    }

mkReadGroupedWithPoll :: PgmqAdapterConfig -> Int32 -> Int32 -> ReadGroupedWithPoll
mkReadGroupedWithPoll config maxSec intervalMs =
  ReadGroupedWithPoll
    { queueName = config.queueName,
      visibilityTimeout = config.visibilityTimeout,
      qty = config.batchSize,
      maxPollSeconds = maxSec,
      pollIntervalMs = intervalMs
    }
```

### pgmqChunks

The core polling loop:

```haskell
pgmqChunks ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) (Vector Pgmq.Message)
pgmqChunks config = Stream.repeatM poll
```

The `poll` function handles all four mode combinations:

```haskell
poll :: Eff es (Vector Pgmq.Message)
poll = case config.fifoConfig of
  Nothing -> pollNonFifo
  Just fifo -> pollFifo fifo

pollNonFifo = case config.polling of
  StandardPolling interval -> do
    result <- readMessage (mkReadMessage config)
    when (Vector.null result) $
      liftIO $ threadDelay (nominalToMicros interval)
    pure result
  LongPolling maxSec intervalMs ->
    readWithPoll (mkReadWithPoll config maxSec intervalMs)

pollFifo fifo = case config.polling of
  StandardPolling interval -> do
    result <- case fifo.readStrategy of
      ThroughputOptimized -> readGrouped (mkReadGrouped config)
      RoundRobin -> readGroupedRoundRobin (mkReadGrouped config)
    when (Vector.null result) $
      liftIO $ threadDelay (nominalToMicros interval)
    pure result
  LongPolling maxSec intervalMs ->
    case fifo.readStrategy of
      ThroughputOptimized ->
        readGroupedWithPoll (mkReadGroupedWithPoll config maxSec intervalMs)
      RoundRobin ->
        readGroupedRoundRobinWithPoll (mkReadGroupedWithPoll config maxSec intervalMs)
```

### Batch Flattening

```haskell
pgmqMessages ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) Pgmq.Message
pgmqMessages config =
  pgmqChunks config
    & Stream.filter (not . Vector.null)  -- Skip empty batches
    & Stream.unfoldEach vectorUnfold     -- Expand Vector to stream
  where
    vectorUnfold = Unfold.unfoldr Vector.uncons
```

**Key implementation detail**: `Stream.unfoldEach vectorUnfold` is critical for correct behavior.

`vectorUnfold` uses `Unfold.unfoldr Vector.uncons`:
- `Vector.uncons :: Vector a -> Maybe (a, Vector a)`
- Returns `Just (head, tail)` or `Nothing` when empty
- `Unfold.unfoldr` creates an `Unfold` from this step function

This ensures every element in every batch is yielded to the stream.

### mkIngested

```haskell
mkIngested ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Pgmq.Message ->
  Eff es (Maybe (Ingested es Value))
mkIngested config msg = do
  if msg.readCount > config.maxRetries
    then do
      -- Auto dead-letter
      let ackHandle = mkAckHandle config msg
      ackHandle.finalize (AckDeadLetter MaxRetriesExceeded)
      pure Nothing  -- Filter from stream
    else
      pure $ Just Ingested
        { envelope = pgmqMessageToEnvelope msg,
          ack = mkAckHandle config msg,
          lease = Just (mkLease config.queueName msg.messageId)
        }
```

**Auto-DLQ logic**:
1. Compare `readCount` to `maxRetries` (using `>`, not `>=`)
2. If exceeded, create ack handle and call `finalize` with `MaxRetriesExceeded`
3. Return `Nothing` to filter message from stream

This means a message with `maxRetries = 3` is dead-lettered on the 4th read.

### mkAckHandle

```haskell
mkAckHandle ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Pgmq.Message ->
  AckHandle es
mkAckHandle config msg = AckHandle $ \decision -> do
  let queueName = config.queueName
      msgId = msg.messageId

  case decision of
    AckOk ->
      void $ deleteMessage (MessageQuery queueName msgId)

    AckRetry (RetryDelay delay) -> do
      let vtSeconds = nominalToSeconds delay
      void $ changeVisibilityTimeout $ VisibilityTimeoutQuery
        { queueName = queueName,
          messageId = msgId,
          visibilityTimeoutOffset = vtSeconds
        }

    AckDeadLetter reason -> do
      case config.deadLetterConfig of
        Nothing ->
          void $ archiveMessage (MessageQuery queueName msgId)
        Just dlqConfig -> do
          let dlqBody = mkDlqPayload msg reason dlqConfig.includeMetadata
          void $ sendMessage $ SendMessage
            { queueName = dlqConfig.dlqQueueName,
              messageBody = dlqBody,
              delay = Nothing
            }
          void $ deleteMessage (MessageQuery queueName msgId)

    AckHalt _reason -> do
      let vtSeconds = 3600 :: Int32  -- 1 hour
      void $ changeVisibilityTimeout $ VisibilityTimeoutQuery
        { queueName = queueName,
          messageId = msgId,
          visibilityTimeoutOffset = vtSeconds
        }
  where
    void = fmap (const ())  -- Local definition to avoid import
```

**Note**: `void` is defined locally rather than imported from `Control.Monad`.

### mkLease

```haskell
mkLease ::
  (Pgmq :> es) =>
  Pgmq.QueueName ->
  Pgmq.MessageId ->
  Lease es
mkLease queueName msgId = Lease
  { leaseId = Text.pack (show (Pgmq.unMessageId msgId)),
    leaseExtend = \duration -> do
      let vtSeconds = nominalToSeconds duration
      _ <- changeVisibilityTimeout $ VisibilityTimeoutQuery
        { queueName = queueName,
          messageId = msgId,
          visibilityTimeoutOffset = vtSeconds
        }
      pure ()
  }
```

The `leaseExtend` function can be called by handlers to extend visibility timeout.

### nominalToSeconds

```haskell
nominalToSeconds :: NominalDiffTime -> Int32
nominalToSeconds = ceiling . nominalDiffTimeToSeconds
```

Uses `ceiling` to round up. A 1.1 second delay becomes 2 seconds in pgmq.

### Prefetch Variants

```haskell
pgmqChunksPrefetch ::
  (Pgmq :> es, IOE :> es) =>
  (StreamP.Config -> StreamP.Config) ->
  PgmqAdapterConfig ->
  Stream (Eff es) (Vector Pgmq.Message)
pgmqChunksPrefetch prefetchConfig config =
  pgmqChunks config
    & StreamP.parBuffered prefetchConfig
```

`parBuffered` runs the upstream concurrently, buffering results.

## pgmq-effectful Integration

The adapter uses these pgmq-effectful functions:

| Function | Purpose | Used by |
|----------|---------|---------|
| `readMessage` | Read messages (standard) | `pollNonFifo` |
| `readWithPoll` | Read with database blocking | `pollNonFifo` |
| `readGrouped` | FIFO read (throughput) | `pollFifo` |
| `readGroupedRoundRobin` | FIFO read (round-robin) | `pollFifo` |
| `readGroupedWithPoll` | FIFO + long poll (throughput) | `pollFifo` |
| `readGroupedRoundRobinWithPoll` | FIFO + long poll (round-robin) | `pollFifo` |
| `deleteMessage` | Delete processed message | `mkAckHandle` (AckOk, DLQ) |
| `archiveMessage` | Archive without DLQ | `mkAckHandle` (DLQ fallback) |
| `changeVisibilityTimeout` | Extend/set VT | `mkAckHandle`, `mkLease` |
| `sendMessage` | Send to DLQ | `mkAckHandle` (DLQ) |

## Error Handling

### Effect-Based Errors

pgmq operations can throw exceptions through the effect system. The adapter does not catch these explicitly - they propagate to the Shibuya supervisor for restart.

### Auto-DLQ as Defensive Programming

Messages that exceed `maxRetries` are automatically dead-lettered in `mkIngested`. This prevents:
- Infinite retry loops
- Poison pills blocking the queue
- Handler having to track retry counts

## Thread Safety

### TVar for Shutdown

The shutdown mechanism uses `TVar Bool` with STM:

```haskell
shutdownVar <- newTVarIO False
-- ...
shutdown = liftIO $ atomically $ writeTVar shutdownVar True
-- ...
Stream.takeWhileM $ \_ -> do
  isShutdown <- liftIO $ atomically $ readTVar shutdownVar
  pure (not isShutdown)
```

STM ensures atomic reads/writes. No race conditions between shutdown signal and stream consumption.

### Streamly Concurrency

`parBuffered` handles its own thread safety internally. The adapter doesn't need additional synchronization.

## Performance Considerations

### Batch Efficiency

After the optimization, all messages in each batch are processed:

| Batch Size | Messages per Poll | DB Roundtrips per N Messages |
|------------|-------------------|------------------------------|
| 1 | 1 | N |
| 10 | 10 | N/10 |
| 100 | 100 | N/100 |

### Memory Usage

Memory usage scales with:
- `batchSize` - size of each Vector
- `bufferSize` (prefetch) - number of buffered Vectors
- Shibuya inbox size - messages waiting for handler

Worst-case buffered messages: `batchSize * bufferSize + inboxSize`

### CPU Overhead

Main sources of CPU usage:
1. JSON parsing (handled by aeson)
2. Stream transformations (Streamly optimized)
3. TVar reads for shutdown check (cheap)

## Test Coverage

Tests are in `test/Shibuya/Adapter/Pgmq/ConvertSpec.hs`:

### Property Tests

| Test | Property |
|------|----------|
| `messageIdToShibuya/messageIdToPgmq` | Roundtrip for all Int64 |
| `pgmqMessageIdToCursor` | Correct CursorInt value |

### Unit Tests

| Test | Coverage |
|------|----------|
| Envelope construction | All fields populated correctly |
| Partition extraction | Handles missing/malformed headers |
| DLQ payload with metadata | All metadata fields present |
| DLQ payload without metadata | Only required fields |
| Reason text conversion | All DeadLetterReason variants |

### Integration Tests (Recommended)

Not currently implemented but recommended:

1. End-to-end message processing
2. Visibility timeout behavior
3. DLQ flow
4. FIFO ordering verification
5. Prefetch latency measurement
6. Graceful shutdown with in-flight messages

Would require PostgreSQL with pgmq extension (testcontainers recommended).
