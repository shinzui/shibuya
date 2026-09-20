---
type: Improvement Request
title: Harden shibuya-metrics for browser clients — CORS, tests, and WS convention alignment
description: >-
  Give shibuya-metrics configurable CORS, a test suite covering every published route and
  WebSocket frame, and strictly additive alignment with the cross-project WebSocket convention,
  so a browser UI on another origin can consume the server and its contract stops being
  working-but-unproven.
timestamp: 2026-09-20T19:22:46Z
requestId: IR-5
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Harden shibuya-metrics for Browser Clients — CORS, Tests, and WS Convention Alignment

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/4-audit-shibuya-and-file-ui-endpoint-improvement-requests`).
This is the enabling request for browser consumption of shibuya-metrics: without CORS, none of
the surface is reachable from a browser page on another origin. Implementation is shibuya's
own downstream work.

The test-suite deliverable in requested change 2 is complete under
`docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md`:
`shibuya-metrics-test` now covers every published HTTP route, exact JSON and Prometheus
fixtures, every frame encoding, and real loopback WebSocket behavior, and the release skill
runs it. CAP-10 no longer calls the endpoints working-but-unproven. Requested changes 1 and
3—configurable CORS/Origin policy and broader additive convention alignment—remain open, so
this request stays proposed and its scope is unchanged.

## Context

Three gaps, all confirmed 2026-08-19 at commit `7158f3e` and re-confirmed at filing time:

1. **No CORS.** `shibuya-metrics/src` contains no CORS handling of any kind, so a browser app
   served from a different origin cannot call any route. CORS (Cross-Origin Resource Sharing)
   is the browser mechanism that blocks cross-origin API calls unless the server opts in via
   response headers.
2. **Zero tests.** `shibuya-metrics.cabal` has no test-suite stanza at all; the capability
   record `docs/capabilities/metrics-endpoints.md` (CAP-10) says it plainly: "Treat the
   endpoints as working-but-unproven." A browser UI that depends on these endpoints needs the
   contract proven, and every other request the initiative files against this server assumes a
   test suite exists to extend.
3. **A pre-convention WebSocket dialect.** The `/ws` protocol
   (`subscribe_all`/`subscribe`/`unsubscribe`/`ping` → `snapshot`/`update`/`pong`/`goodbye`)
   predates the cross-project convention the initiative has since recorded
   (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`, elaborated in the conventions document:
   project `mori://shinzui/keiro-ui`, path `docs/architecture/inspection-api-conventions.md`,
   artifact-level URI pending). The convention was deliberately defined as a superset of this
   dialect, and its frozen-dialect rule protects shibuya's shipped frames: alignment work is
   additive only, and where a gap cannot be closed additively, a documented deviation is the
   correct outcome.

This request deliberately does not duplicate
`mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-1` (the public worker probe
contract requested by the Shikigami project): IR-1 asks for a library-level liveness/readiness
probe contract with the same package-boundary rule this request honors (probes and endpoints
stay out of core); this request is about the HTTP/WS server package itself — its reachability
from browsers, its test coverage, and its protocol documentation.

## Requested Change

1. **Configurable CORS** in the `shibuya-metrics` server configuration: an explicit
   allowed-origins list, disabled by default (today's headerless behavior unchanged), applied
   to HTTP responses, preflight `OPTIONS` requests, and the WebSocket upgrade's `Origin`
   validation; no wildcard origin combinable with credentialed requests.
2. **A test suite** for `shibuya-metrics` covering every published route (`/metrics`,
   `/metrics/<processorId>`, `/metrics/prometheus`, `/health`, `/health/live`,
   `/health/ready`, including the 404 and 503 paths) and the WebSocket protocol (subscribe
   lifecycles, snapshot-then-update, ping/pong, goodbye, delta suppression), so future
   additions — including those requested by
   `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-3` and
   `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-4` — land against a proven
   baseline.
3. **Additive-only convention alignment**: audit the `/ws` dialect against the cross-project
   convention (typed `type`-tagged frames, explicit subscribe/unsubscribe, snapshot-then-delta,
   ping/pong, bounded per-connection queues with in-band overflow signaling, `goodbye`), close
   what can be closed additively (the known candidate: overflow signaling — if a slow consumer
   causes frame drops or disconnection today, that condition should be signaled in-band before
   `goodbye`), document what cannot, and publish a short conformance mapping in the package's
   documentation. Published frames must not break: no renames, removals, or re-typings.

## Acceptance

1. With no CORS configuration, responses are byte-for-byte free of CORS headers; with
   `https://ops.example.com` configured, a preflight `OPTIONS /metrics` from that origin
   succeeds with the matching allow-origin header, a disallowed origin receives no CORS
   headers, and a WebSocket upgrade is accepted or rejected by the same rule. All four cases
   are covered by tests.
2. The test suite runs in CI via the repository's standard check, covers every published route
   and WS frame type, and a deliberate wire-shape regression (renaming a field in a fixture)
   fails it.
3. A client written against the shipped `/ws` dialect operates unchanged against the hardened
   server.
4. The conformance mapping exists in the package documentation, covering every element of the
   convention with met / additively-closed / documented-deviation for each.
5. CAP-10's "working-but-unproven" caveat is retired or amended to reflect the new coverage.

## Requested Deliverables

The CORS configuration and middleware (HTTP + WS upgrade), the test suite, the additive
protocol changes with their tests, the conformance mapping in documentation, an update to the
`metrics-endpoints` capability record, and a durable record of the CORS posture decision
(shibuya has no ADR corpus today; the implementer chooses the venue — the decision itself is
the deliverable).
