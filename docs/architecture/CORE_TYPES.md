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
  { messageId  :: !MessageId
  , cursor     :: !(Maybe Cursor)
  , partition  :: !(Maybe Text)
  , enqueuedAt :: !(Maybe UTCTime)
  , payload    :: !msg
  }
```

Normalized message container. Adapters convert queue-specific formats into `Envelope`.

| Field | Purpose |
|-------|---------|
| `messageId` | Unique ID for deduplication |
| `cursor` | Position in stream (optional) |
| `partition` | Partition key for ordered delivery (optional) |
| `enqueuedAt` | When message was queued (optional) |
| `payload` | The actual message data |

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
  { extend   :: Eff es ()
  , cancel   :: Eff es ()
  , timeLeft :: Eff es NominalDiffTime
  }
```

For queues with visibility timeouts (SQS). Handlers can extend their lease for long-running work.

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
