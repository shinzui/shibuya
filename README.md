<p align="center">
  <img src="docs/images/shibuya-logo.png" alt="Shibuya" width="800"><br>
  A supervised queue processing framework inspired by <a href="https://github.com/dashbitco/broadway">Broadway</a>
</p>

---

> **Pre-1.0** — Shibuya is pre-1.0. The core API went through a cleanup for
> 0.8.0.0 and is stabilizing, but it may still change before the first stable
> release. Upgrading from 0.7.x? See the
> [migration guide](docs/user/migrating-to-0.8.md).

---

Shibuya is a supervised queue-processing framework for Haskell, inspired by
[Broadway](https://github.com/dashbitco/broadway). It provides a unified
abstraction over message-queue backends (Kafka, PostgreSQL/pgmq, and more) with
built-in supervision, backpressure, explicit acknowledgement semantics, and
composable Streamly pipelines — so you write a handler once and swap backends
freely.

## Features

- **Unified queue abstraction** — write handlers once, swap queue backends freely.
- **Supervised processing** — failure isolation via NQE supervision.
- **Backpressure** — bounded inboxes prevent memory exhaustion.
- **Explicit ack semantics** — handlers express intent (ack, retry, dead-letter,
  halt); the framework owns finalization.
- **First-class batching** — accumulate by key with size/timeout/flush triggers
  and per-message `BatchAck` decisions.
- **Ordering & concurrency** — serial, ahead-of-time, async, and partition-keyed
  in-order processing.
- **Built-in retries** — exponential backoff with jitter, driven by the adapter's
  delivery count.
- **OpenTelemetry tracing** — per-message spans and context propagation, with a
  zero-overhead path when disabled.
- **Metrics & introspection** — real-time visibility into processor state and
  statistics.

## Adapters

Queue backends live in sibling repositories so they can release on their own
cadence:

- [`shibuya-kafka-adapter`](https://github.com/shinzui/shibuya-kafka-adapter)
  — Apache Kafka via `hw-kafka-client` and `kafka-effectful`.
- [`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter)
  — PostgreSQL message queue (pgmq) via `pgmq-hs`.

## Installation

Released versions are available on
[Hackage](https://hackage.haskell.org/package/shibuya-core):

```cabal
build-depends:
    shibuya-core ^>=0.8.0.0
```

Optional packages:

- [`shibuya-metrics`](https://hackage.haskell.org/package/shibuya-metrics) — HTTP/JSON, Prometheus, and WebSocket metrics endpoints
- [`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter) — PostgreSQL message queue adapter
- [`shibuya-kafka-adapter`](https://github.com/shinzui/shibuya-kafka-adapter) — Apache Kafka adapter

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

For app authors, a single `import Shibuya` re-exports everything you need. See
the [getting-started guide](docs/user/getting-started.md) for a full walkthrough.

## Ack Decisions

Handlers return an `AckDecision` to express intent; the framework performs the
corresponding queue operation:

```haskell
AckOk                              -- Message processed successfully
AckRetry (RetryDelay 30)           -- Retry after 30 seconds
AckDeadLetter (InvalidPayload msg) -- Send to dead-letter queue
AckHalt (HaltFatal reason)         -- Stop processing entirely
```

## Configuration

`runApp` takes an `AppConfig` (supervision strategy + inbox size) and a list of
named processors:

```haskell
result <- runApp
  defaultAppConfig { inboxSize = 500 }
  [ (ProcessorId "orders", ordersProcessor)
  , (ProcessorId "events", eventsProcessor)
  ]
```

Each `QueueProcessor` chooses how its messages are ordered and how concurrently
they run:

```haskell
-- QueueProcessor fields:
--   adapter     - Queue backend (source stream + shutdown)
--   handler     - Your message handler
--   ordering    - Unordered | StrictInOrder | PartitionedInOrder
--   concurrency - Serial | Ahead Natural | Async Natural
```

`mkProcessor` builds an `Unordered`/`Serial` processor for the common case; use
`mkBatchProcessor` for batch handlers.

## Retries with Exponential Backoff

Shibuya ships a built-in exponential-backoff helper so handlers get
exponentially-growing, jittered retry intervals without doing the math:

```haskell
import Shibuya.Core.Retry (defaultBackoffPolicy, retryWithBackoff)

myHandler msg = do
  result <- tryProcess msg.envelope.payload
  case result of
    Right ()  -> pure AckOk
    Left _err -> retryWithBackoff defaultBackoffPolicy msg.envelope
```

`defaultBackoffPolicy` follows AWS's "exponential backoff with full jitter"
recommendation (1 s base, factor 2, capped at 5 minutes); the `Jitter`
strategies are `NoJitter`, `FullJitter` (default), and `EqualJitter`. The helper
grows the delay using `msg.envelope.attempt` (the adapter's redelivery count,
e.g. pgmq's `read_count`), falling back to the base delay when it is `Nothing`.

A runnable end-to-end demo lives in the
[`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter) repo
(`shibuya-pgmq-example`, `backoff-demo` subcommand).

## Distributed Tracing

Shibuya has built-in OpenTelemetry tracing. Wrap your app in `runTracing tracer`
to enable it, or `runTracingNoop` for a zero-overhead disabled path:

```haskell
import Shibuya.Telemetry.Effect (runTracing, runTracingNoop)

runEff $ runTracing tracer $ do
  runApp defaultAppConfig processors
```

Each message opens a `Consumer`-kind span named `"<destination> process"` with
`messaging.*` attributes, in-flight gauges, and the handler's ack decision, and
propagates parent context from the message's trace headers. Configuration,
Jaeger setup, and the supported `OTEL_*` environment variables are covered in the
[OpenTelemetry guide](docs/user/opentelemetry.md).

## Running Multiple Processors

Run multiple independent queues concurrently under one `runApp`, then introspect
or shut them down through the returned handle:

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
      metrics <- getAppMetrics appHandle
      forM_ (Map.toList metrics) $ \(ProcessorId name, pm) ->
        putStrLn $ name <> ": " <> show pm.stats.processed <> " processed"

      -- Wait for completion, or use stopApp / stopAppGracefully to shut down.
      waitApp appHandle
```

## Documentation

- [Getting Started](docs/user/getting-started.md) — framework walkthrough
- [Usage Guide](docs/USAGE_GUIDE.md) — detailed usage examples
- [OpenTelemetry](docs/user/opentelemetry.md) — tracing setup and configuration
- [Architecture](docs/UNIFIED_ARCHITECTURE.md) — system design and module structure
- [Architecture Details](docs/architecture/) — core types, message flow, metrics, concurrency
- [Migrating to 0.8.0.0](docs/user/migrating-to-0.8.md) — upgrading from 0.7.x
- [CHANGELOG](CHANGELOG.md) — release history and per-version notes

Adapter-specific docs (PGMQ, Kafka, …) live with their respective adapters — see
[Adapters](#adapters) above.

## Design Principles

1. **Separation of concerns** — Streamly handles I/O and backpressure, NQE handles supervision.
2. **Explicit semantics** — handlers express intent, not mechanics.
3. **Adapter abstraction** — queue-specific logic lives in adapters, not the core.
4. **Composable** — stream pipelines are composable and testable in isolation.
5. **Effectful** — all effects are tracked for testability and safety.

## References

- [Broadway (Elixir)](https://github.com/dashbitco/broadway) — primary inspiration
- [Streamly](https://hackage.haskell.org/package/streamly) — stream processing
- [Effectful](https://hackage.haskell.org/package/effectful) — effect system
- [NQE](https://hackage.haskell.org/package/nqe) — actor supervision

## License

MIT
