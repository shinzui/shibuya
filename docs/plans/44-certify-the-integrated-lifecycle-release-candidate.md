---
id: 44
slug: certify-the-integrated-lifecycle-release-candidate
title: "Certify the integrated lifecycle release candidate"
kind: exec-plan
created_at: 2026-09-20T04:05:13Z
intention: "intention_01m2yfmkqxeg9sc0wfmcp4w9fe"
master_plan: "docs/masterplans/6-comprehensive-lifecycle-remediation-and-release-assurance.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-20T04:05:13Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:45:51Z
      verdict: "changes-requested"
      note: "Candidate would not solve: all adapters pin core 0.9 while the candidate is a major version; MessageDB and plan 36 must leave the candidate; plan 46 becomes a prerequisite."
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:46:05Z
      mode: "update"
      note: "Three-adapter candidate without MessageDB or plan 36; plan 46 prerequisite and GC suite cell; Milestone 1 fixes the core version and verifies adapter bounds."
---

# Certify the integrated lifecycle release candidate

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Produce a defensible release decision for one exact set of core, metrics, and adapter revisions. Completion means all required behaviors and performance budgets have evidence, not a promise that no unknown bug can exist.


## Progress


- [ ] Milestone 1: Freeze an exact compatible candidate manifest.
- [ ] Milestone 2: Execute the full fault, restart and soak matrix.
- [ ] Milestone 3: Verify performance evidence and obtain independent review.
- [ ] Milestone 4: Validate and publish the release-readiness verdict without releasing packages.


## Surprises & Discoveries


None yet; implementation has not started.


## Decision Log


2026-09-19: Certify only a frozen, fully evidenced candidate; publishing and claims of universal bug freedom are outside the plan.


## Outcomes & Retrospective


To be filled during implementation. No remediation or certification is claimed by creation of this plan.


## Context and Orientation


The historical audit report docs/lifecycle-audit-progress.md records source inspection and targeted probes, not a live-service certification. Reviews in docs/reviews/ use docs/reviews/profile.dhall; capture fresh candidate reviews under that profile while preserving historical findings. The separate master docs/masterplans/5-post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity.md owns the GC hotfix and dependency/API compatibility work. This plan consumes those outcomes where applicable but does not republish packages or infer that a local release commit reached Hackage.

The baseline is the committed source audit in docs/lifecycle-audit-progress.md and docs/reviews/, not a completed fault-injection campaign. Source inspection, diagnostic reproduction, fixed code, and release verification are separate evidence levels. A finalizer is the adapter operation that acknowledges, retries, or dead-letters a handled delivery. At-least-once delivery allows replay after interruption; it does not permit silently skipping unresolved work. A timeout in a test is a failure bound, not evidence that production cleanup succeeded.

When this plan was drafted no local docs/adr corpus existed in the Shibuya repository; its first record, docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md, was added on 2026-09-20. It requires reachability-sensitive liveness to be tested in a separate process and treated as a release property, which makes both process-isolated GC suites mandatory matrix cells here. Before introducing durable interfaces, follow .agents/skills/exec-plan/ADR.md and record the decision using the then-current repository convention. Locate dependency sources with Mori before choosing APIs. Verify registry releases and upstream tags before changing dependency bounds. Registration-service-v2 is excluded.


## Plan of Work


Milestone 1 freezes a clean candidate manifest in docs/audits/lifecycle-release/candidates/ with exact core, metrics and three adapter revisions (Kafka, PGMQ and Kiroku), compiler/platform/service versions and dependency solution. The MessageDB adapter is deprecated, was excluded by the project owner on 2026-09-19 and is not part of the candidate. Fix the candidate core version in this milestone together with the release owner, from the accumulated diff under the Haskell Package Versioning Policy; new constructors on exported error types make it a major version. Then confirm that each adapter's committed Cabal bound on shibuya-core admits that version, asking the owning adapter plan to change it if not: every adapter currently pins the 0.9 series, and a relaxed bound in a temporary project does not qualify as clean committed source. Construct an isolated Cabal project using those sources. Reconcile compatibility from existing plans 34 and 35, and confirm completion of the standalone plan 46, by their paths listed in Interfaces; an adapter built against a different installed core cannot qualify. Verify authoritative released versions before selecting bounds and test declared supported dependency endpoints as well as the exact release solution. Source, dependency or configuration changes invalidate affected evidence.

Milestone 2 performs the complete boundary matrix established by the evidence plan. Run normal and forced-GC core tests, the latter meaning both process-isolated suites, the idle-application one and the finished-application one added by plan 46, the new metrics suite, each adapter's mock/property tests and actual Kafka/PostgreSQL integration tests against the same candidate. Exercise fault-before/fault-after acquisition, handler execution, acknowledgement, persistence and shutdown; include synchronous exceptions, asynchronous cancellation, timeouts, retries, duplicate callbacks, full queues, empty sources, batching and supervisor restart/stop. Check both StopAllOnFailure and IgnoreFailures. Use at least 100 schedule repetitions and 1,000 seeded model cases per covered model, with recorded seeds and fixed -N1/-N4 configurations on capable hosts. Run 30-minute adapter soaks and restart with an external delivery ledger; every input must be terminally handled or still recoverable according to its documented contract. Record all skipped matrix cells as gaps.

Milestone 3 consumes the performance plan's matched candidate verdict; rerun on any hot-path change since measurement. Review the entire lifecycle surface again, including modules with no original finding, and assess security-adjacent input validation, resource bounds and externally visible status. Have a reviewer other than the fix author inspect diffs, tests, uncovered boundaries and performance evidence in a separate review session. Record findings using the OKF review profile and reopen the owning child for any blocking defect. Never mark a source-only suspicion resolved just because nearby tests pass.

Milestone 4 runs the release validator and writes docs/audits/lifecycle-release/release-verdict.md. Require every finding to be fixed with red/green evidence, disproved with reproducible evidence, or explicitly accepted by a named human release owner with scope/expiry. Require every mandatory boundary, live-service and performance gate to pass. Unresolved high-severity loss/hang defects block comprehensive signoff; any emergency hotfix scope reduction must be a separate human decision and must not be labeled comprehensive approval. List the MessageDB adapter under unsupported configurations as deprecated and uncertified, with its REV-12 findings shown as out of scope by the owner's decision, not as resolved. Include residual risks, unsupported configurations, upgrade/replay implications, rollback constraints and exact next release actions. Distill durable decisions into ADRs and update IR-6/review closure links and the master registry. Publishing or deploying remains a separate authorized release task.


## Concrete Steps


Run local commands from the Shibuya repository root unless the command block explicitly directs a change to a Mori-resolved project. New validator and comparator commands become available when their owning milestones implement them. Use the repository development shell if the compiler or services are missing; an unavailable dependency in offline mode requires an approved fetch, not removal of the test.

```bash
cabal build all --offline
cabal test shibuya-core shibuya-metrics --offline --test-show-details=failures
cabal run shibuya-core-bench:prod-stress
okf validate docs/reviews --strict --profile docs/reviews/profile.dhall --profile-enforce --log-enforce
bun scripts/audit/validate-evidence.ts --release docs/audits/lifecycle-release/candidates/release-candidate.json
```

Successful suites exit zero and report executed tests; zero tests or skipped services are not acceptance. Record exact selectors and fixture commands in this section when the harness is extended.


## Validation and Acceptance


The release validator exits zero only for the exact tested candidate, with no mandatory skipped tests, unowned findings, stale evidence or missing performance gate. All adapters have durable restart evidence, not only mocks. A deliberately stale SHA, unresolved finding or failed performance result makes validation fail. The final verdict names the independent reviewer, remaining risks and scope; it does not assert all possible bugs have been eliminated.

Use STM barriers or injected hooks to control interleavings; sleeps alone do not prove ordering. Assert terminal outcomes and resource ownership, not just logs. For every reproduced defect, record a failing regression against the affected implementation and a passing run against the fix; use an isolated worktree or mutation, never overwrite the working tree. Keep source-only suspicions labeled unconfirmed until reproduced or disproved. Record exact source SHAs, dependency solution, compiler, commands, random seeds, and logs in the EP-37 evidence format. Passing tests with a skipped service-dependent suite do not count as integration evidence.


## Idempotence and Recovery


Work on the current branch, preserve unrelated edits, and commit small conventional changes with MasterPlan, ExecPlan, and Intention trailers from this plan's frontmatter. Repeating unit tests and validation is safe. Use uniquely named ephemeral broker/database resources, never production endpoints or shared database reset commands. Bracket fixture cleanup and retain failed-run logs before deleting only identified fixture resources. Revert an identified implementation commit only with authorization; do not reset the checkout. Missing services or unavailable dependencies remain explicit blockers, not passes.


## Interfaces and Dependencies


Hard dependencies: docs/plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md, docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md, docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md, docs/plans/40-prevent-kafka-acknowledgements-from-skipping-unresolved-deliveries.md, docs/plans/41-verify-pgmq-acknowledgement-and-dead-letter-recovery-under-faults.md, docs/plans/43-make-kiroku-subscription-ownership-exception-safe.md, docs/plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md. docs/plans/42-repair-messagedb-checkpoint-and-shutdown-lifecycle-semantics.md is cancelled and is not a dependency. Existing external prerequisites within this repository are docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md, the standalone urgent fix for the REV-16 supervisor-link defects, which must be complete and whose two tests must pass on the candidate, and docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md and docs/plans/35-align-adapter-effectful-bounds-and-releases-with-shibuya-core-0-9-0-3.md wherever their compatibility/bound decisions are needed; verify actual completion rather than duplicating their release actions. This plan owns candidate assembly, integrated evidence and new OKF review records; EP-37 owns validation schema, EP-45 owns performance verdicts, remediation children own fixes. Relevant Kiroku checkpoint constraints remain mori://shinzui/kiroku/okf/adrs/concepts/ADR-4: preserve existing rows and monotonic saves.


## Revision Notes


2026-09-20 UTC: Revised after a pre-implementation review of the parent MasterPlan. Removed the MessageDB adapter, its cancelled remediation plan and its compatibility plan 36 from the candidate and the dependency list at the project owner's direction, while requiring the verdict to name that adapter as uncertified. Added the standalone plan 46 as an external prerequisite and its finished-application GC suite as a mandatory matrix cell. Made Milestone 1 responsible for fixing the candidate core version with the release owner and for checking that the adapters' committed bounds admit it, because all three currently pin the 0.9 series and the drafted plan would have discovered that only when the candidate failed to solve. Noted the repository's new first ADR.
