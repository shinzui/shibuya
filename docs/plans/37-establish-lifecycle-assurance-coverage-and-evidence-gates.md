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
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:45:51Z
      verdict: "comments"
      note: "Paths and tools verified; inventory range must reach REV-16 and needs an out-of-scope disposition for the deprecated MessageDB adapter."
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:46:05Z
      mode: "update"
      note: "Inventory through REV-16 with external owner EP-46; out-of-scope disposition and validator rules for the excluded MessageDB adapter."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T14:09:29Z
      mode: "implement"
      note: "Implemented the lifecycle evidence inventory, coverage taxonomy, and validator contract"
---

# Establish lifecycle assurance coverage and evidence gates

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Make the audit measurable: every finding and every lifecycle boundary has an owner, an observable invariant, and evidence that can fail a release gate. The result is a coverage ledger and a validator that rejects unsupported completion claims.


## Progress


- [x] (2026-09-20T14:09:02Z) Milestone 1: Inventory every finding and lifecycle boundary.
- [x] (2026-09-20T14:16:17Z) Milestone 2: Implement and test the evidence validator.
- [x] (2026-09-20T14:18:47Z) Milestone 3: Document candidate manifests and execution budgets.


## Surprises & Discoveries


The sixteen reviews contain 52 independently attributable records once confirmed defects,
source concerns, limitations, assumptions, and positive verification are preserved rather
than collapsing repeated observations of the same underlying problem. The inventory therefore
uses review-derived stable keys and lets multiple entries converge on one owner and invariant.
This keeps REV-2's source finding distinct from REV-3's runtime confirmation and keeps the
narrow REV-14 approval from masking REV-16's separate childless-supervisor state.

The five REV-12 records cannot be treated as accepted risk: the entire MessageDB component is
outside the candidate. They use `out-of-scope`, have no remediation owner, retain the project
owner's dated decision, and leave all five MessageDB persistence matrix cases explicitly
not applicable. Release validation must still print them as uncertified scope.


## Decision Log


2026-09-19: Keep historical audit records immutable as evidence and add a separate candidate-specific closure ledger.

2026-09-19: Give excluded findings their own disposition instead of dropping them from the inventory. The project owner excluded the deprecated MessageDB adapter from the initiative, so the REV-12 findings will not be fixed, but a ledger that silently omitted them would make the release look cleaner than it is. An out-of-scope disposition records the human decision and forces the final verdict to name the uncertified component.

2026-09-20: Use a single schema-versioned JSON document for findings, scope, owners, and the
lifecycle boundary matrix. The release validator needs to check owner membership, local
evidence paths, candidate inclusion, and matrix completeness together; splitting those facts
across unrelated files would permit drift. Human-readable semantics stay in `coverage.md`.

2026-09-20: Preserve independently authored review claims under review-derived IDs instead of
deduplicating them. Source confirmation and runtime reproduction have different evidentiary
weight, and a later positive verification can have a narrower state space than a subsequent
defect. Owners close every applicable entry, even when several entries share one fix.

2026-09-20: Record the candidate-bound evidence, exclusion, waiver, and predeclared-budget
policy in `docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md`.
These rules coordinate every remaining child and must remain discoverable after this plan is
complete.

2026-09-20: Store a candidate's exact source-SHA map and solver-plan hash once per evidence
run, then let finding results and matrix cells reference that run. This keeps individual
results small while allowing one source or dependency change to invalidate every result from
the stale run. The validator compares the complete map, not only the project that owns a test.


## Outcomes & Retrospective


EP-37 is complete. The initiative now has a schema-versioned inventory with 52 records from
all sixteen reviews, 15 owned lifecycle boundaries, 70 mandatory in-scope matrix cells, and
five explicit MessageDB exclusions. Inventory validation passes without pretending that the
31 open records are fixed. Release validation binds results to the complete candidate source
map and solver-plan hash, requires every finding result and mandatory matrix cell, rejects
incomplete or agent-approved waivers, and always surfaces exclusions.

The validator has 17 passing Bun tests, including a positive complete candidate and a stale-SHA
mutation of that same candidate. The checked-in incomplete example exits 1 with 152 errors;
representative errors name `REV-2-F1` as open and `startup-registration:normal` as missing,
while all five REV-12 records print as `UNCERTIFIED`. The evidence README defines the
append-only candidate/run layout, raw artifact requirements, identical local and eventual-CI
entry points, deterministic repetition and property budgets, both RTS modes, adapter soaks,
and initial regression limits.

No lifecycle defect beyond the already completed EP-33 and EP-46 work is claimed fixed here.
The remaining children must populate this contract with candidate-bound evidence. The durable
lesson and policy are recorded in
`docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md`: evidence is a
property of an exact candidate, and one changed source or solver identity invalidates every
run that depended on the old candidate.


## Context and Orientation


Read docs/reviews/REV-1-master-lifecycle-gc-regression.md through the reviews indexed by docs/reviews/index.md, including REV-3 through REV-16, and docs/improvement-requests/close-lifecycle-and-health-audit-gaps.md (IR-6). REV-16 was written after the audit closed and after IR-6: it reproduces a residual garbage-collection failure and a duplicated failure delivery in the released master-loop fix. Both are owned by the standalone plan docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md, which is outside this initiative and may already be complete when the inventory is written; record its findings with that plan as owner and, once it has landed, with its fix commit and its two regression tests as evidence. They appear in no IR-6 group and must not be missed for that reason. REV-12 covers the MessageDB adapter, which the project owner declared deprecated and excluded on 2026-09-19; its remediation plan, docs/plans/42-repair-messagedb-checkpoint-and-shutdown-lifecycle-semantics.md, is cancelled. scripts/audit/LifecycleProbe.hs, HealthProbe.hs, ChildlessSupervisorProbe.hs, LinkedFailureDeliveryProbe.hs and MessageDbLedgerProbe.hs print observations; they are not assertion-based release tests. shibuya-core/shibuya-core.cabal has normal and isolated GC suites. shibuya-metrics/shibuya-metrics.cabal currently has no test suite. The historical core run had 212 passing tests, which did not detect these findings.

The baseline is the committed source audit in docs/lifecycle-audit-progress.md and docs/reviews/, not a completed fault-injection campaign. Source inspection, diagnostic reproduction, fixed code, and release verification are separate evidence levels. A finalizer is the adapter operation that acknowledges, retries, or dead-letters a handled delivery. At-least-once delivery allows replay after interruption; it does not permit silently skipping unresolved work. A timeout in a test is a failure bound, not evidence that production cleanup succeeded.

When this plan was drafted no local docs/adr corpus existed; the repository's first record, docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md, was added on 2026-09-20. It concerns linked threads and garbage-collection liveness tests and does not constrain this plan. The corpus is plain Markdown with no OKF profile. Before introducing durable interfaces, follow .agents/skills/exec-plan/ADR.md and record the decision using the then-current repository convention. Locate dependency sources with Mori before choosing APIs. Verify registry releases and upstream tags before changing dependency bounds. Registration-service-v2 is excluded.


## Plan of Work


Milestone 1 establishes the inventory in new docs/audits/lifecycle-release/findings.json and coverage.md. Assign stable finding keys preserving review ID and finding ordinal; include every finding, limitation, and accepted assumption from REV-1 through REV-16, not only the nine IR-6 groups. Enter each REV-12 finding with the disposition `out-of-scope`, no owning child, and a decision record naming the project owner, the date 2026-09-19, the reason (adapter deprecated) and the affected scope (mori://shinzui/shibuya-message-db-adapter); do not mark them fixed, disproved or waived. Preserve historical reviews. Record severity, source URI/path and baseline SHA, claim, confirmation level, owning child, invariant, regression test, fix SHA, evidence references, and disposition. Split a review's independent defects into separate entries. Include startup/registration, ingestion/backpressure, dispatch, keyed ordering, batching, retry/lease, finalization, drain/cancel, supervision, metrics/health, and adapter persistence. Each boundary must have normal, synchronous exception, cancellation, timeout, and repeated-stop coverage or a reasoned non-applicability. Validate that no finding or boundary is orphaned.

Milestone 2 adds scripts/audit/validate-evidence.ts and scripts/audit/validate-evidence.test.ts using Bun's built-in test runner, with no new dependency required. Define schemaVersion 1 and reject unknown dispositions, duplicate IDs, missing owners (an owner may be a child of the parent MasterPlan or a named plan outside it, as for REV-16), nonexistent local evidence, stale candidate SHAs, missing tests on fixed findings, and unjustified exclusions. The `out-of-scope` disposition is the one case allowed to have no owning child: it is valid only with a named human decision, a date, a reason and an affected scope, it may not be applied to a finding whose component is inside the release candidate, and release validation must surface every such entry in its output so the verdict can list the component as uncertified. Distinguish inventory validation from release validation: inventory may contain open findings; release rejects open or unconfirmed safety findings, missing mandatory matrix runs, and unapproved waivers. A waiver requires a named human release owner, rationale, expiry, affected release scope, and compensating controls. No agent can waive its own failed gate. Add fixtures proving each rejection, including a changed source SHA after a successful run.

Milestone 3 adds docs/audits/lifecycle-release/README.md with commands and an append-only candidate evidence layout. A candidate manifest records all project SHAs, dirty patch hashes if used for diagnostics, exact package versions, solver plan hash, compiler/platform, services, timestamps, commands/exit codes, seeds, and artifact locations. Final release evidence must use committed clean sources. Set explicit scenario budgets before remediation runs: 100 deterministic repetitions per concurrency regression, 1,000 seeded property cases per model, both single- and multi-capability RTS runs, and 30-minute bounded soak per in-scope adapter (Kafka, PGMQ and Kiroku) at its documented supported concurrency. A later adjustment requires rationale and release-owner approval. Document how local and eventual CI runs invoke the same validators. Run the commands below and demonstrate that an incomplete candidate fails release validation.


## Concrete Steps


Run local commands from the Shibuya repository root unless the command block explicitly directs a change to a Mori-resolved project. New validator and comparator commands become available when their owning milestones implement them. Use the repository development shell if the compiler or services are missing; an unavailable dependency in offline mode requires an approved fetch, not removal of the test.

```bash
bun test scripts/audit/validate-evidence.test.ts
bun scripts/audit/validate-evidence.ts --inventory docs/audits/lifecycle-release/findings.json
bun scripts/audit/validate-evidence.ts --release docs/audits/lifecycle-release/candidates/example-incomplete.json
```

Successful suites exit zero and report executed tests; zero tests or skipped services are not acceptance. Record exact selectors and fixture commands in this section when the harness is extended.

Milestone 2 added a candidate-complete fixture as a positive control. The focused validation
commands and observed results were:

```bash
bun test scripts/audit/validate-evidence.test.ts
bun scripts/audit/validate-evidence.ts --inventory docs/audits/lifecycle-release/findings.json
bun scripts/audit/validate-evidence.ts --release scripts/audit/fixtures/valid-release.json
```

```text
16 pass
0 fail
Inventory valid: 52 findings, 15 boundaries, 70 mandatory cells, 5 exclusions.
Release valid: 2 findings, 2 boundaries, 5 mandatory cells, 1 exclusions.
```

The sixteen tests include unknown disposition, duplicate key, missing owner, missing local
evidence, missing fixed-finding regression, unjustified exclusion, in-scope exclusion,
orphaned review, missing lifecycle case, open or unconfirmed safety work, missing mandatory
matrix run, stale source SHA, stale solver plan, incomplete waiver, and excluded-component
candidate rejection. The valid release fixture is the control that passes before its source
SHA is changed in the stale-evidence test.

Milestone 3 added the checked-in incomplete candidate and its CLI-level negative-control test.
The final focused run reports:

```text
17 pass
0 fail
Release invalid: 152 error(s)
- REV-2-F1: open finding blocks release
- startup-registration:normal: missing mandatory matrix run
```

The release command also prints all five REV-12 entries as `UNCERTIFIED`, so the excluded
adapter remains visible even while validation fails.


## Validation and Acceptance


Inventory validation and validator tests exit zero; the deliberately incomplete candidate exits nonzero and identifies missing evidence. Every historical finding and every lifecycle boundary is accounted for, with no claim that coverage means implementation is complete. All five remediation plans (core, metrics, Kafka, PGMQ and Kiroku) can append evidence without changing the schema. An `out-of-scope` entry without a named human decision, or one applied to an in-scope component, is rejected.

Use STM barriers or injected hooks to control interleavings; sleeps alone do not prove ordering. Assert terminal outcomes and resource ownership, not just logs. For every reproduced defect, record a failing regression against the affected implementation and a passing run against the fix; use an isolated worktree or mutation, never overwrite the working tree. Keep source-only suspicions labeled unconfirmed until reproduced or disproved. Record exact source SHAs, dependency solution, compiler, commands, random seeds, and logs in the EP-37 evidence format. Passing tests with a skipped service-dependent suite do not count as integration evidence.


## Idempotence and Recovery


Work on the current branch, preserve unrelated edits, and commit small conventional changes with MasterPlan, ExecPlan, and Intention trailers from this plan's frontmatter. Repeating unit tests and validation is safe. Use uniquely named ephemeral broker/database resources, never production endpoints or shared database reset commands. Bracket fixture cleanup and retain failed-run logs before deleting only identified fixture resources. Revert an identified implementation commit only with authorization; do not reset the checkout. Missing services or unavailable dependencies remain explicit blockers, not passes.


## Interfaces and Dependencies


This plan owns the ledger schema, validator, coverage taxonomy, and README. Remediation plans own their finding entries and result artifacts; docs/plans/44-certify-the-integrated-lifecycle-release-candidate.md owns the integrated candidate manifest and release verdict. Validator CLI flags above are new interfaces to implement, not existing commands. There are no hard dependencies. Other children consume this schema after completion.


## Revision Notes


2026-09-20 UTC: Revised after a pre-implementation review of the parent MasterPlan. Extended the inventory range to REV-16, recorded after IR-6 and fixed by a standalone plan outside this initiative, so that it is neither orphaned nor double-owned, and added its two probes to the list of diagnostic scripts. Added the `out-of-scope` disposition and its validator rules because the project owner excluded the deprecated MessageDB adapter: the REV-12 findings stay visible in the ledger and in the verdict without being fixed, and without being mislabelled as waived or resolved. Corrected the count of remediation plans from six to five and scoped soak budgets to the three in-scope adapters.

2026-09-20 UTC: Implemented all three milestones. Added the full review inventory and
boundary taxonomy, the tested inventory/release validator and fixtures, the append-only
candidate evidence contract and execution budgets, a deliberately failing incomplete
candidate, and ADR 0002. The plan is complete; subsequent children append candidate-bound
evidence without changing the schema unless a separately recorded revision is required.
