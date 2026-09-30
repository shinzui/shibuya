---
id: 52
slug: expose-gated-pause-and-resume-control-endpoints
title: "Expose gated pause and resume control endpoints"
kind: exec-plan
created_at: 2026-09-30T23:27:06Z
intention: "intention_01m3ta8zgtebmaz00g0snjzy5a"
master_plan: "docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T23:27:06Z
---


# Expose gated pause and resume control endpoints

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


After this plan, an operator watching a Shibuya application through `shibuya-metrics` can
stop one processor from taking new work and later let it continue, from a browser page or
from `curl`, without restarting the process and without losing the messages that are already
in flight. The operation is deliberately hard to reach by accident: a freshly configured
server refuses every control request with a structured error and performs no action, and a
page can discover that refusal in advance through `GET /control` and render its pause button
disabled with the reason. When the host application opts in by setting one configuration
flag, `POST /control/processors/<id>/pause` pauses the named processor and
`POST /control/processors/<id>/resume` resumes it, each answering with a small JSON object
that names the processor and its new state. The paused condition is visible everywhere the
processor is visible: `GET /metrics/<id>` reports `"status":"paused"`, the WebSocket stream
pushes an `update` frame carrying that state, and the Prometheus state gauge reports the
value the pause plan assigned to it.

You can see it working by starting an application with the control gate enabled and running
these two commands against it; the first returns the discovery object, the second pauses the
processor named `orders`:

```bash
curl -s http://127.0.0.1:9090/control
curl -s -X POST http://127.0.0.1:9090/control/processors/orders/pause
```

This plan is the second half of
`docs/improvement-requests/implement-designed-processor-pause-resume-and-expose-gated-control-endpoints.md`
(IR-4). The first half, the pause primitive itself inside `shibuya-core`, is delivered by
`docs/plans/51-implement-source-level-processor-pause-and-resume.md` (EP-51), which this
plan cannot compile without. This plan delivers IR-4's second and third items, the gated
control surface and its observability, and closes the request once EP-51 is Complete.


## Progress


- [ ] Milestone 1: Add `enableControl` to `MetricsServerConfig`, the `Shibuya.Metrics.Control` module with `GET /control` discovery, and the structured refusal of every action while the gate is off, with tests in `ControlSpec`.
- [ ] Milestone 2: Implement the pause and resume action routes with structured outcomes, test both gate positions through `combinedApp`, and prove the whole path end to end through a real application, a real port, and a real WebSocket connection.
- [ ] Milestone 3: Update the protocol reference, user guide, architecture document, capability bundle, changelogs, and ADR; record wire-load sanity numbers; close IR-4 after EP-51 is Complete.


## Surprises & Discoveries


(None yet.)


## Decision Log


- Decision: Gate every control operation behind one Boolean, `enableControl`, that defaults
  to `False`, and answer a refused request with HTTP 403 and the code `control_disabled`.
  Rationale: IR-4 sets configuration-level gating as the minimum bar and asks Shibuya to
  choose the model. One flag is the smallest model that makes the default unambiguous, and
  `docs/adr/0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`
  requires control to be refused by default with a structured error.
  Date: 2026-09-30

- Decision: Serve `GET /control` in both gate positions.
  Rationale: A page that cannot learn whether control is enabled can only find out by
  attempting a mutation. Discovery lets a client render a disabled action and its reason
  without side effects, which is the honest behavior every consumer of this surface wants.
  Date: 2026-09-30

- Decision: No preview or confirmation step for pause and resume.
  Rationale: Both operations are reversible and destroy nothing; a paused processor is
  resumed by the mirror request. ADR-0007 reserves preview-then-confirm discipline for
  destructive operations, and a future destructive operation must record its own decision.
  Date: 2026-09-30

- Decision: Treat a repeated pause or resume as success with the same body, not as an error.
  Rationale: Operators retry; a browser re-sends on a flaky network. Idempotent success means
  the second request can never leave the processor in a state the operator did not ask for,
  and the body tells them the state they have.
  Date: 2026-09-30

- Decision: Provide no WebSocket control frames.
  Rationale: The existing `update` frame already carries every processor state, so the paused
  condition reaches every subscribed client through the frame they already handle. Adding a
  mutating frame type would give the WebSocket a second gate to reason about for no new
  capability.
  Date: 2026-09-30


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


Shibuya is a supervised queue-processing library. An application configures named
processors, each fed by an adapter that pulls messages from some queue and hands them to a
handler; `shibuya-core` supervises them and counts what they do, and the optional package
`shibuya-metrics` exposes those counts over HTTP, Prometheus text, and a WebSocket. A
processor is identified by a `ProcessorId`, a newtype over `Text` defined in
`shibuya-core/src/Shibuya/Core/Metrics.hs`.

A few terms used throughout. The control plane is the part of the surface that changes what
the application does, as opposed to the read-only surface that reports what it is doing;
until this plan there is no control plane at all. A gate is a configuration setting that
decides whether the control plane acts or refuses; this plan's gate is the flag
`enableControl`. An operation is idempotent when performing it twice has the same effect and
result as performing it once, so pausing a paused processor succeeds and changes nothing. A
reversible operation is one whose effect can be undone by another operation on the same
surface, as resume undoes pause; a destructive operation, such as discarding messages, has
no such mirror and is out of this plan's scope. A preflight is the `OPTIONS` request a
browser sends before a cross-origin `POST` to ask whether the server permits it; the server
never sees the `POST` if the preflight fails.

The server today. `shibuya-metrics/src/Shibuya/Metrics/Server.hs` exports `combinedApp ::
MetricsServerConfig -> Master -> WebSocketState -> [DependencyCheck] -> Application`, the
WAI application that the built-in Warp server runs and that tests drive directly. (WAI is the
standard Haskell web-application interface; an `Application` takes a request and a response
callback.) Inside it, `httpApp` routes by `pathInfo`: `["metrics","prometheus"]` when
`enablePrometheus` is set; `["metrics"]`, `["metrics", _]`, `["health"]`,
`["health","live"]`, and `["health","ready"]` when `enableJSON` is set, all handed to
`jsonAppWithHealth` from `shibuya-metrics/src/Shibuya/Metrics/JSON.hs`; `["ws"]` gets a 404
explaining that the path is a WebSocket endpoint; anything else gets a 404 with the body
`{"error":"Not found"}`. `Master`, defined in `shibuya-core/src/Shibuya/Internal/Runner/Master.hs`,
is the handle the server holds: it owns the registry of live processors and the retained
lifecycle snapshot, and the server samples it through `getAllMetricsIO` and
`getProcessorMetricsIO`. Configuration lives in `shibuya-metrics/src/Shibuya/Metrics/Config.hs`
as the record `MetricsServerConfig` with `defaultConfig`; `validateConfig` in `Server.hs`
rejects nonsensical values when the built-in server starts. The package's Haddock header in
`shibuya-metrics/src/Shibuya/Metrics.hs` is the published protocol reference listing every
route and frame.

The test suite. `shibuya-metrics-test` (Hspec) is declared in
`shibuya-metrics/shibuya-metrics.cabal` and lists its spec modules in
`shibuya-metrics/test/Main.hs`. `shibuya-metrics/test/Shibuya/Metrics/TestSupport.hs`
provides `withMaster` (a started `Master` under `IgnoreAll`), `registerIdleProcessor`, and
`getResponse`, which runs a request through an `Application` in process with
`Network.Wai.Test`. `ServerSpec.hs` shows the route-testing pattern (`appFor`, `assertResponse`,
decoding a body with `decode` and comparing to an `object`), and `WebSocketSpec.hs` shows the
real-socket pattern: `Warp.testWithApplication (pure app)` binds a free port and
`WS.runClient "127.0.0.1" port "/ws"` connects a real client. Run the suite with
`cabal test shibuya-metrics --test-show-details=direct` from the repository root.

The capability bundle. `docs/capabilities/` is an OKF bundle governed by
`docs/capabilities/profile.dhall`; each record has a stable `CAP-N` handle, `status:
shipped`, and evidence entries. CAP-10, `docs/capabilities/metrics-endpoints.md`, describes
the metrics server and states that it performs no authentication and that a non-loopback
bind needs an authorization boundary. Handles are allocated with `okf id next`, never by
counting files, and every change appends to the bundle's `log.md`.

What EP-51 will have added. This plan compiles only against a tree where
`docs/plans/51-implement-source-level-processor-pause-and-resume.md` is Complete. Verify each
of these before starting, and stop with a report if any is missing.
`Shibuya.Internal.Runner.Master` exports `pauseProcessorIO :: Master -> ProcessorId -> IO
ControlOutcome`, `resumeProcessorIO :: Master -> ProcessorId -> IO ControlOutcome`, and
`isProcessorPausedIO :: Master -> ProcessorId -> IO (Maybe Bool)`, with

```haskell
data ControlOutcome
  = ControlApplied           -- the state changed
  | ControlAlreadyInState    -- already paused (or already running); nothing changed
  | ControlNotFound          -- no processor with that identifier is registered
  | ControlNotControllable   -- registered without a pause handle (test-only registrations)
  | ControlTerminal          -- the processor has stopped or failed; pause is meaningless
```

The registry entry per processor carries an optional pause handle, and `registerProcessor
master pid metricsHandle (Just pauseHandle)` registers a controllable processor while
`Nothing` registers one that is not. `ProcessorState` in `Shibuya.Core.Metrics` has the
constructor `Paused !InFlightInfo !UTCTime`, encoded as
`{"status":"paused","pausedAt":"<utc>","inFlight":<n>,"maxConcurrency":<m>}`, and
`sampleMetrics` reports it while the pause holds. Pausing gates the adapter source in the
ingester, so no new message is pulled while in-flight messages finish and acknowledge.
`stopAppGracefully` resumes paused processors before shutting adapters down, so a paused
application still stops cleanly.

What EP-47 will have added. `docs/plans/47-add-configurable-cross-origin-access-to-the-metrics-server.md`
adds `Shibuya.Metrics.Error` exporting `errorResponse :: Status -> Text -> Text -> [Pair] ->
Response`, which renders `{"error": <message>, "code": <code>, ...extra members}` with the
`application/json` content type; it also retrofits `code` onto the existing 404 bodies and
adds `Shibuya.Metrics.Cors.corsMiddleware`, whose preflight answer allows `GET`, `POST`, and
`OPTIONS`. Milestone 1 may proceed without EP-47 by rendering its refusal through a local
helper of the same shape, but Milestone 2 must not begin until `Shibuya.Metrics.Error` exists
so that the surface has exactly one error renderer, and the preflight test in Milestone 2 runs
only once EP-47 is Complete.

ADRs that govern this plan, all under `docs/adr/`.
`0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`
fixes the rules this plan applies: control is refused by default with a structured error;
reversible operations need no preview step; every error body is an object with `error` and
`code` and optional context members, camelCase members, snake_case codes; and the package
boundary keeps every HTTP route in `shibuya-metrics` while the pause primitive stays a plain
function in `shibuya-core`.
`0003-make-processor-termination-and-shutdown-outcomes-explicit.md` defines the retained
lifecycle snapshot (`LifecycleRunning`, `LifecycleDraining`, `LifecycleStopped`,
`LifecycleFailed`) that makes `ControlTerminal` meaningful: a processor that has finished
stays known to the master, so a control request for it is a conflict, not a missing
resource. `0004-make-websocket-lifecycle-and-terminal-delivery-explicit.md` defines the
`update` frames through which the paused state reaches WebSocket clients; this plan adds no
frame. `0001-remove-obsolete-linked-actors-and-test-gc-liveness.md` supplies the rule that a
test asserting corrected behavior must be seen failing before it is trusted; here, the
refusal and outcome tests are seen failing against the tree before the routes exist.

The cross-repository posture in `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7` (a UI
renders a disabled server-side gate as a disabled action with its reason and never adds
capability the server lacks) is context that explains why discovery is worth serving; it
does not bind this repository.


## Plan of Work


### Milestone 1: the gate, discovery, and refusal


Goal: a server can say whether control is enabled, and refuses every action while it is not,
before any action exists. At the end of this milestone `GET /control` works in both gate
positions, both action paths answer 403 with `control_disabled` when the gate is off, and
`ControlSpec` proves both.

Add the field to `MetricsServerConfig` in `shibuya-metrics/src/Shibuya/Metrics/Config.hs`,
after `enableWebSocket`:

```haskell
    -- | Enable the control routes under @/control@ (default: False).
    --
    -- While False, every control action is refused with HTTP 403 and the error code
    -- @control_disabled@, and nothing is changed. Enable it only on a loopback listener
    -- or behind an authenticating boundary: the server performs no authentication, so
    -- anyone who can reach an enabled control route can pause processing.
    enableControl :: !Bool,
```

Set `enableControl = False` in `defaultConfig`. `validateConfig` needs no new rule, because a
Boolean cannot be malformed; note that in the Decision Log if you find yourself adding one.

Create `shibuya-metrics/src/Shibuya/Metrics/Control.hs`, add it to `exposed-modules` in the
cabal file, and export `controlApp :: MetricsServerConfig -> Master -> Application`. Route on
`pathInfo` and `requestMethod` (from `Network.Wai`, compared against `methodGet` and
`methodPost` from `Network.HTTP.Types`):

- `["control"]` with `GET` answers 200 and the body
  `{"enabled": <config.enableControl>, "operations": ["pause","resume"]}`; any other method
  answers 405 with code `method_not_allowed`, message `Method not allowed`, and an `Allow:
  GET` header.
- `["control","processors",pid,"pause"]` and `["control","processors",pid,"resume"]` with
  `POST`: when `config.enableControl` is `False`, answer 403 with code `control_disabled`
  and message `Control operations are disabled`, and call nothing on the master. When it is
  `True`, Milestone 2 fills in the action; in this milestone, leave a clearly named stub that
  returns the same 403 so the test for the enabled path fails visibly. Any other method on
  these two paths answers 405 with code `method_not_allowed` and `Allow: POST`.
- Any other path under `["control", ...]` answers 404 with code `not_found` and message
  `Not found`.

Request bodies are ignored on every route; a client need not send one, and one that does is
not rejected. Render every error through `errorResponse` from `Shibuya.Metrics.Error` if it
exists; if you are running ahead of EP-47, write a private `controlError :: Status -> Text ->
Text -> [Pair] -> Response` with exactly that output shape and replace it with the shared
helper when it lands, recording the swap in the Decision Log. The 405 responses need the extra
`Allow` header, so build them with `responseLBS` and the same JSON body shape rather than
through the helper if the helper takes no headers.

Wire it into `httpApp` in `Server.hs` by adding, beside the JSON routes and under the same
`enableJSON` guard, the case `("control" : _) | config.enableJSON -> controlApp config master
req respond`. Place it before the final catch-all. With JSON endpoints disabled, control paths
fall through to the generic 404 like every other JSON route.

Write `shibuya-metrics/test/Shibuya/Metrics/ControlSpec.hs`, add it to `other-modules` of the
test stanza and to `test/Main.hs`. Use `around withMaster` and the `appFor` pattern from
`ServerSpec.hs`, and send `POST` requests with `Network.Wai.Test` by setting
`requestMethod = methodPost` on `defaultRequest` before `setPath`. Cover: discovery reports
`enabled: false` under `defaultConfig` and `enabled: true` under `defaultConfig {enableControl
= True}`, with the `operations` list in both; `GET /control` returns exactly the decoded
object; `POST` on either action path under `defaultConfig` answers 403 with the exact decoded
body `{"error":"Control operations are disabled","code":"control_disabled"}` and, for a
processor registered with a real pause handle, `isProcessorPausedIO` still answers `Just
False` afterwards; `DELETE /control` answers 405 with `Allow: GET`; `GET` on an action path
answers 405 with `Allow: POST`; `GET /control/other` answers 404 with code `not_found`; and
with `enableJSON = False` every control path answers the generic 404. Before writing the
implementation, run this spec against the unmodified tree and record in Surprises &
Discoveries that every example failed to compile or failed, then implement and watch it pass.

Result and proof: `cabal test shibuya-metrics --test-show-details=direct` passes with the new
examples listed, and the unmodified-tree failure is recorded.


### Milestone 2: the actions, in both gate positions, end to end


Goal: with the gate on, pause and resume act and report; with it off, nothing changes; and
the whole path is proven through a real application on a real port. Do not begin until
`Shibuya.Metrics.Error` exists.

Replace the Milestone 1 stub in `Control.hs`. For `pause` with the gate on, call
`pauseProcessorIO master (ProcessorId pid)` and map the outcome:

- `ControlApplied` or `ControlAlreadyInState`: sample `getProcessorMetricsIO master pid`. If
  the sampled state is `Paused _ pausedAt`, answer 200 with
  `{"processor": pid, "state": "paused", "pausedAt": pausedAt}`. If the sample is missing or
  its state is `Failed` or `Stopped`, the processor reached a terminal state between the
  request and the sample; answer 409 with code `processor_terminal` and a `processor` member.
  Record this race handling in the Decision Log; it is why the response is built from the
  sample rather than from the outcome alone.
- `ControlNotFound`: 404, code `processor_not_found`, message `Processor not found`, member
  `processor`.
- `ControlTerminal`: 409, code `processor_terminal`, message `Processor has finished`, member
  `processor`.
- `ControlNotControllable`: 409, code `processor_not_controllable`, message `Processor does
  not support control operations`, member `processor`.

For `resume`, call `resumeProcessorIO` and answer 200 with `{"processor": pid, "state":
"running"}` for `ControlApplied` and `ControlAlreadyInState`; the three failure outcomes map
exactly as for pause. Both action handlers are idempotent by construction: a second request
returns the same status and body, and for pause the same `pausedAt`, because the pause handle
keeps the original timestamp.

Extend `ControlSpec.hs` with the in-process cases, all under `defaultConfig {enableControl =
True}` and a master whose processors are registered with `registerProcessor master pid handle
(Just pauseHandle)` using a real `PauseHandle` from EP-51's module: pause answers 200 with
state `paused` and a `pausedAt` that parses as a time, and `isProcessorPausedIO` answers
`Just True`; a second pause answers the identical body; resume answers 200 with state
`running` and `isProcessorPausedIO` answers `Just False`; a second resume answers the identical
body; an unregistered identifier answers 404 `processor_not_found` with the `processor`
member echoed; a processor registered with `Nothing` answers 409 `processor_not_controllable`;
a processor whose lifecycle has been marked failed with `markProcessorFailedIO` and then
unregistered answers 409 `processor_terminal`; `GET` on an action path still answers 405.
Apply the ADR-0001 rule again: run the new examples against the Milestone 1 tree first and
record their failure.

Then write the end-to-end example, in `ControlSpec.hs` or a sibling `ControlEndToEndSpec.hs`
if the file grows past comfort, with the real pieces in place of fixtures. Build a live
adapter: a `TBQueue` of envelopes, a `TVar Bool` stop flag, and an `Adapter` whose `source` is
`Stream.repeatM` of an STM action that either takes the next envelope or, once the stop flag
is set, yields a sentinel that `Stream.takeWhile` ends the stream on, and whose `shutdown`
sets the flag. Each envelope's acknowledgement is tracked with `trackedListAdapter`-style
tracking from `Shibuya.Adapter.Mock` (use `mkTrackedIngested` with one shared `TrackingAck`).
The handler increments a `TVar Int` of started messages, then blocks on a per-message
`TMVar ()` gate the test releases, then returns `AckOk`. Start the application with `runEff $
runTracingNoop $ runApp defaultAppConfig [(ProcessorId "orders", QueueProcessor adapter
handler Unordered Serial)]`, take its master with `getAppMaster`, and serve `combinedApp
defaultConfig {enableControl = True, wsPushIntervalUs = 10_000} master wsState []` with
`Warp.testWithApplication`. Speak HTTP over the real port with `http-client` (add
`http-client ^>=0.7.19` to the test stanza's `build-depends`, the bound the wire-load
executable already uses; confirm the current release on Hackage before writing it) and
WebSocket with `WS.runClient`.

The scenario, with every wait an STM barrier or a bounded `timeout` used only as a failure
bound: open a WebSocket client and read its initial snapshot; enqueue message `m1` and wait
until started equals 1; `POST` pause and assert 200 with state `paused`; enqueue `m2`;
release `m1`'s gate and wait until the tracker records `m1` acknowledged with `AckOk`; assert
that a 200-millisecond bounded wait for started to reach 2 returns `Nothing`, which shows the
paused processor pulled nothing more from the adapter; `GET /metrics/orders` and assert the
decoded `state.status` is `paused` with `inFlight` 0; read WebSocket frames until an `update`
for `orders` whose state status is `paused` arrives, within a bounded timeout; `POST` resume
and assert 200 with state `running`; wait until started equals 2, release `m2`'s gate, and wait
until `m2` is acknowledged; finally call `stopAppGracefully defaultShutdownConfig` and assert
it returns `True` within the total shutdown timeout, which proves that a processor paused
and resumed through HTTP still drains and stops.

If EP-47 is Complete, add the preflight example: with `corsAllowedOrigins = ["https://ops.example.com"]`
and `enableControl = True`, an `OPTIONS /control/processors/orders/pause` request carrying
`Origin: https://ops.example.com` and `Access-Control-Request-Method: POST` answers 204 with
`Access-Control-Allow-Origin: https://ops.example.com` and an `Access-Control-Allow-Methods`
value containing `POST`. If EP-47 is not yet Complete, leave this example written but marked
pending in Progress, and do not mark this plan Complete until it has run green.

Result and proof: the metrics suite passes with the new examples, the recorded failures
against the earlier tree exist, and the end-to-end example's transcript in Concrete Steps
shows the pause, the drained `m1`, the WebSocket update, the resume, and the clean stop.


### Milestone 3: records and closure


Goal: everything a reader needs to use the control plane is written down where the other
routes are documented, the durable decision is an ADR, and IR-4 is closed with evidence.

Update the Haddock header of `shibuya-metrics/src/Shibuya/Metrics.hs`: add the three control
routes to the endpoint list, the `enableControl` gate and its default, the response bodies,
and the codes `control_disabled`, `processor_not_found`, `processor_terminal`,
`processor_not_controllable`, `method_not_allowed`, and `not_found` with their statuses.
Re-export `enableControl` through the existing `MetricsServerConfig (..)` export; no new
export is needed for the module, but export `controlApp` from `Shibuya.Metrics.Server`'s
re-export list only if a host would mount it alone, which this plan does not require.

`docs/USAGE_GUIDE.md` is now a short index pointing at `docs/user/getting-started.md`, whose
section "Monitoring & Metrics" is where the metrics server is introduced for users. Add a
subsection "Control operations" there (and a one-line pointer in the index if the index
lists subsections), containing: what the gate is and its default, the configuration snippet
`defaultConfig {enableControl = True}`, the trusted-network warning, and two `curl`
transcripts, one against a server with the gate off showing the 403 body and one with it on
showing discovery, pause, the paused metrics state, and resume. In
`docs/architecture/METRICS.md` add a section "Control plane" after "Accessing Metrics" that
describes the routes, the outcome mapping to statuses, and that the paused state reaches
WebSocket clients through ordinary `update` frames.

Add a capability record. Read `docs/capabilities/profile.dhall` and
`docs/capabilities/metrics-endpoints.md`, then run
`okf id next docs/capabilities CAP --profile docs/capabilities/profile.dhall` (it printed
`CAP-11` at planning time; use whatever it prints) and create
`docs/capabilities/gated-processor-control.md` with the same frontmatter members as CAP-10:
`title`, `type: Capability`, `description`, `generated` with `by` and `at`, `capabilityId`,
`provider: mori://shinzui/shibuya`, `status: shipped`, `stability: experimental`, `since`,
`packages` (`shibuya-metrics`), `interface` (`Shibuya.Metrics.Control`,
`Shibuya.Metrics.Config`), `requires` (`CAP-10` and the capability EP-51 records for pause,
if it added one), and `evidence` entries pointing at `Control.hs`, `ControlSpec.hs`, and the
ADR. `since` names the release that ships the record; if the release owner has not chosen the
version when you write it, use the current `version:` of `shibuya-metrics.cabal` and add a
Progress item to correct it at release. Add a cross-reference sentence to CAP-10's Limits
noting that control exists and is disabled by default. Append to `docs/capabilities/log.md`
with `okf log add docs/capabilities --kind Addition -m "..."` and validate with
`okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce`.

Write the ADR at the next unused number under `docs/adr/` (0008 at planning time; EP-48,
EP-49, and EP-51 may take numbers first), titled "Gate control endpoints off by default and
refuse with a structured error", in the plain-Markdown format of
`docs/adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md` with the
headings Status, Date, Context, Decision, Consequences, and Evidence. Record: the single flag
and its default; the 403 `control_disabled` refusal that performs no action; discovery
through `GET /control` in both positions; idempotent success on repeat; no preview step
because pause and resume are reversible; the trusted-network posture inherited from
ADR-0007; and that any future destructive operation must revisit this decision in its own
ADR rather than inherit the bare-`POST` shape.

Add changelog entries under an `Unreleased` heading in `CHANGELOG.md` and
`shibuya-metrics/CHANGELOG.md`: `MetricsServerConfig` gains `enableControl`, so direct record
construction must choose it (breaking for construction, default preserved through
`defaultConfig`); new routes `GET /control`, `POST /control/processors/<id>/pause`, and
`POST /control/processors/<id>/resume` with their codes are additive; the new
`Shibuya.Metrics.Control` module. Do not pick a version.

Record wire-load sanity numbers: run the `metrics-wire-load` health-polling scenario once on
the tree before Milestone 1 and once after Milestone 2, and paste `operationsPerSecond` and
`latencyP95Micros` from both JSON reports into Concrete Steps. The control routes are off the
message hot path and off the polled routes, so the numbers are a sanity check with no gate;
a change above 10% in p95 must be explained in Surprises & Discoveries.

Close IR-4, only once EP-51 is Complete in the MasterPlan registry. Edit
`docs/improvement-requests/implement-designed-processor-pause-resume-and-expose-gated-control-endpoints.md`:
set `status: completed`, add `completedAt` with the UTC time the end-to-end example passed,
add `resolution` naming EP-51 and this plan by path and the tests that prove each acceptance
item, advance `timestamp` to the same time, and add a short "Delivered" paragraph under its
Status section. Then run `okf log add docs/improvement-requests --kind Update -m "IR-4 completed: pause/resume delivered by EP-51 and gated control endpoints by EP-52."`
and validate with the strict command in Concrete Steps; the pre-existing advisories about a
missing `reviews` member on every record are expected and are not this plan's to fix.

Result and proof: every document named above contains its new section, the capability and
request bundles validate, the ADR exists, and the request's frontmatter reads `completed`.


## Concrete Steps


Run everything from the repository root, `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`,
inside the Nix development shell if `cabal` or `okf` is missing from `PATH`.

Confirm the prerequisites before Milestone 1:

```bash
grep -n 'pauseProcessorIO\|resumeProcessorIO\|isProcessorPausedIO\|ControlOutcome' shibuya-core/src/Shibuya/Internal/Runner/Master.hs
grep -n 'Paused' shibuya-core/src/Shibuya/Core/Metrics.hs
ls shibuya-metrics/src/Shibuya/Metrics/Error.hs shibuya-metrics/src/Shibuya/Metrics/Cors.hs
```

The first two commands must print matches; the third may fail until EP-47 lands, which
blocks Milestone 2 but not Milestone 1.

Build and test after each milestone:

```bash
cabal build all
cabal test shibuya-metrics --test-show-details=direct
cabal test shibuya-core
nix fmt
```

A passing metrics run ends with a line of the form `N examples, 0 failures` where N exceeds
the previous count by the number of examples you added; `cabal test shibuya-core` runs three
suites and all must pass, because this plan touches nothing in the core but must prove it.

Expected transcripts, against a server started on port 9090 with `enableControl = False`:

```text
$ curl -s -i http://127.0.0.1:9090/control
HTTP/1.1 200 OK
Content-Type: application/json

{"enabled":false,"operations":["pause","resume"]}

$ curl -s -i -X POST http://127.0.0.1:9090/control/processors/orders/pause
HTTP/1.1 403 Forbidden
Content-Type: application/json

{"error":"Control operations are disabled","code":"control_disabled"}
```

And with `enableControl = True`:

```text
$ curl -s -X POST http://127.0.0.1:9090/control/processors/orders/pause
{"processor":"orders","state":"paused","pausedAt":"2026-10-02T10:15:30Z"}

$ curl -s http://127.0.0.1:9090/metrics/orders
{"batch":{...},"startedAt":"...","state":{"inFlight":0,"maxConcurrency":1,"pausedAt":"2026-10-02T10:15:30Z","status":"paused"},"stats":{...}}

$ curl -s -X POST http://127.0.0.1:9090/control/processors/orders/resume
{"processor":"orders","state":"running"}

$ curl -s -i -X POST http://127.0.0.1:9090/control/processors/missing/pause
HTTP/1.1 404 Not Found
Content-Type: application/json

{"error":"Processor not found","code":"processor_not_found","processor":"missing"}

$ curl -s -i http://127.0.0.1:9090/control/processors/orders/pause
HTTP/1.1 405 Method Not Allowed
Allow: POST
Content-Type: application/json

{"error":"Method not allowed","code":"method_not_allowed"}
```

Member order inside a body is whatever Aeson emits; compare decoded objects, not bytes.

Wire-load sanity, before Milestone 1 and after Milestone 2, pasting the two numbers here:

```bash
SCENARIO=health OUTPUT_JSON=/tmp/wire-load-before.json cabal run shibuya-metrics:metrics-wire-load
SCENARIO=health OUTPUT_JSON=/tmp/wire-load-after.json cabal run shibuya-metrics:metrics-wire-load
```

Capability and request bundle commands for Milestone 3:

```bash
okf id next docs/capabilities CAP --profile docs/capabilities/profile.dhall
okf log add docs/capabilities --kind Addition -m "CAP-<N> records gated processor control: pause and resume routes, refused by default."
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf log add docs/improvement-requests --kind Update -m "IR-4 completed: pause/resume delivered by EP-51 and gated control endpoints by EP-52."
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

Commit after each milestone with a conventional-commit subject and this trailer block:

```text
MasterPlan: docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md
ExecPlan: docs/plans/52-expose-gated-pause-and-resume-control-endpoints.md
Intention: intention_01m3ta8zgtebmaz00g0snjzy5a
```

Record the exact example counts, seeds if Hspec prints them, and the wire-load numbers in this
section as you go.


## Validation and Acceptance


With `defaultConfig`, `GET /control` answers 200 with `enabled: false` and the operations
list, and a `POST` to either action path answers 403 with code `control_disabled` while the
named processor's pause state is unchanged; both are covered by tests that were seen failing
before the routes existed. With `enableControl = True`, pausing a registered processor answers
200 with state `paused` and a `pausedAt` time and the processor is paused; repeating the
request returns the identical body; resuming answers 200 with state `running` and the
processor is not paused; unknown, non-controllable, and terminal processors answer 404
`processor_not_found`, 409 `processor_not_controllable`, and 409 `processor_terminal`
respectively, each echoing the `processor` member; a wrong method answers 405 with an
`Allow` header; and `enableJSON = False` hides every control path behind the generic 404.

End to end, through a real application on a real port: after a pause, the in-flight message
finishes and is acknowledged while no further message is started; `GET /metrics/<id>` shows
`status` `paused`; a real WebSocket client receives an `update` frame with that state; after
a resume the next message starts and completes; and `stopAppGracefully` returns `True`. When
EP-47 is Complete, a preflight for an action path from an allowed origin answers 204 with
`POST` among the allowed methods.

Documentation acceptance: the Haddock header, the getting-started guide, and
`docs/architecture/METRICS.md` each describe the routes, gate, and codes; the capability
bundle validates with the new record and log entry; the ADR exists; both changelogs carry
the entries; and IR-4's frontmatter reads `status: completed` with `completedAt` and
`resolution`, its bundle validating under the strict command with only the pre-existing
`reviews` advisories. Tests exercise real HTTP requests and a real socket, not only record
construction; a sleep is never the proof of an ordering, only a bound on a wait.


## Idempotence and Recovery


Every step can be repeated. Re-running the test suite is safe. Re-running `okf log add`
appends a duplicate entry; remove the duplicate by hand before committing. `okf id next` is
read-only and returns the next free handle each time; once a handle is committed it is
permanent, so if you delete an uncommitted record, re-run `okf id next` rather than reusing
the number from memory. The end-to-end example creates only in-process resources (a `TBQueue`,
a Warp listener on a free port, a `Master`) and brackets each, so an aborted run leaks
nothing beyond the process. If Milestone 2 starts before `Shibuya.Metrics.Error` exists, stop
and record the wait in Progress rather than inventing a second error renderer. If EP-51's
functions differ in name or shape from the ones named in Context and Orientation, adapt the
calls, record the difference in Surprises & Discoveries, and do not edit `shibuya-core` from
this plan. Revert an implementation commit only with explicit authorization; never reset the
checkout.


## Interfaces and Dependencies


Hard dependency: `docs/plans/51-implement-source-level-processor-pause-and-resume.md`, which
supplies `Shibuya.Internal.Runner.Master.pauseProcessorIO`, `resumeProcessorIO`,
`isProcessorPausedIO`, `ControlOutcome`, the optional pause handle in `registerProcessor`, and
`ProcessorState.Paused` with its JSON encoding. Soft dependency:
`docs/plans/47-add-configurable-cross-origin-access-to-the-metrics-server.md`, which supplies
`Shibuya.Metrics.Error.errorResponse` (required before Milestone 2) and
`Shibuya.Metrics.Cors.corsMiddleware` allowing `GET`, `POST`, and `OPTIONS` (required before
the preflight example runs and before this plan is marked Complete). The `error` WebSocket
frame introduced by `docs/plans/48-align-the-metrics-websocket-protocol-with-bounded-delivery-and-in-band-errors.md`
is a frame on the socket and has nothing to do with the HTTP bodies here; the two plans share
only the snake_case code style.

Interfaces that exist at the end of Milestone 1:

```haskell
-- shibuya-metrics/src/Shibuya/Metrics/Config.hs
data MetricsServerConfig = MetricsServerConfig
  { ...
  , enableControl :: !Bool   -- default False
  , ...
  }

-- shibuya-metrics/src/Shibuya/Metrics/Control.hs
module Shibuya.Metrics.Control (controlApp) where
controlApp :: MetricsServerConfig -> Master -> Application
```

Route table that exists at the end of Milestone 2, all served only when `enableJSON` is
`True`:

```text
GET  /control                              200 {"enabled":<bool>,"operations":["pause","resume"]}
*    /control                              405 code method_not_allowed, Allow: GET
POST /control/processors/<id>/pause        gate off: 403 code control_disabled (no action)
                                           applied / already paused: 200 {"processor","state":"paused","pausedAt"}
                                           not found: 404 code processor_not_found, member processor
                                           terminal: 409 code processor_terminal, member processor
                                           not controllable: 409 code processor_not_controllable, member processor
POST /control/processors/<id>/resume       gate off: 403 code control_disabled (no action)
                                           applied / already running: 200 {"processor","state":"running"}
                                           failures exactly as for pause
*    /control/processors/<id>/{pause,resume} 405 code method_not_allowed, Allow: POST
*    /control/<anything else>              404 code not_found
```

Libraries: `wai` and `http-types` for routing and statuses, `aeson` for bodies, all already
dependencies of the library; `http-client ^>=0.7.19` is added to the test stanza only, for
real-port requests, using the bound the `metrics-wire-load` executable already declares after
confirming the current release on Hackage; `websockets`, `warp`, and `wai-extra` are already
test dependencies. Documentation artifacts: `shibuya-metrics/src/Shibuya/Metrics.hs` header,
`docs/user/getting-started.md`, `docs/architecture/METRICS.md`,
`docs/capabilities/gated-processor-control.md` with its log entry, one new ADR under
`docs/adr/`, `CHANGELOG.md`, `shibuya-metrics/CHANGELOG.md`, and the IR-4 record with its log
entry.
