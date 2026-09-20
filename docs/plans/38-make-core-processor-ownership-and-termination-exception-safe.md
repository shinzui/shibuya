---
id: 38
slug: make-core-processor-ownership-and-termination-exception-safe
title: "Make core processor ownership and termination exception safe"
kind: exec-plan
created_at: 2026-09-20T04:05:12Z
intention: "intention_01m2yfmkqxeg9sc0wfmcp4w9fe"
master_plan: "docs/masterplans/6-comprehensive-lifecycle-remediation-and-release-assurance.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-20T04:05:12Z
---

# Make core processor ownership and termination exception safe

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Make application startup, failure, halt, and shutdown predictable: no registered worker is lost, no empty-inbox halt hangs, and infrastructure failure cannot masquerade as successful completion.


## Progress


- [ ] Milestone 1: Add deterministic regressions for ownership, halt, failures and policies.
- [ ] Milestone 2: Fix exception-safe resource acquisition and cleanup.
- [ ] Milestone 3: Make stop/failure wakeups and scheduler ownership reliable.
- [ ] Milestone 4: Validate capacities and verify all core/GC regressions.


## Surprises & Discoveries


None yet; implementation has not started.


## Decision Log


2026-09-19: Treat infrastructure finalization failure as failure, not graceful Halt; preserve existing deliberate user halt and supported delivery semantics.


## Outcomes & Retrospective


To be filled during implementation. No remediation or certification is claimed by creation of this plan.


## Context and Orientation


Primary modules are shibuya-core/src/Shibuya/App.hs, Internal/App.hs, Internal/Runner/Supervised.hs, Internal/Runner/Halt.hs, Internal/Runner/Finalize.hs, Internal/Runner/KeyedScheduler.hs, Internal/Runner/Batcher.hs, and Policy.hs under the same Shibuya source root. Tests live in shibuya-core/test/Shibuya/App/LifecycleSpec.hs, Runner/SupervisedSpec.hs, Runner/PartitionOrderingSpec.hs, PolicySpec.hs, and Batch/ReliabilitySpec.hs. REV-3 documents cleanup short-circuiting, startup cancellation gaps, and duplicate processor IDs. REV-4 reproduces unwakeable halt and finalizer exhaustion reported as success; REV-5 records delayed keyed failure; REV-6 reproduces zero/negative concurrency invoking Streamly defaults/unbounded concurrency. REV-15 records batching residual risks. The master GC fix already has shibuya-core/test-gc/Main.hs and must remain intact.

The baseline is the committed source audit in docs/lifecycle-audit-progress.md and docs/reviews/, not a completed fault-injection campaign. Source inspection, diagnostic reproduction, fixed code, and release verification are separate evidence levels. A finalizer is the adapter operation that acknowledges, retries, or dead-letters a handled delivery. At-least-once delivery allows replay after interruption; it does not permit silently skipping unresolved work. A timeout in a test is a failure bound, not evidence that production cleanup succeeded.

No local docs/adr corpus existed when this plan was drafted. Before introducing durable interfaces, follow .agents/skills/exec-plan/ADR.md and record the decision using the then-current repository convention. Locate dependency sources with Mori before choosing APIs. Verify registry releases and upstream tags before changing dependency bounds. Registration-service-v2 is excluded.


## Plan of Work


Milestone 1 converts scripts/audit/LifecycleProbe.hs scenarios into assertions in existing Hspec suites. Add explicit barriers around acquisition/registration, empty inbox waits, finalizer retry exhaustion, and keyed worker failure with a still-live input stream. Add duplicate-ID and invalid-policy tests. Observe failures on the audit baseline before fixes. For batch halt, exercise timeout-flush, size-flush, and partial final batches; check each acquired finalizer has one terminal invocation according to its retry contract.

Milestone 2 fixes lifetime ownership in App.hs and Internal/App.hs. Reject duplicate IDs and invalid concurrency before launching any worker or acquiring adapter resources. Use exception-safe acquisition with masking only around ownership transfer; restore interruptibility during blocking operations and handlers. Record each acquired resource before cancellation can lose it. Cleanup must attempt every adapter shutdown and stop the master even when an earlier shutdown fails, then surface the failure without replacing the original startup failure silently. Test synchronous and asynchronous exceptions at every transfer boundary, repeated stop, and concurrent wait/stop. Never use uninterruptible masking for arbitrary user or adapter I/O.

Milestone 3 makes stop and failure observable in Supervised.hs, Halt.hs, Finalize.hs and KeyedScheduler.hs. Replace the separate IORef-only halt observation around inbox waits with a stop signal that participates in the blocking STM decision, so halt wakes every strategy and batch mode. Keep deliberate user Halt distinct from exhausted/fatal infrastructure finalization failure; the latter must reach waitApp and the configured supervision policy. On first keyed worker failure, stop accepting input, wake blocked scheduler branches, terminate owned workers, and propagate the original failure without waiting for infinite upstream exhaustion. Close the spawn/register ownership gap, including workers waiting at a start gate. Preserve per-key ordering and documented graceful drain semantics. Test StopAllOnFailure and IgnoreFailures separately; ignoring a failed worker is not reporting that worker successful.

Milestone 4 validates positive Async/Ahead concurrency and checked arithmetic before calculating buffer sizes; reject values whose derived capacity overflows rather than silently wrapping or clamping. Retain serial semantics and existing accepted positive values. Re-audit ingester, batch consumer/ticker ownership, full queues, cancel during lease/finalizer operations, and timer failures; convert any reachable new defect into a failing regression and fix it within this ownership scope. Publish an internal terminal lifecycle snapshot (running, draining, stopped, failed with retained processor identity) for metrics to consume without depending on the existence of a mutable metrics entry. Define concrete internal types after inspecting current APIs; do not add a public API accidentally. Run all core tests, GC suite, and schedule repetitions.

Before closing this plan, supply focused before/after performance evidence for its changed paths using docs/plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md. Baseline capture is an early coordination requirement, not a reason to defer all measurement until release. Correctness and performance must both pass; the performance plan owns budgets and harnesses.


## Concrete Steps


Run local commands from the Shibuya repository root unless the command block explicitly directs a change to a Mori-resolved project. New validator and comparator commands become available when their owning milestones implement them. Use the repository development shell if the compiler or services are missing; an unavailable dependency in offline mode requires an approved fetch, not removal of the test.

```bash
cabal build lib:shibuya-core --offline
cabal test shibuya-core --offline --test-show-details=failures
cabal test shibuya-core:shibuya-core-gc-test --offline --test-show-details=direct
```

Successful suites exit zero and report executed tests; zero tests or skipped services are not acceptance. Record exact selectors and fixture commands in this section when the harness is extended.


## Validation and Acceptance


Duplicate IDs and nonpositive/overflowing policies fail before startup with zero acquired resources. Each acquired adapter is cleaned up once even if another throws. Halt completes with empty/live sources in Serial, Async, Ahead, partitioned and batch paths. Exhausted finalization returns failure and StopAllOnFailure stops siblings. Infinite upstream cannot suppress a keyed failure. No active worker or start-gate waiter survives cleanup. Existing ordering, retries, batch behavior, and the forced-GC bare-waitApp regression still pass.

Use STM barriers or injected hooks to control interleavings; sleeps alone do not prove ordering. Assert terminal outcomes and resource ownership, not just logs. For every reproduced defect, record a failing regression against the affected implementation and a passing run against the fix; use an isolated worktree or mutation, never overwrite the working tree. Keep source-only suspicions labeled unconfirmed until reproduced or disproved. Record exact source SHAs, dependency solution, compiler, commands, random seeds, and logs in the EP-37 evidence format. Passing tests with a skipped service-dependent suite do not count as integration evidence.


## Idempotence and Recovery


Work on the current branch, preserve unrelated edits, and commit small conventional changes with MasterPlan, ExecPlan, and Intention trailers from this plan's frontmatter. Repeating unit tests and validation is safe. Use uniquely named ephemeral broker/database resources, never production endpoints or shared database reset commands. Bracket fixture cleanup and retain failed-run logs before deleting only identified fixture resources. Revert an identified implementation commit only with authorization; do not reset the checkout. Missing services or unavailable dependencies remain explicit blockers, not passes.


## Interfaces and Dependencies


Hard dependency: docs/plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md for evidence acceptance. This plan alone owns App/Internal.App, supervision, stop/failure representation, policy validation, scheduler and batching lifecycle. docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md consumes the terminal snapshot and owns Core/Metrics.hs; coordinate hook changes at this boundary rather than having both plans change lifecycle semantics. Kafka consumes the surfaced finalizer-failure contract. Source-only residuals must be tested or explicitly remain open.
