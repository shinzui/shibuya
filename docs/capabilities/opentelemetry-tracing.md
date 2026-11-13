---
title: "OpenTelemetry tracing"
type: Capability
description: "Per-message consumer spans with messaging semantic conventions, a link to the producer span from message headers with an adapter-declared parent-or-root policy, and an allocation-free path when tracing is disabled."
generated:
  by: claude-opus-5/1
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-8
provider: mori://shinzui/shibuya
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-core
interface:
  - Shibuya.Telemetry
  - Shibuya.Telemetry.Correlation
  - Shibuya.Telemetry.Effect
  - Shibuya.Telemetry.Process
  - Shibuya.Telemetry.Propagation
  - Shibuya.Telemetry.Semantic
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shibuya-core/test/Shibuya/Telemetry/EffectSpec.hs
    proves: The tracing effect behaves identically enabled and disabled.
  - kind: test
    resource: shibuya-core/test/Shibuya/Telemetry/PropagationSpec.hs
    proves: Parent context is extracted from message headers and injected for outgoing messages.
  - kind: test
    resource: shibuya-core/test/Shibuya/Telemetry/CorrelationSpec.hs
    proves: Processing spans link to the producer span; ParentAndLink parents on it, LinkOnly roots a new trace, and absent or malformed headers keep the ambient parent without a link.
  - kind: test
    resource: shibuya-core/test-retention/Main.hs
    proves: Finished processing spans under either policy do not retain message payloads, and live heap stays flat under sustained traced processing.
  - kind: test
    resource: shibuya-core/test/Shibuya/Telemetry/BatchCorrelationSpec.hs
    proves: Batch spans are roots linking each member's creation context in order with its message id, bounded at 128 with an exact count of omitted valid contexts.
  - kind: test
    resource: shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs
    proves: Span names and messaging.* attributes follow OpenTelemetry semantic conventions.
  - kind: guide
    resource: docs/user/opentelemetry.md
    proves: Configuration, Jaeger setup, and the supported OTEL_* environment variables.
---

# OpenTelemetry tracing

**Builds on:** [CAP-1 — backend-agnostic queue processing](backend-agnostic-queue-processing.md).

Every message opens a `Consumer`-kind span named `"<destination> process"`, carrying
`messaging.*` attributes, in-flight gauges, and the handler's ack decision. When the message's
trace headers decode, the span links to the producer's span.

```haskell
import Shibuya.Telemetry.Effect (runTracing, runTracingNoop)

runEff $ runTracing tracer $ runApp defaultAppConfig processors
```

The adapter declares whether the consumer span is also a child of the producer's span. Under
`ParentAndLink` (the default of `defaultAdapterTelemetry`) the trace continues across the queue
hop as one connected trace. Under `LinkOnly`, meant for replayed, fanned-out or long-delayed
sources, the consumer starts a new trace and the link relates the two. Users change the policy
in the adapter's configuration. Messages without usable headers have no link and keep whatever
context the processing thread already had, as before.

Batch spans are always roots. They link every member's creation context in member order, each
link naming its member's `messaging.message.id`, up to 128 links. The remaining valid contexts
are counted in `shibuya.batch.links.dropped`, and the span carries
`messaging.batch.message_count`.

The same span is available outside the runner through `Shibuya.Telemetry.Process`
(`withProcessSpan`, `withProcessSpanIO`). With valid headers these helpers neither parent on
nor link an ambient span on the calling thread. They are meant for independent message
processing.

## Disabled is free

`runTracingNoop` is not "tracing that discards its output" — the disabled path is
allocation-free, using a shared dummy-span CAF and hoisted constant attributes. Tracing can be
compiled in and left off without paying for it, so there is no separate untraced build.

## Adapter-supplied attributes

Adapters can contribute typed backend-specific attributes — Kafka's
`messaging.kafka.destination.partition`, for instance — which merge with the framework's
defaults. Adapters with nothing to add pay nothing, which is the common case.

## Limits

- Spans follow OpenTelemetry messaging semantic conventions; upgrading conventions is a
  user-visible change and has been one before (see the 0.2.0.0 and 0.3.0.0 entries in
  [`../../CHANGELOG.md`](../../CHANGELOG.md)).
- Propagation requires the backend to carry headers. `Envelope.headers` is `Nothing` when the
  adapter does not surface them, and no parent context is recovered.
- Requires the OpenTelemetry 1.0 library series as of 0.6.0.0.
