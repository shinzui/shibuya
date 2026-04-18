# Changelog

## Unreleased

### Added

- `shibuya-core`: `NFData` instances for `MessageId`, `Cursor`, and `Envelope a`
  (when `a` itself has an `NFData` instance). Benchmark authors no longer need to
  declare these as orphans.

## 0.1.0.0 — 2026-02-24

Initial release of the Shibuya queue processing framework.

### Packages

- **shibuya-core** 0.1.0.0 — Core framework with supervised queue processing, backpressure, concurrent processing modes, graceful shutdown, and OpenTelemetry tracing
- **shibuya-metrics** 0.1.0.0 — Metrics web server with HTTP/JSON, Prometheus, and WebSocket endpoints
- **shibuya-pgmq-adapter** 0.1.0.0 — PGMQ adapter with visibility timeout leasing, prefetching, topic routing, and trace context propagation
