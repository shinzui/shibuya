# Changelog

## Unreleased

### Repo Layout

- `shibuya-pgmq-adapter`, `shibuya-pgmq-adapter-bench`, and
  `shibuya-pgmq-example` now live in their own repository at
  [`shinzui/shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter).
  They will release on their own cadence from this point forward.
  The adapter's own changelog continues in that repository.
- `shibuya-pgmq-adapter/CHANGELOG.md` (per-package history prior to
  the split) was moved with the adapter; this repo's CHANGELOG keeps
  only `shibuya-core` / `shibuya-metrics` history.
- The hasql 1.10 `source-repository-package` pins (`hasql`,
  `hasql-pool`, `hasql-transaction`, `hasql-migration`) were dropped
  from `cabal.project` since no remaining package depends on them.
  The top-level `cabal.project.freeze` was removed so the resolver
  tracks the current dependency graph going forward.

## 0.3.0.0 — 2026-04-24

### Breaking Changes

- `shibuya-pgmq-adapter`: upgrade to `pgmq-hs` 0.2.0.0 series
  (`pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, `pgmq-migration` all
  at `0.2.0.0`).
  - `Pgmq.Effectful.PgmqError` has been renamed to `PgmqRuntimeError`;
    the old name is re-exported as a deprecated alias for one release.
  - Traced spans now follow OpenTelemetry semantic-conventions v1.24.
    Span names (`"publish my-queue"`, `"receive my-queue"`) and
    attribute keys (`messaging.operation`, `messaging.system`,
    `messaging.destination.name`) have changed; dashboards and alerts
    keyed on the old names need updating.
  - `Pgmq.Effectful.Traced.sendMessageTraced` now takes a
    `TracerProvider` instead of a `Tracer`. Use
    `OpenTelemetry.Trace.Core.getTracerTracerProvider` to derive one
    from an existing `Tracer`.

### Other Changes

- `shibuya-core` and `shibuya-metrics` are re-released at 0.3.0.0 to
  track the shared version; neither has user-visible changes of its
  own.
- Documentation: README updated for the 0.2.0.0 release.

## 0.2.0.0 — 2026-04-22

### Breaking Changes

- `shibuya-core`: `Shibuya.Telemetry.Semantic` — rename
  `processMessageSpanName :: Text` to `processSpanName :: Text -> Text`.
  Span names now follow the OpenTelemetry messaging-spans recommendation of
  `"<destination> process"` (e.g. `"shibuya-consumer process"`).
- `shibuya-core`: `Shibuya.Telemetry.Semantic` — remove
  `attrMessagingDestinationPartitionId`. Use the new Shibuya-specific
  `attrShibuyaPartition` instead.
- `shibuya-core`: `Shibuya.Telemetry.Semantic` — remove `eventHandlerException`.

### New Features

- `shibuya-core`: add `attrMessagingOperation` and `attrShibuyaPartition`
  attribute keys. OTel messaging attribute keys are now derived from the
  typed `AttributeKey` values in `OpenTelemetry.SemanticConventions` so
  upstream renames surface as compile errors.
- `shibuya-core`: `NFData` instances for `MessageId`, `Cursor`, and
  `Envelope a` (when `a` itself has an `NFData` instance). Benchmark
  authors no longer need to declare these as orphans.

### Other Changes

- `shibuya-metrics` and `shibuya-pgmq-adapter` are re-released at 0.2.0.0
  to track `shibuya-core`; neither has user-visible changes of its own.
- Add `mori.dhall` project manifest and various schema upgrades for
  registry-based identity and dependency tracking.
- Add Broadway feature comparison and improvement roadmap (docs).

## 0.1.0.0 — 2026-02-24

Initial release of the Shibuya queue processing framework.

### Packages

- **shibuya-core** 0.1.0.0 — Core framework with supervised queue processing, backpressure, concurrent processing modes, graceful shutdown, and OpenTelemetry tracing
- **shibuya-metrics** 0.1.0.0 — Metrics web server with HTTP/JSON, Prometheus, and WebSocket endpoints
- **shibuya-pgmq-adapter** 0.1.0.0 — PGMQ adapter with visibility timeout leasing, prefetching, topic routing, and trace context propagation
