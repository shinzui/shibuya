---
id: 40
slug: prevent-kafka-acknowledgements-from-skipping-unresolved-deliveries
title: "Prevent Kafka acknowledgements from skipping unresolved deliveries"
kind: exec-plan
created_at: 2026-09-20T04:05:13Z
intention: "intention_01m2yfmkqxeg9sc0wfmcp4w9fe"
master_plan: "docs/masterplans/6-comprehensive-lifecycle-remediation-and-release-assurance.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-20T04:05:13Z
---

# Prevent Kafka acknowledgements from skipping unresolved deliveries

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Prevent Kafka commits from crossing unresolved deliveries, and surface acknowledgement failures even when ingestion has already stopped.


## Progress


- [ ] Milestone 1: Reproduce acknowledgement interleavings with a reference model.
- [ ] Milestone 2: Fix unresolved-delivery tracking and terminal failure propagation.
- [ ] Milestone 3: Verify recovery and reassignment against a live ephemeral broker.


## Surprises & Discoveries


None yet; implementation has not started.


## Decision Log


2026-09-19: Prove the commit boundary against unresolved deliveries and assignment identity; numeric offset adjacency is not a correctness assumption.


## Outcomes & Retrospective


To be filled during implementation. No remediation or certification is claimed by creation of this plan.


## Context and Orientation


The owning repository is mori://shinzui/shibuya-kafka-adapter; all paths in this paragraph are relative to that project (artifact-level source URIs pending). shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs and Kafka.hs implement retry barriers and acknowledgements; test/Shibuya/Adapter/Kafka/AckHandleTest.hs and IntegrationTest.hs under the package, plus test/Kafka/TestEnv.hs, provide mock and broker fixtures. REV-10 in the Shibuya review bundle records a source-derived interleaving: buffered offset 42 retries, 43 retries and replaces the barrier, then successful 43 clears it and can permit committing past unresolved 42. It also records ackAttempt setting fatalError while returning success; only a future source read notices, which may never happen during shutdown. Kafka presently requires Serial processing; this plan does not silently expand supported concurrency.

The baseline is the committed source audit in docs/lifecycle-audit-progress.md and docs/reviews/, not a completed fault-injection campaign. Source inspection, diagnostic reproduction, fixed code, and release verification are separate evidence levels. A finalizer is the adapter operation that acknowledges, retries, or dead-letters a handled delivery. At-least-once delivery allows replay after interruption; it does not permit silently skipping unresolved work. A timeout in a test is a failure bound, not evidence that production cleanup succeeded.

No local docs/adr corpus existed when this plan was drafted. Before introducing durable interfaces, follow .agents/skills/exec-plan/ADR.md and record the decision using the then-current repository convention. Locate dependency sources with Mori before choosing APIs. Verify registry releases and upstream tags before changing dependency bounds. Registration-service-v2 is excluded.


## Plan of Work


Milestone 1 adds a small per-partition reference model and deterministic tests in AckHandleTest.hs for buffered offsets 42 and 43, repeated Retry, out-of-order callbacks, duplicate acknowledgement and shutdown after source completion. In the model, the safe commit boundary cannot cross any unresolved delivered offset; gaps in actual Kafka offsets do not themselves imply missing deliveries. Reproduce or disprove each source-derived finding before claiming a fix. Run model sequences with fixed recorded seeds.

Milestone 2 replaces the single overwriteable retry barrier with state that preserves the earliest unresolved delivery and distinguishes stale buffered callbacks from replayed attempts. Specify attempt identity and partition ownership explicitly. If a single earliest-offset barrier suffices, prove it against the reference model; otherwise use an ordered unresolved-delivery ledger. Seeking and clearing state must never discard an earlier retry obligation. Failed terminal acknowledgement must throw or otherwise reach core's terminal failure path directly, rather than rely exclusively on a later kafkaSource read. Keep retryable errors retryable and duplicate finalization safe.

Milestone 3 extends IntegrationTest.hs and Kafka/TestEnv.hs with ephemeral-broker cases: retry while later records are buffered, disconnect during store/commit, DLQ producer failure, cancel while finalizing, stop/drain/consumer-close ordering, restart and partition reassignment with late callbacks. Observe broker-committed offsets after restart, not just mock calls. Fence callbacks from revoked assignments or demonstrate an existing upstream fence with tests; no static-membership feature is required. Document deliberate drop behavior when no DLQ producer is configured. Broker faults must be confined to the test fixture.

Before closing this plan, supply focused before/after performance evidence for its changed paths using docs/plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md. Baseline capture is an early coordination requirement, not a reason to defer all measurement until release. Correctness and performance must both pass; the performance plan owns budgets and harnesses.


## Concrete Steps


Run local commands from the Shibuya repository root unless the command block explicitly directs a change to a Mori-resolved project. New validator and comparator commands become available when their owning milestones implement them. Use the repository development shell if the compiler or services are missing; an unavailable dependency in offline mode requires an approved fetch, not removal of the test.

```bash
mori registry show shinzui/shibuya-kafka-adapter --full
mori registry docs shinzui/shibuya-kafka-adapter
mori registry search kafka-effectful
mori path mori://shinzui/shibuya-kafka-adapter
# Change to the resolved project root, then:
cabal test shibuya-kafka-adapter --test-show-details=direct
```

Successful suites exit zero and report executed tests; zero tests or skipped services are not acceptance. Record exact selectors and fixture commands in this section when the harness is extended.


## Validation and Acceptance


Offset 43 cannot make offset 42 disappear from the recovery obligation. On restart every unresolved record is redelivered or remains durably recoverable; a terminal ack failure after source exhaustion is visible to waitApp. Repeated callbacks do not double-advance offsets. Reassignment rejects stale acknowledgements. Both mock model tests and actual broker tests pass against the same candidate core solution.

Use STM barriers or injected hooks to control interleavings; sleeps alone do not prove ordering. Assert terminal outcomes and resource ownership, not just logs. For every reproduced defect, record a failing regression against the affected implementation and a passing run against the fix; use an isolated worktree or mutation, never overwrite the working tree. Keep source-only suspicions labeled unconfirmed until reproduced or disproved. Record exact source SHAs, dependency solution, compiler, commands, random seeds, and logs in the EP-37 evidence format. Passing tests with a skipped service-dependent suite do not count as integration evidence.


## Idempotence and Recovery


Work on the current branch, preserve unrelated edits, and commit small conventional changes with MasterPlan, ExecPlan, and Intention trailers from this plan's frontmatter. Repeating unit tests and validation is safe. Use uniquely named ephemeral broker/database resources, never production endpoints or shared database reset commands. Bracket fixture cleanup and retain failed-run logs before deleting only identified fixture resources. Revert an identified implementation commit only with authorization; do not reset the checkout. Missing services or unavailable dependencies remain explicit blockers, not passes.


## Interfaces and Dependencies


Hard dependencies: docs/plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md and docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md. All production adapter changes belong to mori://shinzui/shibuya-kafka-adapter; request required cross-workspace write approval before editing. Use a temporary Cabal project including the exact candidate core, not a separately installed older core. This plan owns Kafka delivery state and broker fixtures; it consumes core finalizer failure semantics. Existing dependency-bound/release work remains owned by docs/plans/35-align-adapter-effectful-bounds-and-releases-with-shibuya-core-0-9-0-3.md. Record exact project-relative test selectors and service setup from the existing harness before running; do not treat skipped integration tests as success.
