# Changelog

## Unreleased

- Add opt-in `enableControl` (False by default), discovery and pause/resume POST routes with structured errors and actual-request Origin enforcement. New `Shibuya.Metrics.Control` module; direct MetricsServerConfig construction must supply the flag.


- Add public processor pause/resume intake control and transactional draining refusal. Paused state is additive on the wire, with health `paused` count and Prometheus state 5; exhaustive ProcessorState matches and direct ProcessorHealth/SupervisedProcessor construction need updating.


- Add optional acknowledged `progress` to processor JSON and WebSocket metrics, bounded per partition, with lossless tagged Cursor JSON. Basic detail remains the default. Direct `ProcessorMetrics` construction must supply `progress`.


### Breaking Changes

- `MetricsServerConfig` gains `wsMaxQueuedFrames`, `wsMaxQueuedBytes`, and
  `wsSendTimeoutUs`; direct construction must provide them. `MetricsServer` gains
  the `serverShutdown` action used before Warp cancellation.

- `ServerMessage` gains `ServerError`; exhaustive matches must handle this constructor.

- `MetricsServerConfig` gains `corsAllowedOrigins`; direct record construction
  must supply an explicit origin list. `defaultConfig` keeps it empty (disabled).

### New Features

- Opt-in detailed accounting with `MetricsDetail`, `DetailOptions`, `LatencySummary`,
  `LatencyBucket`, and `OldestInFlight`; the default remains `MetricsBasic`. Monotonic
  timing includes finalization retries, one observation per message attempt or emitted
  batch, using bounded synchronized slots. Add `MessageId` JSON instances, detail-aware
  handle/runner constructors and read-only slot-miss diagnostics.
- Add optional camelCase `latency` and `oldestInFlight` JSON/WebSocket members and the
  `shibuya_message_processing_seconds` histogram and optional
  `shibuya_processor_oldest_in_flight_seconds` gauge. Preserve basic JSON bytes and omit
  unavailable values. WebSocket clients extrapolate age between state changes.

- Bound every queued WebSocket frame and encoded byte with independent sampling
  and one application writer. Drop oldest updates under pressure, followed by an
  adjacent `queue_overflow` error and replacement snapshot; close on required-frame
  saturation or oversized snapshots. Bound individual sends and shutdown flushes.
- Export the pure `Shibuya.Metrics.Outbound` admission model and optional
  `WebSocketHooks` instrumentation. Subscription changes, including unsubscribe,
  establish an ordered snapshot boundary.

- Send additive in-band WebSocket `error` frames for invalid messages and before
  subscription-limit policy closes (1008). Valid existing frames are unchanged.

- add configurable cross-origin HTTP access and preflight handling, plus
  WebSocket upgrade Origin validation before connection-slot acquisition.
- export `Shibuya.Metrics.Cors` and `Shibuya.Metrics.Error`, with reusable
  `corsMiddleware`, `isAllowedOrigin`, `isValidOrigin`, `originGuard`, and `errorResponse`
  helpers, plus top-level re-exports for `combinedApp`, `corsMiddleware`, and `errorResponse`.
- add stable `code` members to existing error bodies, preserving their
  `error` text, context, status, and content type (additive wire change).

## 0.10.0.1 — 2026-10-05

### Other Changes

- Advance the shared release version and require shibuya-core 0.10.0.1, which admits random 1.3.

## 0.10.0.0 — 2026-09-21

### Breaking Changes

- `MetricsServerConfig` and `HealthConfig` gain `dependencyTimeoutMicros`; direct record
  construction must choose a per-check deadline. `ReadinessStatus` gains `application`, and
  its JSON object gains the corresponding lifecycle status field.
- `MetricsServerConfig` gains `host` and `wsMaxSubscriptions`. The built-in server now
  defaults to loopback instead of all interfaces, validates resource limits, and bounds
  retained WebSocket processor selections and exclusions.
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
- Declare the generated `Paths_shibuya_metrics` test module and bound the wire-load
  executable's Effectful and NQE dependencies so `cabal check` accepts the source
  distribution.

### Bug Fixes

- Base stuck detection on sampled progress instead of burst age, retain failed configured
  processors after live metrics unregister, report stopped masters not live, and bound each
  dependency readiness check while normalizing its synchronous exceptions as unhealthy.
- Release WebSocket connection slots on every setup and connection exit, reject upgrades
  when WebSockets are disabled, support exclusions from subscribe-all, and deliver `goodbye`
  when server shutdown begins.
- Close WebSocket clients with policy code 1008 before their retained processor subscription
  or subscribe-all exclusion set can exceed `wsMaxSubscriptions`.

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
