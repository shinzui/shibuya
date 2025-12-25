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
- **Supervised Processing** - Automatic restart strategies via NQE supervision
- **Backpressure** - Bounded inboxes prevent memory exhaustion
- **Explicit Ack Semantics** - Handlers express intent (ack, retry, dead-letter, halt), framework handles mechanics
- **Metrics & Introspection** - Real-time visibility into processor state and statistics
- **Stream Transformations** - Composable pipelines powered by Streamly
- **Effectful** - All effects tracked via the Effectful library

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

import Shibuya.Core
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
  let adapter = postgresAdapter pool "orders_queue"

  let config = defaultRunnerConfig adapter handleOrder

  runApp config >>= \case
    Left err -> liftIO $ print err
    Right () -> pure ()
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
let config = RunnerConfig
      { adapter     = myAdapter
      , handler     = myHandler
      , ordering    = Unordered      -- or StrictInOrder, PartitionedInOrder
      , concurrency = Async 10       -- or Serial, Ahead n
      , inboxSize   = 500
      }
```

## Running Multiple Processors

Use the Master for supervised multi-processor setups:

```haskell
main = runEff . runConcurrent $ do
  master <- startMaster KillAll

  proc1 <- runSupervised master 100 (ProcessorId "orders") ordersAdapter handleOrders
  proc2 <- runSupervised master 100 (ProcessorId "emails") emailsAdapter handleEmails

  -- Monitor metrics
  metrics <- getAllMetrics master
  forM_ (Map.toList metrics) $ \(ProcessorId name, pm) ->
    putStrLn $ name <> ": " <> show pm.stats.processed <> " processed"

  stopMaster master
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
│   │   └── Ingested.hs      -- What handlers receive
│   ├── Handler.hs           -- Handler type
│   ├── Adapter.hs           -- Adapter interface
│   ├── Policy.hs            -- Ordering and concurrency policies
│   ├── Runner.hs            -- RunnerConfig
│   ├── Runner/
│   │   ├── Master.hs        -- Supervision coordinator
│   │   ├── Supervised.hs    -- Supervised processor runner
│   │   ├── Metrics.hs       -- ProcessorState, StreamStats
│   │   └── Serial.hs        -- Sequential runner
│   ├── App.hs               -- runApp entry point
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
