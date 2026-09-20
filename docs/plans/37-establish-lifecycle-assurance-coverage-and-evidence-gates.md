---
id: 37
slug: establish-lifecycle-assurance-coverage-and-evidence-gates
title: "Establish lifecycle assurance coverage and evidence gates"
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

# Establish lifecycle assurance coverage and evidence gates

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Make the audit measurable: every finding and every lifecycle boundary has an owner, an observable invariant, and evidence that can fail a release gate. The result is a coverage ledger and a validator that rejects unsupported completion claims.


## Progress


- [ ] Milestone 1: Inventory every finding and lifecycle boundary.
- [ ] Milestone 2: Implement and test the evidence validator.
- [ ] Milestone 3: Document candidate manifests and execution budgets.


## Surprises & Discoveries


None yet; implementation has not started.


## Decision Log


2026-09-19: Keep historical audit records immutable as evidence and add a separate candidate-specific closure ledger.


## Outcomes & Retrospective


To be filled during implementation. No remediation or certification is claimed by creation of this plan.


## Context and Orientation


Read docs/reviews/REV-1-master-lifecycle-gc-regression.md through the reviews indexed by docs/reviews/index.md, including REV-3 through REV-15, and docs/improvement-requests/close-lifecycle-and-health-audit-gaps.md (IR-6). scripts/audit/LifecycleProbe.hs, HealthProbe.hs, and MessageDbLedgerProbe.hs print observations; they are not assertion-based release tests. shibuya-core/shibuya-core.cabal has normal and isolated GC suites. shibuya-metrics/shibuya-metrics.cabal currently has no test suite. The historical core run had 212 passing tests, which did not detect these findings.

The baseline is the committed source audit in docs/lifecycle-audit-progress.md and docs/reviews/, not a completed fault-injection campaign. Source inspection, diagnostic reproduction, fixed code, and release verification are separate evidence levels. A finalizer is the adapter operation that acknowledges, retries, or dead-letters a handled delivery. At-least-once delivery allows replay after interruption; it does not permit silently skipping unresolved work. A timeout in a test is a failure bound, not evidence that production cleanup succeeded.

No local docs/adr corpus existed when this plan was drafted. Before introducing durable interfaces, follow .agents/skills/exec-plan/ADR.md and record the decision using the then-current repository convention. Locate dependency sources with Mori before choosing APIs. Verify registry releases and upstream tags before changing dependency bounds. Registration-service-v2 is excluded.


## Plan of Work


Milestone 1 establishes the inventory in new docs/audits/lifecycle-release/findings.json and coverage.md. Assign stable finding keys preserving review ID and finding ordinal; include every finding, limitation, and accepted assumption from REV-1 through REV-15, not only the nine IR-6 groups. Preserve historical reviews. Record severity, source URI/path and baseline SHA, claim, confirmation level, owning child, invariant, regression test, fix SHA, evidence references, and disposition. Split a review's independent defects into separate entries. Include startup/registration, ingestion/backpressure, dispatch, keyed ordering, batching, retry/lease, finalization, drain/cancel, supervision, metrics/health, and adapter persistence. Each boundary must have normal, synchronous exception, cancellation, timeout, and repeated-stop coverage or a reasoned non-applicability. Validate that no finding or boundary is orphaned.

Milestone 2 adds scripts/audit/validate-evidence.ts and scripts/audit/validate-evidence.test.ts using Bun's built-in test runner, with no new dependency required. Define schemaVersion 1 and reject unknown dispositions, duplicate IDs, missing owners, nonexistent local evidence, stale candidate SHAs, missing tests on fixed findings, and unjustified exclusions. Distinguish inventory validation from release validation: inventory may contain open findings; release rejects open or unconfirmed safety findings, missing mandatory matrix runs, and unapproved waivers. A waiver requires a named human release owner, rationale, expiry, affected release scope, and compensating controls. No agent can waive its own failed gate. Add fixtures proving each rejection, including a changed source SHA after a successful run.

Milestone 3 adds docs/audits/lifecycle-release/README.md with commands and an append-only candidate evidence layout. A candidate manifest records all project SHAs, dirty patch hashes if used for diagnostics, exact package versions, solver plan hash, compiler/platform, services, timestamps, commands/exit codes, seeds, and artifact locations. Final release evidence must use committed clean sources. Set explicit scenario budgets before remediation runs: 100 deterministic repetitions per concurrency regression, 1,000 seeded property cases per model, both single- and multi-capability RTS runs, and 30-minute bounded soak per adapter at its documented supported concurrency. A later adjustment requires rationale and release-owner approval. Document how local and eventual CI runs invoke the same validators. Run the commands below and demonstrate that an incomplete candidate fails release validation.


## Concrete Steps


Run local commands from the Shibuya repository root unless the command block explicitly directs a change to a Mori-resolved project. New validator and comparator commands become available when their owning milestones implement them. Use the repository development shell if the compiler or services are missing; an unavailable dependency in offline mode requires an approved fetch, not removal of the test.

```bash
bun test scripts/audit/validate-evidence.test.ts
bun scripts/audit/validate-evidence.ts --inventory docs/audits/lifecycle-release/findings.json
bun scripts/audit/validate-evidence.ts --release docs/audits/lifecycle-release/candidates/example-incomplete.json
```

Successful suites exit zero and report executed tests; zero tests or skipped services are not acceptance. Record exact selectors and fixture commands in this section when the harness is extended.


## Validation and Acceptance


Inventory validation and validator tests exit zero; the deliberately incomplete candidate exits nonzero and identifies missing evidence. Every historical finding and every lifecycle boundary is accounted for, with no claim that coverage means implementation is complete. All six remediation plans can append evidence without changing the schema.

Use STM barriers or injected hooks to control interleavings; sleeps alone do not prove ordering. Assert terminal outcomes and resource ownership, not just logs. For every reproduced defect, record a failing regression against the affected implementation and a passing run against the fix; use an isolated worktree or mutation, never overwrite the working tree. Keep source-only suspicions labeled unconfirmed until reproduced or disproved. Record exact source SHAs, dependency solution, compiler, commands, random seeds, and logs in the EP-37 evidence format. Passing tests with a skipped service-dependent suite do not count as integration evidence.


## Idempotence and Recovery


Work on the current branch, preserve unrelated edits, and commit small conventional changes with MasterPlan, ExecPlan, and Intention trailers from this plan's frontmatter. Repeating unit tests and validation is safe. Use uniquely named ephemeral broker/database resources, never production endpoints or shared database reset commands. Bracket fixture cleanup and retain failed-run logs before deleting only identified fixture resources. Revert an identified implementation commit only with authorization; do not reset the checkout. Missing services or unavailable dependencies remain explicit blockers, not passes.


## Interfaces and Dependencies


This plan owns the ledger schema, validator, coverage taxonomy, and README. Remediation plans own their finding entries and result artifacts; docs/plans/44-certify-the-integrated-lifecycle-release-candidate.md owns the integrated candidate manifest and release verdict. Validator CLI flags above are new interfaces to implement, not existing commands. There are no hard dependencies. Other children consume this schema after completion.
