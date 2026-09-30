# Evolve the metrics wire contract additively and keep browser access and control opt-in

Status: Accepted

Date: 2026-09-30

## Context

`shibuya-metrics` publishes a JSON HTTP surface (`/metrics`, `/metrics/<processorId>`,
`/health`, `/health/live`, `/health/ready`), a Prometheus scrape target
(`/metrics/prometheus`), and a WebSocket stream (`/ws`) whose frames are JSON objects tagged
by a `type` member. Since 0.10.0.0 every route, frame, and golden JSON and Prometheus text is
pinned by the release-gated `shibuya-metrics-test` suite. Three improvement requests ask for
more from this surface so that a browser application can operate processors: IR-3
(processing latency, cursor progress, oldest in-flight detail), IR-4 (pause and resume with
control endpoints), and IR-5 (cross-origin access and WebSocket convention alignment). They
were filed by the keiro-ui initiative, but Shibuya is adopted without keiro, and a Shibuya-only
operations page must be possible with nothing but this package.

Several published shapes already disagree with each other in small ways: JSON member names
are camelCase (`inFlight`, `lastProgress`, `messageId`), while enumerated values (`type`
tags such as `subscribe_all`, `status` values such as `configured_empty`) and Prometheus
series names are snake_case. Existing error bodies are objects whose `error` member is a
human-readable string, sometimes beside a sibling such as `processor`. The server has no
authentication, binds to loopback by default, sets no cross-origin headers, and offers no
mutating operation at all.

The metrics write path is a deliberate hot/cold split, atomic counters on the message path
and a cold `TVar` for the rest, and the release evidence policy in
[`docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md`](0002-require-candidate-bound-machine-checkable-release-evidence.md)
budgets any hot-path change at no more than 5% throughput loss, 5% allocation or live-memory
growth, and 10% latency growth under paired measurement.

## Decision

Published wire shapes are frozen and evolve only additively. A route, JSON member, frame
type, frame member, Prometheus series, label, or HTTP status code that has shipped is never
renamed, removed, or re-typed. Extension adds optional members to existing objects, new frame
types, new routes, and new series. An incompatible change ships as a new route or frame, never
as an in-place mutation.

Naming follows the surface as it already exists, not an external style: JSON member names
are camelCase on every object and frame, matching the derived encoders in
`Shibuya.Core.Metrics`; enumerated values, `type` tags, error codes, Prometheus series and
label names, and query parameters are snake_case. A member that is absent from a response
means the value does not exist; a value is never fabricated to fill a member. When a new
optional member is `Nothing`, encoders omit it rather than emitting `null`.

Error responses keep the published object shape and gain a machine-readable code. Every
error body is an object with `error` (a human-readable sentence that may change between
releases) and `code` (a stable snake_case identifier a client may switch on), plus optional
context members such as `processor`. Existing string-valued `error` members stay as they
are; `code` is added beside them. Each error code is documented next to the route that
returns it.

The package boundary stays where CAP-10 put it: `shibuya-core` never gains a web dependency.
Pause, resume, latency accounting, cursor progress, and any future control primitive are
plain values and functions in `shibuya-core`; every HTTP and WebSocket exposure lives in
`shibuya-metrics`, which also exports its bare WAI `Application` so a host can mount it
beside other surfaces.

Browser access and control are opt-in. Cross-origin support is configured as an explicit
list of allowed origins, is disabled by default so an unconfigured server stays byte-for-byte
headerless, never emits `Access-Control-Allow-Credentials`, and rejects the wildcard origin at
configuration time so the forbidden wildcard-with-credentials combination is unrepresentable.
When the list is non-empty, the same list validates the `Origin` header of WebSocket upgrade
requests; when it is empty, upgrades behave exactly as today. Control operations are refused
by default with a structured error and perform no action until the host enables them
explicitly; the first control operations are pause and resume, which are reversible and
non-destructive and therefore need no preview step. The server still performs no
authentication: the documented posture is a trusted network or an authenticating reverse
proxy in front of it, and a reverse proxy that serves the page and the API from one origin
remains a supported deployment that needs no cross-origin configuration.

Hot-path observability stays within the release performance budget. Any per-message
accounting added for inspection is measured with the paired harness of
`docs/audits/lifecycle-release/performance-budgets.json` before it is accepted. Accounting
that cannot meet the budget when always on is placed behind an explicit detail level whose
disabled path is itself measured to be within budget, and the shipped default is the level
the measurement supports.

## Consequences

- A client written against the 0.10.0.0 surface keeps working against every release that
  follows this decision; new capabilities appear as new members, frames, and routes.
- New members inside the processor metrics object are camelCase. This is a documented
  deviation from the cross-project convention that asked for snake_case members, chosen so
  that one object never mixes styles. New frame tags, error codes, and series follow the
  snake_case convention the surface already uses for those positions.
- Adding `code` beside existing string `error` members changes exact-JSON test expectations
  deliberately; the change is recorded in the changelog as additive.
- An unconfigured server is indistinguishable from today's server on the wire, so the
  loopback-only default and the absence of authentication remain the operator's boundary.
- Enabling cross-origin access or control is a host decision recorded in configuration, and
  documentation restates the trusted-network assumption instead of implying safety.
- Core detail accounting may ship disabled by default if measurement requires it; a UI that
  needs it asks the host application to enable the detail level.

## Evidence

The initiative that applies this decision is
[`docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md`](../masterplans/7-browser-ready-processor-inspection-and-control-surface.md).
The published surface it freezes is the one pinned by `shibuya-metrics-test` under
[`docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md`](../plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md),
and the WebSocket lifecycle it extends is
[`docs/adr/0004-make-websocket-lifecycle-and-terminal-delivery-explicit.md`](0004-make-websocket-lifecycle-and-terminal-delivery-explicit.md).
