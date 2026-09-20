---
id: 39
slug: make-metrics-health-and-websocket-lifecycle-reporting-trustworthy
title: "Make metrics health and WebSocket lifecycle reporting trustworthy"
kind: exec-plan
created_at: 2026-09-20T04:05:12Z
intention: "intention_01m2yfmkqxeg9sc0wfmcp4w9fe"
master_plan: "docs/masterplans/6-comprehensive-lifecycle-remediation-and-release-assurance.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-20T04:05:12Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:45:51Z
      verdict: "changes-requested"
      note: "Restamping burst start on zero-to-one still reports a healthy worker under sustained concurrent load stuck after the threshold (Health.hs); needs progress-based detection and a sustained-throughput test."
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:46:05Z
      mode: "update"
      note: "Progress-based stuck detection with sustained-throughput acceptance; core plan becomes a soft dependency with two gated items."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T18:30:00Z
      mode: "implement"
      note: "Begin implementation after EP-38 completed the retained lifecycle snapshot and focused performance acceptance."
---

# Make metrics health and WebSocket lifecycle reporting trustworthy

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Make health endpoints reflect real processor state and ensure disconnected WebSocket clients cannot exhaust connection capacity. Operators must see failures instead of an empty registry being reported healthy.

Give the metrics package the test suite it has never had, and give it first. Today `cabal test shibuya-metrics` reports that there is nothing to run, the package's capability record tells users to treat its endpoints as working but unproven, and no release gate exercises it. This plan changes what the endpoints report, so before it changes anything it pins down what they report now: every published HTTP route, every WebSocket frame, and the exact JSON and Prometheus text. After this plan, a renamed field or a changed status code fails a test that runs on every release, and any change to the wire format is one the implementer chose and wrote down rather than one that slipped through.


## Progress


- [ ] Milestone 1: Characterize the published HTTP and WebSocket contract in a new test suite, before any behavior changes, and add the suite to the release gate.
- [ ] Milestone 2: Repair activity accounting and lifecycle-aware health.
- [ ] Milestone 3: Fix WebSocket ownership, enablement and subscriptions.
- [ ] Milestone 4: Verify endpoint compatibility and accounting together, and retire the package's "unproven" caveat.


## Surprises & Discoveries


2026-09-20: Implementation starts after EP-38 completed, so both soft-gated items are available immediately: lifecycle-aware health and terminal WebSocket notification can consume the retained bounded `LifecycleSnapshot` without a second pause.

2026-09-20: The first real-server characterization run showed that cancelling Warp does not produce the advertised `goodbye` frame; the client remained blocked until the test timeout. Because Milestone 1 must not freeze an audited lifecycle defect as expected behavior, exact `goodbye` encoding/decoding is covered in `TypesSpec` and real delivery is deferred to the failing defect test and fix in Milestone 3.


## Decision Log


2026-09-19: Retain terminal processor identity independently of volatile metrics so removing counters cannot turn failure into readiness.

2026-09-19: Decide "stuck" by absence of progress, not by the age of the current busy period. Rationale: the health check compares the burst start against a 60-second default threshold, and a worker under sustained load with concurrency above one never returns to zero in-flight, so even a correctly restamped burst start ages past the threshold while the worker is healthy. REV-7 and IR-6 item 8 both warn that fixing only the stale timestamp leaves this false-unready path open. The burst start is kept for display.

2026-09-20: Write the contract tests first, against today's behavior, and adopt the test-suite item of IR-5 into this plan. Rationale: Milestones 2 and 3 add processor states and possibly a last-progress field, and Milestone 4 forbids incidental schema changes, but without a recorded baseline there is nothing to detect an incidental change against. IR-5, docs/improvement-requests/harden-shibuya-metrics-for-browser-clients-cors-tests-and-ws-convention-alignment.md, asks for three things; the draft of this plan excluded all of it to keep cross-origin support out, which also threw away its second item, a test suite covering every route and frame, even though that item needs no new feature and is exactly the weakness a major release should close. Its first and third items, configurable CORS and WebSocket convention alignment, are new features for a browser client and stay out.

2026-09-20: Keep the suite green at every commit by separating two kinds of test. A characterization test asserts what the package does today and is expected to stay green; it must never assert a behavior the audit identified as a defect, or the fix would have to break a passing test. A defect test asserts the corrected behavior; it is observed failing in an isolated worktree or by mutation, and is committed together with its fix in Milestone 2 or 3. Rationale: this plan also adds the suite to the release gate, and part of its work waits on another plan, so a test committed red would block every release in between, including urgent patches like the two the project has just shipped.

2026-09-20: Export `combinedApp` from Shibuya.Metrics.Server. Rationale: the routing that honors the three enable flags and produces the not-found responses lives there, so testing it through a copy of the routing would prove nothing, and `startMetricsServer` binds the fixed configured port and reports that same number back, so a test cannot ask it for a free port. Warp's `testWithApplication` takes a WAI application and binds a free port itself. The export is additive, is also what a user needs to mount the endpoints inside an existing server, and is recorded in the changelog.

2026-09-20: Add `cabal test shibuya-metrics` to the release gate in this plan. Rationale: the repository has no continuous integration and `nix flake check` checks formatting only, so the release skill's test step is the only place a suite runs routinely; without it the new suite would run once during certification and never again. The two garbage-collection fixes each added their suite to the same step. Only that step is edited here; the benchmark policy in the following step belongs to docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md.

2026-09-19: Start before the core lifecycle plan completes. Only lifecycle-aware readiness and terminal WebSocket notifications need its retained snapshot; the test suite, activity accounting and WebSocket slot ownership do not, and the activity defect is high priority.


## Outcomes & Retrospective


To be filled during implementation. No remediation or certification is claimed by creation of this plan.


## Context and Orientation


shibuya-core/src/Shibuya/Core/Metrics.hs owns activity counters and burst timing. shibuya-metrics/src/Shibuya/Metrics/Health.hs, WebSocket.hs, Server.hs, JSON.hs, Prometheus.hs, Types.hs and Config.hs expose them. In-flight means handed to a handler and not yet finished; a burst is a period during which the in-flight count is above zero. In Core/Metrics.hs `beginProcessing` stamps `burstStartedRef` only when the in-flight count reaches one and `stateActiveRef` is False, and ordinary `finishProcessing` never clears that flag, so every burst after the first inherits the first burst's timestamp. In Health.hs a processor is counted stuck when its sampled state is `Processing` and that timestamp is older than `stuckThreshold`, 60 seconds by default. REV-7 reproduces a stale active/burst marker making a second short burst appear stuck. REV-8 reproduces failed processors disappearing and readiness returning true, and master liveness remaining true after shutdown. REV-9 identifies connection-slot leaks, ignored enableWebSocket, and ambiguous all-subscription unsubscribe behavior. scripts/audit/HealthProbe.hs captures observations. Add a real test suite to shibuya-metrics/shibuya-metrics.cabal; cabal test currently cannot verify this package.

The published surface that Milestone 1 pins down is small and was read from source on 2026-09-20. `httpApp` in Server.hs routes `/metrics/prometheus` when `enablePrometheus` is set, and `/metrics`, `/metrics/<processorId>`, `/health`, `/health/live` and `/health/ready` when `enableJSON` is set; a disabled or unknown path gets status 404 with a JSON body of the form `{"error": ...}`, and a plain HTTP request to `/ws` gets a 404 explaining that the path is a WebSocket endpoint. JSON.hs answers an unknown processor with 404 and answers the three health routes with 200 or 503 according to liveness and readiness. Prometheus.hs serves `text/plain; version=0.0.4; charset=utf-8` with five series: `shibuya_messages_received_total`, `shibuya_messages_processed_total`, `shibuya_messages_failed_total`, `shibuya_processor_state` and `shibuya_processor_in_flight`. Types.hs defines the WebSocket frames, each a JSON object tagged by a `type` field: a client sends `subscribe_all`, `subscribe` or `unsubscribe` (the last two with a `processors` list) or `ping`; the server sends `snapshot` with a `metrics` map, `update` with `processor` and `metrics`, `pong`, and `goodbye`. WebSocket.hs sends a snapshot on connection, pushes an `update` only for a processor whose sampled metrics changed since the last push, and rejects a connection beyond `wsMaxConnections` with the reason "Too many connections". The metric values themselves are encoded by instances in shibuya-core/src/Shibuya/Core/Metrics.hs: `ProcessorMetrics` has the fields `state`, `stats`, `batch` and `startedAt`, and `ProcessorState` is an object whose `status` is `idle`, `processing`, `failed` or `stopped`, with `inFlight`, `maxConcurrency` and `lastActivity` when processing and `error` and `timestamp` when failed.

Two facts shape the test harness. `combinedApp`, which joins the HTTP routing to the WebSocket upgrade, is not exported, and `startMetricsServer` listens on the fixed `port` from its configuration and returns that same number, so it cannot be asked for a free port. A characterization test is one that records what the code does today so that a later change is noticed; a golden fixture is a checked-in file holding the exact expected output that such a test compares against. The capability record docs/capabilities/metrics-endpoints.md currently warns that the package has no test suite and that its endpoints are working but unproven. The release skill agents/skills/release/SKILL.md runs `cabal test shibuya-core` in its step 4 and nothing for this package, and `CLAUDE.md` lists the same command.

The baseline is the committed source audit in docs/lifecycle-audit-progress.md and docs/reviews/, not a completed fault-injection campaign. Source inspection, diagnostic reproduction, fixed code, and release verification are separate evidence levels. A finalizer is the adapter operation that acknowledges, retries, or dead-letters a handled delivery. At-least-once delivery allows replay after interruption; it does not permit silently skipping unresolved work. A timeout in a test is a failure bound, not evidence that production cleanup succeeded.

When this plan was drafted no local docs/adr corpus existed; the repository's first record, docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md, was added on 2026-09-20. It concerns linked threads and garbage-collection liveness tests; its rule that a test must be seen to fail before it is trusted applies to the defect tests here. The corpus is plain Markdown with no OKF profile. Before introducing durable interfaces, follow .agents/skills/exec-plan/ADR.md and record the decision using the then-current repository convention. Locate dependency sources with Mori before choosing APIs. Verify registry releases and upstream tags before changing dependency bounds. Registration-service-v2 is excluded.


## Plan of Work


Milestone 1 builds the suite and uses it to record today's contract; it changes no behavior. Add an Hspec test-suite stanza named `shibuya-metrics-test` to shibuya-metrics/shibuya-metrics.cabal with a hand-written shibuya-metrics/test/Main.hs that lists its spec modules, as shibuya-core/test/Main.hs does. Follow the core stanza's convention for bounds: none on packages the library already bounds, and a caret bound on test-only packages, which are expected to be `hspec`, `wai-extra` for in-process requests through `Network.Wai.Test`, and the already-present `warp` and `websockets` for a real listening server and client. Confirm the current released version of each new package on Hackage before writing its bound. Export `combinedApp` from Shibuya.Metrics.Server and build the harness on it: route tests run the application in-process, and WebSocket tests start it with Warp's `testWithApplication`, which binds a free port, and connect a real client. Add the controllable clock or direct timestamp fixture that Milestone 2 needs.

Write four groups of characterization tests under shibuya-metrics/test/Shibuya/Metrics/. ServerSpec.hs covers every route listed in Context and Orientation: status code, content type and body shape for each, the 404 for an unknown path and for an unknown processor, each route answering 404 when its enable flag is off, and the 503 path of each health route when readiness or liveness is false. JSONSpec.hs and PrometheusSpec.hs compare encoded output against golden fixtures under shibuya-metrics/test/golden/, built from hand-constructed `ProcessorMetrics` values with fixed timestamps, one per processor state, so that the comparison is exact and independent of the clock; a live registry is only compared structurally. TypesSpec.hs checks that every client and server frame encodes to its documented tag and fields, decodes back to the same value, and that an unknown tag is rejected. WebSocketSpec.hs covers the protocol against a real connection: the snapshot on connect, `subscribe_all` and a filtered `subscribe` each answered by a snapshot, `ping` answered by `pong`, an `update` arriving after a processor's metrics change and none arriving when nothing changed, the rejection beyond the connection limit, and `goodbye` on server shutdown. HealthSpec.hs covers liveness and readiness for a running application, a failed processor that is still registered, and a failing dependency check.

Do not characterize a behavior the audit calls a defect, because its fix would then have to break a passing test. Leave these out of Milestone 1 entirely and test them where they are fixed: readiness of an application whose configured processor has unregistered, liveness after the master is stopped, the stuck decision for a second or a sustained burst, connection-slot accounting on a failed handshake, snapshot or goodbye, an upgrade request while `enableWebSocket` is off, `unsubscribe` while subscribed to everything, and what a client sees when a processor disappears.

Prove the fixtures can fail. In an isolated worktree, rename one JSON field in an encoder and one Prometheus series, run the suite, and record in this plan that the golden tests fail and name the field; do not commit the mutation. Then add the suite to the routine gate: in step 4 of agents/skills/release/SKILL.md add `cabal test shibuya-metrics` beside the core command and say what it guards, and add the same command to the Commands block of `CLAUDE.md`. Add a changelog entry for the exported `combinedApp` and for the new suite. Acceptance is `cabal test shibuya-metrics` exiting zero with a nonzero example count that covers every route and every frame type, the recorded mutation failure, and the suite named in the release gate.

Milestones 2 and 3 fix defects, and each defect follows the same discipline. Write the test that asserts the corrected behavior, observe it fail against the unfixed code in an isolated worktree or by mutation and record that evidence, then commit the test together with its fix so that the suite is green at every commit and the release gate never blocks. If a fix changes any output that a Milestone 1 golden fixture records, update the fixture in the same commit, state in the commit message and in this plan's Decision Log that the wire change is deliberate, and add it to the changelog as a breaking or additive change; a golden test that fails without such a decision is a bug in the fix.

Milestone 2 closes two separate defects in activity accounting; fixing only the first leaves healthy workers reported unready. The first is the stale flag: make active state follow actual in-flight work by clearing it on the last completion and restamping the burst start on each zero-to-one transition, handling overlapping completions, errors and cancellation without negative counts. The second is the stuck rule itself. Even with a correct burst start, a worker under sustained load with concurrency above one never drops to zero in-flight, so its burst start ages past the threshold while it is perfectly healthy. Decide stuck by absence of progress instead: a processor is stuck when it has in-flight work and no handler has started or finished for longer than the threshold. Record progress as an allocation-free monotonic stamp, `GHC.Clock.getMonotonicTimeNSec`, written on each begin and finish, have the sampler expose the last-progress time, and keep the burst start for display only. This adds a clock read per begin and finish on the hottest path in the library, so measure it with the performance plan's harness before accepting it; if it exceeds budget, fall back to sampler-side detection, in which the health checker remembers each processor's completed count between probes and the hot path is untouched, and record which was chosen and why. Document one known limit rather than solving it here: a single wedged handler among others that keep progressing is not detected, and per-message age belongs to docs/improvement-requests/expose-processor-progress-latency-and-in-flight-detail-for-inspection-uis.md. Test three scenarios with the controllable clock: separated short bursts, sustained throughput longer than the threshold during which in-flight never reaches zero, and a genuinely stuck handler. Exposing a last-progress time changes the `processing` state's JSON, which today carries `lastActivity`; decide whether the new value replaces that field's meaning or is added beside it, prefer the additive choice, and update the golden fixtures deliberately.

The rest of Milestone 2 is gated on Milestone 4 of docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md, which publishes the retained terminal lifecycle snapshot; do the accounting work above first and return to this part when that snapshot exists. In Health.hs consume the retained lifecycle snapshot owned by the core plan; an unexpectedly failed configured worker is unready even after live metrics unregister. Explicitly distinguish configured-empty, starting, running, draining, stopped and failed applications. Preserve intended idle-worker readiness. Bound dependency checks through an explicit timeout policy with tests so one hung check cannot hang readiness indefinitely; document any configuration compatibility impact.

Milestone 3 brackets WebSocket slot ownership from acquisition through acceptance, snapshot generation, sender/receiver lifetime and release. Release the slot even if goodbye or cleanup sends throw. Enforce enableWebSocket before upgrading in Server.hs. Define and test subscribe-all followed by selective unsubscribe using an explicit representation; either support exclusions or return a documented unsupported operation, never silently acknowledge a no-op. Test processor removal/terminal notifications using retained lifecycle data and avoid unbounded terminal history; this one item is gated on the core plan's Milestone 4 snapshot, while slot ownership, enablement and subscription semantics are not. Keep CORS/browser expansion from the separate IR-5 out of this change except where needed for existing documented behavior.

Milestone 4 runs endpoint-level tests alongside core accounting tests. Check JSON and Prometheus against the same state; any additive status fields or breaking changes require documented compatibility decisions and changelogs, not an incidental schema change. Compare the golden fixtures as they now stand with their Milestone 1 versions using `git diff` on shibuya-metrics/test/golden/, and confirm that every difference corresponds to a recorded decision and a changelog entry. Capture before/after observations and ensure no change reintroduces either garbage-collection failure, by running all three core suites.

Milestone 4 also retires the caveat the new suite makes untrue. Rewrite the limitation in docs/capabilities/metrics-endpoints.md that says the package has no test suite and that its endpoints are working but unproven, naming the suite and what it covers and keeping any limit that remains true, such as the absence of cross-origin support. That record belongs to an OKF bundle, so follow its profile and update the bundle's log as the existing records do. In IR-5, note that its test-suite item has been delivered by this plan and that its cross-origin and convention-alignment items remain open, without changing the request's scope or closing it.

Before closing this plan, supply focused before/after performance evidence for its changed paths using docs/plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md. Baseline capture is an early coordination requirement, not a reason to defer all measurement until release. Correctness and performance must both pass; the performance plan owns budgets and harnesses.


## Concrete Steps


Run local commands from the Shibuya repository root unless the command block explicitly directs a change to a Mori-resolved project. New validator and comparator commands become available when their owning milestones implement them. Use the repository development shell if the compiler or services are missing; an unavailable dependency in offline mode requires an approved fetch, not removal of the test.

```bash
cabal test shibuya-core --test-show-details=failures
cabal test shibuya-metrics --test-show-details=direct
git diff <milestone-1-commit> -- shibuya-metrics/test/golden/
```

The metrics package depends on `warp`, which the offline package store on the planning machine did not contain, so `--offline` fails for this package there; run these without it, or fetch once first. The core command runs three suites, including the two process-isolated garbage-collection suites.

Successful suites exit zero and report executed tests; zero tests or skipped services are not acceptance. Record exact selectors and fixture commands in this section when the harness is extended.


## Validation and Acceptance


`cabal test shibuya-metrics` runs a nonzero number of examples covering every published route, including each 404 and 503 path and each enable flag, and every WebSocket frame type, and it is part of the release gate. Renaming a JSON field or a Prometheus series makes a golden test fail. Every difference between the final golden fixtures and their Milestone 1 versions is backed by a recorded decision and a changelog entry. The capability record no longer calls the endpoints unproven.

A failed configured worker remains visibly failed and unready; stopped master is not alive; intentionally empty and idle-running applications follow documented policy. A second short burst is not marked stuck because of the first. A worker processing continuously for longer than the stuck threshold, with in-flight work never reaching zero, stays ready, and a handler that makes no progress for longer than the threshold is reported stuck. In-flight counters return to zero after all terminal paths. Failed accepts and abrupt disconnects restore slot capacity, including when goodbye fails. Disabled WebSockets never return an upgrade response. Tests exercise actual local HTTP/WebSocket requests, not only record construction.

Use STM barriers or injected hooks to control interleavings; sleeps alone do not prove ordering. Assert terminal outcomes and resource ownership, not just logs. For every reproduced defect, record a failing regression against the affected implementation and a passing run against the fix; use an isolated worktree or mutation, never overwrite the working tree. Keep source-only suspicions labeled unconfirmed until reproduced or disproved. Record exact source SHAs, dependency solution, compiler, commands, random seeds, and logs in the EP-37 evidence format. Passing tests with a skipped service-dependent suite do not count as integration evidence.


## Idempotence and Recovery


Work on the current branch, preserve unrelated edits, and commit small conventional changes with MasterPlan, ExecPlan, and Intention trailers from this plan's frontmatter. Repeating unit tests and validation is safe. Use uniquely named ephemeral broker/database resources, never production endpoints or shared database reset commands. Bracket fixture cleanup and retain failed-run logs before deleting only identified fixture resources. Revert an identified implementation commit only with authorization; do not reset the checkout. Missing services or unavailable dependencies remain explicit blockers, not passes.


## Interfaces and Dependencies


Hard dependency: docs/plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md. Soft dependency: docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md. This plan may start as soon as the evidence plan is complete. Milestone 1, the activity-accounting half of Milestone 2 and the slot, enablement and subscription work of Milestone 3 need nothing from the core plan. Lifecycle-aware readiness in Milestone 2 and terminal notifications in Milestone 3 need the core plan's Milestone 4 snapshot, and this plan cannot be marked Complete until they have been implemented and tested against it. This plan owns Core/Metrics.hs and the metrics package, including its new test suite; the core plan calls into Core/Metrics.hs from the runner and asks this plan for any new hook instead of changing the accounting model itself. Both plans append to the changelogs: add only this plan's entries under the unreleased heading, mark breaking ones such as a changed `ProcessorState` or JSON field, and do not choose the version. It consumes, not redefines, core terminal lifecycle state. IR-1's full public worker-probe design is not a prerequisite; implement the minimal internal lifecycle contract and record any public changes explicitly. From IR-5 this plan adopts only the test-suite item; its configurable cross-origin support and its WebSocket convention alignment are new features and remain outside this plan and outside the parent MasterPlan.

New interfaces at the end of Milestone 1: the test suite `shibuya-metrics-test`, and `combinedApp :: MetricsServerConfig -> Master -> WebSocketState -> [DependencyCheck] -> Application` exported from `Shibuya.Metrics.Server` with its existing type. New test-only dependencies are expected to be `hspec` and `wai-extra`; verify their current releases on Hackage before bounding them. This plan edits step 4 of agents/skills/release/SKILL.md, the test gate, which the two garbage-collection fixes also edited; step 5, the benchmark policy, belongs to docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md and is not touched here. docs/plans/44-certify-the-integrated-lifecycle-release-candidate.md runs this suite on the candidate.


## Revision Notes


2026-09-20 UTC: Revised after a pre-implementation review of the parent MasterPlan against docs/reviews, IR-6 and the working tree. The drafted Milestone 2 prescribed only restamping the burst start on a zero-to-one transition; checked against Health.hs, that leaves a healthy worker under sustained concurrent load reported stuck after the threshold, which REV-7 and IR-6 item 8 explicitly warn about, so the milestone now bases stuck detection on absence of progress, names the hot-path cost and its fallback, and adds sustained-throughput and genuinely-stuck acceptance. The core lifecycle plan changed from a hard to a soft dependency with two named gated items, because most of this plan, including a high-priority defect, needs nothing from it. Added Prometheus.hs to the module list, defined in-flight and burst, and recorded changelog ownership shared with the core plan.

2026-09-20 UTC: Widened Milestone 1 at the project owner's request, after the question of whether the initiative would fix the package's missing test suite. As drafted, Milestone 1 built a suite only to reproduce the three audited defects, which would have left the routes, the frames and the JSON and Prometheus encoders unproven, given Milestone 4's ban on incidental schema changes no baseline to enforce it against, and left the suite outside every routine gate. Milestone 1 now characterizes the whole published contract first, adopting the test-suite item of IR-5 while leaving its cross-origin and convention items out; defect tests moved into the milestones that fix them so the suite stays green; and the plan now exports `combinedApp`, adds the suite to the release gate, and retires the capability record's "unproven" caveat. The harness description was corrected against source: `combinedApp` was not exported and the server cannot bind a free port, so the drafted ephemeral-port fixture was not achievable as written. Also noted the repository's first ADR, which the earlier revision of this plan predated.
