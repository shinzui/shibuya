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

## Multi-Queue Architecture

Each queue processor runs in its own independent pipeline:

```
runApp strategy inboxSize
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
runApp strategy inboxSize processors
```

1. `startMaster strategy` - Creates NQE Supervisor and MetricsMap
2. For each `(procId, QueueProcessor adapter handler)`:
   - `runSupervised master inboxSize procId adapter handler`
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
4. Call `handler ingested`
5. Call `ingested.ack.finalize decision`
6. Update metrics based on decision
7. Update state to `Idle`
8. Loop

### 5. Graceful Shutdown

```haskell
stopApp appHandle
```

1. Call `adapter.shutdown` for all adapters
2. Adapters stop producing messages
3. Ingesters complete when streams exhaust
4. Processors drain remaining messages
5. `stopMaster` cancels supervisor

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
