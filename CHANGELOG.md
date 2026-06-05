# Changelog

## 0.7.0.0 — 2026-06-05

### Breaking Changes

- `shibuya-core`: `Envelope` gained a `headers :: !(Maybe Headers)` field
  carrying every message header the source broker delivered, in order and
  including duplicates. Direct constructions of `Envelope` must add the
  field. `Nothing` means the adapter does not surface headers; `Just []`
  means it does and the message had none. The new `Headers` type alias
  (`[(ByteString, ByteString)]`) is exported from `Shibuya.Core` and
  `Shibuya.Core.Types`.

### Other Changes

- All `.cabal` files in this repository now declare `cabal-version: 3.12`
  instead of `3.14`, so Nix toolchains whose bundled Cabal predates 3.14
  can build the packages. No package-description syntax that requires 3.14
  was in use, so this is behavior-preserving.
- `shibuya-metrics` is re-released at 0.7.0.0 to track the shared version;
  it has no user-visible changes of its own.

## 0.6.0.0 — 2026-05-31

### Breaking Changes

- `shibuya-core`: OpenTelemetry messaging spans now emit
  `messaging.operation.type = "process"` instead of the deprecated
  `messaging.operation = "process"` wire key. The Haskell constant
  `attrMessagingOperation` keeps the same name and now resolves to the
  current semantic-conventions key, so source imports continue to
  compile. Dashboards, alerts, and trace queries that filter on
  `messaging.operation` must be updated to `messaging.operation.type`.

### Other Changes

- `shibuya-core`: upgrade OpenTelemetry dependencies to the 1.0
  ecosystem: `hs-opentelemetry-api ^>= 1.0`,
  `hs-opentelemetry-propagator-w3c ^>= 1.0`, and test-only
  `hs-opentelemetry-exporter-in-memory ^>= 1.0`. Move
  `hs-opentelemetry-semantic-conventions` to the latest Haskell
  generated package available with the 1.0 release, `^>= 1.40`, and
  source Shibuya's generic messaging keys from its typed exports.
- `shibuya-metrics` is re-released at 0.6.0.0 to track the shared
  version; it has no user-visible changes of its own.

## 0.5.0.0 — 2026-05-05

### Breaking Changes

- `shibuya-core`: `Envelope` gained an `attributes :: !(HashMap Text
  Attribute)` field carrying adapter-supplied OpenTelemetry attributes
  for the per-message processing span. Direct constructions of
  `Envelope` must add the field; pass `Data.HashMap.Strict.empty` when
  the adapter has nothing to contribute (the common case). `Envelope`'s
  `NFData` instance is now hand-written rather than derived (because
  `Attribute` from `hs-opentelemetry-api` does not ship `NFData`); the
  strictness shape is unchanged.

### New Features

- `shibuya-core`: `Shibuya.Runner.Supervised`'s `processOne` now applies
  `envelope.attributes` to its Consumer-kind span after setting the
  framework-default `messaging.*` attributes, so adapter-supplied keys
  override framework defaults of the same name. This lets broker-aware
  adapters (Kafka in particular) emit typed attributes
  (`messaging.kafka.destination.partition`,
  `messaging.kafka.message.offset`) and override the `messaging.system`
  default — without opening a second span.
- `shibuya-core`: new `Shibuya.Telemetry.Propagation.currentTraceHeaders
  :: (Tracing :> es, IOE :> es) => Eff es (Maybe TraceHeaders)` looks up
  the currently-active OTel span and encodes its trace context as W3C
  headers, ready for an adapter to attach to an outgoing message.
  Returns `Nothing` when tracing is disabled or there is no active span.
  Intended for adapter-side DLQ writes and ad-hoc producer paths.

### Other Changes

- `shibuya-metrics` is re-released at 0.5.0.0 to track the shared
  version; it has no user-visible changes of its own.
- Documentation: new OpenTelemetry user guide
  (`docs/user/opentelemetry.md`), getting-started refreshed for the
  current `Envelope` shape, plan 9 (OTel audit) closed out with audit
  findings and live Jaeger smoke transcript captured.

## 0.4.0.0 — 2026-04-29

### Breaking Changes

- `shibuya-core`: `Envelope` gained an `attempt :: !(Maybe Attempt)`
  field carrying the adapter's delivery counter (zero-indexed; `Nothing`
  if unknown). Direct constructions of `Envelope` must add the field.
  The new `Attempt` newtype is exported from `Shibuya.Core` and
  `Shibuya.Core.Types`.

### New Features

- `shibuya-core`: new module `Shibuya.Core.Retry` providing
  `BackoffPolicy`, `Jitter` (`NoJitter`, `FullJitter`, `EqualJitter`),
  `defaultBackoffPolicy`, the pure evaluator `exponentialBackoffPure`,
  the effectful `exponentialBackoff`, and the handler convenience
  `retryWithBackoff`. Handlers can now compute exponentially-growing,
  jittered retry delays with a single call. Adds `random ^>=1.2` as a
  new build-depends. A runnable end-to-end demo lives in the sibling
  [`shinzui/shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter)
  repo (`shibuya-pgmq-example`, `backoff-demo` subcommand).

### Other Changes

- `shibuya-metrics` is re-released at 0.4.0.0 to track the shared
  version; it has no user-visible changes of its own.

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
