---
type: Improvement Request
title: Provide a long-running example that serves detailed metrics with control and CORS configurable
description: No runnable process serves the Unreleased shibuya-metrics surface — detailed processor fields, /control, CORS, and the error and terminal frames — so UIs cannot record it; add an example that runs until interrupted with those options driven by flags or environment.
timestamp: 2026-10-21T21:05:00Z
requestId: IR-9
status: proposed
origin: mori://shinzui/keiro-ui
---

# Provide a long-running example that serves detailed metrics with control and CORS configurable

## Observed behavior

The only processes that start a shibuya metrics server today cannot show the current surface:

- `shibuya-example` (`just example`) starts one on port 9090 and exits after about five
  seconds.
- The `bench/` executables are bounded load fixtures on ephemeral ports.
- The shibuya-pgmq-adapter example consumer runs indefinitely, but it builds against the
  Hackage `shibuya-metrics ^>=0.10.0.0` release. It serves basic metrics only: no `latency`,
  `oldestInFlight`, or `progress`, no `/control` (it answers 404), no CORS headers, and no
  `error` or `terminal` WebSocket frames.

The keiro runtime console (`mori://shinzui/keiro-ui`, filed from
`mori://shinzui/keiro-ui/plans/9-provision-the-local-runtime-stack-and-recorded-fixtures`)
therefore derives its detailed-metrics and control fixtures from
`shibuya-metrics/test/golden/processor-metrics.json.golden` and `Shibuya.Metrics.Control`
by hand, and cannot test pause/resume against a real host. This is not a dependency of any
console plan; the fixtures are re-recorded once a host exists.

## Requested behavior

An example executable (a new one, or a mode of `shibuya-example`) that:

1. Runs until interrupted, with a few processors that keep receiving work, so every
   `state.status` is observable over time and the WebSocket feed keeps pushing updates.
2. Enables `MetricsDetailed`, so `latency`, `oldestInFlight`, and `progress` are served.
3. Takes `enableControl` and `corsAllowedOrigins` from flags or environment, both off by
   default. Note for local hosts that enable control: a dev proxy forwards the browser's
   `Origin` (for example `http://localhost:5173`), and shibuya requires that origin in
   `corsAllowedOrigins` for control POSTs even when CORS is otherwise off, so the example's
   documentation should show setting it.
4. Takes the metrics port from a flag or environment variable.

## Acceptance

1. Started with control and one allowed origin, `GET /control` answers
   `{"enabled":true,...}`, and `POST /control/processors/<id>/pause` with that `Origin` pauses
   the processor. `GET /metrics/<id>` then shows `state.status` `paused` with the detailed
   fields present.
2. Started without flags, `/control` reports `enabled: false`, a pause answers 403
   `control_disabled`, and no CORS headers are sent.
3. The process keeps serving until it is interrupted, and the WebSocket feed delivers
   `update` frames throughout.
