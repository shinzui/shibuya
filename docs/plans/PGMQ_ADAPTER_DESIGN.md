# PGMQ Adapter Design for Shibuya

## Overview

This document outlines the design for `shibuya-pgmq-adapter`, a Shibuya adapter that integrates with [pgmq](https://github.com/tembo-io/pgmq) (PostgreSQL Message Queue) using the [pgmq-hs](https://github.com/topagentnetwork/pgmq-hs) Haskell client library.

## Background

### What is pgmq?

pgmq is a lightweight message queue built on PostgreSQL. Key characteristics:

- **PostgreSQL-native**: Uses PostgreSQL tables for queue storage
- **Visibility timeout**: Messages become invisible after read, auto-retry on timeout
- **FIFO support**: Grouped message ordering (pgmq 1.8.0+)
- **No built-in DLQ**: Applications must implement dead-letter logic
- **JSON messages**: Payloads stored as JSONB

### What is Shibuya?

Shibuya is a supervised queue processing framework for Haskell that provides:

- **Unified queue abstraction** via the `Adapter` type
- **Backpressure** via bounded inbox
- **Explicit ack semantics** (AckOk, AckRetry, AckDeadLetter, AckHalt)
- **NQE-based supervision** for fault tolerance
- **Metrics and introspection**

## Shibuya Adapter Interface

The adapter interface is a simple record type:

```haskell
-- From Shibuya.Adapter
data Adapter es msg = Adapter
  { adapterName :: !Text,                        -- Name for logging
    source :: Stream (Eff es) (Ingested es msg), -- Message stream
    shutdown :: Eff es ()                        -- Cleanup
  }
```

Each message in the stream is an `Ingested`:

```haskell
data Ingested es msg = Ingested
  { envelope :: !(Envelope msg),    -- Message + metadata
    ack :: !(AckHandle es),         -- Ack callback
    lease :: !(Maybe (Lease es))    -- Optional lease extension
  }
```

## Type Mappings

### Shibuya ↔ pgmq Type Correspondence

| Shibuya Type | pgmq Type | Notes |
|--------------|-----------|-------|
| `MessageId` (Text) | `MessageId` (Int64) | Convert via `show` |
| `Cursor` | `MessageId` (Int64) | Use `CursorInt` variant |
| `Envelope.enqueuedAt` | `Message.enqueuedAt` | Direct mapping |
| `Envelope.payload` | `Message.body` | JSON Value, needs parsing |
| `Envelope.partition` | `headers."x-pgmq-group"` | For FIFO queues |
| `Lease.leaseId` | `MessageId` (Int64) | Convert to Text |
| `Lease.leaseExtend` | `changeVisibilityTimeout` | Extend VT |

### AckDecision ↔ pgmq Operations

| AckDecision | pgmq Operation | Notes |
|-------------|----------------|-------|
| `AckOk` | `deleteMessage` | Permanently remove from queue |
| `AckRetry delay` | `changeVisibilityTimeout` | Extend VT by delay duration |
| `AckDeadLetter reason` | Custom: archive + send to DLQ | pgmq has no built-in DLQ |
| `AckHalt reason` | `changeVisibilityTimeout` (long) | Make message visible later, stop processor |

## Adapter Configuration

```haskell
data PgmqAdapterConfig = PgmqAdapterConfig
  { queueName :: !QueueName,
    -- | Visibility timeout in seconds (default: 30)
    visibilityTimeout :: !Int32,
    -- | Batch size for reads (default: 1)
    batchSize :: !Int32,
    -- | Polling configuration
    polling :: !PollingConfig,
    -- | Dead-letter queue configuration (optional)
    deadLetterConfig :: !(Maybe DeadLetterConfig),
    -- | Maximum retries before dead-lettering (default: 3)
    maxRetries :: !Int64,
    -- | FIFO mode configuration (optional)
    fifoConfig :: !(Maybe FifoConfig)
  }

data PollingConfig
  = -- | Standard polling with sleep between reads
    StandardPolling
      { pollInterval :: !NominalDiffTime  -- e.g., 1 second
      }
  | -- | Long polling (blocks in database)
    LongPolling
      { maxPollSeconds :: !Int32,        -- e.g., 10
        pollIntervalMs :: !Int32         -- e.g., 100
      }

data DeadLetterConfig = DeadLetterConfig
  { dlqQueueName :: !QueueName,
    -- | Whether to include original message metadata
    includeMetadata :: !Bool
  }

data FifoConfig = FifoConfig
  { -- | Reading strategy
    readStrategy :: !FifoReadStrategy
  }

data FifoReadStrategy
  = -- | Fill batch from same group (SQS-like)
    ThroughputOptimized
  | -- | Fair round-robin across groups
    RoundRobin
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Shibuya Application                          │
│                                                                   │
│  runApp → Master → Processor                                      │
│                        │                                          │
│              ┌─────────┴─────────┐                                │
│              │  shibuya-pgmq-adapter                             │
│              │                   │                                │
│              │  ┌───────────────┐│                                │
│              │  │ PgmqAdapter   ││                                │
│              │  │               ││                                │
│              │  │ • source      ││ ← Streamly stream of Ingested  │
│              │  │ • shutdown    ││                                │
│              │  │               ││                                │
│              │  └───────┬───────┘│                                │
│              │          │        │                                │
│              └──────────┼────────┘                                │
│                         │                                         │
└─────────────────────────┼─────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                     pgmq-effectful                               │
│                                                                   │
│  • readMessage / readWithPoll / readGrouped*                      │
│  • deleteMessage                                                  │
│  • changeVisibilityTimeout                                        │
│  • archiveMessage                                                 │
│  • sendMessage (for DLQ)                                          │
│                                                                   │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                     PostgreSQL + pgmq                            │
│                                                                   │
│  • pgmq.read() / pgmq.read_with_poll() / pgmq.read_grouped*()    │
│  • pgmq.delete()                                                  │
│  • pgmq.set_vt()                                                  │
│  • pgmq.archive()                                                 │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

## Implementation Details

### Message Stream

The adapter's `source` produces a Streamly stream that:

1. **Polls pgmq** using `readMessage`, `readWithPoll`, or `readGrouped*`
2. **Converts** each `Pgmq.Message` to `Shibuya.Ingested`
3. **Provides ack callback** that maps `AckDecision` to pgmq operations
4. **Provides lease** for visibility timeout extension

```haskell
pgmqSource ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) (Ingested es Value)
pgmqSource config = Stream.unfoldM pollStep ()
  where
    pollStep () = do
      msgs <- case config.polling of
        StandardPolling interval -> do
          result <- readMessage (mkReadMessage config)
          when (Vector.null result) $
            liftIO $ threadDelay (nominalToMicros interval)
          pure result
        LongPolling maxSec intervalMs ->
          readWithPoll (mkReadWithPoll config maxSec intervalMs)

      case Vector.uncons msgs of
        Nothing -> pure $ Just (Nothing, ())  -- Continue polling
        Just (msg, rest) -> do
          ingested <- mkIngested config msg
          -- Return first message, queue rest for next iterations
          pure $ Just (Just ingested, ())
```

### AckHandle Implementation

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
      -- Successfully processed - delete from queue
      void $ deleteMessage (MessageQuery queueName msgId)

    AckRetry (RetryDelay delay) ->
      -- Retry after delay - extend visibility timeout
      let vtSeconds = ceiling (nominalDiffTimeToSeconds delay)
       in void $ changeVisibilityTimeout
            (VisibilityTimeoutQuery queueName msgId vtSeconds)

    AckDeadLetter reason -> do
      -- Check if DLQ is configured
      case config.deadLetterConfig of
        Nothing ->
          -- No DLQ - just archive the message
          void $ archiveMessage (MessageQuery queueName msgId)
        Just dlqConfig -> do
          -- Send to DLQ with metadata
          let dlqBody = mkDlqBody msg reason dlqConfig.includeMetadata
          void $ sendMessage (SendMessage dlqConfig.dlqQueueName dlqBody)
          -- Delete from original queue
          void $ deleteMessage (MessageQuery queueName msgId)

    AckHalt _reason ->
      -- Halt processing - extend VT far into future so message
      -- becomes visible again after processor restarts
      let vtSeconds = 3600  -- 1 hour
       in void $ changeVisibilityTimeout
            (VisibilityTimeoutQuery queueName msgId vtSeconds)
```

### Lease Implementation

```haskell
mkLease ::
  (Pgmq :> es) =>
  QueueName ->
  Pgmq.MessageId ->
  Lease es
mkLease queueName msgId = Lease
  { leaseId = Text.pack (show (Pgmq.unMessageId msgId)),
    leaseExtend = \duration -> do
      let vtSeconds = ceiling (nominalDiffTimeToSeconds duration)
      void $ changeVisibilityTimeout
        (VisibilityTimeoutQuery queueName msgId vtSeconds)
  }
```

### Retry Logic with readCount

pgmq tracks retry attempts via `readCount`. The adapter should check this:

```haskell
mkIngested ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Pgmq.Message ->
  Eff es (Ingested es Value)
mkIngested config msg = do
  -- Check if max retries exceeded
  when (msg.readCount > config.maxRetries) $ do
    -- Auto dead-letter messages that exceed retry limit
    let ackHandle = mkAckHandle config msg
    ackHandle.finalize (AckDeadLetter MaxRetriesExceeded)
    -- This message won't be returned to the handler

  pure Ingested
    { envelope = mkEnvelope msg,
      ack = mkAckHandle config msg,
      lease = Just (mkLease config.queueName msg.messageId)
    }
```

### Shutdown

```haskell
pgmqShutdown ::
  (IOE :> es) =>
  TVar Bool ->  -- Shutdown signal
  Eff es ()
pgmqShutdown shutdownVar = do
  liftIO $ atomically $ writeTVar shutdownVar True
  -- The polling loop checks this var and exits gracefully
```

## Module Structure

```
shibuya-pgmq-adapter/
├── shibuya-pgmq-adapter.cabal
└── src/
    └── Shibuya/
        └── Adapter/
            ├── Pgmq.hs              -- Main adapter API
            ├── Pgmq/
            │   ├── Config.hs        -- Configuration types
            │   ├── Convert.hs       -- Type conversions
            │   └── Internal.hs      -- Internal implementation
            └── Pgmq.hs              -- Re-exports
```

### Public API

```haskell
module Shibuya.Adapter.Pgmq
  ( -- * Adapter
    pgmqAdapter,

    -- * Configuration
    PgmqAdapterConfig (..),
    PollingConfig (..),
    DeadLetterConfig (..),
    FifoConfig (..),
    FifoReadStrategy (..),

    -- * Defaults
    defaultConfig,
    defaultPollingConfig,

    -- * Re-exports from pgmq
    QueueName,
    parseQueueName,
  ) where
```

### Example Usage

```haskell
import Shibuya.App (runApp, QueueProcessor (..))
import Shibuya.Adapter.Pgmq
import Pgmq.Effectful (runPgmq)
import Hasql.Pool qualified as Pool

main :: IO ()
main = do
  -- Create connection pool
  pool <- Pool.acquire 10 Nothing connectionSettings

  -- Configure adapter
  let config = defaultConfig
        { queueName = "orders",
          visibilityTimeout = 30,
          maxRetries = 3,
          polling = LongPolling
            { maxPollSeconds = 10,
              pollIntervalMs = 100
            },
          deadLetterConfig = Just DeadLetterConfig
            { dlqQueueName = "orders_dlq",
              includeMetadata = True
            }
        }

  -- Run with effectful
  runEff
    . runPgmq pool
    $ do
        adapter <- pgmqAdapter config

        result <- runApp IgnoreFailures 100
          [ (ProcessorId "orders", QueueProcessor adapter handleOrder)
          ]

        case result of
          Left err -> liftIO $ print err
          Right handle -> do
            -- Wait for shutdown signal
            liftIO $ waitForShutdown
            stopApp handle

handleOrder :: Handler es Value
handleOrder ingested = do
  case parseOrder (ingested.envelope.payload) of
    Left err -> pure $ AckDeadLetter (InvalidPayload err)
    Right order -> do
      processOrder order
      pure AckOk
```

## Dependencies

```yaml
build-depends:
  , base            ^>=4.21
  , aeson           ^>=2.2
  , effectful-core  ^>=2.6
  , pgmq-core
  , pgmq-effectful
  , shibuya-core
  , stm
  , streamly        ^>=0.11
  , streamly-core   ^>=0.3
  , text            ^>=2.1
  , time
  , vector          ^>=0.13
```

## Design Decisions

### 1. Effect Integration

**Decision**: Use `Pgmq` effect from pgmq-effectful directly.

**Rationale**:
- Both libraries use effectful
- Allows composition with other effects in the handler
- User controls effect interpretation (pool management)

**Trade-off**: Requires user to run `runPgmq` in their effect stack.

### 2. Polling Strategy

**Decision**: Support both standard and long polling.

**Rationale**:
- Long polling reduces database load when queue is empty
- Standard polling is simpler and works better for high-throughput scenarios
- User chooses based on their workload characteristics

### 3. Dead-Letter Queue

**Decision**: DLQ is optional and application-managed.

**Rationale**:
- pgmq has no built-in DLQ support
- Some applications may prefer archiving over DLQ
- Allows custom DLQ queue names and payload formats

**Implementation**: When `deadLetterConfig` is provided, messages are sent to the DLQ queue before deletion from the main queue.

### 4. FIFO Support

**Decision**: Support all pgmq FIFO read strategies.

**Rationale**:
- pgmq 1.8.0+ provides powerful FIFO capabilities
- Round-robin is better for multi-tenant scenarios
- Throughput-optimized is better for batch processing

**Implementation**: FIFO mode uses `readGrouped` or `readGroupedRoundRobin` based on config.

### 5. Retry Semantics

**Decision**: Use visibility timeout for retries, `readCount` for limits.

**Rationale**:
- Visibility timeout is pgmq's native retry mechanism
- `readCount` provides accurate retry tracking
- Auto dead-letter when `maxRetries` exceeded

**Implementation**: `AckRetry` extends visibility timeout; adapter checks `readCount` before returning message to handler.

### 6. Message Payload Type

**Decision**: Default to `Value` (JSON), allow custom parsing.

**Rationale**:
- pgmq messages are JSONB
- Handlers can parse to domain types as needed
- Could provide typed adapter variant in future

### 7. Batch Processing

**Decision**: Initial implementation processes one message at a time.

**Rationale**:
- Matches Shibuya's current serial processing model
- Batch reads can still be used for efficiency
- Individual ack per message provides better error isolation

**Future**: When Shibuya supports async/ahead modes, batch processing can be revisited.

## Testing Strategy

### Unit Tests

1. **Type conversion tests**: `Pgmq.Message` → `Shibuya.Ingested`
2. **AckHandle tests**: Each `AckDecision` maps to correct pgmq operation
3. **Retry logic tests**: `readCount` tracking and max retry enforcement
4. **Configuration validation**: Invalid configs are rejected

### Integration Tests

1. **End-to-end processing**: Send message, process, verify deleted
2. **Retry behavior**: Message reappears after visibility timeout
3. **DLQ flow**: Failed messages appear in DLQ
4. **FIFO ordering**: Messages in same group processed in order
5. **Lease extension**: Handler can extend visibility timeout
6. **Graceful shutdown**: In-flight messages are not lost

### Test Setup

```haskell
-- Use testcontainers or local PostgreSQL with pgmq extension
withPgmqTestContainer $ \pool -> do
  runEff . runPgmq pool $ do
    createQueue testQueueName
    -- Run tests
    dropQueue testQueueName
```

## Future Enhancements

1. **Typed payloads**: `pgmqAdapter @MyMessage` with automatic JSON parsing
2. **Batch acking**: Accumulate acks and batch delete for throughput
3. **Metrics integration**: Expose pgmq queue metrics to shibuya-metrics
4. **Notification-based polling**: Use `pgmq.enable_notify_insert` for push-style
5. **Partitioned queues**: Support for pgmq partitioned queue creation
6. **Connection pool sharing**: Multiple adapters share single pool

## References

- [pgmq GitHub](https://github.com/tembo-io/pgmq)
- [pgmq-hs GitHub](https://github.com/topagentnetwork/pgmq-hs)
- [Shibuya Architecture](../architecture/MESSAGE_FLOW.md)
- [pgmq SQL Functions](https://tembo.io/pgmq/api/sql/functions/)
