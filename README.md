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

### Current Status (v0.4.0.0 — [Hackage](https://hackage.haskell.org/package/shibuya-core-0.4.0.0))

| Feature | Status |
|---------|--------|
| Serial Processing | ✅ Implemented |
| Backpressure (bounded inbox) | ✅ Implemented |
| Ack Semantics (Ok/Retry/DLQ/Halt) | ✅ Implemented |
| Metrics & Introspection | ✅ Implemented |
| NQE Supervision | ✅ Implemented |
| Concurrent Processing (Ahead/Async) | ✅ Implemented |
| OpenTelemetry Tracing | ✅ Implemented |
| Graceful Shutdown (drain timeout) | ✅ Implemented |
| Policy Validation | ✅ Implemented |

## Adapters

Queue backends live in sibling repositories so they can release on
their own cadence:

- [`shibuya-kafka-adapter`](https://github.com/shinzui/shibuya-kafka-adapter)
  — Apache Kafka via `hw-kafka-client` and `kafka-effectful`.
- [`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter)
  — PostgreSQL message queue (pgmq) via `pgmq-hs`.

### What's New in 0.4.0.0

- **Exponential backoff for retries** — new `Shibuya.Core.Retry`
  module providing `BackoffPolicy`, `Jitter` (`NoJitter`,
  `FullJitter`, `EqualJitter`), `defaultBackoffPolicy`,
  `exponentialBackoffPure`, `exponentialBackoff`, and the handler
  convenience `retryWithBackoff`. See the
  [Exponential Backoff](#exponential-backoff) section below.
- **Breaking** — `Envelope` gained an `attempt :: !(Maybe Attempt)`
  field carrying the adapter's delivery counter (zero-indexed;
  `Nothing` if the adapter does not track redeliveries). Direct
  constructions of `Envelope` must add the field. The new `Attempt`
  newtype is exported from `Shibuya.Core` and `Shibuya.Core.Types`.
- `shibuya-metrics` is re-released at 0.4.0.0 to track the shared
  version; it has no user-visible changes of its own.

See the [CHANGELOG](CHANGELOG.md) for full release history.

## Installation

Available on [Hackage](https://hackage.haskell.org/package/shibuya-core). Add to your `cabal` file:

```cabal
build-depends:
    shibuya-core ^>=0.4.0.0
```

Optional packages:
- [`shibuya-metrics`](https://hackage.haskell.org/package/shibuya-metrics) — HTTP/JSON, Prometheus, and WebSocket metrics endpoints
- [`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter) — PostgreSQL message queue adapter (standalone repo)
- [`shibuya-kafka-adapter`](https://github.com/shinzui/shibuya-kafka-adapter) — Apache Kafka adapter (standalone repo)

## Quick Start

```haskell
{-# LANGUAGE DeriveGeneric #-}

module Main where

import Shibuya.App
import Shibuya.Telemetry.Effect (runTracingNoop)
import Effectful
import Effectful.Concurrent (runConcurrent)

-- Your domain type
data OrderEvent = OrderEvent
  { orderId :: Text
  , amount  :: Int
  }
  deriving (Generic, FromJSON)

-- Your handler - just return what should happen
handleOrder :: Handler es OrderEvent
handleOrder ingested = do
  let order = ingested.envelope.payload

  result <- liftIO $ processOrder order

  pure $ case result of
    Right ()  -> AckOk                      -- Success
    Left err  -> AckRetry (RetryDelay 30)   -- Retry in 30 seconds

main :: IO ()
main = runEff . runConcurrent . runTracingNoop $ do
  let ordersProcessor = QueueProcessor
        { adapter = myAdapter       -- your adapter of choice
        , handler = handleOrder
        , ordering = Unordered
        , concurrency = Serial
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
--   Int                 - Inbox size for backpressure
--   [(ProcessorId, QueueProcessor es)] - Named processors

result <- runApp
  IgnoreFailures   -- Keep running even if a processor fails
  500              -- Inbox buffer size
  [ (ProcessorId "orders", ordersProcessor)
  , (ProcessorId "events", eventsProcessor)
  ]

-- QueueProcessor fields:
--   adapter     - Queue backend (source stream + shutdown)
--   handler     - Your message handler
--   ordering    - Unordered | StrictInOrder
--   concurrency - Serial | Ahead Natural | Async Natural
```

## Exponential Backoff

Shibuya 0.4 ships a built-in exponential-backoff helper for handlers
that want exponentially-growing, jittered retry intervals without
having to compute the math themselves:

```haskell
import Shibuya.Core.Retry (defaultBackoffPolicy, retryWithBackoff)

myHandler ingested = do
  result <- tryProcess ingested.envelope.payload
  case result of
    Right ()  -> pure AckOk
    Left _err -> retryWithBackoff defaultBackoffPolicy ingested.envelope
```

`defaultBackoffPolicy` is AWS's published "exponential backoff with
full jitter" recommendation: 1 s base, factor 2, capped at 5 minutes.
The available `Jitter` strategies are `NoJitter`, `FullJitter`
(default), and `EqualJitter`; switch by record-updating the policy
(`defaultBackoffPolicy { jitter = NoJitter }`).

Adapters that track per-message redelivery counts populate
`ingested.envelope.attempt :: Maybe Attempt`; the helper reads it and
grows the delay each time the same message returns. The PGMQ adapter
sources the counter from pgmq's `read_count` column. Adapters that do
not track redeliveries leave `attempt = Nothing`, in which case
`retryWithBackoff` treats the delivery as `Attempt 0` (base delay).

A runnable end-to-end demonstration lives in the
[`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter)
repo's `shibuya-pgmq-example/` package. With a local Postgres
reachable via `DATABASE_URL`, run:

```sh
# Terminal 1 — consumer
cabal run shibuya-pgmq-consumer -- backoff-demo nojitter

# Terminal 2 — enqueue one message
cabal run shibuya-pgmq-simulator -- one-shot backoff_demo
```

The consumer's stdout shows the message being delivered four times,
with the wallclock gaps growing 1 s, 2 s, 4 s, then succeeding on the
fourth delivery. Drop the `nojitter` flag for the default
full-jittered policy.

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
- **Span name**: `"<destination> process"` (e.g. `"shibuya-consumer process"`), following the OpenTelemetry messaging-spans recommendation
- **Span kind**: `Consumer`
- **Attributes**:
  - `messaging.system`: "shibuya"
  - `messaging.operation`: "process"
  - `messaging.destination.name`: The processor id
  - `messaging.message.id`: The message ID
  - `shibuya.partition`: Partition (if present)
  - `shibuya.inflight.count`: Current in-flight messages
  - `shibuya.inflight.max`: Max concurrency
  - `shibuya.ack.decision`: Handler's ack decision
- **Events**: `shibuya.handler.started`, `shibuya.handler.completed`, `shibuya.ack.decision` (plus the standard `exception` event on handler exceptions, via `recordException`)
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
main = runEff . runConcurrent . runTracingNoop $ do
  let ordersProcessor = QueueProcessor
        { adapter = ordersAdapter
        , handler = handleOrders
        , ordering = Unordered
        , concurrency = Async 10    -- 10 concurrent handlers
        }
      eventsProcessor = QueueProcessor
        { adapter = eventsAdapter
        , handler = handleEvents
        , ordering = Unordered
        , concurrency = Serial
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

      -- Wait for completion or use stopApp/stopAppGracefully to shut down
      waitApp appHandle
```

## Documentation

- [Usage Guide](docs/USAGE_GUIDE.md) - Detailed usage examples
- [Getting Started](docs/user/getting-started.md) - Framework walkthrough
- [Architecture](docs/UNIFIED_ARCHITECTURE.md) - System design and module structure
- [Architecture Details](docs/architecture/) - Core types, message flow, metrics, concurrency
- [CHANGELOG](CHANGELOG.md) - Release history

Adapter-specific docs (PGMQ, Kafka, ...) live with their respective
adapters — see the [Adapters](#adapters) section above.

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

MIT
