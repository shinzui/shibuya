---
title: "Supervised processing with bounded backpressure"
type: Capability
description: "Run many named queue processors under one supervised application with bounded inboxes, failure isolation, and graceful shutdown that drains in-flight work."
generated:
  by: claude-opus-5/1
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-3
provider: mori://shinzui/shibuya
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-core
interface:
  - Shibuya.App
  - Shibuya.Internal.Runner.Supervised
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs
    proves: Failure isolation, restart behavior, drain-on-shutdown, and shutdown timeouts.
  - kind: test
    resource: shibuya-core/test/Shibuya/App/LifecycleSpec.hs
    proves: Application lifecycle across supervision strategies and inbox sizes.
  - kind: test
    resource: shibuya-core/test/Shibuya/RunnerSpec.hs
    proves: An invalid inbox size is rejected before any processor starts.
  - kind: example
    resource: shibuya-example/app/Main.hs
    proves: Multiple independent processors running concurrently under one application.
---

# Supervised processing with bounded backpressure

**Builds on:** [CAP-1 — backend-agnostic queue processing](backend-agnostic-queue-processing.md).

`runApp` takes an `AppConfig` — a supervision strategy and an inbox size — and a list of named
processors, and returns a handle for introspection and shutdown.

```haskell
result <- runApp
  defaultAppConfig { inboxSize = 500 }
  [ (ProcessorId "orders", ordersProcessor)
  , (ProcessorId "events", eventsProcessor)
  ]
```

Supervision and backpressure are one capability rather than two because a consumer cannot adopt
either separately: both are properties of `AppConfig`, and calling `runApp` gets both.

## What it provides

- **Failure isolation.** A processor that fails is supervised independently; one bad queue does
  not take down the others.
- **Bounded inboxes.** Ingestion is bounded, so a fast producer cannot exhaust memory while a
  slow handler catches up. An `inboxSize` of zero or below is rejected before startup rather
  than producing a stalled processor.
- **Graceful shutdown.** `stopAppGracefully` drains in-flight work within a deadline;
  `stopApp` stops promptly. A pending partial batch is flushed and acknowledged on graceful
  shutdown.

## Limits

- Backpressure is bounded ingestion, not rate limiting: it stops the pipeline from running
  ahead of the handler, but it does not pace the broker.
- Supervision restarts a processor; it does not reason about *why* it failed. A handler that
  fails deterministically on a poisoned message needs `AckDeadLetter` (see
  [CAP-2](explicit-acknowledgement-semantics.md)), not supervision.
