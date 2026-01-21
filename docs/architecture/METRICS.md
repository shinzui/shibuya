# Metrics and Observability

This document describes Shibuya's metrics and introspection capabilities.

## Metrics Types

### ProcessorId

```haskell
newtype ProcessorId = ProcessorId { unProcessorId :: Text }
```

Unique identifier for each processor. Used as key in MetricsMap.

### ProcessorState

```haskell
data ProcessorState
  = Idle
  | Processing !Int !UTCTime
  | Failed !Text !UTCTime
  | Stopped
```

| State | Meaning |
|-------|---------|
| `Idle` | Waiting for next message |
| `Processing count time` | Currently processing message #count |
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

### ProcessorMetrics

```haskell
data ProcessorMetrics = ProcessorMetrics
  { state     :: !ProcessorState
  , stats     :: !StreamStats
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
getAllMetrics       :: Master -> Eff es MetricsMap
getProcessorMetrics :: Master -> ProcessorId -> Eff es (Maybe ProcessorMetrics)
```

Direct access via Master handle.

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

From NQE's `Strategy`:

```haskell
data Strategy
  = Notify (Listen (Child, Maybe SomeException))
  | KillAll
  | IgnoreGraceful
  | IgnoreAll
```

| Strategy | On Child Failure |
|----------|-----------------|
| `Notify callback` | Notify via callback, continue others |
| `KillAll` | Kill all children |
| `IgnoreGraceful` | Ignore normal exits, notify on exceptions |
| `IgnoreAll` | Ignore all exits |

Recommended: `IgnoreAll` for most queue processing (let individual messages fail without affecting others).
