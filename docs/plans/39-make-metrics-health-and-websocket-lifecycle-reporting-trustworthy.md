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
---

# Make metrics health and WebSocket lifecycle reporting trustworthy

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Make health endpoints reflect real processor state and ensure disconnected WebSocket clients cannot exhaust connection capacity. Operators must see failures instead of an empty registry being reported healthy.


## Progress


- [ ] Milestone 1: Add an executable metrics and endpoint test suite.
- [ ] Milestone 2: Repair activity accounting and lifecycle-aware health.
- [ ] Milestone 3: Fix WebSocket ownership, enablement and subscriptions.
- [ ] Milestone 4: Verify endpoint compatibility and accounting together.


## Surprises & Discoveries


None yet; implementation has not started.


## Decision Log


2026-09-19: Retain terminal processor identity independently of volatile metrics so removing counters cannot turn failure into readiness.

2026-09-19: Decide "stuck" by absence of progress, not by the age of the current busy period. Rationale: the health check compares the burst start against a 60-second default threshold, and a worker under sustained load with concurrency above one never returns to zero in-flight, so even a correctly restamped burst start ages past the threshold while the worker is healthy. REV-7 and IR-6 item 8 both warn that fixing only the stale timestamp leaves this false-unready path open. The burst start is kept for display.

2026-09-19: Start before the core lifecycle plan completes. Only lifecycle-aware readiness and terminal WebSocket notifications need its retained snapshot; the test suite, activity accounting and WebSocket slot ownership do not, and the activity defect is high priority.


## Outcomes & Retrospective


To be filled during implementation. No remediation or certification is claimed by creation of this plan.


## Context and Orientation


shibuya-core/src/Shibuya/Core/Metrics.hs owns activity counters and burst timing. shibuya-metrics/src/Shibuya/Metrics/Health.hs, WebSocket.hs, Server.hs, JSON.hs, Prometheus.hs, Types.hs and Config.hs expose them. In-flight means handed to a handler and not yet finished; a burst is a period during which the in-flight count is above zero. In Core/Metrics.hs `beginProcessing` stamps `burstStartedRef` only when the in-flight count reaches one and `stateActiveRef` is False, and ordinary `finishProcessing` never clears that flag, so every burst after the first inherits the first burst's timestamp. In Health.hs a processor is counted stuck when its sampled state is `Processing` and that timestamp is older than `stuckThreshold`, 60 seconds by default. REV-7 reproduces a stale active/burst marker making a second short burst appear stuck. REV-8 reproduces failed processors disappearing and readiness returning true, and master liveness remaining true after shutdown. REV-9 identifies connection-slot leaks, ignored enableWebSocket, and ambiguous all-subscription unsubscribe behavior. scripts/audit/HealthProbe.hs captures observations. Add a real test suite to shibuya-metrics/shibuya-metrics.cabal; cabal test currently cannot verify this package.

The baseline is the committed source audit in docs/lifecycle-audit-progress.md and docs/reviews/, not a completed fault-injection campaign. Source inspection, diagnostic reproduction, fixed code, and release verification are separate evidence levels. A finalizer is the adapter operation that acknowledges, retries, or dead-letters a handled delivery. At-least-once delivery allows replay after interruption; it does not permit silently skipping unresolved work. A timeout in a test is a failure bound, not evidence that production cleanup succeeded.

No local docs/adr corpus existed when this plan was drafted. Before introducing durable interfaces, follow .agents/skills/exec-plan/ADR.md and record the decision using the then-current repository convention. Locate dependency sources with Mori before choosing APIs. Verify registry releases and upstream tags before changing dependency bounds. Registration-service-v2 is excluded.


## Plan of Work


Milestone 1 adds shibuya-metrics/test/Main.hs and Shibuya/Metrics/HealthSpec.hs, WebSocketSpec.hs, ServerSpec.hs beneath that test directory, with an Hspec test-suite stanza. Add a controllable clock or direct timestamp fixture for activity windows and a local WAI/WebSocket server fixture bound to an ephemeral port. Reproduce failed-worker disappearance, stopped-master liveness, idle-to-busy timing, acceptance failure, disconnect during goodbye, and disabled upgrades. Verify the new suite runs nonzero test counts.

Milestone 2 closes two separate defects in activity accounting; fixing only the first leaves healthy workers reported unready. The first is the stale flag: make active state follow actual in-flight work by clearing it on the last completion and restamping the burst start on each zero-to-one transition, handling overlapping completions, errors and cancellation without negative counts. The second is the stuck rule itself. Even with a correct burst start, a worker under sustained load with concurrency above one never drops to zero in-flight, so its burst start ages past the threshold while it is perfectly healthy. Decide stuck by absence of progress instead: a processor is stuck when it has in-flight work and no handler has started or finished for longer than the threshold. Record progress as an allocation-free monotonic stamp, `GHC.Clock.getMonotonicTimeNSec`, written on each begin and finish, have the sampler expose the last-progress time, and keep the burst start for display only. This adds a clock read per begin and finish on the hottest path in the library, so measure it with the performance plan's harness before accepting it; if it exceeds budget, fall back to sampler-side detection, in which the health checker remembers each processor's completed count between probes and the hot path is untouched, and record which was chosen and why. Document one known limit rather than solving it here: a single wedged handler among others that keep progressing is not detected, and per-message age belongs to docs/improvement-requests/expose-processor-progress-latency-and-in-flight-detail-for-inspection-uis.md. Test three scenarios with the controllable clock: separated short bursts, sustained throughput longer than the threshold during which in-flight never reaches zero, and a genuinely stuck handler.

The rest of Milestone 2 is gated on Milestone 4 of docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md, which publishes the retained terminal lifecycle snapshot; do the accounting work above first and return to this part when that snapshot exists. In Health.hs consume the retained lifecycle snapshot owned by the core plan; an unexpectedly failed configured worker is unready even after live metrics unregister. Explicitly distinguish configured-empty, starting, running, draining, stopped and failed applications. Preserve intended idle-worker readiness. Bound dependency checks through an explicit timeout policy with tests so one hung check cannot hang readiness indefinitely; document any configuration compatibility impact.

Milestone 3 brackets WebSocket slot ownership from acquisition through acceptance, snapshot generation, sender/receiver lifetime and release. Release the slot even if goodbye or cleanup sends throw. Enforce enableWebSocket before upgrading in Server.hs. Define and test subscribe-all followed by selective unsubscribe using an explicit representation; either support exclusions or return a documented unsupported operation, never silently acknowledge a no-op. Test processor removal/terminal notifications using retained lifecycle data and avoid unbounded terminal history; this one item is gated on the core plan's Milestone 4 snapshot, while slot ownership, enablement and subscription semantics are not. Keep CORS/browser expansion from the separate IR-5 out of this change except where needed for existing documented behavior.

Milestone 4 runs endpoint-level tests alongside core accounting tests. Check JSON and Prometheus against the same state; any additive status fields or breaking changes require documented compatibility decisions and changelogs, not an incidental schema change. Capture before/after observations and ensure no change reintroduces the bare-waitApp GC failure.

Before closing this plan, supply focused before/after performance evidence for its changed paths using docs/plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md. Baseline capture is an early coordination requirement, not a reason to defer all measurement until release. Correctness and performance must both pass; the performance plan owns budgets and harnesses.


## Concrete Steps


Run local commands from the Shibuya repository root unless the command block explicitly directs a change to a Mori-resolved project. New validator and comparator commands become available when their owning milestones implement them. Use the repository development shell if the compiler or services are missing; an unavailable dependency in offline mode requires an approved fetch, not removal of the test.

```bash
cabal test shibuya-core --offline --test-show-details=failures
cabal test shibuya-metrics --offline --test-show-details=direct
```

Successful suites exit zero and report executed tests; zero tests or skipped services are not acceptance. Record exact selectors and fixture commands in this section when the harness is extended.


## Validation and Acceptance


A failed configured worker remains visibly failed and unready; stopped master is not alive; intentionally empty and idle-running applications follow documented policy. A second short burst is not marked stuck because of the first. A worker processing continuously for longer than the stuck threshold, with in-flight work never reaching zero, stays ready, and a handler that makes no progress for longer than the threshold is reported stuck. In-flight counters return to zero after all terminal paths. Failed accepts and abrupt disconnects restore slot capacity, including when goodbye fails. Disabled WebSockets never return an upgrade response. Tests exercise actual local HTTP/WebSocket requests, not only record construction.

Use STM barriers or injected hooks to control interleavings; sleeps alone do not prove ordering. Assert terminal outcomes and resource ownership, not just logs. For every reproduced defect, record a failing regression against the affected implementation and a passing run against the fix; use an isolated worktree or mutation, never overwrite the working tree. Keep source-only suspicions labeled unconfirmed until reproduced or disproved. Record exact source SHAs, dependency solution, compiler, commands, random seeds, and logs in the EP-37 evidence format. Passing tests with a skipped service-dependent suite do not count as integration evidence.


## Idempotence and Recovery


Work on the current branch, preserve unrelated edits, and commit small conventional changes with MasterPlan, ExecPlan, and Intention trailers from this plan's frontmatter. Repeating unit tests and validation is safe. Use uniquely named ephemeral broker/database resources, never production endpoints or shared database reset commands. Bracket fixture cleanup and retain failed-run logs before deleting only identified fixture resources. Revert an identified implementation commit only with authorization; do not reset the checkout. Missing services or unavailable dependencies remain explicit blockers, not passes.


## Interfaces and Dependencies


Hard dependency: docs/plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md. Soft dependency: docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md. This plan may start as soon as the evidence plan is complete. Milestone 1, the activity-accounting half of Milestone 2 and the slot, enablement and subscription work of Milestone 3 need nothing from the core plan. Lifecycle-aware readiness in Milestone 2 and terminal notifications in Milestone 3 need the core plan's Milestone 4 snapshot, and this plan cannot be marked Complete until they have been implemented and tested against it. This plan owns Core/Metrics.hs and the metrics package, including its new test suite; the core plan calls into Core/Metrics.hs from the runner and asks this plan for any new hook instead of changing the accounting model itself. Both plans append to the changelogs: add only this plan's entries under the unreleased heading, mark breaking ones such as a changed `ProcessorState` or JSON field, and do not choose the version. It consumes, not redefines, core terminal lifecycle state. IR-1's full public worker-probe design and IR-5's broader browser work are not prerequisites; implement the minimal internal lifecycle contract and record any public changes explicitly.


## Revision Notes


2026-09-20 UTC: Revised after a pre-implementation review of the parent MasterPlan against docs/reviews, IR-6 and the working tree. The drafted Milestone 2 prescribed only restamping the burst start on a zero-to-one transition; checked against Health.hs, that leaves a healthy worker under sustained concurrent load reported stuck after the threshold, which REV-7 and IR-6 item 8 explicitly warn about, so the milestone now bases stuck detection on absence of progress, names the hot-path cost and its fallback, and adds sustained-throughput and genuinely-stuck acceptance. The core lifecycle plan changed from a hard to a soft dependency with two named gated items, because most of this plan, including a high-priority defect, needs nothing from it. Added Prometheus.hs to the module list, defined in-flight and burst, and recorded changelog ownership shared with the core plan.
