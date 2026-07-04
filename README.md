<p align="center">
  <img src="docs/images/shibuya-logo.png" alt="Shibuya" width="800"><br>
  A supervised queue processing framework inspired by <a href="https://github.com/dashbitco/broadway">Broadway</a>
</p>

---

> **⚠️ Pre-1.0**
>
> Shibuya is pre-1.0. The core API went through a cleanup for 0.8.0.0 and is
> stabilizing, but it may still change before the first stable release.
> Upgrading from 0.7.x? See the [migration guide](docs/user/migrating-to-0.8.md).

---

Shibuya provides a unified abstraction over various message queue backends (Kafka, PostgreSQL queues, SQS, Redis) with built-in supervision, backpressure, and composable stream transformations.

## Features

- **Unified Queue Abstraction** - Write handlers once, swap queue backends freely
- **Supervised Processing** - Failure isolation via NQE supervision
- **Backpressure** - Bounded inboxes prevent memory exhaustion
- **Explicit Ack Semantics** - Handlers express intent (ack, retry, dead-letter, halt), framework handles mechanics
- **First-Class Batching** - Accumulate by key with size/timeout/flush triggers, `BatchAck` decisions, and resilient finalization
- **Metrics & Introspection** - Real-time visibility into processor state and statistics
- **Stream Transformations** - Composable pipelines powered by Streamly
- **Effectful** - All effects tracked via the Effectful library

### Current Status (v0.8.0.0)

| Feature | Status |
|---------|--------|
| Serial Processing | Implemented |
| Backpressure (bounded inbox) | Implemented |
| Ack Semantics (Ok/Retry/DLQ/Halt) | Implemented |
| Metrics & Introspection | Implemented |
| NQE Supervision | Implemented |
| Concurrent Processing (Ahead/Async) | Implemented |
| Partitioned Ordering for single-message processors | Implemented |
| First-Class Batching (size/timeout/key) | Implemented |
| OpenTelemetry Tracing | Implemented |
| Graceful Shutdown (drain timeout) | Implemented |
| Policy Validation | Implemented |

## Adapters

Queue backends live in sibling repositories so they can release on
their own cadence:

- [`shibuya-kafka-adapter`](https://github.com/shinzui/shibuya-kafka-adapter)
  — Apache Kafka via `hw-kafka-client` and `kafka-effectful`.
- [`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter)
  — PostgreSQL message queue (pgmq) via `pgmq-hs`.

### What's New in 0.8.0.0

- **Breaking** — `runApp` now takes an `AppConfig` record:
  `runApp defaultAppConfig processors`. Customize with record updates such as
  `defaultAppConfig { strategy = StopAllOnFailure, inboxSize = 500 }`.
- **Breaking** — handlers receive `Message es msg`, not internal
  `Ingested es msg`. The framework retains the `AckHandle` and owns
  finalization.
- **Breaking** — `Ordering` is now `OrderingPolicy`, removing the need to hide
  `Prelude.Ordering`.
- **Breaking** — runner internals moved under `Shibuya.Internal.Runner.*`;
  application code should import the `Shibuya` umbrella module.
- **Breaking** — removed dead surface: `StreamStats.dropped`,
  `HandlerTimeout`, `InboxOverflow`, and the always-zero dropped Prometheus
  metric.
- `PartitionedInOrder` with `Ahead` or `Async` is now enforced for
  single-message processors by a keyed scheduler.
- `mkEnvelope` and `mkIngested` are the recommended constructors for adapter
  authors.
- **New** — first-class batch processing (`Shibuya.Batch`, `mkBatchProcessor`)
  and a faster hot path (atomic per-message metrics, allocation-free disabled
  tracing).

📖 **Upgrading from 0.7.x?** See the
[migration guide](docs/user/migrating-to-0.8.md) — most changes are mechanical.

### What's New in 0.6.0.0

- **Breaking** — OpenTelemetry messaging spans now emit
  `messaging.operation.type = "process"` instead of the deprecated
  `messaging.operation = "process"` wire key. The Haskell constant
  `attrMessagingOperation` keeps its name and resolves to the current
  semantic-conventions key, so source imports keep compiling, but
  dashboards, alerts, and trace queries filtering on
  `messaging.operation` must move to `messaging.operation.type`.
- Upgraded the OpenTelemetry dependencies to the 1.0 ecosystem
  (`hs-opentelemetry-api ^>= 1.0`, propagator and exporters to
  match) and sourced Shibuya's generic messaging keys from
  `hs-opentelemetry-semantic-conventions ^>= 1.40`.

See the [CHANGELOG](CHANGELOG.md) for full release history.

## Installation

Released versions are available on [Hackage](https://hackage.haskell.org/package/shibuya-core).
For the current 0.8.0.0 source tree, add:

```cabal
build-depends:
    shibuya-core ^>=0.8.0.0
```

Optional packages:
- [`shibuya-metrics`](https://hackage.haskell.org/package/shibuya-metrics) — HTTP/JSON, Prometheus, and WebSocket metrics endpoints
- [`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter) — PostgreSQL message queue adapter (standalone repo)
- [`shibuya-kafka-adapter`](https://github.com/shinzui/shibuya-kafka-adapter) — Apache Kafka adapter (standalone repo)

## Quick Start

```haskell
{-# LANGUAGE DeriveGeneric #-}

module Main where

import Shibuya
import Shibuya.Telemetry.Effect (runTracingNoop)
import Effectful

-- Your domain type
data OrderEvent = OrderEvent
  { orderId :: Text
  , amount  :: Int
  }
  deriving (Generic, FromJSON)

-- Your handler - just return what should happen
handleOrder :: Handler es OrderEvent
handleOrder msg = do
  let order = msg.envelope.payload

  result <- liftIO $ processOrder order

  pure $ case result of
    Right ()  -> AckOk                      -- Success
    Left err  -> AckRetry (RetryDelay 30)   -- Retry in 30 seconds

main :: IO ()
main = runEff . runTracingNoop $ do
  let ordersProcessor = QueueProcessor
        { adapter = myAdapter       -- your adapter of choice
        , handler = handleOrder
        , ordering = Unordered
        , concurrency = Serial
        }

  result <- runApp defaultAppConfig
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
--   AppConfig - supervision strategy and inbox size
--   [(ProcessorId, QueueProcessor es)] - Named processors

result <- runApp
  defaultAppConfig { inboxSize = 500 }
  [ (ProcessorId "orders", ordersProcessor)
  , (ProcessorId "events", eventsProcessor)
  ]

-- QueueProcessor fields:
--   adapter     - Queue backend (source stream + shutdown)
--   handler     - Your message handler
--   ordering    - Unordered | StrictInOrder | PartitionedInOrder
--   concurrency - Serial | Ahead Natural | Async Natural
```

## Exponential Backoff

Shibuya 0.4 ships a built-in exponential-backoff helper for handlers
that want exponentially-growing, jittered retry intervals without
having to compute the math themselves:

```haskell
import Shibuya.Core.Retry (defaultBackoffPolicy, retryWithBackoff)

myHandler msg = do
  result <- tryProcess msg.envelope.payload
  case result of
    Right ()  -> pure AckOk
    Left _err -> retryWithBackoff defaultBackoffPolicy msg.envelope
```

`defaultBackoffPolicy` is AWS's published "exponential backoff with
full jitter" recommendation: 1 s base, factor 2, capped at 5 minutes.
The available `Jitter` strategies are `NoJitter`, `FullJitter`
(default), and `EqualJitter`; switch by record-updating the policy
(`defaultBackoffPolicy { jitter = NoJitter }`).

Adapters that track per-message redelivery counts populate
`msg.envelope.attempt :: Maybe Attempt`; the helper reads it and
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
    result <- runApp defaultAppConfig processors
    -- ...

  -- Or run with tracing disabled (zero overhead)
  runEff $ runTracingNoop $ do
    result <- runApp defaultAppConfig processors
    -- ...
```

### What Gets Traced

Each message creates a span with:
- **Span name**: `"<destination> process"` (e.g. `"shibuya-consumer process"`), following the OpenTelemetry messaging-spans recommendation
- **Span kind**: `Consumer`
- **Attributes**:
  - `messaging.system`: "shibuya"
  - `messaging.operation.type`: "process"
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
main = runEff . runTracingNoop $ do
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

  result <- runApp defaultAppConfig
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
- [Migrating to 0.8.0.0](docs/user/migrating-to-0.8.md) - Upgrading from 0.7.x
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
