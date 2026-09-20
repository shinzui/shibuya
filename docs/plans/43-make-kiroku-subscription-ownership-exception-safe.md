---
id: 43
slug: make-kiroku-subscription-ownership-exception-safe
title: "Make Kiroku subscription ownership exception safe"
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
      verdict: "comments"
      note: "REV-13 claims re-verified at unchanged HEAD; ADR-4 resolves; nothing is gated on core; adapter bounds shibuya-core <0.10."
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:46:05Z
      mode: "update"
      note: "Core plan becomes an integration-only soft dependency; record core <0.10 bound handling; owner marks adapter critical."
---

# Make Kiroku subscription ownership exception safe

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Ensure every acquired Kiroku subscription is either transferred to a live processor or stopped, including cancellation between group members and failures while cleaning up.


## Progress


- [ ] Milestone 1: Reproduce member acquisition and cleanup ownership gaps.
- [ ] Milestone 2: Implement exception-safe group ownership transfer.
- [ ] Milestone 3: Verify acknowledgement and checkpoint recovery with the real store.


## Surprises & Discoveries


None yet; implementation has not started.


## Decision Log


2026-09-19: Fix ownership without weakening monotonic checkpoints or silently redefining normal cancellation replay as exactly-once processing.


## Outcomes & Retrospective


To be filled during implementation. No remediation or certification is claimed by creation of this plan.


## Context and Orientation


The owning repository is mori://shinzui/kiroku. Project-relative paths (artifact-level source URIs pending) are shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs, shibuya-kiroku-adapter/test/Main.hs and kiroku-store/src/Kiroku/Store/Subscription/Stream.hs. REV-13 records source-only ownership risks between successful member creation and recursive group construction, and cleanup aborting after the first throwing shutdown. On 2026-09-20 the repository's HEAD was still the reviewed commit 758b81a, and both were confirmed in `kirokuConsumerGroupProcessorsWith`: `onException` wraps only the next `mkMemberAdapter` call, and `shutdownCreated` is a plain `mapM_`; recheck before starting. The project owner has called this adapter critical. The bridge uses an acknowledgement reply variable and a closed-state signal; cancelling before checkpoint persistence can legitimately replay. The accepted decision mori://shinzui/kiroku/okf/adrs/concepts/ADR-4 says missing-checkpoint initialization is explicit, existing checkpoints win, normal saves are monotonic, and reset is a separate intentional operation.

The baseline is the committed source audit in docs/lifecycle-audit-progress.md and docs/reviews/, not a completed fault-injection campaign. Source inspection, diagnostic reproduction, fixed code, and release verification are separate evidence levels. A finalizer is the adapter operation that acknowledges, retries, or dead-letters a handled delivery. At-least-once delivery allows replay after interruption; it does not permit silently skipping unresolved work. A timeout in a test is a failure bound, not evidence that production cleanup succeeded.

When this plan was drafted no local docs/adr corpus existed in the Shibuya repository; its first record, docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md, was added on 2026-09-20. It concerns linked threads and garbage-collection liveness tests in core; its testing rule, that a liveness test must not retain the object under test through its own cleanup, is worth applying to the subscription-leak tests here. Before introducing durable interfaces, follow .agents/skills/exec-plan/ADR.md and record the decision using the then-current repository convention. Locate dependency sources with Mori before choosing APIs. Verify registry releases and upstream tags before changing dependency bounds. Registration-service-v2 is excluded.


## Plan of Work


Milestone 1 introduces deterministic acquisition/transfer hooks in adapter tests without exposing them as public API. Cancel immediately after acquiring member one and before registering it or starting member two; separately make member two acquisition fail and make one cleanup action throw. Assert that all successfully acquired subscriptions become stopped. Reproduce the ownership gaps or document why current dependencies already close them.

Milestone 2 brackets group construction with a masked ownership ledger, restoring interruptibility around subscription startup and database work. Transfer ownership atomically relative to cancellation; on failure, attempt all acquired-member shutdowns and retain the primary failure. Do not change Kiroku's checkpoint SQL or initialization policy as an incidental adapter fix. Audit single-member ownership and idempotent shutdown using the same invariants.

Milestone 3 runs real ephemeral-store tests for handler success, retry, halt, duplicate replies, source error, cancellation before/after reply, and shutdown during checkpoint persistence. Observe whether the last event was saved and replayed on restart; assert no unacknowledged event is skipped and no subscription thread remains. Test preexisting checkpoints and missing-checkpoint startup policies to preserve the accepted ADR, and correct adapter documentation that says handler exceptions are never finalized when core converts them to retry.

Before closing this plan, supply focused before/after performance evidence for its changed paths using docs/plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md. Baseline capture is an early coordination requirement, not a reason to defer all measurement until release. Correctness and performance must both pass; the performance plan owns budgets and harnesses.


## Concrete Steps


Run local commands from the Shibuya repository root unless the command block explicitly directs a change to a Mori-resolved project. New validator and comparator commands become available when their owning milestones implement them. Use the repository development shell if the compiler or services are missing; an unavailable dependency in offline mode requires an approved fetch, not removal of the test.

```bash
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
mori path mori://shinzui/kiroku/okf/adrs/concepts/ADR-4
mori path mori://shinzui/kiroku
# Change to the resolved project root, then:
cabal test shibuya-kiroku-adapter --test-show-details=direct
```

Successful suites exit zero and report executed tests; zero tests or skipped services are not acceptance. Record exact selectors and fixture commands in this section when the harness is extended.


## Validation and Acceptance


Cancellation at each construction transfer leaves zero owned subscriptions running. One cleanup exception does not skip other members. Duplicate acknowledgements do not advance twice. Restart replays unpersisted work without skipping it, preserves existing checkpoints, and obeys the configured missing-checkpoint policy. Tests distinguish replay from resource leakage.

Use STM barriers or injected hooks to control interleavings; sleeps alone do not prove ordering. Assert terminal outcomes and resource ownership, not just logs. For every reproduced defect, record a failing regression against the affected implementation and a passing run against the fix; use an isolated worktree or mutation, never overwrite the working tree. Keep source-only suspicions labeled unconfirmed until reproduced or disproved. Record exact source SHAs, dependency solution, compiler, commands, random seeds, and logs in the EP-37 evidence format. Passing tests with a skipped service-dependent suite do not count as integration evidence.


## Idempotence and Recovery


Work on the current branch, preserve unrelated edits, and commit small conventional changes with MasterPlan, ExecPlan, and Intention trailers from this plan's frontmatter. Repeating unit tests and validation is safe. Use uniquely named ephemeral broker/database resources, never production endpoints or shared database reset commands. Bracket fixture cleanup and retain failed-run logs before deleting only identified fixture resources. Revert an identified implementation commit only with authorization; do not reset the checkout. Missing services or unavailable dependencies remain explicit blockers, not passes.


## Interfaces and Dependencies


Hard dependency: docs/plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md. Soft dependency: docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md, for integration only: nothing in this plan is gated on a core milestone, because group construction and cleanup happen before core owns the processors, so this plan starts as soon as the evidence plan is complete. This plan owns the Kiroku adapter and its tests in mori://shinzui/kiroku, not the database checkpoint contract. Obtain required cross-workspace write permission. Core owns processor lifetime; the adapter owns subscription acquisition until explicit transfer. Changes to the store bridge, if unavoidable, require a separately recorded rationale and tests in the owning project. Coordinate effectful bounds with docs/plans/35-align-adapter-effectful-bounds-and-releases-with-shibuya-core-0-9-0-3.md. The adapter's committed Cabal file bounds shibuya-core as `>=0.9 && <0.10`, and the candidate core is expected to carry a new major version because the core plan adds constructors to exported error types. Build against the candidate in a temporary Cabal project that lists the candidate core checkout and this adapter as packages and relaxes only that bound, for example with `allow-newer: shibuya-kiroku-adapter:shibuya-core`; never commit the relaxation. Change the committed bound once, in the adapter's repository and as part of this plan, when Milestone 1 of docs/plans/44-certify-the-integrated-lifecycle-release-candidate.md fixes the candidate core version with the release owner, because final evidence must come from clean committed sources.


## Revision Notes


2026-09-20 UTC: Revised after a pre-implementation review of the parent MasterPlan. The core lifecycle plan changed from a hard dependency to an integration-only soft one, because the group-construction ownership defect sits entirely before core takes ownership. Recorded the adapter's 0.9-series bound on shibuya-core and how to build against a major-version candidate. Recorded that the review's source claims were re-verified against the repository's unchanged HEAD, that the owner considers this adapter critical, and the Shibuya repository's new first ADR.
