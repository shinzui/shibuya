# Changelog

## 0.3.0.0 — 2026-04-23

Upgraded to `pgmq-hs` 0.2.0.0 series
(`pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, `pgmq-migration`
all at `0.2.0.0`).

### Breaking Changes

- Consumers that pin the `Pgmq.Effectful.PgmqError` name in their own
  `runError` / `runErrorNoCallStack` stack must migrate to
  `PgmqRuntimeError`. The old type is still re-exported as a
  deprecated alias for one release.
- Spans emitted by the traced interpreter now follow OpenTelemetry
  semantic-conventions v1.24. Span names (`"publish my-queue"`,
  `"receive my-queue"`) and attribute keys (`messaging.operation`,
  `messaging.system`, `messaging.destination.name`) have changed.
  Dashboards and alerts keyed on the old names will need updating.
- Callers of `Pgmq.Effectful.Traced.sendMessageTraced` must pass an
  `OpenTelemetry.Trace.TracerProvider` instead of an
  `OpenTelemetry.Trace.Tracer`. If you only have a `Tracer` in scope,
  use `OpenTelemetry.Trace.Core.getTracerTracerProvider` to derive the
  provider.

### Other Changes

- No user-visible changes to `shibuya-pgmq-adapter`'s own API.

## 0.2.0.0 — 2026-04-22

Version bumped to track `shibuya-core` 0.2.0.0. No user-visible changes
to `shibuya-pgmq-adapter` itself.

## 0.1.0.0 — 2026-02-24

Initial release.

### New Features

- PGMQ adapter for PostgreSQL message queue integration
- Visibility timeout-based leasing with automatic retry handling
- Optional dead-letter queue support
- Configurable prefetching via PrefetchConfig
- Concurrent prefetching with streamly parBuffered
- OpenTelemetry trace context propagation
- Topic routing support (pgmq-hs 0.1.1.0)
- Comprehensive test suite with property-based and integration tests

### Bug Fixes

- Fix batch wastage using streamly unfoldEach
