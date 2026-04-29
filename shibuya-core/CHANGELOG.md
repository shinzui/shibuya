# Changelog

## Unreleased

### Breaking changes

- `Envelope` gained an `attempt :: !(Maybe Attempt)` field carrying the
  adapter's delivery counter (zero-indexed; `Nothing` if unknown). Direct
  constructions of `Envelope` must add the field. The new `Attempt`
  newtype is exported from `Shibuya.Core` and `Shibuya.Core.Types`.

### Additions

- New module `Shibuya.Core.Retry` providing `BackoffPolicy`, `Jitter`
  (`NoJitter`, `FullJitter`, `EqualJitter`), `defaultBackoffPolicy`, the
  pure evaluator `exponentialBackoffPure`, the effectful
  `exponentialBackoff`, and the handler convenience `retryWithBackoff`.
  Handlers can now compute exponentially-growing, jittered retry delays
  with a single call: `retryWithBackoff defaultBackoffPolicy
  ingested.envelope`. Pulls in `random ^>=1.2` as a new build-depends
  (already a transitive dep — ships with GHC). See the module haddock and
  the new `RetrySpec` test for usage patterns.
- A runnable end-to-end demonstration of the new API lives in the
  sibling [`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter)
  repo at `shibuya-pgmq-example/`, exposed via the `backoff-demo`
  subcommand of `shibuya-pgmq-consumer`. The plan
  `docs/plans/8-demonstrate-backoff-end-to-end.md` records setup
  instructions and captured transcripts.

Planned next release: 0.4.0.0 (major — breaks direct `Envelope` construction).

## 0.3.0.0 — 2026-04-24

Version bumped to track the shared release version. No user-visible
changes to `shibuya-core` itself.

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
