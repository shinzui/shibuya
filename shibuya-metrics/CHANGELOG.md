# Changelog

## Unreleased

### Breaking Changes

- `MetricsServerConfig` and `HealthConfig` gain `dependencyTimeoutMicros`; direct record
  construction must choose a per-check deadline. `ReadinessStatus` gains `application`, and
  its JSON object gains the corresponding lifecycle status field.
- The processing-state JSON object gains `lastProgress`, paired with the new third field of
  `shibuya-core`'s `ProcessorState.Processing` constructor.
- `ServerMessage` gains `ProcessorTerminal`, with the new public
  `ProcessorTerminalStatus` type, and the exposed `WebSocketState` record gains a shutdown
  cell. Exhaustive matches and direct record construction must handle these additions.

### New Features

- Export `combinedApp` so callers can mount the unified metrics WAI application on
  an externally managed server.
- Send an additive `terminal` WebSocket frame when a formerly visible processor leaves the
  live registry in a retained stopped or failed state.

### Other Changes

- Add `shibuya-metrics-test`, a release-gated Hspec suite covering every published
  HTTP route and WebSocket frame plus exact JSON and Prometheus golden contracts.

### Bug Fixes

- Base stuck detection on sampled progress instead of burst age, retain failed configured
  processors after live metrics unregister, report stopped masters not live, and bound each
  dependency readiness check.
- Release WebSocket connection slots on every setup and connection exit, reject upgrades
  when WebSockets are disabled, support exclusions from subscribe-all, and deliver `goodbye`
  when server shutdown begins.

## 0.9.0.3 — 2026-09-20

Version bumped to track `shibuya-core` 0.9.0.3. The core dependency bound is
updated to `^>=0.9.0.3`; no user-visible changes to `shibuya-metrics` itself.

## 0.9.0.2 — 2026-09-19

Version bumped to track `shibuya-core` 0.9.0.2. The core dependency bound is
updated to `^>=0.9.0.2`; no user-visible changes to `shibuya-metrics` itself.

## 0.9.0.1 — 2026-09-15

Version bumped to track `shibuya-core` 0.9.0.1. The core dependency bound is
updated to `^>=0.9.0.1`; no user-visible changes to `shibuya-metrics` itself.

## 0.9.0.0 — 2026-08-10

Version bumped to track `shibuya-core` 0.9.0.0. The core dependency bound is
updated to `^>=0.9.0.0`; no user-visible metrics API changes.

## 0.8.0.1 — 2026-07-04

Version bumped to track `shibuya-core` 0.8.0.1. No user-visible changes
to `shibuya-metrics` itself.

## 0.8.0.0 — 2026-07-04

### Breaking Changes

- Version bumped to track `shibuya-core` 0.8.0.0.
- The Prometheus endpoint no longer emits
  `shibuya_messages_dropped_total`; `shibuya-core` removed the always-zero
  `StreamStats.dropped` counter.
- Internal imports moved from `Shibuya.Runner.Master` and
  `Shibuya.Runner.Metrics` to the new public paths `Shibuya.App` and
  `Shibuya.Core.Metrics`. Application code using `shibuya-metrics` through
  `Shibuya.Metrics` does not need to change.

## 0.7.1.0 — 2026-06-15

Version bumped to track `shibuya-core` 0.7.1.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.7.0.0 — 2026-06-05

Version bumped to track `shibuya-core` 0.7.0.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.6.0.0 — 2026-05-31

Version bumped to track `shibuya-core` 0.6.0.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.5.0.0 — 2026-05-05

Version bumped to track `shibuya-core` 0.5.0.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.4.0.0 — 2026-04-29

Version bumped to track `shibuya-core` 0.4.0.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.3.0.0 — 2026-04-24

Version bumped to track `shibuya-core` 0.3.0.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.2.0.0 — 2026-04-22

Version bumped to track `shibuya-core` 0.2.0.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.1.0.0 — 2026-02-24

Initial release.

### New Features

- HTTP/JSON metrics endpoint
- Prometheus metrics endpoint
- WebSocket streaming metrics endpoint
- Kubernetes-compatible health check endpoints
