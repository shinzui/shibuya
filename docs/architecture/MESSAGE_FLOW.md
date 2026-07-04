# Message Flow

This document describes how messages flow through Shibuya from adapter to handler.

## Single Queue Processor Flow

The diagram below shows the internal flow for **one** queue processor.
Each queue processor created via `runApp` gets its own instance of this pipeline.

```
┌──────────────────────────────────────────────────────────────────┐
│                 runSupervised (per queue processor)              │
└──────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│                    runIngesterAndProcessor                       │
│                                                                  │
│  ┌────────────────────┐                                          │
│  │ newBoundedInbox    │◄── inboxSize (backpressure control)     │
│  │    (inboxSize)     │                                          │
│  └─────────┬──────────┘                                          │
│            │                                                     │
│  ┌─────────┴─────────────────────────────────────────────────┐   │
│  │                                                           │   │
│  │  ┌─────────────────┐         ┌─────────────────────────┐  │   │
│  │  │   Ingester      │         │      Processor          │  │   │
│  │  │   (async)       │         │      (main thread)      │  │   │
│  │  │                 │         │                         │  │   │
│  │  │ adapter.source  │         │ receive inbox           │  │   │
│  │  │      │          │         │      │                  │  │   │
│  │  │      ▼          │         │      ▼                  │  │   │
│  │  │ incReceived     │         │ handler(ingested)       │  │   │
│  │  │      │          │         │      │                  │  │   │
│  │  │      ▼          │         │      ▼                  │  │   │
│  │  │ send to inbox ──┼────────►│ ack.finalize(decision)  │  │   │
│  │  │                 │         │      │                  │  │   │
│  │  │                 │         │      ▼                  │  │   │
│  │  │                 │         │ incProcessed/incFailed  │  │   │
│  │  └─────────────────┘         └─────────────────────────┘  │   │
│  │                                                           │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                  │
│  On stream exhaust: set streamDoneVar = True                    │
│  Processor exits when: streamDone AND inbox empty               │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## Batching Stage (optional)

A processor created with `mkBatchProcessor` (or the `BatchingProcessor`
constructor) inserts a **Batcher** between the bounded inbox and the handler.
Instead of running a `Handler` once per message, the framework accumulates
messages into batches and runs a `BatchHandler` once per emitted batch.

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                    runSupervisedBatch (per batching processor)           │
│                                                                          │
│  adapter.source ──► Ingester ──► ┌─────────────────┐                     │
│   (stream)          incReceived  │  Bounded Inbox  │◄── inboxSize         │
│                                  │  (backpressure) │    (blocks if full)  │
│                                  └────────┬────────┘                      │
│                                           │                              │
│                                           ▼                              │
│                    ┌──────────────────────────────────────────┐          │
│                    │              Batcher                      │          │
│                    │  accumulate by batchKey (per-key size &   │          │
│                    │  timeout); emit a batch on the first of:  │          │
│                    │    • reached batchSize   → TriggerSize    │          │
│                    │    • batchTimeout elapsed → TriggerTimeout│          │
│                    │    • drain / shutdown    → TriggerFlush   │          │
│                    └────────────────────┬─────────────────────┘          │
│                                         │ NonEmpty (Message es msg)       │
│                                         ▼         + BatchInfo             │
│                    ┌──────────────────────────────────────────┐          │
│                    │           Batch handler                   │          │
│                    │  runs once over the whole batch,          │          │
│                    │  returns a single BatchAck                │          │
│                    └────────────────────┬─────────────────────┘          │
│                                         │ BatchAck (decisions + fallback) │
│                                         ▼                                 │
│                    ┌──────────────────────────────────────────┐          │
│                    │        Batch finalization                 │          │
│                    │  one decision per RETAINED message        │          │
│                    │  (MessageId lookup in decisions, else     │          │
│                    │  fallback); apply each via idempotent     │          │
│                    │  finalizer with bounded retry; a          │          │
│                    │  permanent finalizer failure fails loud   │          │
│                    │  with the affected MessageId              │          │
│                    └──────────────────────────────────────────┘          │
│                                                                          │
│  A single timeout ticker thread scans accumulators, so flush latency is  │
│  bounded by tickInterval. Concurrency (Serial | Ahead n | Async n) is    │
│  reused to bound how many BATCHES run at once while preserving FIFO       │
│  execution within each BatchKey.                                         │
└──────────────────────────────────────────────────────────────────────────┘
```

**Batch key routing.** Each message's `batchKey` is computed from its envelope
(a pure function in `BatchConfig`). Messages sharing a key accumulate into the
same sub-batch, and every `BatchKey` has its own independent size counter and
timeout. Use `const defaultBatchKey` for a single undivided batch.

**Three triggers.** A batch is emitted on the first of: reaching `batchSize`
(`TriggerSize`), `batchTimeout` elapsing since the batch's first message arrived
(`TriggerTimeout`), or the processor draining on shutdown, which flushes any
partial batch (`TriggerFlush`). The `BatchInfo` passed to the handler records
which `trigger` fired.

**Batch handler.** The `BatchHandler` receives the `BatchInfo` and the whole
batch as a `NonEmpty (Message es msg)`, runs once, and returns a single
`BatchAck`.

**One decision per retained message + bounded retry / fail loud.** Given the
emitted batch and the returned `BatchAck`, the framework resolves exactly one
`AckDecision` for every message in its own retained batch list. For each
retained message it looks the message's `MessageId` up in `decisions`; if the id
is absent it uses `fallback`. The handler's return value only supplies decisions
— it never drives which messages are acked. Each resolved decision is then
applied through the message's idempotent finalizer with bounded retries. A
permanently failing finalizer is surfaced as a loud processor failure with the
affected `MessageId`; it is not swallowed.

## Multi-Queue Architecture

Each queue processor runs in its own independent pipeline:

```
runApp AppConfig { strategy, inboxSize }
  [ (ProcessorId "orders", mkProcessor ordersAdapter ordersHandler)
  , (ProcessorId "events", mkProcessor eventsAdapter eventsHandler)
  ]

                    │
                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                           Master                                │
│         (shared Supervisor + MetricsMap)                        │
└─────────────────────────────────────────────────────────────────┘
          │                                    │
          ▼                                    ▼
┌──────────────────────────┐    ┌──────────────────────────┐
│ runIngesterAndProcessor  │    │ runIngesterAndProcessor  │
│      "orders"            │    │      "events"            │
│                          │    │                          │
│  ┌────────────────────┐  │    │  ┌────────────────────┐  │
│  │  Bounded Inbox     │  │    │  │  Bounded Inbox     │  │
│  │  (own inboxSize)   │  │    │  │  (own inboxSize)   │  │
│  └────────────────────┘  │    └────────────────────────┘  │
│  Ingester → Processor    │    │  Ingester → Processor    │
│  ordersAdapter           │    │  eventsAdapter           │
│  ordersHandler           │    │  eventsHandler           │
└──────────────────────────┘    └──────────────────────────┘
```

Each queue processor is **completely independent**:
- Own bounded inbox (backpressure is per-queue)
- Own ingester thread
- Own processor thread
- Own metrics (registered with shared Master)
- Supervised as separate children (failures don't affect other queues)

## Detailed Steps

### 1. Application Startup

```haskell
runApp config processors
```

1. Validate `config.inboxSize`, all ordering/concurrency policies, and every
   batch config before starting any processor.
2. `startMaster config.strategy` - Creates NQE Supervisor and MetricsMap
3. For each `(procId, QueueProcessor adapter handler)`:
   - `runSupervised master config.inboxSize procId ordering concurrency adapter handler`
   - Creates its own bounded inbox
   - Registers its metrics TVar with Master
   - Spawns as supervised child

### 2. Processor Startup

```haskell
runIngesterAndProcessor metricsVar doneVar inboxSize adapter handler
```

1. Create bounded inbox: `newBoundedInbox inboxSize`
2. Create stream-done signal: `newTVarIO False`
3. Spawn ingester async
4. Run processor in main thread

### 3. Ingester Loop

```haskell
runIngesterWithMetrics metricsVar adapter.source inbox
```

For each message from `adapter.source`:

1. Increment `received` metric
2. Send to inbox (blocks if full - **backpressure**)
3. Continue until stream exhausts
4. Set `streamDoneVar = True`

### 4. Processor Loop

```haskell
processUntilDrained metricsVar handler inbox streamDoneVar
```

Loop:

1. Check: `streamDone AND inbox empty`?
   - Yes: Exit (all done)
   - No: Continue
2. `receive inbox` (blocks if empty)
3. Update state to `Processing`
4. Project the internal `Ingested` value to handler-facing `Message`
5. Call `handler message`
6. Call `ingested.ack.finalize decision`
7. Update metrics based on decision
8. Update state to `Idle`
9. Loop

### 5. Graceful Shutdown

```haskell
stopApp appHandle
```

1. Call `adapter.shutdown` for all adapters
2. Adapters stop producing messages
3. Ingesters complete when streams exhaust
4. Processors drain remaining messages for `defaultShutdownConfig.drainTimeout`
5. `stopMaster` cancels any remaining supervised processors

`stopAppGracefully customConfig appHandle` runs the same sequence with a custom
drain timeout and returns `True` if every processor drained before the timeout.

## Backpressure

Backpressure is provided by NQE's bounded inbox:

```
Fast Adapter                  Slow Handler
     │                              │
     ▼                              │
 Ingester                           │
     │                              │
     ▼                              │
┌─────────────┐                     │
│   Inbox     │ ◄── When full,      │
│ [msg][msg]  │     send BLOCKS     │
│ [msg][msg]  │                     │
└─────────────┘                     │
     │                              │
     └──────────────────────────────┘
                  │
                  ▼
              Processor
                  │
                  ▼
               Handler (slow)
```

- `inboxSize` controls how many messages can buffer
- Small inbox = tighter backpressure, less memory
- Large inbox = smoother throughput, more memory

## Metrics Updates

| Event | Metric Updated | State Change |
|-------|----------------|--------------|
| Message received by ingester | `stats.received++` | - |
| Handler called | - | `Idle → Processing` |
| `AckOk` | `stats.processed++` | `Processing → Idle` |
| `AckRetry` | `stats.processed++` | `Processing → Idle` |
| `AckDeadLetter` | `stats.failed++` | `Processing → Idle` |
| `AckHalt` | - | `Processing → Failed` |
| Handler throws | `stats.failed++` | `Processing → Failed` |
| Batch emitted at `batchSize` | `batch.batchesEmitted++`, `batch.batchedMessages += N`, `batch.sizeTriggered++` | - |
| Batch emitted at `batchTimeout` | `batch.batchesEmitted++`, `batch.batchedMessages += N`, `batch.timeoutTriggered++` | - |
| Batch flushed on drain/shutdown | `batch.batchesEmitted++`, `batch.batchedMessages += N`, `batch.flushTriggered++` | - |
| Batch partial failure (handler named ≥1 failing message) | `batch.partialFailures++` | - |
| Per-message ack within a batch | `stats.processed++` or `stats.failed++` per message | - |

A batching processor's per-message counters (`stats.received/processed/failed`)
update exactly as for a single-message processor — each message in a batch is
finalized individually — while the `batch.*` counters summarize batch-level
activity.

## Finite vs Infinite Streams

### Infinite Streams (Production)

- Adapter polls queue forever
- Ingester runs until cancelled
- Processor runs until cancelled
- Use `stopApp` for graceful shutdown

### Finite Streams (Testing)

- Adapter produces fixed list of messages
- Ingester completes when stream exhausts
- Processor drains remaining messages then exits
- `waitApp` returns when all processors done
