---
title: "Metrics endpoints over HTTP, Prometheus, and WebSocket"
type: Capability
description: "Expose live processor metrics as a JSON HTTP endpoint, a Prometheus scrape target, a WebSocket stream, and a health check, from a separate optional package."
generated:
  by: claude-opus-5/1
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-10
provider: mori://shinzui/shibuya
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-metrics
interface:
  - Shibuya.Metrics
  - Shibuya.Metrics.Server
  - Shibuya.Metrics.Config
requires:
  - CAP-9
evidence:
  - kind: module
    resource: shibuya-metrics/src/Shibuya/Metrics/Server.hs
    proves: The metrics web server that hosts the endpoints.
  - kind: module
    resource: shibuya-metrics/src/Shibuya/Metrics/Prometheus.hs
    proves: Processor counters are rendered as a Prometheus scrape target.
  - kind: module
    resource: shibuya-metrics/src/Shibuya/Metrics/JSON.hs
    proves: The HTTP/JSON representation of live metrics.
  - kind: module
    resource: shibuya-metrics/src/Shibuya/Metrics/WebSocket.hs
    proves: Metrics are streamed to subscribers over WebSocket.
  - kind: module
    resource: shibuya-metrics/src/Shibuya/Metrics/Health.hs
    proves: A health endpoint suitable for orchestrator probes.
---

# Metrics endpoints over HTTP, Prometheus, and WebSocket

**Builds on:** [CAP-9 — in-process processor introspection](processor-introspection.md).

`shibuya-metrics` turns the in-process counters of [CAP-9](processor-introspection.md) into
network-visible endpoints: a JSON HTTP endpoint, a Prometheus scrape target, a live WebSocket
stream, and a health check.

```cabal
build-depends: shibuya-metrics
```

It is a separate package rather than part of the core precisely so that adopting Shibuya does
not mean adopting a web server. An application that already reports through its own telemetry
pipeline uses CAP-9 directly and never depends on this.

## Limits

- **This package has no test suite.** Its evidence here is module-level only, which is
  materially weaker than the rest of this catalog — every other capability names tests that
  exercise it. Treat the endpoints as working-but-unproven and verify them in your own
  deployment.
- Versions track `shibuya-core` rather than signalling independent change. Several releases
  (0.2.0.0, 0.3.0.0, 0.5.0.0, 0.6.0.0, 0.7.0.0) are re-releases with no user-visible change of
  their own.
- The always-zero `shibuya_messages_dropped_total` Prometheus series was **removed** in 0.8.0.0
  along with the core dropped-message metric surface. A dashboard or alert referencing it breaks
  on upgrade.
- Metrics are per-process; the endpoints expose one application's counters, not a fleet's.
