# PGMQ Adapter: Advanced Configuration

This guide covers FIFO ordering, concurrent prefetching, lease extension, and tuning.

## FIFO Ordering

pgmq 1.8.0+ supports grouped message ordering via the `x-pgmq-group` header.

### Setup

```haskell
let config = (defaultConfig queueName)
      { fifoConfig = Just FifoConfig
          { readStrategy = RoundRobin  -- or ThroughputOptimized
          }
      }
```

Messages must have the `x-pgmq-group` header. The adapter extracts it and exposes it as `ingested.envelope.partition`.

### ThroughputOptimized

Fills each batch from the same group before moving to the next:

```
Groups:     A:[1,2,3]  B:[1,2]  C:[1,2,3,4]
Batch 1:    [A:1, A:2, A:3]
Batch 2:    [B:1, B:2, C:1]
Batch 3:    [C:2, C:3, C:4]
```

Best for: order processing, document workflows - when completing one group matters.

### RoundRobin

Fair distribution across groups:

```
Groups:     A:[1,2,3]  B:[1,2]  C:[1,2,3,4]
Batch 1:    [A:1, B:1, C:1]
Batch 2:    [A:2, B:2, C:2]
Batch 3:    [A:3, C:3, C:4]
```

Best for: multi-tenant systems, load balancing - when fairness across groups matters.

## Concurrent Prefetching

Prefetching polls the next batch while the current one is being processed, reducing latency.

### Enabling Prefetch

```haskell
let config = (defaultConfig queueName)
      { prefetchConfig = Just defaultPrefetchConfig,  -- bufferSize = 4
        batchSize = 10
      }
```

### Custom Buffer Size

```haskell
let config = (defaultConfig queueName)
      { prefetchConfig = Just PrefetchConfig { bufferSize = 8 }
      }
```

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

### Visibility Timeout Safety

Prefetched messages have their visibility timeout ticking while buffered. Ensure:

```
bufferSize * batchSize * avgProcessingTime < visibilityTimeout
```

Example:
```
bufferSize = 4, batchSize = 10, avgProcessingTime = 200ms
maxBufferedTime = 4 * 10 * 200ms = 8 seconds
visibilityTimeout should be > 8 seconds (e.g., 30 seconds)
```

### When to Enable

| Scenario | Recommendation |
|----------|---------------|
| Processing latency matters | Enable |
| Consistent handler processing time | Enable |
| Highly variable processing time | Avoid |
| Tight visibility timeout | Avoid |
| Memory constrained | Avoid |

## Lease Extension

For queues with visibility timeouts, extend the lease for long-running operations:

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

The PGMQ adapter always provides a lease. Extending the lease calls `changeVisibilityTimeout` to push the message's VT into the future.

## Tuning Guidelines

### Visibility Timeout

| Workload | Recommended VT |
|----------|----------------|
| Fast handlers (< 1s) | 30 seconds |
| Medium handlers (1-10s) | 60 seconds |
| Long-running (> 10s) | 2-3x expected max time |
| Variable length | Use lease extension |

### Batch Size

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

### Multi-Tenant FIFO

```haskell
let config = (defaultConfig queueName)
      { batchSize = 20,
        visibilityTimeout = 60,
        fifoConfig = Just FifoConfig { readStrategy = RoundRobin },
        maxRetries = 5
      }
```

### Order Processing (Strict FIFO with DLQ)

```haskell
let config = (defaultConfig queueName)
      { batchSize = 50,
        visibilityTimeout = 300,  -- 5 minutes
        fifoConfig = Just FifoConfig { readStrategy = ThroughputOptimized },
        deadLetterConfig = Just $ directDeadLetter ordersDlq True,
        maxRetries = 3
      }
```
