<p align="center">
  <img src="docs/images/shibuya-logo.png" alt="Shibuya" width="800"><br>
  A supervised queue processing framework inspired by <a href="https://github.com/dashbitco/broadway">Broadway</a>
</p>

---

> **⚠️ Work in Progress**
>
> Shibuya is under active development and not yet complete. The API may change significantly before the first stable release. 

---

Shibuya provides a unified abstraction over various message queue backends (Kafka, PostgreSQL queues, SQS, Redis) with built-in supervision, backpressure, and composable stream transformations.

## Features

- **Unified Queue Abstraction** - Write handlers once, swap queue backends freely
- **Supervised Processing** - Failure isolation via NQE supervision
- **Backpressure** - Bounded inboxes prevent memory exhaustion
- **Explicit Ack Semantics** - Handlers express intent (ack, retry, dead-letter, halt), framework handles mechanics
- **Metrics & Introspection** - Real-time visibility into processor state and statistics
- **Stream Transformations** - Composable pipelines powered by Streamly
- **Effectful** - All effects tracked via the Effectful library

### Current Status (v0.1.0-alpha)

| Feature | Status |
|---------|--------|
| Serial Processing | ✅ Implemented |
| Backpressure (bounded inbox) | ✅ Implemented |
| Ack Semantics (Ok/Retry/DLQ/Halt) | ✅ Implemented |
| Metrics & Introspection | ✅ Implemented |
| NQE Supervision | ✅ Implemented |
| Concurrent Processing (Ahead/Async) | ✅ Implemented |
| OpenTelemetry Tracing | ✅ Implemented |

## Installation

Add to your `cabal` file:

```cabal
build-depends:
    shibuya-core
```

## Quick Start

```haskell
{-# LANGUAGE DeriveGeneric #-}

module Main where

import Shibuya.App
import Shibuya.Adapter.Postgres (postgresAdapter)  -- or your adapter of choice
import Effectful
import Effectful.Concurrent (runConcurrent)

-- Your domain type
data OrderEvent = OrderEvent
  { orderId :: Text
  , amount  :: Int
  }
  deriving (Generic, FromJSON)

-- Your handler - just return what should happen
handleOrder :: Handler '[IOE] OrderEvent
handleOrder ingested = do
  let order = payload (envelope ingested)

  result <- liftIO $ processOrder order

  pure $ case result of
    Right ()  -> AckOk                      -- Success
    Left err  -> AckRetry (RetryDelay 30)   -- Retry in 30 seconds

main :: IO ()
main = runEff . runConcurrent $ do
  pool <- createConnectionPool "postgresql://localhost/mydb"

  let ordersProcessor = QueueProcessor
        { adapter = postgresAdapter pool "orders_queue"
        , handler = handleOrder
        }

  result <- runApp IgnoreFailures 100
    [ (ProcessorId "orders", ordersProcessor)
    ]

  case result of
    Left err -> liftIO $ print err
    Right appHandle -> waitApp appHandle
```

## Ack Decisions

Handlers return an `AckDecision` to express intent:

```haskell
AckOk                              -- Message processed successfully
AckRetry (RetryDelay 30)           -- Retry after 30 seconds
AckDeadLetter (InvalidPayload msg) -- Send to dead-letter queue
AckHalt (HaltFatal reason)         -- Stop processing entirely
```

## Configuration

```haskell
-- runApp takes:
--   SupervisionStrategy - How to handle processor failures
--   Natural             - Inbox size for backpressure
--   [(ProcessorId, QueueProcessor es)] - Named processors

result <- runApp
  IgnoreFailures   -- Keep running even if a processor fails
  500              -- Inbox buffer size
  [ (ProcessorId "orders", ordersProcessor)
  , (ProcessorId "events", eventsProcessor)
  ]
```

## Distributed Tracing

Shibuya includes built-in OpenTelemetry tracing support for distributed observability.

### Enabling Tracing

```haskell
import Shibuya.Telemetry.Effect (runTracing, runTracingNoop)
import OpenTelemetry.Trace qualified as OTel

main :: IO ()
main = do
  -- Initialize OpenTelemetry (via SDK or your preferred method)
  provider <- initTracerProvider  -- Your initialization
  let tracer = OTel.makeTracer provider "my-service" OTel.tracerOptions

  -- Run with tracing enabled
  runEff $ runTracing tracer $ do
    result <- runApp IgnoreFailures 100 processors
    -- ...

  -- Or run with tracing disabled (zero overhead)
  runEff $ runTracingNoop $ do
    result <- runApp IgnoreFailures 100 processors
    -- ...
```

### What Gets Traced

Each message creates a span with:
- **Span name**: `shibuya.process.message`
- **Span kind**: `Consumer`
- **Attributes**:
  - `messaging.system`: "shibuya"
  - `messaging.message.id`: The message ID
  - `messaging.destination.partition.id`: Partition (if present)
  - `shibuya.inflight.count`: Current in-flight messages
  - `shibuya.inflight.max`: Max concurrency
  - `shibuya.ack.decision`: Handler's ack decision
- **Events**: `handler.started`, `handler.completed`, `handler.exception`
- **Context propagation**: Parent context from `traceContext` message headers

### Local Testing with Jaeger

```bash
# Start Jaeger
docker compose -f docker-compose.otel.yaml up -d

# View traces at http://localhost:16686
```

### Environment Variables

Configure tracing via standard OpenTelemetry environment variables:
- `OTEL_SERVICE_NAME` - Service name in traces
- `OTEL_EXPORTER_OTLP_ENDPOINT` - OTLP collector endpoint
- `OTEL_TRACES_SAMPLER` - Sampling strategy (e.g., `always_on`, `parentbased_always_on`)

## Running Multiple Processors

Run multiple independent queues concurrently with `runApp`:

```haskell
main = runEff . runConcurrent $ do
  let ordersProcessor = QueueProcessor
        { adapter = sqsAdapter "orders-queue"
        , handler = handleOrders
        }
      eventsProcessor = QueueProcessor
        { adapter = kafkaAdapter "events-topic"
        , handler = handleEvents
        }

  result <- runApp IgnoreFailures 100
    [ (ProcessorId "orders", ordersProcessor)
    , (ProcessorId "events", eventsProcessor)
    ]

  case result of
    Left err -> print err
    Right appHandle -> do
      -- Monitor metrics
      metrics <- getAppMetrics appHandle
      forM_ (Map.toList metrics) $ \(ProcessorId name, pm) ->
        putStrLn $ name <> ": " <> show pm.stats.processed <> " processed"

      -- Wait for completion or use stopApp to shut down
      waitApp appHandle
```

## Documentation

- [Usage Guide](docs/USAGE_GUIDE.md) - Detailed usage examples
- [Architecture](docs/UNIFIED_ARCHITECTURE.md) - System design and module structure

## Project Structure

```
shibuya-core/
├── Shibuya/
│   ├── Core.hs              -- Public API (import this)
│   ├── Core/
│   │   ├── Types.hs         -- MessageId, Cursor, Envelope
│   │   ├── Ack.hs           -- AckDecision, RetryDelay, DeadLetterReason
│   │   ├── Lease.hs         -- Visibility timeout extension
│   │   ├── AckHandle.hs     -- Ack finalization
│   │   ├── Ingested.hs      -- What handlers receive
│   │   └── Error.hs         -- Structured error types
│   ├── Handler.hs           -- Handler type
│   ├── Adapter.hs           -- Adapter interface
│   ├── Policy.hs            -- Ordering and concurrency policies
│   ├── Runner/
│   │   ├── Master.hs        -- Supervision coordinator
│   │   ├── Supervised.hs    -- Supervised processor runner
│   │   ├── Metrics.hs       -- ProcessorState, StreamStats
│   │   └── Ingester.hs      -- Stream to inbox ingestion
│   ├── App.hs               -- runApp, QueueProcessor, AppHandle
│   └── Stream.hs            -- Stream utilities
```

## Design Principles

1. **Separation of Concerns** - Streamly handles I/O and backpressure, NQE handles supervision
2. **Explicit Semantics** - Handlers express intent, not mechanics
3. **Adapter Abstraction** - Queue-specific logic lives in adapters, not the core
4. **Composable** - Stream pipelines are composable and testable in isolation
5. **Effectful** - All effects tracked for testability and safety

## References

- [Broadway (Elixir)](https://github.com/dashbitco/broadway) - Primary inspiration
- [Streamly](https://hackage.haskell.org/package/streamly) - Stream processing
- [Effectful](https://hackage.haskell.org/package/effectful) - Effect system
- [NQE](https://hackage.haskell.org/package/nqe) - Actor supervision

## License

BSD-3-Clause
