# Multi-Queue Processing Design

## Overview

This document analyzes the design for `runApp`, which enables a single Shibuya application to process messages from multiple independent queues concurrently.

## Current State

The existing infrastructure already supports multi-queue processing internally:

```
┌─────────────────────────────────────────────────────┐
│                      Master                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │ MetricsMap  │  │ Supervisor  │  │   Inbox     │  │
│  │  (TVar)     │  │   (NQE)     │  │ (messages)  │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  │
└─────────────────────────────────────────────────────┘
         │                 │
         │    ┌────────────┼────────────┐
         │    │            │            │
         ▼    ▼            ▼            ▼
    ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
    │ Processor 1 │  │ Processor 2 │  │ Processor N │
    │ (Adapter A) │  │ (Adapter B) │  │ (Adapter C) │
    │  + Handler  │  │  + Handler  │  │  + Handler  │
    │  + Metrics  │  │  + Metrics  │  │  + Metrics  │
    └─────────────┘  └─────────────┘  └─────────────┘
```

**Existing components:**
- `Master` - Coordinator process managing child processors
- `Supervisor` (NQE) - Restarts failed children based on strategy
- `runSupervised` - Spawns adapter+handler as supervised child
- `ProcessorMetrics` - Per-processor stats (received, processed, failed)

**Gap:** `runApp` only accepts a single `RunnerConfig` and uses `runSerial` directly.

## Proposed API

### Option 1: List of RunnerConfigs (Homogeneous message type)

```haskell
runApp ::
  (IOE :> es) =>
  Strategy ->
  [RunnerConfig es msg] ->
  Eff es (Either AppError AppHandle)
```

**Limitation:** All adapters must produce the same message type `msg`.

### Option 2: Existential wrapper (Heterogeneous message types)

```haskell
data SomeAdapter es where
  SomeAdapter :: Adapter es msg -> Handler es msg -> SomeAdapter es

runApp ::
  (IOE :> es) =>
  Strategy ->
  [(ProcessorId, SomeAdapter es)] ->
  Eff es (Either AppError AppHandle)
```

**Benefit:** Each adapter can have its own message type.

### Option 3: Builder pattern

```haskell
data AppBuilder es = AppBuilder
  { processors :: [(ProcessorId, SomeAdapter es)]
  , strategy :: Strategy
  , ...
  }

buildApp :: AppBuilder es -> Eff es (Either AppError AppHandle)

-- Usage:
app <- buildApp $
  defaultAppBuilder
    & addProcessor "orders" ordersAdapter ordersHandler
    & addProcessor "events" eventsAdapter eventsHandler
    & withStrategy OneForOne
```

## Recommended: Option 2 with Named Processors

```haskell
-- | Wrapper for adapter + handler pair with hidden message type.
data QueueProcessor es where
  QueueProcessor ::
    { adapter :: Adapter es msg
    , handler :: Handler es msg
    } -> QueueProcessor es

-- | Handle for a running multi-queue application.
data AppHandle = AppHandle
  { master :: Master
  , processors :: Map ProcessorId SupervisedProcessor
  }

-- | Run multiple queue processors concurrently.
runApp ::
  (IOE :> es) =>
  -- | Supervision strategy (OneForOne, AllForOne, etc.)
  Strategy ->
  -- | Named processors
  [(ProcessorId, QueueProcessor es)] ->
  Eff es (Either AppError AppHandle)
```

## Implementation Sketch

```haskell
runApp strategy namedProcessors = do
  -- 1. Validate all processor configs
  for_ namedProcessors $ \(_, QueueProcessor{..}) ->
    validatePolicy ...

  -- 2. Start the Master coordinator
  master <- startMaster strategy

  -- 3. Spawn each processor under supervision
  processors <- for namedProcessors $ \(procId, QueueProcessor{adapter, handler}) ->
    (procId,) <$> runSupervised master inboxSize procId adapter handler

  -- 4. Return handle for introspection/control
  pure $ Right AppHandle
    { master = master
    , processors = Map.fromList processors
    }
```

## AppHandle API

```haskell
-- | Get metrics for all processors.
getAppMetrics :: AppHandle -> Eff es (Map ProcessorId ProcessorMetrics)

-- | Get metrics for a specific processor.
getProcessorMetrics :: AppHandle -> ProcessorId -> Eff es (Maybe ProcessorMetrics)

-- | Gracefully stop all processors.
stopApp :: AppHandle -> Eff es ()

-- | Wait for all processors to complete (for finite streams).
waitApp :: AppHandle -> Eff es ()
```

## Supervision Strategies

The NQE Supervisor supports:

| Strategy | Behavior |
|----------|----------|
| `OneForOne` | Only restart the failed child |
| `AllForOne` | Restart all children if one fails |
| `RestForOne` | Restart failed child and all started after it |

For independent queues, `OneForOne` is typically correct - a failure in the orders queue shouldn't affect the events queue.

## Example Usage

```haskell
main :: IO ()
main = runEff $ do
  -- Define processors
  let ordersProc = QueueProcessor
        { adapter = sqsAdapter "orders-queue"
        , handler = ordersHandler
        }
      eventsProc = QueueProcessor
        { adapter = sqsAdapter "events-queue"
        , handler = eventsHandler
        }

  -- Run all processors
  result <- runApp OneForOne
    [ ("orders", ordersProc)
    , ("events", eventsProc)
    ]

  case result of
    Left err -> print err
    Right appHandle -> do
      -- Introspect
      metrics <- getAppMetrics appHandle
      print metrics

      -- Wait or do other work...
      waitApp appHandle
```

## Open Questions

1. **Shared handler vs per-adapter handler?**
   - Current design: Each adapter has its own handler
   - Alternative: Single handler that pattern-matches on source
   - Recommendation: Per-adapter is more type-safe and flexible

2. **Dynamic processor management?**
   - Should we support adding/removing processors at runtime?
   - Could expose `addProcessor :: AppHandle -> ProcessorId -> QueueProcessor es -> Eff es ()`
   - Adds complexity; defer to future iteration

3. **Backpressure configuration?**
   - Current: Global `inboxSize`
   - Could be per-processor for different throughput characteristics
   - Add to `QueueProcessor` if needed

4. **Graceful shutdown ordering?**
   - Should processors shut down in a specific order?
   - For independent queues, parallel shutdown is fine
   - May need ordered shutdown for dependent processors (future)

## Migration Path

1. Add `QueueProcessor` and `AppHandle` types
2. Implement `runApp` using existing `Master` + `runSupervised`
3. Add `AppHandle` introspection functions
4. Update example to demonstrate multi-queue
5. Consider deprecating single-adapter `runApp` in favor of `runApp` with single-element list
