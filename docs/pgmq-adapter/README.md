# PGMQ Adapter for Shibuya

The `shibuya-pgmq-adapter` package provides integration between Shibuya and [pgmq](https://github.com/tembo-io/pgmq) (PostgreSQL Message Queue). This adapter enables Shibuya to consume messages from PostgreSQL-backed queues with visibility timeout semantics, automatic retry handling, and optional dead-letter queue support.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Features](#features)
- [Requirements](#requirements)
- [Module Structure](#module-structure)
- [Related Documentation](#related-documentation)

## Overview

The pgmq adapter creates a Shibuya `Adapter` that:

1. **Polls messages** from a pgmq queue with configurable polling strategies
2. **Manages visibility timeouts** to prevent duplicate processing
3. **Maps Shibuya ack decisions** to appropriate pgmq operations
4. **Provides lease extension** for long-running handlers
5. **Handles automatic dead-lettering** when retry limits are exceeded
6. **Supports FIFO ordering** via pgmq's grouped read operations
7. **Enables concurrent prefetching** to minimize processing latency

```
┌─────────────────────────────────────────────────────────────────┐
│                     Shibuya Application                          │
│                                                                   │
│  runApp → Master → Processor                                      │
│                        │                                          │
│              ┌─────────┴─────────┐                                │
│              │  pgmqAdapter      │                                │
│              │                   │                                │
│              │  source (stream)──┼──► Ingested messages           │
│              │  shutdown         │                                │
│              └───────────────────┘                                │
│                        │                                          │
└────────────────────────┼──────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                  pgmq-effectful / PostgreSQL                     │
│                                                                   │
│  • readMessage / readWithPoll                                     │
│  • readGrouped / readGroupedRoundRobin                           │
│  • deleteMessage / archiveMessage                                 │
│  • changeVisibilityTimeout / sendMessage                          │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

### Installation

Add to your `.cabal` file:

```cabal
build-depends:
  shibuya-core,
  shibuya-pgmq-adapter,
  pgmq-effectful,
  hasql-pool,
```

### Basic Usage

```haskell
import Shibuya.App (runApp, QueueProcessor (..), ProcessorId (..))
import Shibuya.Adapter.Pgmq
import Pgmq.Effectful (runPgmq)
import Hasql.Pool qualified as Pool
import Effectful (runEff)

main :: IO ()
main = do
  -- Create PostgreSQL connection pool
  pool <- Pool.acquire poolSettings

  -- Parse queue name (validated)
  let Right queueName = parseQueueName "orders"

  -- Create adapter configuration
  let config = defaultConfig queueName

  -- Run with effectful
  runEff . runPgmq pool $ do
    -- Create adapter
    adapter <- pgmqAdapter config

    -- Start Shibuya application
    result <- runApp IgnoreFailures 100
      [ (ProcessorId "orders", QueueProcessor adapter handleOrder)
      ]

    case result of
      Left err -> liftIO $ print err
      Right handle -> do
        -- Application is running...
        liftIO waitForShutdown
        stopApp handle

handleOrder :: Handler es Value
handleOrder ingested = do
  case parseOrder (ingested.envelope.payload) of
    Left err -> pure $ AckDeadLetter (InvalidPayload err)
    Right order -> do
      processOrder order
      pure AckOk
```

### With Dead-Letter Queue

```haskell
let config = (defaultConfig queueName)
      { deadLetterConfig = Just $ directDeadLetter dlqName True,
        maxRetries = 3
      }
```

### With Topic-Routed Dead-Letter (pgmq 1.11.0+)

```haskell
let Right routingKey = parseRoutingKey "dlq.orders.failed"
let config = (defaultConfig queueName)
      { deadLetterConfig = Just $ topicDeadLetter routingKey True,
        maxRetries = 3
      }
```

### With FIFO Ordering

```haskell
let config = (defaultConfig queueName)
      { fifoConfig = Just FifoConfig
          { readStrategy = RoundRobin
          }
      }
```

### With Concurrent Prefetching

```haskell
let config = (defaultConfig queueName)
      { prefetchConfig = Just defaultPrefetchConfig,
        batchSize = 10
      }
```

## Features

| Feature | Description |
|---------|-------------|
| **Batch Polling** | Configurable batch sizes for efficient database access |
| **Long Polling** | Database-side blocking to reduce empty poll overhead |
| **Visibility Timeout** | Messages become invisible during processing |
| **Lease Extension** | Handlers can extend timeout for long-running operations |
| **Automatic Retry** | Uses pgmq's `readCount` to track and limit retries |
| **Dead-Letter Queue** | Optional DLQ with configurable metadata inclusion |
| **FIFO Ordering** | Grouped message processing with pgmq 1.8.0+ |
| **Concurrent Prefetch** | Polls next batch while processing current messages |
| **Graceful Shutdown** | Stops polling while allowing in-flight messages to complete |

## Requirements

- **GHC 9.10+** (GHC2024 language standard)
- **PostgreSQL** with pgmq extension installed
- **pgmq 1.8.0+** for FIFO support
- **effectful 2.6+** for effect system integration

### Key Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `pgmq-core` | - | pgmq type definitions |
| `pgmq-effectful` | - | effectful integration for pgmq operations |
| `pgmq-hasql` | - | Hasql-based pgmq client |
| `shibuya-core` | - | Shibuya framework types |
| `streamly` | ^0.11 | Stream processing |
| `streamly-core` | ^0.3 | Streamly core utilities |
| `effectful-core` | ^2.6.1 | Effect system |

## Module Structure

```
shibuya-pgmq-adapter/
├── shibuya-pgmq-adapter.cabal
├── src/
│   └── Shibuya/
│       └── Adapter/
│           ├── Pgmq.hs              # Public API (pgmqAdapter, exports)
│           └── Pgmq/
│               ├── Config.hs        # Configuration types
│               ├── Convert.hs       # Type conversions (pgmq ↔ Shibuya)
│               └── Internal.hs      # Stream implementation (not public)
└── test/
    ├── Main.hs
    └── Shibuya/
        └── Adapter/
            └── Pgmq/
                └── ConvertSpec.hs   # Conversion tests
```

### Public Modules

| Module | Purpose |
|--------|---------|
| `Shibuya.Adapter.Pgmq` | Main entry point. Exports `pgmqAdapter` and all configuration types. |
| `Shibuya.Adapter.Pgmq.Config` | Configuration type definitions only. |
| `Shibuya.Adapter.Pgmq.Convert` | Type conversion utilities for advanced use cases. |

### Internal Modules

| Module | Purpose |
|--------|---------|
| `Shibuya.Adapter.Pgmq.Internal` | Stream construction, polling logic, ack handling. Not part of public API. |

## Related Documentation

- [User Guides](../user/README.md) - Task-oriented guides for common use cases
- [ARCHITECTURE.md](./ARCHITECTURE.md) - Data flow, design decisions, message lifecycle
- [CONFIGURATION.md](./CONFIGURATION.md) - Complete configuration reference
- [INTERNALS.md](./INTERNALS.md) - Implementation details for code auditing
- [Shibuya Core Architecture](../architecture/MESSAGE_FLOW.md) - How Shibuya processes messages
- [pgmq Documentation](https://tembo.io/pgmq/) - Upstream pgmq documentation
