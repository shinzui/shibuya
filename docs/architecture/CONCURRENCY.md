# Concurrency Architecture

This document describes the concurrency model in Shibuya and the responsibilities of each layer.

## Overview

Shibuya's concurrency is built on three distinct layers:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Application Layer                              │
│                                                                          │
│   runApp IgnoreFailures 100 [(pid, QueueProcessor adapter handler)]     │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         Shibuya Orchestration                            │
│                                                                          │
│   • Creates one pipeline per QueueProcessor                              │
│   • Manages handler-level concurrency (Serial/Async/Ahead)               │
│   • Provides metrics and introspection                                   │
│   • Coordinates graceful shutdown                                        │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
                    ▼               ▼               ▼
┌─────────────────────────┐ ┌─────────────────────────┐
│        Streamly         │ │          NQE            │
│   (Stream Processing)   │ │  (Process Supervision)  │
│                         │ │                         │
│ • Stream-level conc.    │ │ • Thread management     │
│ • Backpressure          │ │ • Supervision strategies│
│ • Message fetching      │ │ • Failure isolation     │
│ • Transformation        │ │ • Bounded inboxes       │
└─────────────────────────┘ └─────────────────────────┘
```

## The Three Concurrency Layers

### Layer 1: NQE (Process Supervision)

**Responsibility**: Thread lifecycle, supervision, and inter-process communication.

**What NQE handles:**

| Feature | Description |
|---------|-------------|
| Thread spawning | `addChild` spawns supervised async threads |
| Supervision strategies | `IgnoreAll`, `KillAll` control failure behavior |
| Process linking | `link` propagates exceptions to parent |
| Bounded inboxes | `newBoundedInbox` creates bounded channels |
| Message passing | `send`/`receive` for typed communication |

**Shibuya's use of NQE:**

```haskell
-- Master creates a supervisor for all processors
startMaster :: SupervisionStrategy -> Eff es Master
startMaster strategy = liftIO $ do
  sup <- Supervisor.supervisor (toNQEStrategy strategy)
  -- ...

-- Each processor runs as a supervised child
supervisedChild <- addChild master.state.supervisor $
  runIngesterAndProcessor metricsVar doneVar inboxSize adapter handler
```

**NQE does NOT handle:**
- What happens inside each processor (that's Shibuya's domain)
- Stream-level concurrency (that's Streamly's domain)
- Application-level retry/DLQ logic (that's the handler's domain)

---

### Layer 2: Streamly (Stream Processing)

**Responsibility**: Stream-level concurrency for message fetching and transformation.

**What Streamly handles:**

| Feature | Description |
|---------|-------------|
| Stream sources | Create streams from queues (Redis, SQS, Kafka) |
| Stream-level concurrency | `parMapM`, `parConcatMap` for parallel fetching |
| Transformations | Filter, batch, rate-limit, decode |
| Backpressure | Flow control between stream and consumers |
| Stream fusion | 10-100x performance via compile-time fusion |

**Key Streamly concurrency combinators:**

```haskell
-- Concurrent map over stream elements
parMapM :: (Config -> Config) -> (a -> m b) -> Stream m a -> Stream m b

-- Configuration options
maxThreads :: Int -> Config -> Config      -- Max concurrent workers
maxBuffer :: Int -> Config -> Config       -- Max buffered results
ordered :: Bool -> Config -> Config        -- Preserve input order
eager :: Bool -> Config -> Config          -- Aggressive worker dispatch
```

**Who controls Streamly concurrency?**

The **user** controls Streamly concurrency through their `Adapter`. Shibuya receives
a `Stream` from the adapter and consumes it - Shibuya does not configure the stream.

```haskell
-- User's adapter can configure stream-level concurrency
myAdapter :: Adapter es MyMessage
myAdapter = Adapter
  { adapterName = "my-queue"
  , source = parMapM (maxThreads 10) fetchMessage messageIds  -- User's choice!
  , shutdown = closeConnection
  }
```

**Streamly does NOT handle:**
- Handler execution (that's Shibuya's domain)
- Process supervision (that's NQE's domain)
- Ack/Nack semantics (that's the handler's domain)

---

### Layer 3: Shibuya (Handler Orchestration)

**Responsibility**: Orchestrating handler execution with ordering and concurrency policies.

**What Shibuya handles:**

| Feature | Description |
|---------|-------------|
| Pipeline creation | One ingester→inbox→processor per queue |
| Handler invocation | Calling handlers with `Ingested` messages |
| Ack semantics | Routing `AckOk`/`AckRetry`/`AckDeadLetter`/`AckHalt` |
| Metrics | Tracking received/processed/failed counts |
| Handler-level concurrency | Serial/Async/Ahead modes (see below) |

**Current implementation (v0.1.0-alpha):**

All processing is **Serial** - one message at a time per processor:

```
Adapter.source → Ingester → Inbox → Processor → Handler (one at a time)
                              │
                              └── Backpressure via bounded inbox
```

---

## Handler-Level Concurrency (Planned)

Shibuya defines three handler concurrency modes in `Policy.hs`:

```haskell
data Concurrency
  = Serial       -- Process one message at a time (IMPLEMENTED)
  | Ahead !Int   -- Prefetch N, process in order (PLANNED)
  | Async !Int   -- Process N concurrently (PLANNED)
```

### Serial (Current)

```
┌─────────────────────────────────────────────────────────────┐
│                    Serial Processing                         │
│                                                              │
│  Inbox: [msg1] [msg2] [msg3] [msg4] [msg5]                  │
│            │                                                 │
│            ▼                                                 │
│        Handler ─────► Handler ─────► Handler ─────► ...     │
│          msg1          msg2          msg3                   │
│                                                              │
│  Output order: msg1, msg2, msg3, msg4, msg5                 │
│  Guaranteed: Input order = Output order                      │
└─────────────────────────────────────────────────────────────┘
```

**Semantics:**
- Messages processed one at a time
- Output order matches input order
- Simple and predictable
- Lower throughput for I/O-bound handlers

---

### Ahead (Planned)

```
┌─────────────────────────────────────────────────────────────┐
│                 Ahead Processing (N=3)                       │
│                                                              │
│  Inbox: [msg1] [msg2] [msg3] [msg4] [msg5]                  │
│            │      │      │                                   │
│            ▼      ▼      ▼                                   │
│        ┌──────┬──────┬──────┐                               │
│        │ H(1) │ H(2) │ H(3) │  ← Concurrent execution       │
│        └──┬───┴──┬───┴──┬───┘                               │
│           │      │      │                                    │
│           ▼      ▼      ▼                                    │
│        [done] [done] [done]  ← Results buffered             │
│           │                                                  │
│           ▼                                                  │
│        Output: msg1, msg2, msg3  ← In original order        │
│                                                              │
│  Output order: msg1, msg2, msg3, msg4, msg5                 │
│  Guaranteed: Input order = Output order                      │
└─────────────────────────────────────────────────────────────┘
```

**Semantics:**
- Prefetch N messages, process handlers concurrently
- **Output order preserved** (like Streamly's `ordered True`)
- Better throughput than Serial for I/O-bound handlers
- Use case: When order matters but handlers are slow

**Implementation approach:**
Would use Streamly's `parMapM (maxBuffer n . ordered True)` internally.

---

### Async (Planned)

```
┌─────────────────────────────────────────────────────────────┐
│                 Async Processing (N=3)                       │
│                                                              │
│  Inbox: [msg1] [msg2] [msg3] [msg4] [msg5]                  │
│            │      │      │                                   │
│            ▼      ▼      ▼                                   │
│        ┌──────┬──────┬──────┐                               │
│        │ H(1) │ H(2) │ H(3) │  ← Concurrent execution       │
│        │ slow │ fast │ med  │                               │
│        └──┬───┴──┬───┴──┬───┘                               │
│           │      │      │                                    │
│           │      ▼      │                                    │
│           │   [msg2]    │  ← msg2 completes first           │
│           │      │      ▼                                    │
│           │      │   [msg3]  ← msg3 completes second        │
│           ▼      │      │                                    │
│        [msg1]    │      │  ← msg1 completes last            │
│                                                              │
│  Output order: msg2, msg3, msg1  ← Completion order!        │
│  NOT guaranteed: Input order ≠ Output order                  │
└─────────────────────────────────────────────────────────────┘
```

**Semantics:**
- Process N handlers concurrently
- **Output order NOT preserved** (completion order)
- Maximum throughput
- Use case: When order doesn't matter (e.g., independent events)

**Implementation approach:**
Would use Streamly's `parMapM (maxBuffer n)` (without `ordered`).

---

## Ordering Policies

The `Ordering` policy documents the message ordering contract:

```haskell
data Ordering
  = StrictInOrder       -- Every message in exact order
  | PartitionedInOrder  -- Order within partitions (like Kafka)
  | Unordered           -- No ordering guarantees
```

### Policy Validation

Certain combinations are invalid:

| Ordering | Serial | Ahead | Async |
|----------|--------|-------|-------|
| StrictInOrder | ✅ | ✅ | ❌ |
| PartitionedInOrder | ✅ | ✅ | ✅ |
| Unordered | ✅ | ✅ | ✅ |

`StrictInOrder` + `Async` is invalid because Async doesn't preserve order.

---

## Concurrency Boundaries Summary

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        WHO IS RESPONSIBLE FOR WHAT                        │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  STREAM-LEVEL CONCURRENCY (fetching messages)                            │
│  ─────────────────────────────────────────────                           │
│  Owner: Streamly (configured by USER in Adapter)                         │
│                                                                           │
│  Examples:                                                                │
│  • Fetch from multiple partitions concurrently                           │
│  • Batch messages from slow sources                                      │
│  • Rate-limit message production                                         │
│                                                                           │
│  User configures via:                                                     │
│    adapter.source = parMapM (maxThreads 10) fetchMessage ids            │
│                                                                           │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  HANDLER-LEVEL CONCURRENCY (processing messages)                         │
│  ───────────────────────────────────────────────                         │
│  Owner: Shibuya (configured by USER via Concurrency policy)              │
│                                                                           │
│  Examples:                                                                │
│  • Call handlers for multiple messages concurrently                      │
│  • Prefetch messages while handler is running                            │
│  • Preserve ordering while parallelizing                                 │
│                                                                           │
│  User configures via:                                                     │
│    Concurrency = Serial | Ahead 10 | Async 10                           │
│    (NOTE: Only Serial implemented in v0.1.0-alpha)                       │
│                                                                           │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  PROCESS-LEVEL CONCURRENCY (multiple processors)                         │
│  ───────────────────────────────────────────────                         │
│  Owner: NQE (configured by Shibuya internally)                           │
│                                                                           │
│  Examples:                                                                │
│  • Run multiple queue processors concurrently                            │
│  • Isolate failures between processors                                   │
│  • Supervise and restart failed processors                               │
│                                                                           │
│  User configures via:                                                     │
│    SupervisionStrategy = IgnoreFailures | StopAllOnFailure              │
│                                                                           │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Current Limitations (v0.1.0-alpha)

1. **Handler concurrency**: Only `Serial` is implemented. `Ahead` and `Async` are defined but not enforced.

2. **Policy validation**: `validatePolicy` exists but is not called. Invalid combinations are not rejected.

3. **No restart semantics**: NQE doesn't have one-for-one restart. Failed processors stay failed (with `IgnoreFailures`) or all stop (with `StopAllOnFailure`).

---

## Future Work

### Implementing Ahead/Async

When implementing handler-level concurrency, Shibuya would use Streamly internally:

```haskell
-- Conceptual implementation
processorLoop :: Concurrency -> Handler es msg -> Stream m (Ingested es msg) -> m ()
processorLoop concurrency handler inboxStream = case concurrency of
  Serial ->
    Stream.fold Fold.drain $ Stream.mapM (processOne handler) inboxStream

  Ahead n ->
    Stream.fold Fold.drain $
      parMapM (maxBuffer n . ordered True) (processOne handler) inboxStream

  Async n ->
    Stream.fold Fold.drain $
      parMapM (maxBuffer n) (processOne handler) inboxStream
```

### Considerations

1. **Ack ordering**: With Async, acks may complete out of order. The adapter must handle this.

2. **Error propagation**: With concurrent handlers, how do failures affect other in-flight handlers?

3. **Backpressure**: The bounded inbox already provides backpressure, but handler concurrency adds another buffer.

4. **Metrics accuracy**: With concurrent handlers, "currently processing" count becomes more complex.

---

## Related Documentation

- [MESSAGE_FLOW.md](MESSAGE_FLOW.md) - Detailed message flow diagrams
- [METRICS.md](METRICS.md) - Metrics and introspection
- [../USAGE_GUIDE.md](../USAGE_GUIDE.md) - User guide
