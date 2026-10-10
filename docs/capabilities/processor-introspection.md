---
title: "In-process processor introspection"
type: Capability
description: "Read live per-processor state, in-flight information, stream statistics, and batch statistics from the application handle, with no metrics server required."
generated:
  by: claude-opus-5/1
  at: "2026-08-08T00:00:00Z"
timestamp: 2026-10-10T22:17:52Z
capabilityId: CAP-9
provider: mori://shinzui/shibuya
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-core
interface:
  - Shibuya.Core.Metrics
  - Shibuya.App
requires:
  - CAP-3
evidence:
  - kind: module
    resource: shibuya-core/src/Shibuya/Core/Metrics.hs
    proves: ProcessorState, InFlightInfo, StreamStats, and BatchStats are public types with public accessors.
  - kind: test
    resource: shibuya-core/test/Shibuya/Core/MetricsSpec.hs
    proves: Bounded synchronized slots, zero timestamps, cumulative buckets, exact duration sums, absence of basic detail clocks and repeated concurrent reuse at 1/4/64/256 are exercised.
  - kind: test
    resource: shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs
    proves: Growing age, oldest identity, completed failure duration and cancellation cleanup are tested in supervised runners.
  - kind: test
    resource: shibuya-core/test/Shibuya/App/BatchSpec.hs
    proves: AppConfig detail opt-in counts one latency observation per emitted batch.
  - kind: example
    resource: shibuya-example/app/Main.hs
    proves: Reading per-processor counters from the application handle at runtime.
---

# In-process processor introspection

**Builds on:** [CAP-3 — supervised processing with bounded backpressure](supervised-processing-with-backpressure.md).

The handle returned by `runApp` exposes live counters for every named processor, as ordinary
Haskell values:

```haskell
metrics <- getAppMetrics appHandle
forM_ (Map.toList metrics) $ \(ProcessorId name, pm) ->
  putStrLn $ name <> ": " <> show pm.stats.processed <> " processed"
```

`Shibuya.Core.Metrics` publishes `ProcessorState`, `InFlightInfo`, `StreamStats`, and
`BatchStats` — including batch-specific counters for batches emitted, messages batched, partial
failures, and which trigger fired.

This is the substrate for any monitoring approach. Exposing it over HTTP or Prometheus is a
separate, optional package — see [CAP-10](metrics-endpoints.md) — so an application that logs
its own counters, or reports them through an existing telemetry pipeline, does not take on a web
server dependency.

## Limits

- The metrics types are public but the `Shibuya.App` state constructors are not, as of 0.8.0.0:
  read metrics through the handle rather than constructing state directly.
- Counters are per-process. Aggregating across replicas is the caller's job.
- Per-message counters moved off `TVar` updates in 0.8.0.0 for throughput; the values are live
  but not transactional snapshots across processors.

Opt-in `MetricsDetailed defaultDetailOptions` on `AppConfig.metricsDetail` adds optional
`latency` and `oldestInFlight`. Basic remains the default. Duration includes handler execution
and finalization retries, once per attempt or emitted batch; interrupted attempts do not count.
Identity and monotonic start are published together in bounded synchronized slots. Sampling
is best effort across slots. See [the accounting decision](../adr/0009-account-for-in-flight-detail-and-latency-with-bounded-synchronized-slots-behind-an-opt-in-detail-level.md)
and [the metrics architecture](../architecture/METRICS.md#latency-and-in-flight-detail).
