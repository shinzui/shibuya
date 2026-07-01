# Metrics and Observability

This document describes Shibuya's metrics and introspection capabilities.

## Metrics Types

### ProcessorId

```haskell
newtype ProcessorId = ProcessorId { unProcessorId :: Text }
```

Unique identifier for each processor. Used as key in MetricsMap.

### InFlightInfo

```haskell
data InFlightInfo = InFlightInfo
  { inFlight       :: !Int
  , maxConcurrency :: !Int
  }
```

Tracks the number of handlers currently executing and the configured concurrency limit.

### ProcessorState

```haskell
data ProcessorState
  = Idle
  | Processing !InFlightInfo !UTCTime
  | Failed !Text !UTCTime
  | Stopped
```

| State | Meaning |
|-------|---------|
| `Idle` | Waiting for next message |
| `Processing info time` | Currently processing (tracks in-flight count and max concurrency) |
| `Failed msg time` | Last processing failed with error |
| `Stopped` | Processor has been stopped |

### StreamStats

```haskell
data StreamStats = StreamStats
  { received  :: !Int  -- Messages received from adapter
  , dropped   :: !Int  -- Messages dropped (reserved for future)
  , processed :: !Int  -- Messages successfully processed
  , failed    :: !Int  -- Messages that failed processing
  }
```

Counters for message processing:

| Counter | Incremented When |
|---------|-----------------|
| `received` | Ingester sends message to inbox |
| `dropped` | Reserved for drop-on-full strategy |
| `processed` | Handler returns `AckOk` or `AckRetry` |
| `failed` | Handler returns `AckDeadLetter` or throws |

### BatchStats

```haskell
data BatchStats = BatchStats
  { batchesEmitted  :: !Int  -- batches handed to the batch handler
  , batchedMessages :: !Int  -- total messages across all emitted batches
  , partialFailures :: !Int  -- batches where the handler named >=1 failing message
  , sizeTriggered   :: !Int  -- batches emitted at batchSize
  , timeoutTriggered :: !Int -- batches emitted at batchTimeout
  , flushTriggered  :: !Int  -- batches emitted by a drain/shutdown flush
  }
```

Batch-processing counters, tracked alongside per-message `StreamStats`:

| Counter | Incremented When |
|---------|-----------------|
| `batchesEmitted` | A batch is emitted and handed to the batch handler |
| `batchedMessages` | Add `N` for every emitted batch of `N` messages |
| `partialFailures` | The handler returns normally and names ≥ 1 message with a failing decision (counted per batch, not per message) |
| `sizeTriggered` | A batch is emitted because it reached `batchSize` (`TriggerSize`) |
| `timeoutTriggered` | A batch is emitted because `batchTimeout` elapsed (`TriggerTimeout`) |
| `flushTriggered` | A batch is emitted by a drain/shutdown flush (`TriggerFlush`) |

For a non-batching processor these counters are all zero; for a batching
processor they summarize batch-level activity while `stats` continues to count
per-message outcomes (each message in a batch is finalized individually, so
`stats.processed`/`stats.failed` update exactly as for single-message
processing).

### ProcessorMetrics

```haskell
data ProcessorMetrics = ProcessorMetrics
  { state     :: !ProcessorState
  , stats     :: !StreamStats
  , batch     :: !BatchStats
  , startedAt :: !UTCTime
  }
```

Combined metrics for a single processor.

### MetricsMap

```haskell
type MetricsMap = Map ProcessorId ProcessorMetrics
```

Metrics for all processors, keyed by ID.

## Accessing Metrics

### From AppHandle

```haskell
getAppMetrics :: AppHandle es -> Eff es MetricsMap
```

Get metrics for all processors:

```haskell
appHandle <- runApp ...
metrics <- getAppMetrics appHandle
-- metrics :: Map ProcessorId ProcessorMetrics
```

### From SupervisedProcessor

```haskell
getMetrics        :: SupervisedProcessor -> Eff es ProcessorMetrics
getProcessorState :: SupervisedProcessor -> Eff es ProcessorState
isDone            :: SupervisedProcessor -> Eff es Bool
```

Get metrics for a single processor:

```haskell
sp <- runWithMetrics 100 (ProcessorId "test") adapter handler
metrics <- getMetrics sp
state <- getProcessorState sp
done <- isDone sp
```

### From Master

```haskell
getAllMetrics        :: (IOE :> es) => Master -> Eff es MetricsMap
getProcessorMetrics :: (IOE :> es) => Master -> ProcessorId -> Eff es (Maybe ProcessorMetrics)
```

Direct access via Master handle.

### IO Accessor Functions

For use outside of the `Eff` monad (e.g., from Prometheus metrics callbacks):

```haskell
getAllMetricsIO        :: Master -> IO MetricsMap
getProcessorMetricsIO :: Master -> ProcessorId -> IO (Maybe ProcessorMetrics)
```

## Metrics Flow

```
┌─────────────────────────────────────────────────────────────┐
│                          Master                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │              MetricsMap (TVar)                        │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │  │
│  │  │ proc-1      │  │ proc-2      │  │ proc-3      │   │  │
│  │  │ TVar        │  │ TVar        │  │ TVar        │   │  │
│  │  │ Metrics     │  │ Metrics     │  │ Metrics     │   │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘   │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
         ▲                    ▲                    ▲
         │                    │                    │
    ┌────┴────┐          ┌────┴────┐          ┌────┴────┐
    │Processor│          │Processor│          │Processor│
    │   1     │          │   2     │          │   3     │
    └─────────┘          └─────────┘          └─────────┘
```

Each processor:
1. Creates its own `TVar ProcessorMetrics`
2. Registers TVar with Master on startup
3. Updates TVar directly during processing
4. Unregisters from Master on shutdown

This design allows:
- O(1) metrics reads (no locking needed for reads)
- Processors update their own metrics independently
- Master provides aggregated view

## Example: Monitoring Processing

```haskell
monitorLoop :: AppHandle es -> Eff es ()
monitorLoop appHandle = do
  metrics <- getAppMetrics appHandle
  forM_ (Map.toList metrics) $ \(procId, pm) -> do
    liftIO $ putStrLn $ unpack (unProcessorId procId)
      <> ": received=" <> show pm.stats.received
      <> ", processed=" <> show pm.stats.processed
      <> ", failed=" <> show pm.stats.failed
      <> ", state=" <> show pm.state

  liftIO $ threadDelay 1_000_000  -- 1 second
  monitorLoop appHandle
```

## Supervision Strategies

Shibuya defines its own `SupervisionStrategy` type that maps to NQE strategies internally:

```haskell
data SupervisionStrategy
  = IgnoreFailures     -- Other processors continue if one fails
  | StopAllOnFailure   -- All processors stop if any fails
```

| SupervisionStrategy | NQE Strategy | Behavior |
|---------------------|--------------|----------|
| `IgnoreFailures` | `IgnoreAll` | Keep running, ignore dead children |
| `StopAllOnFailure` | `KillAll` | Stop all children and propagate exception |

Recommended: `IgnoreFailures` for most queue processing (let individual processors fail without affecting others).
