# Shibuya Architecture

Shibuya is a queue processing framework for Haskell, inspired by Broadway (Elixir). It provides supervised, metrics-tracked message processing with backpressure.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                           runApp                                │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                         Master                            │  │
│  │  ┌─────────────────┐  ┌─────────────────┐                │  │
│  │  │   Supervisor    │  │   MetricsMap    │                │  │
│  │  │    (NQE)        │  │    (TVar)       │                │  │
│  │  └────────┬────────┘  └─────────────────┘                │  │
│  └───────────┼───────────────────────────────────────────────┘  │
│              │                                                   │
│   ┌──────────┴──────────┐                                       │
│   │                     │                                       │
│   ▼                     ▼                                       │
│ ┌─────────────────┐  ┌─────────────────┐                       │
│ │   Processor 1   │  │   Processor 2   │  ...                  │
│ │ ┌─────────────┐ │  │ ┌─────────────┐ │                       │
│ │ │  Ingester   │ │  │ │  Ingester   │ │                       │
│ │ │  (async)    │ │  │ │  (async)    │ │                       │
│ │ └──────┬──────┘ │  │ └──────┬──────┘ │                       │
│ │        ▼        │  │        ▼        │                       │
│ │ ┌─────────────┐ │  │ ┌─────────────┐ │                       │
│ │ │Bounded Inbox│ │  │ │Bounded Inbox│ │                       │
│ │ │ (inboxSize) │ │  │ │ (inboxSize) │ │                       │
│ │ └──────┬──────┘ │  │ └──────┬──────┘ │                       │
│ │        ▼        │  │        ▼        │                       │
│ │ ┌─────────────┐ │  │ ┌─────────────┐ │                       │
│ │ │  Processor  │ │  │ │  Processor  │ │                       │
│ │ │  (handler)  │ │  │ │  (handler)  │ │                       │
│ │ └─────────────┘ │  │ └─────────────┘ │                       │
│ └─────────────────┘  └─────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

## Key Components

| Component | Module | Purpose |
|-----------|--------|---------|
| `runApp` | `Shibuya.App` | Entry point, starts Master and processors |
| `Master` | `Shibuya.Runner.Master` | Holds Supervisor and MetricsMap |
| `Supervisor` | NQE | Manages processor lifecycles |
| `Ingester` | `Shibuya.Runner.Ingester` | Reads from adapter, sends to inbox |
| `Processor` | `Shibuya.Runner.Processor` | Receives from inbox, calls handler |
| `Adapter` | `Shibuya.Adapter` | Queue-specific message source |
| `Handler` | `Shibuya.Handler` | User-defined message processing |

## Message Flow

```
Adapter.source (Stream)
       │
       ▼
   Ingester ──────► incReceived
       │
       ▼
 Bounded Inbox ◄── backpressure (blocks when full)
       │
       ▼
   Processor
       │
       ▼
    Handler
       │
       ▼
  AckDecision ────► incProcessed / incFailed
       │
       ▼
  ack.finalize
```

## Documents

- [Core Types](./CORE_TYPES.md) - Message, Envelope, AckDecision
- [Message Flow](./MESSAGE_FLOW.md) - Detailed processing pipeline
- [Metrics](./METRICS.md) - Observability and introspection

## Quick Example

```haskell
import Shibuya.App

main :: IO ()
main = runEff $ do
  result <- runApp
    IgnoreFailures      -- Supervision strategy
    100                 -- Inbox size (backpressure)
    [ (ProcessorId "orders", mkProcessor ordersAdapter ordersHandler)
    ]

  case result of
    Left err -> liftIO $ print err
    Right appHandle -> do
      -- App is running, processors are processing
      waitApp appHandle  -- Wait for completion (finite streams)
      -- or: stopApp appHandle  -- Graceful shutdown
```
