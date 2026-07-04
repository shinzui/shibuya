# Shibuya Framework Architecture

Shibuya is a supervised queue processing framework for Haskell. The core
package owns the common runtime: adapter ingestion, bounded backpressure,
handler execution, explicit ack decisions, batching, supervision, metrics, and
OpenTelemetry spans. Queue-specific broker behavior lives in adapter packages.

For deeper references, see:

- [Core Types](architecture/CORE_TYPES.md)
- [Message Flow](architecture/MESSAGE_FLOW.md)
- [Concurrency](architecture/CONCURRENCY.md)
- [Metrics](architecture/METRICS.md)
- [OpenTelemetry](user/opentelemetry.md)

## Runtime Shape

```text
runApp AppConfig [(ProcessorId, QueueProcessor)]
        |
        v
      Master
        |
        +-- Supervised processor "orders"
        |     Adapter.source -> bounded inbox -> Handler/BatchHandler -> AckHandle.finalize
        |
        +-- Supervised processor "events"
              Adapter.source -> bounded inbox -> Handler/BatchHandler -> AckHandle.finalize
```

Each processor has its own adapter stream, bounded inbox, runner, metrics
handle, and shutdown path. The shared `Master` holds the NQE supervisor and the
metrics registry used by `getAppMetrics` and `shibuya-metrics`.

## Public Entry Point

Most application code imports `Shibuya` or `Shibuya.App`.

```haskell
runApp
  :: (IOE :> es, Tracing :> es)
  => AppConfig
  -> [(ProcessorId, QueueProcessor es)]
  -> Eff es (Either AppError (AppHandle es))

data AppConfig = AppConfig
  { strategy  :: !SupervisionStrategy
  , inboxSize :: !Int
  }

defaultAppConfig :: AppConfig
-- IgnoreFailures, inboxSize = 100
```

`runApp` validates the application config, ordering/concurrency policies, and
batch configs before starting processors. `inboxSize` must be at least 1.

## Processor Types

```haskell
data QueueProcessor es where
  QueueProcessor ::
    { adapter     :: Adapter es msg
    , handler     :: Handler es msg
    , ordering    :: OrderingPolicy
    , concurrency :: Concurrency
    } -> QueueProcessor es

  BatchingProcessor ::
    { adapter      :: Adapter es msg
    , batchHandler :: BatchHandler es msg
    , batchConfig  :: BatchConfig es msg
    , ordering     :: OrderingPolicy
    , concurrency  :: Concurrency
    } -> QueueProcessor es

mkProcessor
  :: Adapter es msg -> Handler es msg -> QueueProcessor es

mkBatchProcessor
  :: Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es
```

The smart constructors use `Unordered` + `Serial` defaults. Set the fields
directly when a processor needs stricter ordering or more concurrency.

## Message Types

Adapters emit framework-internal `Ingested` values:

```haskell
data Ingested es msg = Ingested
  { envelope :: !(Envelope msg)
  , ack      :: !(AckHandle es)
  , lease    :: !(Maybe (Lease es))
  }
```

Handlers receive the read-only projection:

```haskell
data Message es msg = Message
  { envelope :: !(Envelope msg)
  , lease    :: !(Maybe (Lease es))
  }

type Handler es msg = Message es msg -> Eff es AckDecision
```

The framework retains the `AckHandle` and finalizes exactly once per delivery
decision, retrying the same decision when finalization itself throws.

## Envelope

```haskell
data Envelope msg = Envelope
  { messageId    :: !MessageId
  , cursor       :: !(Maybe Cursor)
  , partition    :: !(Maybe Text)
  , enqueuedAt   :: !(Maybe UTCTime)
  , traceContext :: !(Maybe TraceHeaders)
  , headers      :: !(Maybe Headers)
  , attempt      :: !(Maybe Attempt)
  , attributes   :: !(HashMap Text Attribute)
  , payload      :: !msg
  }
```

`headers` is the lossless broker-header view. `traceContext` is the parsed W3C
projection used to parent the Consumer span. `attributes` lets adapters attach
typed OpenTelemetry attributes to Shibuya's per-message span.

## Ack Decisions

```haskell
data AckDecision
  = AckOk
  | AckRetry !RetryDelay
  | AckDeadLetter !DeadLetterReason
  | AckHalt !HaltReason
```

Handlers express intent; adapters implement mechanics in `AckHandle.finalize`.
If a handler throws, the runner records the failure and finalizes the message as
`AckRetry (RetryDelay 0)` so it is not lost.

## Batching

Batching processors insert a batcher between the bounded inbox and the handler.
Messages accumulate per `BatchKey` and emit on size, timeout, or shutdown flush.

```haskell
type BatchHandler es msg =
  BatchInfo -> NonEmpty (Message es msg) -> Eff es BatchAck

data BatchAck = BatchAck
  { decisions :: !(Map MessageId AckDecision)
  , fallback  :: !AckDecision
  }
```

The runtime resolves one decision for every retained message in the emitted
batch: a `MessageId` lookup in `decisions`, or `fallback` when absent. It then
applies each resolved decision through that message's idempotent finalizer with
bounded retry.

`BatchingProcessor` rejects `PartitionedInOrder` with `Ahead` or `Async` because
batches are scheduled by `BatchKey`, not by `Envelope.partition`.

## Ordering and Concurrency

```haskell
data OrderingPolicy
  = StrictInOrder
  | PartitionedInOrder
  | Unordered

data Concurrency
  = Serial
  | Ahead !Int
  | Async !Int
```

`StrictInOrder` requires `Serial`. `PartitionedInOrder` with concurrent
single-message processors uses the internal keyed scheduler: messages sharing a
`Just partition` key are processed and finalized in arrival order, while
different partitions can run concurrently up to the configured bound. Messages
without a partition key are unconstrained.

## Supervision and Shutdown

```haskell
data SupervisionStrategy
  = IgnoreFailures
  | StopAllOnFailure

data ShutdownConfig = ShutdownConfig
  { drainTimeout :: !NominalDiffTime
  }
```

`IgnoreFailures` maps to NQE `IgnoreAll`; failed processors stay failed while
siblings continue. `StopAllOnFailure` maps to NQE `IgnoreGraceful`; real
failures stop siblings, but graceful exits do not.

`stopApp` is `stopAppGracefully defaultShutdownConfig`. Shutdown signals every
adapter, waits for processors to drain until the timeout, then stops the master
and any remaining supervised processors.

## Metrics

```haskell
data ProcessorMetrics = ProcessorMetrics
  { state     :: !ProcessorState
  , stats     :: !StreamStats
  , batch     :: !BatchStats
  , startedAt :: !UTCTime
  }

data StreamStats = StreamStats
  { received  :: !Int
  , processed :: !Int
  , failed    :: !Int
  }
```

Hot per-message counters use atomic fetch-and-add operations. Colder state,
batch counters, and metadata live in the processor's `MetricsHandle` and are
sampled by `getAppMetrics`, `getAllMetrics`, and the metrics server.

## Adapter Skeleton

```haskell
myAdapter :: (IOE :> es) => Adapter es Payload
myAdapter =
  Adapter
    { adapterName = "my-queue"
    , source = myStreamOfIngestedMessages
    , shutdown = closeConsumer
    }

toIngested :: NativeMessage -> Ingested es Payload
toIngested msg =
  let msgId = MessageId msg.id
      env =
        (mkEnvelope msgId msg.payload)
          { cursor = Just (CursorText msg.offset)
          , partition = msg.partitionKey
          , headers = Just msg.headers
          , traceContext = extractTraceHeaders msg.headers
          , attempt = msg.deliveryAttempt
          , attributes = msg.otelAttributes
          }
   in mkIngested env (AckHandle (finalizeNative msg))
```

Adapter source streams should stop when `shutdown` is called so graceful
shutdown can drain already-ingested messages and flush partial batches.
