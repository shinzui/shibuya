---
id: 7
slug: browser-ready-processor-inspection-and-control-surface
title: "Browser-ready processor inspection and control surface"
kind: master-plan
created_at: 2026-09-30T23:27:01Z
intention: "intention_01m3ta8zgtebmaz00g0snjzy5a"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T23:27:01Z
---


# Browser-ready processor inspection and control surface

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope


After this initiative, a browser page served from any origin the host allows can watch and
steer the processors of a Shibuya application through `shibuya-metrics` alone. For every
processor the page can answer how fast it runs (a processing-latency distribution), how far
it has got (the most recently acknowledged cursor, per partition where the adapter supplies
partition keys), and what it is stuck on (the identity and age of the oldest in-flight
message). An operator can pause a misbehaving processor so it takes no new work while
in-flight messages drain and acknowledge normally, see that pause as a distinct processor
state in JSON, Prometheus, and the WebSocket stream, and resume it later. Every one of these
additions is visible on the wire the same way: `GET /metrics/<processorId>` and the WebSocket
`update` frame carry the same new members, the Prometheus text gains series, and a client
written against the 0.10.0.0 surface keeps working unchanged.

The surface is Shibuya's own. Nothing in it names keiro, keiro-ui, kiroku, or pgmq, and
nothing requires a composed deployment: a standalone Shibuya operations page needs only the
`shibuya-metrics` package, one allowed origin in its configuration, and, if it wants to act,
the control gate switched on. The three improvement requests that motivate the work were
filed from the keiro-ui initiative, `docs/improvement-requests/expose-processor-progress-latency-and-in-flight-detail-for-inspection-uis.md`
(IR-3), `docs/improvement-requests/implement-designed-processor-pause-resume-and-expose-gated-control-endpoints.md`
(IR-4), and `docs/improvement-requests/harden-shibuya-metrics-for-browser-clients-cors-tests-and-ws-convention-alignment.md`
(IR-5); this initiative treats them as requirements against Shibuya's published surface and
treats the cross-project conventions they cite as an external input that Shibuya's own
contract, recorded in `docs/adr/0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`,
is compatible with where that compatibility costs nothing and documents its deviation from
where it does not.

In scope: configurable cross-origin access for HTTP and WebSocket upgrades; a bounded
per-connection WebSocket delivery queue with in-band `error` frames and a documented
conformance mapping; a processing-latency distribution, oldest-in-flight detail, and
acknowledged-cursor progress in `shibuya-core` and their exposure in `shibuya-metrics`;
source-level pause and resume in `shibuya-core` with a public application API; control
endpoints in `shibuya-metrics` that refuse by default; the tests, golden fixtures,
documentation, capability records, changelog entries, and ADRs each of those needs; and the
closure of IR-3, IR-4, and IR-5 with evidence. The test-suite item of IR-5 is already
delivered by `docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md`
and is consumed, not repeated.

Out of scope: any browser application itself, whether keiro-ui or a standalone Shibuya
page; authentication, authorization, and TLS, which remain the deployment's reverse proxy;
Server-Sent Events; queue depth, queue age, and dead-letter browsing, which belong to the
adapters that know the backing queue; the public worker probe contract of
`docs/improvement-requests/expose-a-public-worker-probe-contract.md` (IR-1); the transient
handler-exception readiness defect of
`docs/improvement-requests/restore-readiness-after-a-transient-handler-exception.md` (IR-7)
and the separate retry-decision counter of
`docs/improvement-requests/expose-retry-decisions-separately-from-processed-counters.md`
(IR-8), both filed by another consumer and adjacent to but not part of these requests;
changing the meaning of any published counter; choosing the next release version; and
publishing packages. Children may make deliberate breaking source changes that a feature
genuinely needs, such as a new `ProcessorState` constructor, and must record each for the
changelog; the version is a release-time decision.


## Decomposition Strategy


Six children, grouped into two waves. Wave A holds the three streams that need nothing from
one another and can start immediately: cross-origin access for the server (EP-47), latency
and oldest-in-flight accounting in the core (EP-49), and source-level pause and resume in the
core (EP-51). Wave B holds the three streams that build on a Wave A sibling: WebSocket
delivery and convention alignment (EP-48), which closes IR-5 only once EP-47 has landed;
cursor progress (EP-50), which extends the record, detail switch, and fixtures EP-49
introduces and closes IR-3; and the gated control endpoints (EP-52), which cannot compile
without EP-51's pause primitives and closes IR-4.

The split follows functional concerns, one independently observable behavior per child. The
two halves of IR-5 are separate because cross-origin policy is a request/response concern
in `Shibuya.Metrics.Server` while delivery and error frames are a connection-lifetime concern
in `Shibuya.Metrics.WebSocket`; each is verifiable alone through real loopback requests. IR-3
is split because its three asks rest on two different mechanisms: latency and oldest
in-flight share one per-message timing slot, whereas cursor progress is a per-partition
record of already-allocated cursor values, and each half has its own performance question.
IR-4 is split at the package boundary: the core pause primitive is complete and testable
through the application handle before any HTTP route exists, and the endpoint child is then
small enough to stay focused on gating and wire shape.

Alternatives rejected: one child per request would have produced three plans of very
unequal size, with IR-3 doing most of the work and its two performance decisions hidden
inside one milestone list; a child per source file would have split the hot-path timing from
the encoders that expose it and made no milestone independently demonstrable; and folding
the control endpoints into the pause child would have coupled a public core API and its tests
to server configuration, contrary to the package boundary that CAP-10 and
`docs/adr/0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`
keep.

Local ADRs were scanned by filename and heading and the relevant ones read in full. ADR-0007,
created with this MasterPlan, is the shared contract every child cites: frozen shapes and
additive evolution, camelCase members with snake_case values and codes, the `code` member on
error bodies, the core/metrics package boundary, opt-in cross-origin access and control, and
the hot-path budget rule. `docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md`
supplies the paired-measurement budgets the core children must meet.
`docs/adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md` defines the
retained lifecycle snapshot and the halt-versus-failure distinction that pause must respect.
`docs/adr/0004-make-websocket-lifecycle-and-terminal-delivery-explicit.md` defines slot
ownership, subscriptions, `goodbye`, and once-only `terminal` delivery that EP-48's queue must
preserve. `docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md` contributes
the rule that a defect test must be seen failing before it is trusted. ADR-0005 and ADR-0006
concern dependency bounds and are not relevant. Cross-repository decisions were read through
Mori for context only: `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`,
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`, and
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7` describe what that consumer expects; none
binds this repository, and children cite only ADR-0007 for the contract.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 47 | Add configurable cross-origin access to the metrics server | [EP-47](../plans/47-add-configurable-cross-origin-access-to-the-metrics-server.md) | None | None | Not Started |
| 48 | Align the metrics WebSocket protocol with bounded delivery and in-band errors | [EP-48](../plans/48-align-the-metrics-websocket-protocol-with-bounded-delivery-and-in-band-errors.md) | None | EP-47 gates only the IR-5 closure milestone | Not Started |
| 49 | Expose per-processor latency distribution and oldest in-flight detail | [EP-49](../plans/49-expose-per-processor-latency-distribution-and-oldest-in-flight-detail.md) | None | None | Not Started |
| 50 | Expose acknowledged cursor progress per processor and partition | [EP-50](../plans/50-expose-acknowledged-cursor-progress-per-processor-and-partition.md) | None | EP-49 owns the detail switch, record fields, and fixtures this plan extends; implement after it | Not Started |
| 51 | Implement source-level processor pause and resume | [EP-51](../plans/51-implement-source-level-processor-pause-and-resume.md) | None | None | Not Started |
| 52 | Expose gated pause and resume control endpoints | [EP-52](../plans/52-expose-gated-pause-and-resume-control-endpoints.md) | EP-51 | EP-47 owns the error helper and the CORS handling that browser `POST` needs | Not Started |

Row numbers are the child plans' own sequence numbers under `docs/plans/`, so EP-47 is
`docs/plans/47-...`. Wave A is EP-47, EP-49, and EP-51. Wave B is EP-48, EP-50, and EP-52.


## Dependency Graph


EP-52 has the initiative's only hard dependency. Its control routes call the pause and
resume functions that EP-51 adds to `Shibuya.Internal.Runner.Master`, and its tests assert
the `Paused` processor state that EP-51 adds to `Shibuya.Core.Metrics`; without EP-51 the
endpoint child does not compile. Every other edge is a soft dependency, an ordering of
completion or an obligation on one milestone, not a blocked start.

EP-48 can start at once: the `error` frame, the bounded outbound queue, and the conformance
mapping touch `Shibuya.Metrics.WebSocket` and `Shibuya.Metrics.Types`, which EP-47 does not
edit. Its last milestone closes IR-5, and IR-5 asks for configurable cross-origin access as
well, so that milestone waits for EP-47 to be Complete and the conformance mapping's
cross-origin row cites EP-47's configuration.

EP-50 can start at once in principle, but it extends the `MetricsDetail` switch, the
`ProcessorMetrics` record, the omit-`Nothing` encoder, the `processOne` and
`processOneBatch` hook points, and the golden fixtures that EP-49 introduces. Implementing
it first would force EP-49 to rebase the same edits. The registry therefore orders EP-50
after EP-49, and EP-50 closes IR-3 only after both are Complete. If EP-49 concludes that
detailed accounting must default to off, EP-50 inherits that default and re-measures its own
addition under both levels.

EP-52 soft-depends on EP-47 for two artifacts: the shared error-response helper that emits
`error` plus `code`, and the cross-origin middleware that a browser needs for `POST` and its
`OPTIONS` preflight. EP-52's endpoint milestone must not begin until the helper exists; its
browser preflight test runs only once EP-47 is Complete, and EP-52 is not marked Complete
before that test has run.

EP-49 and EP-51 both edit `Shibuya.Core.Metrics`: EP-49 adds record fields and the detail
switch, EP-51 adds the `Paused` constructor and its sampling rule. The edits are disjoint in
content but not in file, so implement them sequentially in either order and rebase the
second on the first. Neither waits on the other.

```text
Wave A: EP-47 (cross-origin)     EP-49 (latency + in-flight)     EP-51 (pause core)
           :   \                      :                              |
           :    \.........> EP-52 <---+ (hard: pause API, Paused state)
           :                          :
           :.........> EP-48 (closes IR-5 after EP-47)
                                      :
                       EP-49 ........> EP-50 (cursor progress; closes IR-3)

--->  hard dependency        ....>  soft dependency: ordering, or one gated milestone
```

Three children can proceed in parallel from the start. A contributor picking the next plan
takes the first Not Started child whose hard dependencies are Complete, which selects EP-47,
then EP-48, then EP-49, then EP-50, then EP-51, then EP-52 in registry order; the soft
constraints above only defer single milestones, so that order never deadlocks.


## Integration Points


**The wire contract, owned by this MasterPlan through ADR-0007.** Every child follows
`docs/adr/0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`:
published routes, members, frames, series, and status codes are frozen; additions are
optional members, new frame types, new routes, and new series; JSON member names are
camelCase, enumerated values and error codes and series names are snake_case; a `Nothing`
member is omitted, never emitted as `null`; and no value is fabricated. A child that changes
an encoder updates the golden fixtures under `shibuya-metrics/test/golden/` and the fixture
values in `shibuya-metrics/test/Shibuya/Metrics/TestSupport.hs` in the same commit, records
the change in its Decision Log, and adds a changelog line naming it as additive. A golden
diff without such a record is a defect in the change, exactly as
`docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md` ruled.

**Error bodies, owned by EP-47.** EP-47 adds a helper, `errorResponse` in a new module
`Shibuya.Metrics.Error`, that renders an error body as an object with `error` (message),
`code` (stable snake_case), and optional context members, and retrofits `code` additively
onto the existing 404 bodies (`not_found`, `processor_not_found`,
`websocket_upgrade_required`). EP-52 consumes the helper for `control_disabled`,
`processor_not_found`, `processor_terminal`, `processor_not_controllable`, and
`method_not_allowed`; EP-47 uses it for `origin_not_allowed`. The WebSocket `error` frame of
EP-48 uses the same code vocabulary style but is a frame, not an HTTP body, and lives in
`Shibuya.Metrics.Types`.

**`MetricsServerConfig` in `shibuya-metrics/src/Shibuya/Metrics/Config.hs`.** Three children
add one field each: EP-47 adds `corsAllowedOrigins :: [Text]` (default `[]`), EP-48 adds
`wsMaxQueuedFrames :: Int` (default 64), and EP-52 adds `enableControl :: Bool` (default
`False`). Each child adds its own default in `defaultConfig`, its own rule in
`validateConfig` in `Shibuya.Metrics.Server`, its own Haddock, and its own changelog line
marking direct record construction as affected. Fields are independent, so order does not
matter; the second child to land rebases trivially.

**`Shibuya.Metrics.Server.combinedApp` and `httpApp`.** EP-47 wraps `combinedApp`'s HTTP
side in the cross-origin middleware and guards the WebSocket branch's `Origin` header before
`websocketApp` acquires a connection slot. EP-52 adds the `control` routes inside `httpApp`.
The two edits are in different functions; EP-52 lands after EP-47 by its soft dependency.

**`Shibuya.Metrics.Types.ServerMessage`.** Only EP-48 adds a constructor, `ServerError`, for
the `error` frame. EP-49, EP-50, and EP-51 change what `snapshot` and `update` frames carry
only through the `ProcessorMetrics` and `ProcessorState` encoders in `shibuya-core`; they do
not edit `Types.hs` beyond round-trip test fixtures. Adding a constructor to the exported
`ServerMessage` is a source-breaking change for exhaustive matches, recorded by EP-48 for the
changelog.

**`Shibuya.Core.Metrics`.** EP-49 owns the `MetricsDetail` switch (`MetricsBasic` or
`MetricsDetailed DetailOptions`, where `DetailOptions` already carries
`maxTrackedPartitions` for EP-50), the slot-based in-flight table and sharded histogram, the
`latency` and `oldestInFlight` fields on `ProcessorMetrics`, the switch of that record's JSON
instances to omit `Nothing` members, `newMetricsHandleWith`, and the two detail-only hooks
`claimInFlightSlot` and `releaseInFlightSlot`. EP-50 adds the `progress` field, the
acknowledged-cursor record (`recordAcknowledgedCursor`), and the bounded partition table,
reusing EP-49's switch and encoder options. EP-51 adds the `Paused InFlightInfo UTCTime`
constructor to `ProcessorState`, its JSON encoding (`status: paused`, `pausedAt`,
`inFlight`, `maxConcurrency`), and the sampling rule that cold `Paused` wins over `Idle` and
`Processing` but loses to `Failed` and `Stopped`. The existing public functions
`beginProcessing`, `finishProcessing`, `recordBatchOutcomeMetrics`, and `newMetricsHandle`
keep their types; `newMetricsHandle` means basic detail.

**`AppConfig` in `shibuya-core/src/Shibuya/App.hs`.** EP-49 adds `metricsDetail ::
MetricsDetail`, whose default is the constant `defaultMetricsDetail` exported from
`Shibuya.Core.Metrics` and set to whichever level EP-49's measurement supports. Because the
performance harness calls `runSupervised` directly and the comparator rejects a changed
harness, `runSupervised` and `runSupervisedBatch` keep their types and delegate to new
`runSupervisedWith` and `runSupervisedBatchWith` variants that take the `MetricsDetail`
and pass it to `newMetricsHandleWith` with the concurrency bound; `Shibuya.App` calls the
`With` variants. EP-50 and EP-51 do not add configuration to `AppConfig`.

**Hook points in `Shibuya.Internal.Runner.Supervised.processOne` and
`Shibuya.Internal.Runner.BatchProcessor.processOneBatch`.** EP-49 claims a slot after
`beginProcessing` and releases it after `finishProcessing`, only when the handle is
detailed. EP-50 records the acknowledged cursor after a successful `finalizeWithRetry`
whose decision is `AckOk` or `AckDeadLetter`, per message in the batch path, only when the
handle is detailed. EP-51 does not touch these functions; its gate lives in
`Shibuya.Internal.Runner.Ingester`.

**`Shibuya.Internal.Runner.Master`.** Only EP-51 edits it: the registry entry per processor
gains an optional pause handle beside the metrics handle, `registerProcessor` accepts it,
and `pauseProcessorIO`, `resumeProcessorIO`, and `processorPauseStateIO` become the
Master-level control functions that EP-52 calls from the server. Test support code and the
wire-load fixture that call `registerProcessor` pass `Nothing`.

**Health and Prometheus in `shibuya-metrics`.** EP-51 makes both compile against the new
constructor: `Shibuya.Metrics.Health.ProcessorHealth` gains an additive `paused` count,
paused processors are neither healthy, failed, nor stuck and do not fail readiness, and
`Shibuya.Metrics.Prometheus` maps `Paused` to gauge value 5 with the HELP text extended.
EP-49 adds the `shibuya_message_processing_seconds` histogram (`_bucket`, `_sum`, `_count`,
emitted only for processors that have a summary) and the
`shibuya_processor_oldest_in_flight_seconds` gauge, emitted only while a processor has
something in flight, since a fabricated zero would break ADR-0007; the JSON `buckets` list
carries the eighteen finite bounds and leaves `+Inf` to the Prometheus text. EP-50 adds no
Prometheus series;
an opaque cursor is not a numeric time series.

**WebSocket delta suppression in `Shibuya.Metrics.WebSocket.sendIfChanged`.** EP-49 makes
the change comparison ignore the derived `ageSeconds` member of `oldestInFlight`, so a
stuck processor does not emit an update every push interval; clients extrapolate age from
the last frame's `ageSeconds` and their own clock. EP-48 restructures the same module around
one outbound queue; whichever lands second rebases, and the projection must survive the
restructure.

**Performance evidence.** Every core child (EP-49, EP-50, EP-51) supplies focused paired
before/after measurements with `scripts/audit/capture-performance-paired.ts` and
`scripts/audit/compare-performance.ts` against `docs/audits/lifecycle-release/performance-budgets.json`,
at least ten alternating pairs under both `-N1` and `-N4`, for the scenarios its Plan of
Work names. EP-49 and EP-50 measure both detail levels. A failed or inconclusive cell is not
accepted by the implementing agent; it is either fixed or escalated to the release owner,
never waived. EP-47, EP-48, and EP-52 are off the message hot path and record only the
wire-load fixture numbers as a sanity check.

**Documentation and records.** The Haddock header of `shibuya-metrics/src/Shibuya/Metrics.hs`
is the published protocol reference; every child that adds a route, member, or frame updates
it. `docs/architecture/METRICS.md` gains a section from EP-49 (latency and in-flight), EP-50
(progress), and EP-51 (pause), and EP-48 adds the WebSocket protocol and conformance mapping
there. `docs/USAGE_GUIDE.md` is only an index; the user guide proper is
`docs/user/getting-started.md`, whose "Monitoring & Metrics" section gains cross-origin
(EP-47), pause and resume (EP-51), and control (EP-52) subsections, and whose metrics
structure description EP-49 and EP-50 extend. The capability bundle `docs/capabilities/` is edited by EP-47
and EP-48 (CAP-10 limits and evidence), EP-49 and EP-50 (CAP-9 and CAP-10 evidence), and
EP-52 (a new capability record allocated with `okf id next docs/capabilities CAP`), each
validating with the bundle's profile and appending to its `log.md`. The three changelogs
(`CHANGELOG.md`, `shibuya-core/CHANGELOG.md`, `shibuya-metrics/CHANGELOG.md`) receive each
child's own lines under an `Unreleased` heading; no child chooses the version.

**Improvement-request closure.** EP-48 closes IR-5, EP-50 closes IR-3, and EP-52 closes
IR-4, in each case after every plan the request spans is Complete. Closure sets `status:
completed`, `completedAt`, and `resolution` in the request's frontmatter, advances its
`timestamp`, appends a dated entry with `okf log add`, and re-validates the bundle with
`okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce`.
The MasterPlan has already linked each request to this plan through its `plan` frontmatter
member and marked it `accepted`.

**Cross-plan decisions recorded as ADRs.** ADR-0007 (created with this MasterPlan) holds the
wire contract and browser posture. EP-49 creates an ADR for hot-path observability
accounting: the slot table, sharded histogram, the detail switch, and the measured default;
EP-50 extends it with the bounded partition table. EP-51 creates an ADR for source-level
pause as operator intent, including halt precedence and resume-before-shutdown. EP-52
creates an ADR for the control gate: refuse by default, structured refusal, no preview step
for reversible operations. EP-48 creates an ADR for the single bounded outbound queue and
marks the sender paragraph of ADR-0004 as superseded in part.


## Progress


Check an item only when the owning child records its acceptance evidence.

- [ ] EP-47 M1: Characterize headerless behavior, add the shared error helper, and retrofit additive error codes.
- [ ] EP-47 M2: Configurable cross-origin policy for HTTP responses and preflight requests.
- [ ] EP-47 M3: Validate the WebSocket upgrade `Origin` header by the same policy.
- [ ] EP-47 M4: Documentation, capability record, changelog, and wire-load sanity numbers.
- [ ] EP-48 M1: Add the `error` frame for invalid client messages and subscription-limit closes.
- [ ] EP-48 M2: One bounded outbound queue per connection with drop-oldest overflow and resync.
- [ ] EP-48 M3: Conformance mapping, documentation, ADR, capability record, and IR-5 closure.
- [ ] EP-49 M1: Prototype detailed accounting behind `MetricsDetail`, measure both levels, and fix the default.
- [ ] EP-49 M2: Expose the latency summary and oldest in-flight detail in JSON, Prometheus, and WebSocket frames.
- [ ] EP-49 M3: Documentation, ADR, changelog, and capability evidence.
- [ ] EP-50 M1: Record acknowledged cursors in a per-processor slot and a bounded partition table, and measure.
- [ ] EP-50 M2: Expose progress in JSON and WebSocket frames, absent when no cursor exists.
- [ ] EP-50 M3: Documentation, ADR extension, changelog, and IR-3 closure.
- [ ] EP-51 M1: Pause handle, ingester gate, `Paused` state, registry control entries, and the design's deterministic tests.
- [ ] EP-51 M2: Public application API, metrics-package updates for the new state, and resume-before-shutdown.
- [ ] EP-51 M3: Performance evidence for the gate, documentation, ADR, and changelog.
- [ ] EP-52 M1: `enableControl` configuration, `GET /control` discovery, and structured refusal when disabled.
- [ ] EP-52 M2: Pause and resume routes with structured outcomes, tested in both gate positions end to end.
- [ ] EP-52 M3: Documentation, capability record, ADR, changelog, and IR-4 closure.


## Surprises & Discoveries


**A browser cannot reach today's server from another origin at all (2026-09-30 UTC,
planning).** `shibuya-metrics/src` contains no `Access-Control-*` handling and no `Origin`
inspection, and CAP-10 records cross-origin access as unsupported. Every read-only feature in
this initiative is therefore invisible to a browser page until EP-47 lands, which is why it
is first in registry order even though nothing hard-depends on it.

**The pause design's gate would hold a leased message (2026-09-30 UTC, planning).**
`docs/plans/PROCESSOR_PAUSE_DESIGN.md` gates with `Stream.mapM`, which runs after the
upstream element has been produced, so one message would be pulled from the adapter and then
held at the gate for the whole pause. EP-51 instead waits before each pull, so a paused
processor requests nothing further from the adapter. The design's other choices stand.

**Per-message timing cannot be free, and the repository has measured that (2026-09-30 UTC,
planning).** EP-39 recorded that two clock reads per message with boxed storage cost 28% on
the serial no-op benchmark and were rejected. A latency distribution needs two clock reads
per message by definition, so EP-49 stores timestamps unboxed in a per-slot byte array,
shards histogram counters to avoid contended atomics, measures both an always-on and a
disabled path, and lets the measurement choose the default rather than assuming either.

**Slow WebSocket consumers cannot overflow anything today, and that is not entirely good
(2026-09-30 UTC, planning).** The push loop sends straight to the socket, so a stalled peer
blocks the push loop on TCP backpressure; memory stays bounded, but `goodbye` and `terminal`
frames are delayed behind the stall, and the receive loop's snapshot replies interleave with
pushes from another thread. EP-48's single outbound queue fixes ordering and delay together
and gives the convention's overflow signal a real meaning.


## Decision Log


- Decision: Treat the three keiro-ui requests as requirements against Shibuya's own surface
  and record Shibuya's own wire contract in ADR-0007 before any child starts.
  Rationale: The project owner asked that nothing tie the surface to keiro so a standalone
  Shibuya page remains possible. Without a shared contract, six children would each choose
  naming, error shapes, and gating independently; ADR-0007 fixes those choices once and each
  child cites it.
  Date: 2026-09-30

- Decision: Keep camelCase member names for additions to existing JSON objects, and record
  this as a documented deviation from the snake_case members the requests asked for.
  Rationale: Every published object on the surface uses camelCase members, including the
  `terminal` frame's `messageId`; a single object that mixes styles is worse for every
  consumer than a consistent surface that differs from an external convention, and the
  convention itself accepts documented deviations for shipped dialects.
  Date: 2026-09-30

- Decision: Add `code` beside the existing string `error` member instead of nesting a new
  error envelope on new routes.
  Rationale: The published error shape is frozen, so a nested envelope would have given the
  surface two error shapes forever. Adding `code` additively makes every error, old and new,
  machine-switchable with one shape.
  Date: 2026-09-30

- Decision: Six children in two waves rather than three request-shaped plans.
  Rationale: Independent verifiability and balanced scope; see Decomposition Strategy. The
  only hard edge is EP-51 to EP-52, which is a genuine compile-time dependency.
  Date: 2026-09-30

- Decision: Put detailed accounting behind a `MetricsDetail` switch on `AppConfig` and let
  EP-49's paired measurement choose the shipped default.
  Rationale: The request forbids hot-path cost, yet a latency distribution needs per-message
  clock reads. A switch whose disabled path is measured within budget satisfies the request
  literally; the default is the level the evidence supports, so the decision is not guessed.
  Date: 2026-09-30

- Decision: Gate control endpoints with a single `enableControl` flag, default off, and
  require no preview step for pause and resume.
  Rationale: The request sets configuration-level gating as the minimum. Pause and resume
  are reversible and non-destructive, so the preview-then-force discipline for destructive
  operations would add ceremony without safety; a future destructive operation must revisit
  this in its own ADR.
  Date: 2026-09-30

- Decision: Replace the direct-send push loop with one bounded outbound queue per connection
  instead of documenting overflow as not applicable.
  Rationale: A queue fixes frame ordering between the receive and push loops, keeps
  `goodbye` and `terminal` delivery from stalling behind a slow peer, and gives the overflow
  signal an honest meaning; the alternative would have left a real ordering race documented
  rather than fixed.
  Date: 2026-09-30

- Decision: Reconcile the drafted children with the coordination text after parallel
  drafting: `runSupervisedWith` and `runSupervisedBatchWith` instead of changed internal
  signatures, the oldest-in-flight gauge emitted only while something is in flight, the
  user guide at `docs/user/getting-started.md` rather than the index file, and ADR numbers
  allocated at implementation time by every child.
  Rationale: EP-49 found that the comparator rejects a changed harness, so the harness's
  direct `runSupervised` calls must keep compiling unchanged; the remaining points are
  corrections of facts the drafts checked against the working tree.
  Date: 2026-09-30

- Decision: Use intention `intention_01m3ta8zgtebmaz00g0snjzy5a`, created through `mina ci`
  at the project owner's request, for this MasterPlan and every child.
  Rationale: Requested by the owner during plan creation. Plan creation authorizes no
  implementation, release, or cross-repository write.
  Date: 2026-09-30


## Outcomes & Retrospective


(To be filled during and after implementation.)
