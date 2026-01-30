# PGMQ Adapter Configuration Reference

This document provides a complete reference for all configuration options in the shibuya-pgmq-adapter.

## Table of Contents

- [PgmqAdapterConfig](#pgmqadapterconfig)
- [PollingConfig](#pollingconfig)
- [DeadLetterConfig](#deadletterconfig)
- [FifoConfig](#fifoconfig)
- [PrefetchConfig](#prefetchconfig)
- [Default Configurations](#default-configurations)
- [Configuration Examples](#configuration-examples)
- [Tuning Guidelines](#tuning-guidelines)

## PgmqAdapterConfig

The main configuration record for the pgmq adapter.

```haskell
data PgmqAdapterConfig = PgmqAdapterConfig
  { queueName :: !QueueName,
    visibilityTimeout :: !Int32,
    batchSize :: !Int32,
    polling :: !PollingConfig,
    deadLetterConfig :: !(Maybe DeadLetterConfig),
    maxRetries :: !Int64,
    fifoConfig :: !(Maybe FifoConfig),
    prefetchConfig :: !(Maybe PrefetchConfig)
  }
```

### Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `queueName` | `QueueName` | Required | Name of the pgmq queue to consume from. Use `parseQueueName` to create. |
| `visibilityTimeout` | `Int32` | 30 | Seconds a message is invisible after being read. |
| `batchSize` | `Int32` | 1 | Maximum messages to read per poll. |
| `polling` | `PollingConfig` | `StandardPolling` | Polling strategy (standard or long polling). |
| `deadLetterConfig` | `Maybe DeadLetterConfig` | `Nothing` | Optional dead-letter queue configuration. |
| `maxRetries` | `Int64` | 3 | Maximum retries before auto dead-lettering. |
| `fifoConfig` | `Maybe FifoConfig` | `Nothing` | Optional FIFO ordering configuration. |
| `prefetchConfig` | `Maybe PrefetchConfig` | `Nothing` | Optional concurrent prefetch configuration. |

### queueName

The queue name must be valid according to pgmq naming rules. Use `parseQueueName` to validate:

```haskell
case parseQueueName "my-queue" of
  Left err -> error $ "Invalid queue name: " <> err
  Right name -> defaultConfig name
```

### visibilityTimeout

The visibility timeout determines how long a message is invisible after being read.

- **Too short**: Messages may be processed twice if handlers are slow
- **Too long**: Failed messages take longer to become available for retry

Recommendations:
- Start with 30 seconds
- Set to 2-3x your expected maximum processing time
- Use lease extension for variable-length operations

### batchSize

Number of messages to read per poll. Higher values reduce database round-trips.

- **batchSize = 1**: Simple, one message at a time
- **batchSize = 10-100**: Better throughput for fast handlers
- **batchSize = 1000+**: Maximum throughput (ensure memory available)

Note: All messages in a batch are processed. There is no wastage.

### maxRetries

Based on pgmq's `readCount` field. When a message's `readCount` exceeds `maxRetries`:

1. The adapter automatically dead-letters the message
2. The handler never sees the message
3. No manual retry tracking needed

Set to 0 to disable auto dead-lettering (not recommended).

## PollingConfig

Configures how the adapter polls for messages when the queue may be empty.

```haskell
data PollingConfig
  = StandardPolling { pollInterval :: !NominalDiffTime }
  | LongPolling { maxPollSeconds :: !Int32, pollIntervalMs :: !Int32 }
```

### StandardPolling

Client-side polling with sleep between empty polls.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `pollInterval` | `NominalDiffTime` | 1 second | Sleep duration when no messages available. |

**Behavior**:
1. Poll pgmq for messages
2. If messages found: process them
3. If no messages: sleep for `pollInterval`, then repeat

**Use when**:
- Queue usually has messages
- You want simple, predictable behavior
- You don't mind occasional empty polls

```haskell
polling = StandardPolling { pollInterval = 0.5 }  -- 500ms
```

### LongPolling

Database-side blocking until messages available.

| Field | Type | Description |
|-------|------|-------------|
| `maxPollSeconds` | `Int32` | Maximum seconds to wait for messages. |
| `pollIntervalMs` | `Int32` | Database check interval in milliseconds. |

**Behavior**:
1. Call pgmq's `read_with_poll` function
2. Database blocks checking every `pollIntervalMs` for up to `maxPollSeconds`
3. Returns immediately when messages appear, or timeout with empty result

**Use when**:
- Queue is often empty
- You want to reduce database round-trips
- You accept holding a connection during the wait

```haskell
polling = LongPolling { maxPollSeconds = 10, pollIntervalMs = 100 }
```

**Trade-offs**:
- Holds database connection during wait
- May delay shutdown (must wait for current poll to timeout)
- More efficient when queue is frequently empty

## DeadLetterConfig

Configures dead-letter queue handling when messages fail permanently.

```haskell
data DeadLetterConfig = DeadLetterConfig
  { dlqQueueName :: !QueueName,
    includeMetadata :: !Bool
  }
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `dlqQueueName` | `QueueName` | Name of the dead-letter queue. |
| `includeMetadata` | `Bool` | Whether to include original message metadata. |

### Without DeadLetterConfig

When `deadLetterConfig = Nothing`, dead-lettered messages are archived using pgmq's `archiveMessage`. They remain in the archive table but are not sent to a separate queue.

### With DeadLetterConfig

When configured, dead-lettered messages are:
1. Sent to the DLQ with a new message body
2. Deleted from the original queue

### DLQ Message Format

The DLQ message body is a JSON object:

**With `includeMetadata = True`**:
```json
{
  "original_message": { "order_id": 123, "item": "widget" },
  "dead_letter_reason": "max_retries_exceeded",
  "original_message_id": 456,
  "original_enqueued_at": "2024-01-15T10:30:00Z",
  "read_count": 4,
  "original_headers": { "x-pgmq-group": "customer-1" }
}
```

**With `includeMetadata = False`**:
```json
{
  "original_message": { "order_id": 123, "item": "widget" },
  "dead_letter_reason": "max_retries_exceeded"
}
```

### Dead Letter Reasons

| Reason | Description |
|--------|-------------|
| `max_retries_exceeded` | Message exceeded `maxRetries` |
| `poison_pill: <text>` | Handler returned `AckDeadLetter (PoisonPill text)` |
| `invalid_payload: <text>` | Handler returned `AckDeadLetter (InvalidPayload text)` |

## FifoConfig

Configures FIFO (First-In-First-Out) ordering for grouped messages.

```haskell
data FifoConfig = FifoConfig
  { readStrategy :: !FifoReadStrategy
  }

data FifoReadStrategy
  = ThroughputOptimized
  | RoundRobin
```

### Requirements

- pgmq 1.8.0 or later
- FIFO indexes created on the queue
- Messages must have `x-pgmq-group` header

### ThroughputOptimized

Fills each batch from the same message group before moving to the next.

```
Groups:     A:[1,2,3]  B:[1,2]  C:[1,2,3,4]
Batch 1:    [A:1, A:2, A:3]
Batch 2:    [B:1, B:2, C:1]
Batch 3:    [C:2, C:3, C:4]
```

**Use when**:
- Processing order within a group matters
- You want to complete one group before starting another
- Example: Order processing (process all items for order 1, then order 2)

### RoundRobin

Fair distribution across groups.

```
Groups:     A:[1,2,3]  B:[1,2]  C:[1,2,3,4]
Batch 1:    [A:1, B:1, C:1]
Batch 2:    [A:2, B:2, C:2]
Batch 3:    [A:3, C:3, C:4]
```

**Use when**:
- Fairness across groups is important
- No single group should monopolize processing
- Example: Multi-tenant systems (fair processing across tenants)

### Partition Extraction

The adapter extracts the partition from the `x-pgmq-group` header:

```haskell
extractPartition :: Maybe Value -> Maybe Text
extractPartition headers = do
  Object obj <- headers
  value <- KeyMap.lookup "x-pgmq-group" obj
  case value of
    String group -> Just group
    _ -> Nothing
```

The partition is available in `ingested.envelope.partition`.

## PrefetchConfig

Configures concurrent prefetching to reduce latency.

```haskell
data PrefetchConfig = PrefetchConfig
  { bufferSize :: !Natural
  }
```

### Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `bufferSize` | `Natural` | 4 | Number of batches to buffer ahead. |

### How It Works

Without prefetching:
```
[Poll] -> [Process batch] -> [Poll] -> [Process batch]
  10ms        100ms            10ms        100ms
```

With prefetching:
```
[Poll] ────────────────────────────────►
        [Process batch] [Process batch]
             100ms          100ms
```

Uses Streamly's `parBuffered` to poll concurrently while processing.

### Visibility Timeout Pressure

**Warning**: Prefetched messages have their visibility timeout ticking while buffered.

Calculate safe buffer size:
```
maxBufferedTime = bufferSize * batchSize * avgProcessingTime
visibilityTimeout > maxBufferedTime
```

Example calculation:
```
bufferSize = 4
batchSize = 10
avgProcessingTime = 200ms

maxBufferedTime = 4 * 10 * 200ms = 8 seconds
visibilityTimeout should be > 8 seconds (e.g., 30 seconds)
```

### When to Enable

Enable prefetching when:
- Processing latency matters
- Handler processing time is consistent
- visibilityTimeout is sufficiently large

Avoid prefetching when:
- Handler processing time is highly variable
- visibilityTimeout is tight
- Memory is constrained

## Default Configurations

### defaultConfig

```haskell
defaultConfig :: QueueName -> PgmqAdapterConfig
defaultConfig name = PgmqAdapterConfig
  { queueName = name,
    visibilityTimeout = 30,
    batchSize = 1,
    polling = defaultPollingConfig,
    deadLetterConfig = Nothing,
    maxRetries = 3,
    fifoConfig = Nothing,
    prefetchConfig = Nothing
  }
```

### defaultPollingConfig

```haskell
defaultPollingConfig :: PollingConfig
defaultPollingConfig = StandardPolling { pollInterval = 1 }
```

### defaultPrefetchConfig

```haskell
defaultPrefetchConfig :: PrefetchConfig
defaultPrefetchConfig = PrefetchConfig { bufferSize = 4 }
```

## Configuration Examples

### High-Throughput Processing

```haskell
let config = (defaultConfig queueName)
      { batchSize = 100,
        visibilityTimeout = 120,  -- 2 minutes
        polling = StandardPolling { pollInterval = 0.1 },  -- 100ms
        prefetchConfig = Just PrefetchConfig { bufferSize = 8 }
      }
```

### Low-Latency with DLQ

```haskell
let config = (defaultConfig queueName)
      { batchSize = 10,
        visibilityTimeout = 30,
        polling = LongPolling { maxPollSeconds = 5, pollIntervalMs = 50 },
        deadLetterConfig = Just DeadLetterConfig
            { dlqQueueName = dlqName,
              includeMetadata = True
            },
        maxRetries = 3,
        prefetchConfig = Just defaultPrefetchConfig
      }
```

### Multi-Tenant FIFO

```haskell
let config = (defaultConfig queueName)
      { batchSize = 20,
        visibilityTimeout = 60,
        fifoConfig = Just FifoConfig { readStrategy = RoundRobin },
        maxRetries = 5
      }
```

### Order Processing (Strict FIFO)

```haskell
let config = (defaultConfig queueName)
      { batchSize = 50,
        visibilityTimeout = 300,  -- 5 minutes (orders may take time)
        fifoConfig = Just FifoConfig { readStrategy = ThroughputOptimized },
        deadLetterConfig = Just DeadLetterConfig
            { dlqQueueName = ordersDlq,
              includeMetadata = True
            },
        maxRetries = 3
      }
```

## Tuning Guidelines

### visibilityTimeout

| Workload | Recommended VT |
|----------|----------------|
| Fast handlers (< 1s) | 30 seconds |
| Medium handlers (1-10s) | 60 seconds |
| Long-running (> 10s) | 2-3x expected max time |
| Variable length | Use lease extension |

### batchSize

| Scenario | Recommended Size |
|----------|------------------|
| Simple processing | 1-10 |
| High throughput | 50-200 |
| Maximum throughput | 500-1000 |
| Memory constrained | 10-50 |

### Polling Strategy

| Queue Behavior | Recommended Strategy |
|----------------|----------------------|
| Usually has messages | StandardPolling (100-500ms) |
| Often empty | LongPolling (5-10s max) |
| Bursty | LongPolling with short max |
| High throughput | StandardPolling (10-50ms) |

### Prefetch Buffer

| Processing Time | Recommended Buffer |
|-----------------|-------------------|
| < 100ms avg | 8-16 batches |
| 100-500ms avg | 4-8 batches |
| > 500ms avg | 2-4 batches |
| Highly variable | Disable prefetching |

Remember: `bufferSize * batchSize * avgTime < visibilityTimeout`
