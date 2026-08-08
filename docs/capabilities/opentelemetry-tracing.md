---
title: "OpenTelemetry tracing"
type: Capability
description: "Per-message consumer spans with messaging semantic conventions and trace-context propagation from message headers, with an allocation-free path when tracing is disabled."
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
  - Shibuya.Telemetry.Effect
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
    resource: shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs
    proves: Span names and messaging.* attributes follow OpenTelemetry semantic conventions.
  - kind: guide
    resource: docs/user/opentelemetry.md
    proves: Configuration, Jaeger setup, and the supported OTEL_* environment variables.
---

# OpenTelemetry tracing

**Builds on:** [CAP-1 — backend-agnostic queue processing](backend-agnostic-queue-processing.md).

Every message opens a `Consumer`-kind span named `"<destination> process"`, carrying
`messaging.*` attributes, in-flight gauges, and the handler's ack decision, with parent context
propagated from the message's trace headers.

```haskell
import Shibuya.Telemetry.Effect (runTracing, runTracingNoop)

runEff $ runTracing tracer $ runApp defaultAppConfig processors
```

A distributed trace therefore survives the queue hop: a span started in the producing service
continues into the consumer rather than starting a disconnected root.

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
