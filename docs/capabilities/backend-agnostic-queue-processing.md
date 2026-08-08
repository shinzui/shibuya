---
title: "Backend-agnostic queue processing"
type: Capability
description: "Write a message handler once against a typed envelope and run it on any queue backend, swapping backends without touching handler code."
generated:
  by: claude-opus-5/1
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-1
provider: mori://shinzui/shibuya
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-core
interface:
  - Shibuya
  - Shibuya.Adapter
  - Shibuya.App
  - Shibuya.Handler
evidence:
  - kind: module
    resource: shibuya-core/src/Shibuya/Adapter.hs
    proves: The adapter seam a backend implements — a source stream plus shutdown — is the only backend-specific surface.
  - kind: module
    resource: shibuya-core/src/Shibuya/Adapter/Mock.hs
    proves: An in-memory adapter ships with the core, so handlers are testable with no broker running.
  - kind: example
    resource: shibuya-example/app/Main.hs
    proves: A complete multi-processor application built against the mock adapter.
  - kind: guide
    resource: docs/user/getting-started.md
    proves: End-to-end walkthrough from handler to running application.
---

# Backend-agnostic queue processing

A handler is a function from a typed `Envelope` to an ack decision. It names no broker, no
client library, and no transport. The queue backend is supplied separately as an `Adapter`,
which contributes a source stream and a shutdown action; everything else — supervision,
ordering, acknowledgement, retries, tracing — is the framework's.

The practical consequence is that switching from PostgreSQL to Kafka is a change to the value
you pass as `adapter`, not a rewrite of the handler.

## Using it

```haskell
import Shibuya

handleOrder :: Handler es OrderEvent
handleOrder msg = do
  result <- liftIO $ processOrder msg.envelope.payload
  pure $ case result of
    Right () -> AckOk
    Left _   -> AckRetry (RetryDelay 30)

main = runEff . runTracingNoop $ do
  result <- runApp defaultAppConfig
    [ (ProcessorId "orders", mkProcessor myAdapter handleOrder) ]
  either print waitApp result
```

`import Shibuya` re-exports everything an application author needs.

## Limits

- The core ships only `Shibuya.Adapter.Mock`. Real backends are separate packages with their own
  release cadence — see [`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter)
  and [`shibuya-kafka-adapter`](https://github.com/shinzui/shibuya-kafka-adapter).
- Backends differ in what they can express. Temporary ownership (`Shibuya.Core.Lease`) is
  meaningful for visibility-timeout queues and unused by Kafka-style adapters, and
  `Envelope.attempt` is populated only by backends that track redelivery.
