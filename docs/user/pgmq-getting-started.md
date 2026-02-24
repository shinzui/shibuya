# PGMQ Adapter: Getting Started

This guide covers setting up the PGMQ adapter to consume messages from PostgreSQL-backed queues.

## Prerequisites

- PostgreSQL with the [pgmq](https://github.com/tembo-io/pgmq) extension installed
- pgmq 1.8.0+ for FIFO support, pgmq 1.11.0+ for topic routing

## Installation

Add to your `.cabal` file:

```cabal
build-depends:
  shibuya-core,
  shibuya-pgmq-adapter,
  pgmq-effectful,
  hasql-pool,
```

## Basic Consumer

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

## Configuration Basics

The `defaultConfig` provides sensible defaults:

```haskell
defaultConfig :: QueueName -> PgmqAdapterConfig
-- visibilityTimeout = 30 seconds
-- batchSize = 1
-- polling = StandardPolling (1 second)
-- deadLetterConfig = Nothing
-- maxRetries = 3
-- fifoConfig = Nothing
-- prefetchConfig = Nothing
```

Override fields as needed:

```haskell
let config = (defaultConfig queueName)
      { batchSize = 10,
        visibilityTimeout = 60,
        maxRetries = 5
      }
```

## Polling Strategies

### Standard Polling

Client-side sleep between polls when the queue is empty:

```haskell
let config = (defaultConfig queueName)
      { polling = StandardPolling { pollInterval = 0.5 }  -- 500ms
      }
```

Best when the queue usually has messages.

### Long Polling

Database-side blocking until messages arrive:

```haskell
let config = (defaultConfig queueName)
      { polling = LongPolling
          { maxPollSeconds = 10,
            pollIntervalMs = 100
          }
      }
```

Best when the queue is often empty. Reduces database round-trips but holds a connection during the wait.

## Multi-Queue Consumer

Set up multiple processors consuming from different queues:

```haskell
runConsumer pool = runEff . runPgmq pool $ do
  ordersAdapter <- pgmqAdapter ordersConfig
  paymentsAdapter <- pgmqAdapter paymentsConfig
  notificationsAdapter <- pgmqAdapter notificationsConfig

  result <- runApp IgnoreFailures 100
    [ (ProcessorId "orders", mkProcessor ordersAdapter ordersHandler),
      (ProcessorId "payments", mkProcessor paymentsAdapter paymentsHandler),
      (ProcessorId "notifications", mkProcessor notificationsAdapter notificationsHandler)
    ]

  case result of
    Left err -> liftIO $ print err
    Right appHandle -> do
      liftIO $ putStrLn "All processors running"
      -- Wait for shutdown signal...
      let shutdownConfig = ShutdownConfig { drainTimeout = 30 }
      stopAppGracefully shutdownConfig appHandle
```

## Message Lifecycle

1. Messages are read from pgmq with a visibility timeout
2. During processing, messages are invisible to other consumers
3. On `AckOk`, messages are deleted from the queue
4. On `AckRetry`, visibility timeout is extended by the retry delay
5. On `AckDeadLetter`, messages are archived or sent to DLQ
6. On `AckHalt`, visibility timeout is extended to 1 hour and the processor stops

## Automatic Retry Tracking

pgmq tracks retries via the `readCount` field. When a message's `readCount` exceeds `maxRetries`:

1. The adapter automatically dead-letters the message
2. The handler never sees the message
3. No manual retry tracking needed

## Next Steps

- [Dead-Letter Queues](./pgmq-dead-letter-queues.md) - Configure DLQ with direct or topic-based routing
- [Topic Routing](./pgmq-topic-routing.md) - AMQP-like topic binding and pattern matching
- [Advanced PGMQ](./pgmq-advanced.md) - FIFO ordering, prefetching, lease extension, tuning
- [Configuration Reference](../pgmq-adapter/CONFIGURATION.md) - Complete field-by-field reference
