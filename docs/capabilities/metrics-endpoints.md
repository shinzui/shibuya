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
  - kind: test
    resource: shibuya-metrics/test/Shibuya/Metrics/ServerSpec.hs
    proves: Every HTTP route, enable flag, 404 path, and unhealthy 503 path is exercised.
  - kind: test
    resource: shibuya-metrics/test/Shibuya/Metrics/TypesSpec.hs
    proves: Every published client and server frame has an exact JSON contract and round trip.
  - kind: test
    resource: shibuya-metrics/test/Shibuya/Metrics/WebSocketSpec.hs
    proves: Real loopback connections exercise snapshots, subscriptions, updates, shutdown, limits, and terminal removal.
  - kind: test
    resource: shibuya-metrics/test/golden/processor-metrics.json.golden
    proves: Processor JSON fields and state shapes are compared byte-for-byte.
  - kind: test
    resource: shibuya-metrics/test/golden/prometheus.golden
    proves: Prometheus series, labels, state values, and counters are compared byte-for-byte.
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

- The built-in server binds to `127.0.0.1` by default. Setting `host = "*"` exposes
  metrics, processor IDs, message IDs, and terminal failure text; do so only behind an
  authentication and authorization boundary. The server does not implement authentication
  or WebSocket `Origin` validation itself.
- WebSocket connection state is bounded by `wsMaxConnections` and
  `wsMaxSubscriptions` (1,000 retained processor IDs per connection by default). A client
  that would exceed the subscription or subscribe-all exclusion limit is closed with policy
  violation code 1008. Nonpositive resource limits and timeouts are rejected when the
  built-in server starts.
- The release-gated `shibuya-metrics-test` suite exercises every published HTTP route,
  including enable flags and 404/503 paths, exact JSON and Prometheus golden output, every
  client/server frame encoding, and the WebSocket protocol over real loopback connections.
  This is contract and lifecycle evidence, not a production-network or security certification.
- Cross-origin browser access remains unsupported: the server has no configurable CORS
  response policy or WebSocket `Origin` validation. Bounded slow-consumer queues, overflow
  signaling, and broader cross-project WebSocket convention alignment also remain open under
  IR-5.
- Versions track `shibuya-core` rather than signalling independent change. Several releases
  (0.2.0.0, 0.3.0.0, 0.5.0.0, 0.6.0.0, 0.7.0.0) are re-releases with no user-visible change of
  their own.
- The always-zero `shibuya_messages_dropped_total` Prometheus series was **removed** in 0.8.0.0
  along with the core dropped-message metric surface. A dashboard or alert referencing it breaks
  on upgrade.
- Metrics are per-process; the endpoints expose one application's counters, not a fleet's.
