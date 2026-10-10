# Evolve the metrics wire contract additively and keep browser access and control opt-in

Status: Accepted

Date: 2026-10-10

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
remains supported without cross-origin configuration for reads. New control POSTs with
an Origin require an explicit matching allow-list entry even for same-origin deployments;
headerless CLI requests remain supported. Origin checking is not authentication.

Hot-path observability stays within the release performance budget. Any per-message
accounting added for inspection is measured with the paired harness of
`docs/audits/lifecycle-release/performance-budgets.json` before it is accepted. Accounting
that cannot meet the budget when always on is placed behind an explicit detail level whose
disabled path is itself measured to be within budget, and this initiative keeps MetricsBasic as the default. A future default change needs a separate
decision and full integrated evidence, not only a focused per-child pass.

The actual control POST validates a supplied Origin before mutation, including simple POSTs
that do not trigger preflight. Enabled CORS responses merge Vary: Origin even for absent or
refused origins; preflight also varies by requested method and headers. JSON object member
order is not a semantic contract. Preflight permits GET, POST and OPTIONS and validates
requested header names as ASCII HTTP tokens, refusing empty lists and wildcard requests
with `cors_headers_not_allowed`. Duplicate Origin fields are refused on preflight and enabled
WebSocket upgrades. Existing Vary tokens are retained, including `Vary: *`; stale host CORS
permission headers are removed before ordinary-response policy is applied. Origin lists are
encoded once when constructing an application, then compared byte-for-byte. Direct hosts
of the pure `combinedApp` must enforce the configuration constraints themselves; only the
built-in server performs startup validation. These policies govern browser response access
and do not themselves authorize mutating requests. New Cursor objects use a kind tag and string value so
integer positions remain lossless in browser JSON.

Pause means intake admission intent: a pull already admitted and adapter prefetch may still
complete. Registry lifecycle checks, pause intent, timestamp and cold state publication are
atomic. Control success returns the state captured by that transaction; it does not infer
success by sampling later. Draining rejects operator control and atomically resumes intake
before adapter shutdown. Cold Failed metrics alone do not prove a terminal lifecycle. Paused metrics retain the
existing lastProgress timestamp: outstanding work still fails readiness when stuck, while
a drained pause does not. Pause must not reset the stall clock.

WebSocket output has strict frame and byte limits, including required frames. Sampling is
independent of the sole writer, and subscription changes and resync batches are serialized.
Required-frame saturation or a send deadline closes the connection rather than growing the
queue. Delivery of terminal or goodbye to an unresponsive peer cannot be guaranteed.

Completion requires the full integrated basic performance matrix against the pre-initiative
baseline, identical harnesses with real cursor inputs, and sustained real observer load.
Detailed allocation and contention are measured, not claimed absent. API review cannot
certify performance. These constraints refine the planned extension; implementation remains
pending in MasterPlan 7.

## Consequences

- An extension-tolerant client can keep using existing members; unknown state/frame handling
  must be tested explicitly, since additive sum values can break exhaustive decoders; new capabilities appear as new members, frames, and routes.
- New members inside the processor metrics object are camelCase. This is a documented
  deviation from the cross-project convention that asked for snake_case members, chosen so
  that one object never mixes styles. New frame tags, error codes, and series follow the
  snake_case convention the surface already uses for those positions.
- Adding `code` beside existing string `error` members changes exact-JSON test expectations
  deliberately; the change is recorded in the changelog as additive.
- Unconfigured existing read routes retain their header behavior; additive error codes
  change bodies deliberately. The loopback-only default and the absence of authentication remain the operator's boundary.
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

HTTP cross-origin access and upgrade origin validation are implemented and tested under
[`docs/plans/47-add-configurable-cross-origin-access-to-the-metrics-server.md`](../plans/47-add-configurable-cross-origin-access-to-the-metrics-server.md).
The remaining control, detailed accounting, delivery queue and integrated performance
requirements remain pending in MasterPlan 7; this evidence certifies only the origin-policy child.
