# Keep telemetry ownership and disabled-context contracts explicit

Status: Accepted

Date: 2026-10-12

## Context

Adapters supply incoming context and message attributes; the framework owns the
Consumer span around processing and finalization. Source-stream and adapter
shutdown operations also need trace coverage without adding per-message ingestion
spans or changing cancellation and once-only shutdown behavior. Applications
choose a tracing runner and own their provider lifetime.

The public effect exposes a concrete `Tracer` through `getTracer` and a concrete
`Span` to `withSpan'` callbacks, including disabled mode. Replacing these with
optional values would require callers to migrate. Provider construction per no-op
runner invocation was unnecessary.

## Decision

Keep the existing public signatures. Disabled runners share one private no-op
tracer/provider initialized once through public SDK constructors, independent of
the global provider. It has no processors or background resources. The callback
receives a shared non-recording sentinel with all-zero, invalid IDs. Those IDs
represent absence and are never supported correlation or parent identifiers.
Shibuya's injection helper returns an empty header list for invalid context;
`currentTraceHeaders` returns `Nothing` for disabled, absent, or invalid context.
Enabled non-recording spans with valid IDs may still propagate normally.

The framework emits one Internal `shibuya.ingest` span per source lifetime for
both single and batch processors, and one Internal `<ProcessorId> shutdown` span
per adapter shutdown attempt. Both carry `shibuya.processor.id`. SDK brackets
record exceptions and rethrow, including cancellation and deadline expiration.
The existing once-only shutdown leader and cached outcome remain authoritative.
Capture the enabled startup tracer in the internal application handle so stopping
requires no new effect constraint and uses the same provider as application work.

Callers keep the provider alive through application completion and stop cleanup.
A bracket ending immediately after asynchronous `runApp` returns is insufficient.
Shibuya does not initialize, reconfigure, or shut down caller providers.

## Consequences

- Existing effect callbacks and stop call sites keep their signatures. Direct
  construction of internal handles and ingester calls follows the new internal
  representation; internal modules carry no public compatibility guarantees.
- Exactly one Consumer span still represents each individually processed message;
  total trace span counts additionally include lifecycle operations.
- Long-lived source spans normally export only when they end. Live lifecycle
  metrics remain necessary for operations that have not completed.
- Invalid outgoing contexts now produce no headers. Callers inspecting a disabled
  callback must branch with `isTracingEnabled` when they need explicit absence.
- The shared no-op provider lives for the process lifetime. It owns no exporter
  or background resource; this decision makes no measured startup-cost claim.

## Evidence

[Plan 9](../plans/9-audit-and-improve-opentelemetry-api.md) records PostgreSQL
consumer-to-DLQ ID equality for both delivery routes and preserved producer headers.
`shibuya-core/test/Shibuya/Telemetry/LifecycleSpec.hs` checks finite single/batch
lifetimes, failure and cancellation spans, shutdown error caching, deadline results,
startup tracer capture, and disabled mode. `EffectSpec.hs` checks shared-provider
identity, concrete tracer usability, and sentinel inspection/injection.
`PropagationSpec.hs` compares active headers with exported IDs. The cancellation
and ownership contract remains [ADR 3](0003-make-processor-termination-and-shutdown-outcomes-explicit.md).
