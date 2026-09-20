---
id: 41
slug: verify-pgmq-acknowledgement-and-dead-letter-recovery-under-faults
title: "Verify PGMQ acknowledgement and dead-letter recovery under faults"
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

# Verify PGMQ acknowledgement and dead-letter recovery under faults

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Demonstrate that PGMQ acknowledgements remain recoverable under database faults and prevent duplicate durable dead-letter moves after an ambiguous commit response.


## Progress


- [ ] Milestone 1: Reproduce ambiguous commits and finalizer fault paths.
- [ ] Milestone 2: Implement durable idempotent DLQ movement.
- [ ] Milestone 3: Verify leases, outage recovery and restart on ephemeral PostgreSQL.


## Surprises & Discoveries


None yet; implementation has not started.


## Decision Log


2026-09-19: Require durable idempotence for DLQ movement while retaining at-least-once processing and documented lease-expiry replay.


## Outcomes & Retrospective


To be filled during implementation. No remediation or certification is claimed by creation of this plan.


## Context and Orientation


The owning repository is mori://shinzui/shibuya-pgmq-adapter; project-relative source paths below are pending artifact-level source URIs. shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs and Pgmq.hs handle finalization and leasing. Existing package tests include test/Shibuya/Adapter/Pgmq/ChaosSpec.hs, IntegrationSpec.hs, InternalSpec.hs, PropertySpec.hs, and test/TmpPostgres.hs. REV-11 records a source-derived risk: DLQ send plus source delete is transactional, but a committed transaction with a lost response can be retried; finalized is marked only after the response and the delete result is ignored. A lease is temporary message invisibility, not deletion. Prefetched messages waiting for lease expiry after stop are an existing accepted tradeoff.

The baseline is the committed source audit in docs/lifecycle-audit-progress.md and docs/reviews/, not a completed fault-injection campaign. Source inspection, diagnostic reproduction, fixed code, and release verification are separate evidence levels. A finalizer is the adapter operation that acknowledges, retries, or dead-letters a handled delivery. At-least-once delivery allows replay after interruption; it does not permit silently skipping unresolved work. A timeout in a test is a failure bound, not evidence that production cleanup succeeded.

No local docs/adr corpus existed when this plan was drafted. Before introducing durable interfaces, follow .agents/skills/exec-plan/ADR.md and record the decision using the then-current repository convention. Locate dependency sources with Mori before choosing APIs. Verify registry releases and upstream tags before changing dependency bounds. Registration-service-v2 is excluded.


## Plan of Work


Milestone 1 extends the mock and ephemeral PostgreSQL fixtures to distinguish failure before commit from a successful commit whose response is lost. Inject at the transaction boundary or use a controlled connection fault; a pre-commit exception alone does not prove this scenario. Record source queue row and DLQ row counts and original message identity. Add duplicate/concurrent acknowledgement, renew failure, retry visibility, and cancellation during finalization tests. Reproduce the suspected duplicate DLQ move before choosing a fix.

Milestone 2 makes the durable move idempotent. Prefer atomically claiming/deleting the source row and conditionally sending to the DLQ only if that claim succeeded in the same transaction, provided PGMQ's verified API supplies the required result and preserves rollback. Verify actual dependency SQL through Mori. If not, use a durable deduplication identity with a documented migration and cleanup policy; do not invent unsupported API behavior or rely on an IORef for crash safety. Concurrent callers and lost-response retries must converge on one durable move. Preserve source recoverability on transaction failure and surface exhausted finalization failures.

Milestone 3 exercises short leases, prefetched messages on stop, renewal outage, database reconnect, automatic DLQ callback failure, shutdown with a pending move, and restart. Observe durable queues and redelivery after lease expiry. Keep no-delete/no-loss guarantees distinct from delayed availability and from exactly-once application side effects. Document callback visibility requirements so a failed automatic DLQ operation is not silently invisible to operators.

Before closing this plan, supply focused before/after performance evidence for its changed paths using docs/plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md. Baseline capture is an early coordination requirement, not a reason to defer all measurement until release. Correctness and performance must both pass; the performance plan owns budgets and harnesses.


## Concrete Steps


Run local commands from the Shibuya repository root unless the command block explicitly directs a change to a Mori-resolved project. New validator and comparator commands become available when their owning milestones implement them. Use the repository development shell if the compiler or services are missing; an unavailable dependency in offline mode requires an approved fetch, not removal of the test.

```bash
mori registry show shinzui/shibuya-pgmq-adapter --full
mori registry docs shinzui/shibuya-pgmq-adapter
mori path mori://shinzui/shibuya-pgmq-adapter
# Change to the resolved project root, then:
cabal test shibuya-pgmq-adapter --test-show-details=direct
```

Successful suites exit zero and report executed tests; zero tests or skipped services are not acceptance. Record exact selectors and fixture commands in this section when the harness is extended.


## Validation and Acceptance


A commit followed by lost response and retry produces one durable DLQ copy per source identity, with the source removed exactly when the transaction succeeds. Failed moves leave a recoverable source message. Duplicate finalization converges without loss. Stop with prefetched messages permits replay after documented visibility expiry. The ephemeral database suite proves these observations; source inspection alone cannot close the finding.

Use STM barriers or injected hooks to control interleavings; sleeps alone do not prove ordering. Assert terminal outcomes and resource ownership, not just logs. For every reproduced defect, record a failing regression against the affected implementation and a passing run against the fix; use an isolated worktree or mutation, never overwrite the working tree. Keep source-only suspicions labeled unconfirmed until reproduced or disproved. Record exact source SHAs, dependency solution, compiler, commands, random seeds, and logs in the EP-37 evidence format. Passing tests with a skipped service-dependent suite do not count as integration evidence.


## Idempotence and Recovery


Work on the current branch, preserve unrelated edits, and commit small conventional changes with MasterPlan, ExecPlan, and Intention trailers from this plan's frontmatter. Repeating unit tests and validation is safe. Use uniquely named ephemeral broker/database resources, never production endpoints or shared database reset commands. Bracket fixture cleanup and retain failed-run logs before deleting only identified fixture resources. Revert an identified implementation commit only with authorization; do not reset the checkout. Missing services or unavailable dependencies remain explicit blockers, not passes.


## Interfaces and Dependencies


Hard dependencies: docs/plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md and docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md. This plan owns PGMQ finalization and fault fixtures in mori://shinzui/shibuya-pgmq-adapter; obtain necessary write authority first. Resolve PGMQ and Hasql APIs with Mori before modifying SQL/transactions. Use the exact candidate core in a coherent Cabal project; coordinate package bounds with docs/plans/35-align-adapter-effectful-bounds-and-releases-with-shibuya-core-0-9-0-3.md. If a migration is necessary, update this plan with an additive rollout and rollback design before applying it.
