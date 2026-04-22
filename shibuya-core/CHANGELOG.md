# Changelog

## 0.2.0.0 — 2026-04-22

### Breaking Changes

- `Shibuya.Telemetry.Semantic`: rename `processMessageSpanName :: Text` to
  `processSpanName :: Text -> Text`. The span name is now built from the
  destination (processor id), yielding e.g. `"shibuya-consumer process"`, in
  line with the OpenTelemetry messaging-spans recommendation.
- `Shibuya.Telemetry.Semantic`: remove `attrMessagingDestinationPartitionId`
  (replaced by the Shibuya-specific `attrShibuyaPartition`).
- `Shibuya.Telemetry.Semantic`: remove `eventHandlerException`.

### New Features

- `Shibuya.Telemetry.Semantic`: add `attrMessagingOperation` and
  `attrShibuyaPartition` attribute keys. Messaging attribute keys are now
  sourced from the typed `AttributeKey` values exported by
  `OpenTelemetry.SemanticConventions`, so upstream renames surface as
  compile errors rather than silent wire-format drift.
- `Shibuya.Core.Types`: add `NFData` instances for `MessageId`, `Cursor`,
  and `Envelope a` (when `a` itself has an `NFData` instance). Benchmark
  authors no longer need to declare these as orphans.

## 0.1.0.0 — 2026-02-24

Initial release.

### New Features

- Multi-queue processing with `runApp` and `QueueProcessor` API
- Backpressure via bounded inbox
- AckHalt support to stop processing on halt decision
- Serial, Ahead, and Async concurrent processing modes
- Policy validation enforcement (StrictInOrder requires Serial)
- Graceful shutdown with configurable drain timeout
- NQE-based supervision via Master/Supervisor
- OpenTelemetry tracing integration with W3C trace context propagation
- Mock adapter for testing

### Bug Fixes

- Fix race conditions and incomplete cleanup in runner
- Fix data races in concurrent test handlers using atomicModifyIORef'

### Other Changes

- Consolidate error handling with unified error types
- Define own SupervisionStrategy type to decouple from NQE
- Use registerDelay for cleaner timeout handling
- Replace polling with STM blocking in waitApp
