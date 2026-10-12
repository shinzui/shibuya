---
id: 42
slug: repair-messagedb-checkpoint-and-shutdown-lifecycle-semantics
title: "Repair MessageDB checkpoint and shutdown lifecycle semantics"
kind: exec-plan
created_at: 2026-09-20T04:05:13Z
intention: "intention_01m2yfmkqxeg9sc0wfmcp4w9fe"
master_plan: "docs/masterplans/6-comprehensive-lifecycle-remediation-and-release-assurance.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-20T04:05:13Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:46:05Z
      mode: "update"
      note: "Cancelled: project owner declared the MessageDB adapter deprecated; findings dispositioned out of scope, body preserved."
---

# Repair MessageDB checkpoint and shutdown lifecycle semantics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

**Status: Cancelled on 2026-09-19. Do not implement this plan.** The project owner stated
during review of the parent MasterPlan that the MessageDB adapter is deprecated. The
REV-12 findings described below remain true of that adapter and are not fixed; they are
carried in the evidence ledger with an out-of-scope disposition by
docs/plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md, and the release
verdict produced by docs/plans/44-certify-the-integrated-lifecycle-release-candidate.md
names the adapter as uncertified and unsupported. The body is preserved unchanged as a
record of the intended remediation should the adapter ever be revived.


## Purpose / Big Picture


Make MessageDB progress advance across sparse category positions without skipping unresolved deliveries, and make retry/shutdown and checkpoint persistence failure observable and recoverable.


## Progress


- [ ] Milestone 1: Complete compatibility prerequisite and add sparse-position regressions.
- [ ] Milestone 2: Separate checkpoint candidates from durable saved progress.
- [ ] Milestone 3: Fix retry shutdown and persister supervision.
- [ ] Milestone 4: Verify restart and outages against a real ephemeral database.


## Surprises & Discoveries


None yet; implementation has not started.


## Decision Log


2026-09-19: Track contiguous completion in the observed delivery sequence, not integer global positions; durable progress changes only after persistence succeeds.

2026-09-19: Cancel this plan. The project owner declared the MessageDB adapter deprecated and limited adapter scope to Kafka, PGMQ and Kiroku. Repairing code that will not ship would consume the initiative's budget, and the compatibility prerequisite in docs/plans/36-upgrade-shibuya-message-db-adapter-to-shibuya-core-0-9-and-structured-dead-letter-reasons.md had not started. The findings are dispositioned as out of scope, not resolved.


## Outcomes & Retrospective


To be filled during implementation. No remediation or certification is claimed by creation of this plan.


## Context and Orientation


The owning repository is mori://shinzui/shibuya-message-db-adapter. Its project-relative paths (artifact-level source URIs pending) are shibuya-message-db-adapter/src/Shibuya/Adapter/MessageDb/Internal.hs and Internal/InflightState.hs, with tests under shibuya-message-db-adapter/test/Shibuya/Adapter/MessageDb/, including InflightStateTest.hs, RetryBufferTest.hs and CheckpointResumeTest.hs. REV-12 records four primary defects: advanceCheckpointTo requires exact lastSaved+1 although category positions are globally sparse; stopped retry workers can spin on an unpopped queue head; empty source polls filter away the shutdown check; the ledger is cleared before storeCheckpoint succeeds and persister failure is unmonitored. scripts/audit/MessageDbLedgerProbe.hs reproduces sparse non-advance and loss of a second persistence claim, but not a real database outage.

The baseline is the committed source audit in docs/lifecycle-audit-progress.md and docs/reviews/, not a completed fault-injection campaign. Source inspection, diagnostic reproduction, fixed code, and release verification are separate evidence levels. A finalizer is the adapter operation that acknowledges, retries, or dead-letters a handled delivery. At-least-once delivery allows replay after interruption; it does not permit silently skipping unresolved work. A timeout in a test is a failure bound, not evidence that production cleanup succeeded.

No local docs/adr corpus existed when this plan was drafted. Before introducing durable interfaces, follow .agents/skills/exec-plan/ADR.md and record the decision using the then-current repository convention. Locate dependency sources with Mori before choosing APIs. Verify registry releases and upstream tags before changing dependency bounds. Registration-service-v2 is excluded.


## Plan of Work


Milestone 1 completes the compatibility prerequisite in docs/plans/36-upgrade-shibuya-message-db-adapter-to-shibuya-core-0-9-and-structured-dead-letter-reasons.md without duplicating its API migration. Convert the ledger probe to InflightStateTest.hs assertions. Model progress over ordered deliveries, not all integer positions: deliveries 2, 5, 9 may advance to 5 when 2 and 5 are terminal, but not past unresolved 2 merely because 5 finished first. Preserve the existing checkpoint inclusive/exclusive convention by testing restart SQL end to end.

Milestone 2 changes InflightState.hs to separate observed delivery order, completed acknowledgements, pending checkpoint candidate, and durably saved progress. Compute a candidate from the acknowledged prefix of observed deliveries; never remove the recovery obligation before successful persistence. On store failure, retain/retry the candidate or fail the supervised adapter visibly. Serialize or version persistence completion so late success cannot acknowledge a newer unsaved frontier accidentally. Add a controllable store failure between candidate selection and durable commit; ensure retry or final flush still has the candidate.

Milestone 3 makes stopped state win over queued retry work in awaitRetryHeadOrShutdown and ensures retryFiber exits without spinning on a due head. Check stop before filtering empty polls, so idle shutdown does not require forced cancellation. Supervise the checkpoint persister and propagate fatal failures. Exercise stop while retries are due/not due, during polling, and during persistence. Bound internal retry accumulation or document and test a defensible bound; also verify consumer-group category distribution rather than assuming all configured members do useful work.

Milestone 4 extends CheckpointResumeTest.hs and the ephemeral database TestEnv.hs with interleaved categories, acknowledged-prefix restart, store outage, persister crash, DLQ failure and shutdown. Preserve documented best-effort DLQ semantics unless explicitly changed with compatibility documentation. Verify that the adapter neither claims unsaved progress nor busy-loops when stopped.

Before closing this plan, supply focused before/after performance evidence for its changed paths using docs/plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md. Baseline capture is an early coordination requirement, not a reason to defer all measurement until release. Correctness and performance must both pass; the performance plan owns budgets and harnesses.


## Concrete Steps


Run local commands from the Shibuya repository root unless the command block explicitly directs a change to a Mori-resolved project. New validator and comparator commands become available when their owning milestones implement them. Use the repository development shell if the compiler or services are missing; an unavailable dependency in offline mode requires an approved fetch, not removal of the test.

```bash
mori registry show shinzui/shibuya-message-db-adapter --full
mori registry docs shinzui/shibuya-message-db-adapter
mori registry search message-db-hs
mori path mori://shinzui/shibuya-message-db-adapter
# Change to the resolved project root, then:
cabal test shibuya-message-db-adapter --test-show-details=direct
```

Successful suites exit zero and report executed tests; zero tests or skipped services are not acceptance. Record exact selectors and fixture commands in this section when the harness is extended.


## Validation and Acceptance


Sparse category positions advance to the last safely completed observed delivery; out-of-order acknowledgements cannot skip an unresolved predecessor. A failed store keeps a retryable candidate, and a successful retry persists it. Idle and queued-retry shutdown terminate without an active retry fiber. A persister crash is visible. Actual database restart resumes correctly with interleaved categories and permits only contractually expected replay.

Use STM barriers or injected hooks to control interleavings; sleeps alone do not prove ordering. Assert terminal outcomes and resource ownership, not just logs. For every reproduced defect, record a failing regression against the affected implementation and a passing run against the fix; use an isolated worktree or mutation, never overwrite the working tree. Keep source-only suspicions labeled unconfirmed until reproduced or disproved. Record exact source SHAs, dependency solution, compiler, commands, random seeds, and logs in the EP-37 evidence format. Passing tests with a skipped service-dependent suite do not count as integration evidence.


## Idempotence and Recovery


Work on the current branch, preserve unrelated edits, and commit small conventional changes with MasterPlan, ExecPlan, and Intention trailers from this plan's frontmatter. Repeating unit tests and validation is safe. Use uniquely named ephemeral broker/database resources, never production endpoints or shared database reset commands. Bracket fixture cleanup and retain failed-run logs before deleting only identified fixture resources. Revert an identified implementation commit only with authorization; do not reset the checkout. Missing services or unavailable dependencies remain explicit blockers, not passes.


## Interfaces and Dependencies


Hard dependencies: docs/plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md, docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md, and the existing compatibility plan docs/plans/36-upgrade-shibuya-message-db-adapter-to-shibuya-core-0-9-and-structured-dead-letter-reasons.md. This plan owns adapter lifecycle/checkpoint fixes and tests, not that plan's API migration. Changes are in mori://shinzui/shibuya-message-db-adapter and require cross-workspace authority. Consult mori://message-db/message-db for authoritative category query semantics (project-relative database/functions/get-category-messages.sql; artifact URI pending) and discover the Haskell client through Mori. Use a candidate Cabal project with one resolved core version.


## Revision Notes


2026-09-20 UTC: Marked the plan Cancelled and recorded the decision. The project owner declared the MessageDB adapter deprecated during review of the parent MasterPlan, so none of the milestones will be implemented. No milestone text was altered, so the plan still documents the intended repair; the unchecked Progress items are abandoned, not pending.
