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
| `traceContext` | W3C trace context headers for distributed tracing (optional) |
| `payload` | The actual message data |

### TraceHeaders

```haskell
type TraceHeaders = [(ByteString, ByteString)]
```

W3C Trace Context headers for distributed tracing. Typically contains `"traceparent"` and optionally `"tracestate"` headers. Used by the telemetry layer to propagate trace context across queue boundaries.

## What Handlers Receive

### Ingested

```haskell
data Ingested es msg = Ingested
  { envelope :: !(Envelope msg)
  , ack      :: !(AckHandle es)
  , lease    :: !(Maybe (Lease es))
  }
```

The single type that flows through the system. Handlers receive this and return an `AckDecision`.

| Field | Purpose |
|-------|---------|
| `envelope` | Message metadata + payload |
| `ack` | Handle for acknowledgment (managed by framework) |
| `lease` | Optional visibility timeout extension |

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
type Handler es msg = Ingested es msg -> Eff es AckDecision
```

A handler is simply a function from `Ingested` to `AckDecision`. The `es` type parameter allows effectful operations (IO, database, etc.).

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
  | HandlerTimeout

data RuntimeError
  = SupervisorFailed !Text
  | InboxOverflow
```

Error types used to categorize failures in the framework:

| Type | Purpose |
|------|---------|
| `PolicyError` | Invalid ordering/concurrency policy combinations |
| `HandlerError` | Handler threw an exception or timed out |
| `RuntimeError` | Supervisor failures or inbox overflow |

These are wrapped by `AppError` in `Shibuya.App`:

```haskell
data AppError
  = AppPolicyError !PolicyError
  | AppHandlerError !HandlerError
  | AppRuntimeError !RuntimeError
```
