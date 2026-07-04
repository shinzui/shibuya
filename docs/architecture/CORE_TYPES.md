# Core Types

This document describes the fundamental types in Shibuya.

## Message Identity

### MessageId

```haskell
newtype MessageId = MessageId { unMessageId :: Text }
```

Unique identifier for idempotency and observability. Every message must have one.

### Cursor

```haskell
data Cursor
  = CursorInt !Int
  | CursorText !Text
```

Optional position/offset in ordered streams. Used for:
- Kafka offsets
- SQS sequence numbers
- Event store positions

## Message Envelope

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

Normalized message container. Adapters convert queue-specific formats into `Envelope`.

| Field | Purpose |
|-------|---------|
| `messageId` | Unique ID for deduplication |
| `cursor` | Position in stream (optional) |
| `partition` | Partition key for ordered delivery (optional) |
| `enqueuedAt` | When message was queued (optional) |
| `traceContext` | Parsed W3C trace context headers for distributed tracing (optional) |
| `headers` | Lossless broker headers, preserving order and duplicates (optional) |
| `attempt` | Zero-indexed delivery attempt, if the adapter can report it |
| `attributes` | Adapter-supplied OpenTelemetry attributes for the per-message span |
| `payload` | The actual message data |

### Headers

```haskell
type Headers = [(ByteString, ByteString)]
```

Raw message headers as delivered by the source broker. Order is preserved and
duplicate keys are allowed. `Nothing` means the adapter does not surface headers;
`Just []` means it does and this message had none.

### TraceHeaders

```haskell
type TraceHeaders = [(ByteString, ByteString)]
```

W3C Trace Context headers for distributed tracing. Typically contains
`"traceparent"` and optionally `"tracestate"` headers. This is the narrow parsed
projection the telemetry layer uses to parent the Consumer span; the original
headers also remain in `headers` when the adapter surfaces them.

### Attempt

```haskell
newtype Attempt = Attempt { unAttempt :: Word }
```

Zero-indexed delivery attempt count. `Just (Attempt 0)` is the first delivery;
`Nothing` means the adapter does not track redeliveries.

## Adapter-Ingested Messages

### Ingested

```haskell
data Ingested es msg = Ingested
  { envelope :: !(Envelope msg)
  , ack      :: !(AckHandle es)
  , lease    :: !(Maybe (Lease es))
  }
```

The framework-side type that flows through the runner. Adapters construct this;
handlers receive its read-only `Message` projection and return an `AckDecision`.

| Field | Purpose |
|-------|---------|
| `envelope` | Message metadata + payload |
| `ack` | Adapter finalizer, managed by the framework |
| `lease` | Optional visibility timeout extension |

Application handlers do not receive `Ingested` directly. The runner projects it
to the read-only `Message` type before invoking user code.

## What Handlers Receive

### Message

```haskell
data Message es msg = Message
  { envelope :: !(Envelope msg)
  , lease    :: !(Maybe (Lease es))
  }
```

Handlers receive `Message`, not `Ingested`, so they cannot ack directly or
finalize with two conflicting decisions. They return an `AckDecision`; the
framework applies that decision through the retained `AckHandle`.

### AckHandle

```haskell
newtype AckHandle es = AckHandle
  { finalize :: AckDecision -> Eff es ()
  }
```

Adapter-provided callback. The framework calls `finalize` after the handler returns.

### Lease

```haskell
data Lease es = Lease
  { leaseId     :: !Text
  , leaseExtend :: NominalDiffTime -> Eff es ()
  }
```

For queues with visibility timeouts (SQS). Handlers can extend their lease for long-running work by calling `leaseExtend` with a duration.

## Ack Decisions

### AckDecision

```haskell
data AckDecision
  = AckOk
  | AckRetry !RetryDelay
  | AckDeadLetter !DeadLetterReason
  | AckHalt !HaltReason
```

Handlers express intent, not mechanics. The framework handles the actual ack/nack.

| Decision | Meaning | Framework Action |
|----------|---------|------------------|
| `AckOk` | Success | Ack to queue, increment `processed` |
| `AckRetry delay` | Transient failure | Nack with delay, message redelivered |
| `AckDeadLetter reason` | Permanent failure | Move to DLQ, increment `failed` |
| `AckHalt reason` | Stop processing | Record halt, stop processor |

### RetryDelay

```haskell
newtype RetryDelay = RetryDelay { unRetryDelay :: NominalDiffTime }
```

How long to wait before retry.

### DeadLetterReason

```haskell
data DeadLetterReason
  = PoisonPill !Text
  | InvalidPayload !Text
  | MaxRetriesExceeded
```

Why a message is permanently failed.

### HaltReason

```haskell
data HaltReason
  = HaltOrderedStream !Text
  | HaltFatal !Text
```

Why processing should stop. Important for ordered streams where out-of-order processing is unacceptable.

## Handler Type

```haskell
type Handler es msg = Message es msg -> Eff es AckDecision
```

A handler is simply a function from `Message` to `AckDecision`. The `es` type
parameter allows effectful operations (IO, database, etc.).

## Adapter Type

```haskell
data Adapter es msg = Adapter
  { adapterName :: !Text
  , source      :: Stream (Eff es) (Ingested es msg)
  , shutdown    :: Eff es ()
  }
```

Adapters provide:
- A name for observability
- A stream of ingested messages
- A shutdown action for cleanup

## Batch Processing

Types in `Shibuya.Batch` (re-exported from `Shibuya.App`) opt a processor into
batching: messages are accumulated into batches and a `BatchHandler` runs once
per emitted batch instead of a `Handler` running once per message.

### BatchKey

```haskell
newtype BatchKey = BatchKey { unBatchKey :: Text }
```

Groups messages into independent sub-batches within one processor. Messages
sharing a key accumulate together; each key has its own size counter and
timeout. `defaultBatchKey = BatchKey "default"` is the key used when a
configuration does not distinguish sub-batches.

### BatchTrigger

```haskell
data BatchTrigger
  = TriggerSize      -- reached the configured batchSize
  | TriggerTimeout   -- batchTimeout elapsed since the batch's first message
  | TriggerFlush     -- processor is draining/shutting down (partial flush)
```

Why the framework emitted a batch. A batch is emitted on the first of these to
occur.

### BatchInfo

```haskell
data BatchInfo = BatchInfo
  { batchKey  :: !BatchKey
  , size      :: !Int
  , trigger   :: !BatchTrigger
  , partition :: !(Maybe Text)
  }
```

Metadata passed to the `BatchHandler` alongside the messages.

| Field | Purpose |
|-------|---------|
| `batchKey` | The key all messages in this batch share |
| `size` | How many messages are in this batch (always ≥ 1) |
| `trigger` | Why this batch was emitted |
| `partition` | Partition of the batch's first message, if the envelope had one |

### BatchConfig

```haskell
data BatchConfig es msg = BatchConfig
  { batchSize    :: !Int
  , batchTimeout :: !NominalDiffTime
  , batchKey     :: !(Envelope msg -> BatchKey)
  , tickInterval :: !(Maybe NominalDiffTime)
  }
```

| Field | Purpose |
|-------|---------|
| `batchSize` | Emit a batch once it holds this many messages (must be ≥ 1) |
| `batchTimeout` | Emit this long after the batch's first message arrives, even if not full (must be > 0) |
| `batchKey` | Compute a message's sub-batch key from its envelope; use `const defaultBatchKey` for a single undivided batch |
| `tickInterval` | How often the timeout ticker scans for timed-out batches; `Nothing` means "use `batchTimeout`". Flush latency is bounded by this interval |

`defaultBatchConfig` uses `batchSize = 100`, `batchTimeout = 1` second,
`batchKey = const defaultBatchKey`, and `tickInterval = Nothing`, matching
Broadway's defaults. `validateBatchConfig` rejects a non-positive
`batchSize`/`batchTimeout`/`tickInterval` with a `BatchConfigError`
(`BatchSizeNotPositive`, `BatchTimeoutNotPositive`, `TickIntervalNotPositive`);
a bad config surfaces from `runApp` as `AppBatchConfigError`.

### BatchHandler

```haskell
type BatchHandler es msg =
  BatchInfo -> NonEmpty (Message es msg) -> Eff es BatchAck
```

Unlike `Handler` (one message → one decision), a batch handler receives every
message in the batch plus its `BatchInfo`, runs once, and returns a single
`BatchAck` describing per-message outcomes.

### BatchAck

```haskell
data BatchAck = BatchAck
  { decisions :: !(Map MessageId AckDecision)
  , fallback  :: !AckDecision
  }
```

How to acknowledge every message in a batch.

| Field | Purpose |
|-------|---------|
| `decisions` | Per-message overrides, keyed by `MessageId` |
| `fallback` | Decision for any message not present in `decisions` |

**Acknowledgement decision contract:**

> Given an emitted batch and the BatchAck a BatchHandler returns, the framework
> resolves exactly one AckDecision for every message in its own retained batch
> list. For each retained message it looks the message's MessageId up in
> `decisions`; if the id is absent it uses `fallback`. The handler's return
> value only supplies decisions — it never drives which messages are acked. The
> execution stage then applies those decisions through each message's idempotent
> finalizer with bounded retries. A permanently failing finalizer is surfaced as
> a loud processor failure with the affected MessageId; it is not swallowed.
> This requires MessageIds to be unique within a batch, which holds for every
> real adapter and the mock adapter.

Smart constructors build a `BatchAck` without touching the `Map` directly:

| Constructor | Meaning |
|-------------|---------|
| `ackAllOk` | Acknowledge every message OK (the common case) |
| `ackAll d` | Apply one decision `d` to every message |
| `ackExcept overrides` | Ack everything OK except the listed messages |
| `withFallback fb overrides` | Give the listed messages their decisions and everything else `fb` |
| `failMessages fs` | Dead-letter the listed messages (with reasons) and ack the rest OK (the common failure case) |

### BatchingProcessor

```haskell
data QueueProcessor es where
  QueueProcessor    :: { adapter :: Adapter es msg, handler :: Handler es msg
                       , ordering :: OrderingPolicy, concurrency :: Concurrency
                       } -> QueueProcessor es
  BatchingProcessor :: { adapter :: Adapter es msg, batchHandler :: BatchHandler es msg
                       , batchConfig :: BatchConfig es msg
                       , ordering :: OrderingPolicy, concurrency :: Concurrency
                       } -> QueueProcessor es

mkBatchProcessor ::
  Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es
```

`BatchingProcessor` is the second `QueueProcessor` constructor; it pairs an
adapter with a `BatchHandler` and a `BatchConfig`. `mkBatchProcessor` is the
convenience constructor with safe default policies (`Unordered` ordering +
`Serial` concurrency, i.e. one batch at a time). The `Concurrency` mode is
reused to bound how many batches run concurrently while preserving FIFO
execution within each `BatchKey`: `Serial` runs one batch at a time in emission
order, `Ahead n` runs batches concurrently but finalizes in order, and `Async n`
runs batches concurrently without ordering.

`BatchingProcessor` rejects `PartitionedInOrder` with `Ahead` or `Async` at
startup because batching is scheduled by `BatchKey`, not by
`Envelope.partition`.

A runnable example lives at `shibuya-example/app-batch/Main.hs`
(`cabal run shibuya-batch-example`).

## In-Flight Tracking

### InFlightInfo

```haskell
data InFlightInfo = InFlightInfo
  { inFlight       :: !Int
  , maxConcurrency :: !Int
  }
```

Tracks concurrent handler executions. Used in the `Processing` state of `ProcessorState`.

| Field | Purpose |
|-------|---------|
| `inFlight` | Number of handlers currently executing |
| `maxConcurrency` | Configured concurrency limit (1 for Serial) |

## Error Types

### Shibuya.Core.Error

```haskell
data PolicyError
  = InvalidPolicyCombo !Text

data HandlerError
  = HandlerException !Text

data RuntimeError
  = SupervisorFailed !Text

data ConfigError
  = InvalidInboxSize !Int
```

Error types used to categorize failures in the framework:

| Type | Purpose |
|------|---------|
| `PolicyError` | Invalid ordering/concurrency policy combinations |
| `HandlerError` | Handler threw an exception |
| `RuntimeError` | Supervisor failures |
| `ConfigError` | Invalid application configuration |

These are wrapped by `AppError` in `Shibuya.App`:

```haskell
data AppError
  = AppPolicyError !PolicyError
  | AppHandlerError !HandlerError
  | AppRuntimeError !RuntimeError
  | AppBatchConfigError !BatchConfigError
  | AppConfigInvalid !ConfigError
```
