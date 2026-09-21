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
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T03:00:00Z
      mode: "implement"
      note: "Started candidate certification and made the property and schedule execution budgets mechanically enforceable."
---

# Certify the integrated lifecycle release candidate

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Produce a defensible release decision for one exact set of core, metrics, and adapter revisions. Completion means all required behaviors and performance budgets have evidence, not a promise that no unknown bug can exist.


## Progress


- [x] (2026-09-21 13:41Z) Milestone 1: Freeze an exact compatible candidate manifest.
- [x] (2026-09-21 13:41Z) Milestone 2: Execute the full fault, restart and soak matrix.
- [ ] Milestone 3: Verify performance evidence and obtain independent review.
- [ ] Milestone 4: Validate and publish the release-readiness verdict without releasing packages.


## Surprises & Discoveries


2026-09-21: Two core property workloads imposed local `withMaxSuccess` caps of 30 and 50.
Those caps take precedence over Hspec's release-run `--qc-max-success=1000` option, so an
apparently compliant command would have executed fewer cases than the evidence budget. The
local caps are removed for the candidate harness; ordinary runs use Hspec's normal default,
while the release command supplies and records 1,000 cases and its seed.

2026-09-21: The Kafka flake's generated default package pointed `callCabal2nix` at the
multi-package repository root, which contains no Cabal file. Correcting the package path then
exposed stale nixpkgs selections for the released Kafka, Shibuya, Streamly, and OpenTelemetry
packages. Pinning their authoritative Hackage releases makes `nix build .#default` and
`nix flake check` pass. The flake builds the distributable library without its tests while
Shibuya 0.10 remains unpublished; the separate cross-repository candidate project owns and
has passed the tests against the unreleased lifecycle API.

2026-09-21: The unified production cohort solves at the exact frozen versions, but enabling
every repository's test helpers in one Cabal plan introduces a test-only `pg-migrate` conflict:
Kiroku selects the authoritative 1.2 release while `pgmq-migration` still pins 1.1. Mori source
inspection confirmed that the 1.2 core release has no API or behavior change. Certification
therefore uses one unified production solve plus the owning repositories' exact local-source
test projects; it does not weaken either test dependency bound merely to make an artificial
all-tests plan solve.

2026-09-21: Release preparation changes after EP-45 touched no production source tree in Core,
Metrics, Kafka, PGMQ, Kiroku Store, or the Kiroku adapter. EP-45's matched performance verdict
is therefore carried forward under Milestone 3's explicit no-hot-path-change rule. The
candidate-bound attestation records both the measured and frozen SHAs and both solver hashes;
it does not rewrite the identity embedded in the original measurements.


## Decision Log


2026-09-19: Certify only a frozen, fully evidenced candidate; publishing and claims of universal bug freedom are outside the plan.

2026-09-21: Control property-case counts at the test-runner boundary and remove lower
per-property caps. Candidate evidence uses `--ignore-dot-hspec --qc-max-success=1000` with an
explicit seed, so user configuration cannot silently lower the release budget.

2026-09-21: Treat Kafka's portable flake build and its cross-repository candidate tests as
distinct release gates until the candidate core is published. The flake must use released,
content-addressed Hackage inputs and prove the distributable library builds; the candidate
Cabal project must compile and run the adapter tests against the exact local core. Neither
gate substitutes for the other.

2026-09-21: Release Core and Metrics as 0.10.0.0 because exported lifecycle error constructors
make the accumulated change PVP-major. Coordinate adapter patch releases at Kafka 0.9.0.2,
PGMQ 0.16.0.1, Kiroku Store 0.8.0.2, and the Kiroku adapter 0.5.1.3, with committed Core 0.10
bounds. This decision freezes source candidates; Hackage uploads, tags, and pushes remain
outside this certification plan.

2026-09-21: Carry forward the completed EP-45 measurements because byte-level production-tree
diff checks are empty between every measured revision and frozen release revision. Bind that
decision to the new solver-plan hash in a separate attestation, while retaining the original
measurement hash and raw artifacts unchanged.

2026-09-21: Accept REV-15-L1 as a named, bounded residual risk for Shibuya 0.10.x. Release
owner Nadeem Bitar accepted the risk through 2026-12-31 or before 0.11.0.0, whichever occurs
first, provided callers bound caller-controlled distinct batch-key cardinality and release
documentation states the measured finite-range 703-byte-per-key envelope. This is an
acceptance, not a waiver or an implementation-enforced key limit.


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

2026-09-21 UTC: Started implementation after EP-45 completed. Removed two local QuickCheck case
caps that would have silently overridden the 1,000-case release command, and added a deterministic
runner that records every one of the eight schedule-sensitive selectors across 100 seeds under
both N1 and N4. The normal core suite and both isolated GC suites pass after the harness change.
Candidate version/bound edits remain pending the explicit release-owner version decision.

2026-09-21 UTC: Repaired the Kafka release gates in
`mori://shinzui/shibuya-kafka-adapter`. Commit `d2725ba` raises its deterministic
acknowledgement reference model from 10 to 1,000 replayable seeds; the full candidate-core suite
passes against live Kafka. Commit `35a3e41` points the default Nix package at the actual adapter
subdirectory and pins the released dependency compatibility set. `nix build .#default`,
`nix flake check`, and formatting pass. This closes the pre-existing broken-default-output
obligation, but does not freeze Milestone 1: the core version and all three committed adapter
bounds still require the release owner's decision.

2026-09-21 UTC: Completed the version-neutral EP-34 compatibility gates. The current core,
tests, examples, and benchmark components depend directly on `effectful-core` and accept
2.6.1.0 plus 2.7.1.1 or later while rejecting 2.7.1.0. The all-package build, all core/GC and
metrics suites, package check, formatting, and flake checks pass. The release skill now runs
performance comparison for any runtime-bound change, including a patch. EP-34 publication and
EP-35's adapter bounds remain coordinated with the candidate version decision.

2026-09-21 UTC: Completed EP-35's version-neutral adapter compatibility gates. Kafka
`1c455b5`, PGMQ `9247388`, and Kiroku `0dcd092` plus `f91bb05` admit effectful-core 2.6.1.0
and 2.7.1.2 while rejecting 2.7.1.0. Their live-service suites, Kiroku's store suite, package
checks, formatting, and flakes pass. A combined local-source cohort solve proves the same
accepted/rejected families. Publications remain pending and do not block source assembly once
the candidate Core version is fixed.

2026-09-21 UTC: Froze the release candidate at Core/Metrics
`ecccecce14e9a9d4a2a6dd4c31efcad74d0ce67c`, Kafka
`74fed7e8df366072b0587c4bdae8d4e92317c8a3`, PGMQ
`9c709d76b8c1e66a45148888970d5518cc3c0d7e`, and Kiroku
`246a27b6e7ac55fbd7c7a66e8ad84a3b3f46237e`. The unified production solve has SHA-256
`847a62275e285f674d42a4203b4ec05fd4f7b1e3f4972bcbae1cacf8264f4d56`. Exact frozen-source
N1/N4 runs pass 236 Core examples with eight 1,000-case models, 48 Metrics examples, both
process-isolated GC suites, 53 Kafka tests against Redpanda, 177 PGMQ tests against ephemeral
PostgreSQL, and 308 Kiroku Store plus 38 Kiroku adapter examples. The deterministic scheduler
artifact passes all 1,600 executions. All 70 mandatory matrix cells and 47 in-scope finding
records are present in `docs/audits/lifecycle-release/candidates/release-candidate.json`.
Release owner Nadeem Bitar subsequently accepted REV-15-L1 for Shibuya 0.10.x through
2026-12-31 or before 0.11.0.0, whichever occurs first, with the recorded caller-side cardinality
control and release-note disclosure. The release validator then passed all 52 findings, 15
boundaries, and 70 mandatory cells. A deliberately stale candidate SHA fails all five evidence
runs, proving the negative control. Independent review is still required before Milestones 3
and 4 can close.
