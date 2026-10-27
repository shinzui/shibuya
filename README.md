<p align="center">
  <img src="docs/images/shibuya-logo.png" alt="Shibuya" width="800"><br>
  Supervised queue processing for Haskell, inspired by <a href="mori://dashbitco/broadway">Broadway</a>
</p>

Shibuya runs message handlers under supervision with bounded inboxes, explicit
acknowledgement decisions, keyed batching, and configurable ordering. Adapters
provide messages and implement the queue's commit, retry, and dead-letter
operations. Handlers work with a common message API while the adapter retains
ownership of backend semantics.

**Current release: 0.12.0.0.** Shibuya is pre-1.0 and follows the Haskell PVP;
source-breaking changes increment the second version component. See the
[upgrade notes](#upgrading-to-01200) before changing an existing application's
bounds.

## Packages and adapters

This repository releases two packages together:

| Package | Purpose | API reference |
|---------|---------|---------------|
| `shibuya-core` | Processors, handlers, adapters, batching, supervision, tracing, and metrics collection | [Hackage](https://hackage.haskell.org/package/shibuya-core-0.12.0.0/docs/Shibuya.html) |
| `shibuya-metrics` | HTTP/JSON, Prometheus, WebSocket metrics, health probes, and optional intake control | [Hackage](https://hackage.haskell.org/package/shibuya-metrics-0.12.0.0/docs/Shibuya-Metrics.html) |

Queue adapters release independently in their own repositories. Check an
adapter's declared `shibuya-core` bounds when choosing a version.

| Backend | Canonical project | Source |
|---------|-------------------|--------|
| Apache Kafka | `mori://shinzui/shibuya-kafka-adapter` | [GitHub](https://github.com/shinzui/shibuya-kafka-adapter) |
| PostgreSQL / pgmq | `mori://shinzui/shibuya-pgmq-adapter` | [GitHub](https://github.com/shinzui/shibuya-pgmq-adapter) |
| In-memory lists | This repository: `Shibuya.Adapter.Mock` | [Source](shibuya-core/src/Shibuya/Adapter/Mock.hs) |

## Installation

The current packages target **GHC 9.12** (`base ^>=4.21.0.0`). To run the example
below, save it as `Main.hs` and use this executable stanza in your Cabal package:

```cabal
executable orders
  main-is: Main.hs
  default-language: GHC2024
  ghc-options: -threaded
  build-depends:
    base ^>=4.21.0.0,
    effectful-core (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8),
    shibuya-core ^>=0.12.0.0
```

Add `shibuya-metrics ^>=0.12.0.0` for the web server, plus the appropriate adapter
package for your queue. The core package includes in-memory adapters for local
examples and tests.

## Quick start

This complete example processes two messages and records their acknowledgement
decisions. It needs no broker.

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Effectful (IOE, liftIO, runEff, (:>))
import Effectful.Exception qualified as Exception
import Shibuya
import Shibuya.Adapter.Mock
  ( getTrackedDecisions,
    newTrackingAck,
    trackedListAdapter,
  )

handleOrder :: (IOE :> es) => Handler es Int
handleOrder message = do
  liftIO $ putStrLn $ "Processing order " <> show message.envelope.payload
  pure AckOk

main :: IO ()
main = runEff $ runTracingNoop $ do
  tracking <- newTrackingAck
  let messages =
        [ mkEnvelope (MessageId "order-1") (1 :: Int),
          mkEnvelope (MessageId "order-2") 2
        ]
      orders = mkProcessor (trackedListAdapter tracking messages) handleOrder

  result <- runApp defaultAppConfig [(ProcessorId "orders", orders)]
  case result of
    Left err -> liftIO $ fail (show err)
    Right app -> waitApp app `Exception.finally` stopApp app

  decisions <- getTrackedDecisions tracking
  liftIO $ print decisions
```

Run it with `cabal run orders`. Replace the in-memory adapter with a queue
adapter to use the same handler structure with an external backend.

`import Shibuya` provides the application API, including tracing runners.
Handlers receive a read-only `Message`: its envelope contains the payload,
message identity, optional partition, cursor, delivery attempt, headers, and
tracing metadata. A message may also carry a lease for visibility extension.
The framework owns acknowledgement finalization.

## Acknowledgements and retries

A handler returns an `AckDecision`:

| Decision | Intent |
|----------|--------|
| `AckOk` | Acknowledge successful processing. |
| `AckRetry (RetryDelay 30)` | Ask the adapter to retry after 30 seconds. |
| `AckDeadLetter (InvalidPayload detail)` | Reject a structurally invalid payload. |
| `AckDeadLetter (ApplicationFailure code detail)` | Reject a permanent application-rule failure. |
| `AckHalt (HaltFatal reason)` | Halt this processor. Graceful halt does not stop sibling processors. |

Validate application dead-letter codes once at startup with `mkDeadLetterCode`.
Other built-in reasons include `PoisonPill` and `MaxRetriesExceeded`; use
`HaltOrderedStream` when halting an ordered stream. Backend retry and dead-letter
behavior is defined by the adapter.

`retryWithBackoff defaultBackoffPolicy message.envelope` returns a retry decision
using the adapter's delivery attempt, or attempt zero when absent. Defaults are a
1-second base, factor 2, a 5-minute cap, and full jitter; `NoJitter` and
`EqualJitter` are also available.

An uncaught handler exception is finalized with `AckRetry (RetryDelay 0)`.
Finalization itself has bounded retries; exhausting them fails the processor.
Adapters must make repeated finalization with the same decision safe. Design
application side effects for redelivery.

## Ordering, batching, and supervision

`mkProcessor` defaults to `Unordered` and `Serial`. A processor's record fields
select its ordering and concurrency; different processors in one `runApp` may
use different payload types and policies.

| Setting | Behavior |
|---------|----------|
| `Serial` | Run one handler at a time. |
| `Ahead n` | Run up to `n` handlers concurrently, with stream results yielded in input order. Handler effects and acknowledgements can complete out of order. |
| `Async n` | Run up to `n` handlers concurrently without ordered result yielding. |
| `StrictInOrder` | Require `Serial`. |
| `PartitionedInOrder` | Process and finalize messages within a partition in arrival order while allowing different partitions to run concurrently. Messages without a partition key are unconstrained. |

Concurrency counts must be positive. Invalid policies, duplicate processor IDs,
and invalid inbox or batch settings are rejected before adapter acquisition.

For batching, use `mkBatchProcessor adapter batchHandler batchConfig`. A
`BatchHandler` receives `BatchInfo` and a nonempty collection of messages, then
returns a `BatchAck`. Configure grouping with `batchKey`, and flush on size,
timeout, or draining. Defaults are 100 messages and a 1-second timeout. Helpers
such as `ackAllOk`, `ackExcept`, and `failMessages` combine a fallback decision
with per-message overrides. See the [batch example](shibuya-example/app-batch/Main.hs).

Application settings start with `defaultAppConfig`:

```haskell
let config = defaultAppConfig
      { strategy = StopAllOnFailure,
        inboxSize = 500,
        metricsDetail = MetricsDetailed defaultDetailOptions
      }
```

The default strategy, `IgnoreFailures`, isolates failed processors;
`StopAllOnFailure` stops siblings and propagates a processor failure. A finite
source completing or a handler returning `AckHalt` does not trigger that failure
policy. The default inbox capacity is 100 per processor; a full inbox blocks
further intake.

## Lifecycle and intake control

`runApp` returns an `AppHandle` for observation, control, and shutdown:

| Operation | Purpose |
|-----------|---------|
| `waitApp app` | Wait for every processor to finish; an infinite source keeps it waiting. |
| `getAppMetrics app` | Read the current processor metrics. |
| `pauseProcessor app processorId` | Pause further source admissions. |
| `resumeProcessor app processorId` | Resume intake. |
| `isProcessorPaused app processorId` | Inspect pause state when the processor is controllable. |
| `stopApp app` | Shut down using the default graceful-stop configuration. |
| `stopAppGracefully shutdownConfig app` | Choose shutdown deadlines and observe whether draining completed cleanly. |

Pausing lets already admitted polls, inbox messages, and handlers drain; it does
not cancel their work. Control requests report outcomes such as already paused,
unknown processor, terminal processor, or application draining.

Shutdown asks adapters to stop, drains admitted work, then force-stops remaining
processors as needed. Defaults allow 30 seconds for draining and 60 seconds for
the overall graceful phase. Repeated and concurrent stop calls share one shutdown
result. Use exception-safe cleanup around the returned handle, as in the quick
start.

## Metrics, health, and tracing

Basic metrics are enabled by default: processor state, in-flight work, received,
processed, failed, and batch statistics. Opt into
`MetricsDetailed defaultDetailOptions` for latency histograms, the oldest
in-flight message, and bounded acknowledged cursor progress. Cursor progress
reflects successful finalization; it is not a restart checkpoint.

The optional `shibuya-metrics` server binds to `127.0.0.1:9090` by default:

| Endpoint | Purpose |
|----------|---------|
| `GET /metrics` | JSON metrics for all processors. |
| `GET /metrics/<processor-id>` | JSON metrics for one processor. |
| `GET /metrics/prometheus` | Prometheus metrics. |
| `/ws` | WebSocket snapshots, updates, and terminal notifications. |
| `GET /health`, `/health/live`, `/health/ready` | Detailed health, liveness, and readiness. |
| `GET /control` | Discover whether intake control is enabled. |
| `POST /control/processors/<processor-id>/pause` or `/resume` | Optional intake control. |

Use `withMetricsServer defaultConfig (getAppMaster app)` to scope the server's
lifetime to an `IO` action. Control POSTs require `enableControl = True` and have
no built-in authentication. Configure explicit `corsAllowedOrigins` for browser
access; HTTP CORS headers are absent by default. WebSocket delivery has bounded
frame and byte queues, recovery snapshots after dropped updates, and send and
shutdown deadlines. See the [metrics reference](docs/architecture/METRICS.md).

For OpenTelemetry, wrap the application in `runTracing tracer`; use
`runTracingNoop` to disable recording. Enabled tracing covers message processing,
source lifetimes, and adapter shutdown, including incoming W3C parent context and
acknowledgement outcomes. SDK/exporter setup and custom handler spans are covered
in the [OpenTelemetry guide](docs/user/opentelemetry.md).

## Upgrading to 0.12.0.0

`Ingested` now carries `deliveryStatus`. Direct record constructors must add
`deliveryStatus = pure DeliveryCurrent`; positional construction needs the extra
field. `mkIngested` supplies this default, so smart-constructor users need no
change for this field.

An adapter can return `DeliverySuperseded` when redelivery is arranged or a
delivery has been fenced. The runner samples status once at handler admission;
superseded deliveries receive no handler or finalizer call and no processing
outcome. Batches retain current members in order and report their retained size.
The action must return promptly without side effects or synchronous exceptions.
A current answer is a snapshot, not protection against a later concurrent retry.

`shibuya-metrics` now requires `shibuya-core ^>=0.12.0.0`. When upgrading from an
older series, also review the [changelog](CHANGELOG.md) for earlier configuration,
processor-state, health, and WebSocket API changes. Prefer default configurations
with record updates to constructing every field yourself.

## Documentation and development

- [Getting started](docs/user/getting-started.md) — handlers, batches, and applications.
- [User guides](docs/user/README.md) — tracing and earlier migration guides.
- [Architecture](docs/architecture/) — core types, message flow, metrics, and concurrency.
- [Changelog](CHANGELOG.md) — release history and breaking changes.
- [Core example](shibuya-example/app/Main.hs) — multiple processors and a metrics server.
- [Batch example](shibuya-example/app-batch/Main.hs) — grouping and batch decisions.

The repository's Nix development shell pins GHC 9.12.4. From a checkout:

```bash
nix develop
cabal build all
cabal test shibuya-core shibuya-metrics --enable-tests
cabal run shibuya-example
# Or run the finite batching example:
cabal run shibuya-batch-example
```

`shibuya-example` and `shibuya-core-bench` are local example and benchmark packages;
they are not published to Hackage. See the [benchmark runbook](shibuya-core-bench/README.md)
for the existing performance workflow. Format with `nix fmt` and run
`nix flake check` before contributing.

## License

[MIT](LICENSE)
