# Changelog

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
