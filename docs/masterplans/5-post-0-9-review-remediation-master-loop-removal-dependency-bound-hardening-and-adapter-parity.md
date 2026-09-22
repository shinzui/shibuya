---
id: 5
slug: post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity
title: "Post-0.9 review remediation: master loop removal, dependency bound hardening, and adapter parity"
kind: master-plan
created_at: 2026-09-16T23:04:43Z
intention: intention_01m2ycc3fxedxtw5339e0efzy1
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-16T23:04:43Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-20T03:01:18Z
      mode: "update"
      note: "Synchronize EP-33 regression milestone, both-suite release gate, provisional version target, and unchanged MLS-only consumer scope."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T03:15:22Z
      mode: "update"
      note: "Synchronize EP-1 patch release target and active intention"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T13:46:21Z
      mode: "update"
      note: "Move EP-2's provisional release target to 0.9.0.4 after standalone EP-46 published 0.9.0.3"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-09-22T17:29:05Z
      mode: "update"
      note: "Refresh to published state: EP-2/EP-3 complete via 0.10 cohort, EP-4 cancelled, ADRs 0005/0006, final retrospective"
---

# Post-0.9 review remediation: master loop removal, dependency bound hardening, and adapter parity

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

**Status as of 2026-09-22: Complete.** EP-1 shipped in shibuya-core 0.9.0.2. EP-2 and EP-3
shipped in the lifecycle release cohort published on 2026-09-22 (shibuya-core and
shibuya-metrics 0.10.0.0, shibuya-kafka-adapter 0.9.1.0, shibuya-pgmq-adapter 0.16.1.0,
kiroku-store 0.8.0.2, shibuya-kiroku-adapter 0.5.1.3), not in the separate patch releases this
plan originally scheduled. EP-4 is Cancelled because the project owner deprecated the
MessageDB adapter on 2026-09-19. The durable decisions are recorded in ADRs 0005 and 0006.


## Vision & Scope

This initiative closes the issues found by a review, on 2026-09-16, of every change made to
shibuya and its adapters since the `v0.8.0.1` release of 2026-07-04. The review covered
shibuya-core and shibuya-metrics 0.9.0.0 and 0.9.0.1 (application-defined dead-letter reasons,
the effectful 2.7 bound, the seihou nix migration), shibuya-pgmq-adapter 0.12.0.0 through
0.16.0.0 (idle-stream shutdown fix, pgmq-hs 0.4/0.5/0.6, structured dead-letter payloads,
grouped-head FIFO polling), shibuya-kafka-adapter 0.9.0.0 and 0.9.0.1 (dead-letter rendering,
effectful-core 2.7 bound, a whitespace-and-comment-only reformat), and the kiroku-hosted
shibuya-kiroku-adapter 0.5.1.0 and 0.5.1.1 (core 0.9 upgrade with a total reason match). The
code in those releases was correct as far as the review could determine: the dead-letter changes
are gated behind the disabled-tracing short circuit, the pgmq shutdown gate reorder is right,
the grouped-head dispatch is covered by mutation-checked tests, and a hot-path benchmark run
during the review shows effectful 2.7.1 at parity with 2.6.1 (the numbers are recorded in
`docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md`).

The review found four problems. This MasterPlan coordinated the fixes. What happened to each
is recorded below.

First, a bare `runApp` followed by `waitApp` crashed at the first major garbage collection
with `ExceptionInLinkedThread ... thread blocked indefinitely in an STM transaction`, because
the master started a linked actor loop that nothing ever sent to. This was not a regression of
the 0.9 releases; commit `f364183` first shipped it in 0.8.0.0. EP-1
(`docs/plans/33-remove-the-idle-linked-master-loop-that-deadlocks-bare-waitapp-callers.md`, an
existing plan adopted as a child) removed the actor, added a process-isolated regression suite,
and shipped the fix as 0.9.0.2. Resolved.

Second, the effectful bounds that core 0.9.0.1 and the Kafka adapter's 0.9.0.1 widened to `<2.8`
admitted `effectful-core` 2.7.0.0 and 2.7.1.0. Those are the two releases whose changelog
records a per-operation overhead regression for dynamically dispatched effects, fixed in
2.7.1.1. Every adapter's queue effect (`Pgmq`, `KafkaConsumer`) is dynamically dispatched. The
bump also went out as a patch, which skipped the benchmark gate. Meanwhile the pgmq and kiroku
adapters excluded effectful 2.7 entirely. EP-2 and EP-3 put one exclusion range into every
package, keyed the release benchmark gate to runtime-dependency changes, and all of it is now
published. Resolved.

Third, shibuya-message-db-adapter was stranded on `shibuya-core ^>=0.5.0.0` and could not build
against any current core. EP-4 planned the migration. On 2026-09-19 the project owner declared
that adapter deprecated, so EP-4 was cancelled. The adapter remains unsupported and uncertified
at core 0.10. Not resolved, by deliberate decision.

The target end state, as reached: an idle single-processor worker runs for as long as its
processors do. shibuya-core, the pgmq adapter, the Kafka adapter, and the kiroku adapter build
together on effectful 2.6.1 or on effectful 2.7.1.1 and later, and none of them can resolve to
the regressed effectful-core releases. Runtime-dependency bumps are benchmark-gated whatever
their release level.

Deliberately excluded, because each is already documented as accepted or is separately
planned: the pgmq prefetch buffer stranding up to `bufferSize * batchSize` messages invisible
at shutdown (accepted and bounded by a regression guard in
`mori://shinzui/shibuya-pgmq-adapter/plans/3-prototype-re-enabling-pgmq-prefetch-via-scoped-concunlift`);
removal of the legacy `dead_letter_reason` payload field (gated by
`mori://shinzui/shibuya-pgmq-adapter/plans/6-remove-the-legacy-dead-letter-reason-field-after-structured-rollout`);
Kafka static membership support
(`mori://shinzui/shibuya-kafka-adapter/plans/15-support-kafka-static-membership-deployments`, a
feature, not a defect); the residual roughly twenty percent `Async` allocation overhead accepted
in `docs/plans/30-investigate-and-reduce-the-async-ahead-concurrency-allocation-regression.md`;
and a `shibuya.dead_letter.reason.code` attribute on batch spans, which
`docs/user/migrating-to-0.9.md` states is intentionally absent because one batch can carry
several different reasons. Consumers other than the `mls-service-v2` follow-up named in plan 33
are also out of scope. Since 2026-09-19 the MessageDB adapter is out of scope as well (see
Decision Log).


## Decomposition Strategy

The work split by functional concern into four child plans:

- a runtime crash fix in the core (the master loop);
- dependency and release-process hardening in the core (bounds and the release gate);
- the same hardening applied to the three maintained adapters;
- a multi-version API migration of the one adapter that had fallen behind.

Each had its own acceptance check: a garbage-collection regression test that failed before the
fix and passed after it; a cabal solve that rejects the regressed effectful-core versions and
accepts the fixed ones; a combined solve of core plus adapters on both effectful families; and
a message-db adapter test suite passing against core 0.9 with an `ApplicationFailure` round-trip.
The first three were met. The fourth was cancelled.

Alternatives considered at creation. Folding the bound change into plan 33 would have kept one
release but widened a plan scoped to a single defect, so the two core plans were kept separate.
One child plan per adapter repository was rejected: each adapter change was a bound edit and a
changelog line, and one plan with a milestone per adapter kept the bound expression identical
across all three. Folding the message-db upgrade into the adapter alignment plan was rejected
because it was a four-major-version API migration with its own database test harness.
Cancelling the message-db adapter was left to the maintainer, who later made that call.

The release plan was not followed as written. Every schedule here assumed patch releases on
the 0.9 line. In practice the lifecycle initiative,
`docs/masterplans/6-comprehensive-lifecycle-remediation-and-release-assurance.md`, prepared a
breaking 0.10.0.0 candidate across the same repositories at the same time. EP-2's and EP-3's
tested bound commits were carried into that candidate rather than published as 0.9.0.4 and
adapter patches (see Decision Log).

ADRs: this repository had no `docs/adr/` directory when the plan was created, and it still has
no profile-governed OKF bundle, so ADRs follow the plain filesystem convention of
`docs/adr/0001-*.md`. Relevant records:

- `docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md`, written by EP-1 and
  amended by the standalone plan 46, covers the linked-actor and GC-liveness decision.
- `docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md`, written by the
  lifecycle initiative, governs the candidate that shipped EP-2 and EP-3.
- `docs/adr/0005-exclude-regressed-effectful-core-releases-in-every-package.md`, written at this
  plan's completion, records the exclusion range and why every package carries it.
- `docs/adr/0006-benchmark-gate-runtime-dependency-changes-regardless-of-release-level.md`,
  written at this plan's completion, records the release-gating rule.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Remove the idle linked master loop that deadlocks bare waitApp callers | docs/plans/33-remove-the-idle-linked-master-loop-that-deadlocks-bare-waitapp-callers.md | None | None | Complete (released 0.9.0.2) |
| 2 | Harden shibuya-core dependency bounds and release gating for effectful 2.7 | docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md | None | None | Complete (released in 0.10.0.0) |
| 3 | Align adapter effectful bounds and releases with shibuya-core 0.9.0.3 | docs/plans/35-align-adapter-effectful-bounds-and-releases-with-shibuya-core-0-9-0-3.md | None | EP-1, EP-2 | Complete (released in the 0.10 adapter cohort) |
| 4 | Upgrade shibuya-message-db-adapter to shibuya-core 0.9 and structured dead-letter reasons | docs/plans/36-upgrade-shibuya-message-db-adapter-to-shibuya-core-0-9-and-structured-dead-letter-reasons.md | None | EP-1 | Cancelled (MessageDB adapter deprecated, owner decision 2026-09-19) |

Status values: Not Started, In Progress, Complete, Cancelled; parenthetical notes describe the current milestone.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).
Plan 35's title and file name still say "0.9.0.3". They are kept so the plan's identity and
existing references stay stable; its body records the versions that actually shipped.


## Dependency Graph

No child plan depended on another at the compiler level, so there were no hard dependencies.
The constraints were about release order. This is how the releases actually went:

1. 2026-09-20: EP-1 shipped shibuya-core and shibuya-metrics 0.9.0.2, the master-loop fix.
2. 2026-09-20: the standalone plan
   `docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md`,
   which is not a child of this MasterPlan, shipped 0.9.0.3 for an urgent supervisor-link fix.
3. 2026-09-21: EP-2 finished its bound, benchmark-policy, and evidence milestones (commits
   `16625ff`, `a1bf986`, `df24b8a`), and EP-3 finished its adapter bounds and combined solve.
   Neither was published at that point, because the same repositories were about to take the
   breaking lifecycle candidate.
4. 2026-09-22: the lifecycle initiative's certification plan,
   `docs/plans/44-certify-the-integrated-lifecycle-release-candidate.md`, published the
   cohort in this order: core 0.10.0.0, metrics 0.10.0.0, Kafka 0.9.1.0 and pgmq 0.16.1.0,
   kiroku-store 0.8.0.2, then shibuya-kiroku-adapter 0.5.1.3. Every one of those packages
   carries the EP-2 range.

EP-4 was cancelled before it started, so it never took part in any release.


## Integration Points

The core version, `shibuya-core/shibuya-core.cabal`, and the changelog were touched by EP-1 and
then EP-2. EP-1 owned 0.9.0.2. EP-2's changelog entry went out under the `## 0.10.0.0` heading
of `shibuya-core/CHANGELOG.md`, and the version bump was owned by EP-44.

The effectful-core bound expression is owned by EP-2 and was copied verbatim by EP-3:

```text
effectful-core (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8)
effectful >=2.6.1 && <2.8        -- only where a package depends on the umbrella package
```

It is now present in every released component of shibuya-core, shibuya-example,
shibuya-core-bench, `mori://shinzui/shibuya-pgmq-adapter`, `mori://shinzui/shibuya-kafka-adapter`,
and `mori://shinzui/kiroku` (both `kiroku-store` and `shibuya-kiroku-adapter`).
`docs/adr/0005-exclude-regressed-effectful-core-releases-in-every-package.md` owns it from now
on. Change the ADR first, then every package.

EP-2 changed the release skill's benchmark gate in step 5 of `.agents/skills/release/SKILL.md`.
EP-1 had already changed the same skill's core test gate to `cabal test shibuya-core`, which
selects all core suites. EP-2 kept that gate. The rule is recorded in
`docs/adr/0006-benchmark-gate-runtime-dependency-changes-regardless-of-release-level.md`.

EP-4 was going to consume the structured dead-letter projections `deadLetterReasonCode`,
`deadLetterReasonDetail`, and `renderDeadLetterReason` in
`shibuya-core/src/Shibuya/Core/Ack.hs`. It was cancelled, so no plan here consumes them.


## Progress

- [x] (2026-09-20 UTC) EP-1: dedicated garbage-collection regression test compiles and fails with the linked STM exception on 0.9.0.1
- [x] (2026-09-20 UTC) EP-1: master loop, mailbox, and `MasterMessage` removed; suite green
- [x] (2026-09-20 UTC) EP-1: documentation no longer describes the master as an actor
- [x] (2026-09-20 UTC) EP-1: shibuya-core and shibuya-metrics 0.9.0.2 released with the runtime fix
- [x] (2026-09-20 UTC) EP-1: `mls-service-v2` single-processor subcommands run past the crash point
- [x] (2026-09-21 UTC) EP-2: effectful-core exclusion bound applied to shibuya-core, shibuya-example, and shibuya-core-bench; both effectful families still build
- [x] (2026-09-21 UTC) EP-2: release skill gates runtime-dependency bumps on the benchmark regardless of bump level
- [x] (2026-09-21 UTC) EP-2: 2.6.1-versus-2.7.1 and 2.7.1.0-versus-2.7.1.2 benchmark evidence recorded in the plan
- [x] (2026-09-22 UTC) EP-2: hardened bounds published in shibuya-core and shibuya-metrics 0.10.0.0 (superseding the provisional 0.9.0.4 patch)
- [x] (2026-09-22 UTC) EP-3: shibuya-pgmq-adapter bound widened and published in 0.16.1.0
- [x] (2026-09-22 UTC) EP-3: shibuya-kafka-adapter bound tightened and published in 0.9.1.0
- [x] (2026-09-22 UTC) EP-3: kiroku-store 0.8.0.2 and shibuya-kiroku-adapter 0.5.1.3 widened and published
- [x] (2026-09-21 UTC) EP-3: combined solve of core plus adapters proven on effectful 2.6.1 and 2.7.1.2, and rejected on 2.7.1.0
- [ ] EP-4: message-db adapter builds against shibuya-core 0.9 — Cancelled 2026-09-19 (adapter deprecated)
- [ ] EP-4: dead-letter metadata carries structured code and detail — Cancelled 2026-09-19
- [ ] EP-4: examples and tests migrated; 0.2.0.0 tagged — Cancelled 2026-09-19
- [x] (2026-09-22 UTC) ADR distillation: ADRs 0005 and 0006 written


## Surprises & Discoveries

- 2026-09-16: The review that produced this plan benchmarked the current tree under effectful
  2.6.1.0 and under effectful 2.7.1.0 with effectful-core 2.7.1.2 (the pair the 0.9.0.1 bound
  bump was tested with). tasty-bench reported every hot-path leaf as `same as baseline`; the
  full table is in EP-2. The regression the effectful-core changelog describes is therefore not
  present in the versions the cohort was built with, and the bound work is about what the
  bounds still admit, not about the shipped build.

- 2026-09-16: Two refinements of that measurement, both recorded in EP-2. First, effectful
  2.7.1 is not merely at parity: the `Async` hot-path leaf runs in less than half the time
  (roughly 55 ms against 122 ms) with 17% less allocation, confirmed by alternating re-runs.
  Second, a third build pinned to the regressed `effectful-core` 2.7.1.0 measured the same as
  2.7.1.2 on every leaf. That is expected, because nothing in shibuya-core is dynamically
  dispatched; the exclusion in EP-2 and EP-3 rests on the upstream changelog and on the
  adapters' queue effects being dynamic, and the core suite cannot confirm or refute it.

- 2026-09-16: The kiroku adapter's widening in EP-3 was conditional on `kiroku-store`, which
  declared `effectful-core >=2.4 && <2.7`. On 2026-09-21 EP-3 widened kiroku-store as well,
  first to a broad `<2.8` range that admitted the regressed releases, then to the disjoint
  range. kiroku-store 0.8.0.2 shipped it, which removed the blocker.

- 2026-09-19: The project owner declared the MessageDB adapter deprecated while reviewing the
  lifecycle MasterPlan. That cancelled
  `docs/plans/42-repair-messagedb-checkpoint-and-shutdown-lifecycle-semantics.md` and, with it,
  the only reason to run EP-4.

- 2026-09-20 UTC: EP-1's regression is `shibuya-core/test-gc/Main.hs`, a dedicated Cabal test
  executable. Weak-pointer cleanup could lose its target and leak threads into later tests;
  running it in its own process avoids keeping a handle alive just to clean it up. Normal
  core and release checks must select every core test suite. Removing only the idle master
  actor makes the test pass repeatedly, and the complete 212-example core suite stays green.

- 2026-09-20 UTC: EP-1 published shibuya-core and shibuya-metrics 0.9.0.2 with Haddocks,
  the annotated tag `v0.9.0.2`, and a GitHub release. At first the downstream MLS solver saw
  Hackage's package pages before its package index had caught up, and it correctly rejected
  0.9.0.2 until the index included the release. After the index advanced,
  `mori://tan/mls-service-v2` selected 0.9.0.2, passed its 282 tests, and its isolated worker
  ran past the crash point (consumer commit `536b107`).

- 2026-09-20 UTC: Plan 46's review of EP-1 found that the remaining NQE supervisor link still
  killed callers of *finished* applications during garbage collection. It shipped separately as
  0.9.0.3 and amended ADR 0001. EP-1's fix was correct but incomplete for that class of bug.

- 2026-09-21 UTC: The bound and release-policy work finished at the same moment the lifecycle
  initiative was freezing a breaking candidate across the same four repositories. Publishing
  0.9.0.4 plus three adapter patches first would have forced consumers through two cohort pin
  bumps in two days, and every adapter would have needed a fresh candidate. See Decision Log.

- 2026-09-22 UTC: Because the adapters also took core 0.10 bounds and lifecycle fixes, they
  shipped as minor releases (0.16.1.0, 0.9.1.0), not the patch numbers EP-3 had planned
  (0.16.0.1, 0.9.0.2). The kiroku adapter went from the planned 0.5.1.2 to 0.5.1.3 because of a
  packaging fix reviewed in REV-18.


## Decision Log

- Decision: Adopt the existing `docs/plans/33-…` as EP-1 instead of writing a new plan.
  Rationale: The defect is fully diagnosed there, with a failing-first regression test, and
  duplicating it would create two sources of truth for one change. Its frontmatter gains a
  `master_plan` field pointing here; its body is unchanged.
  Date: 2026-09-16

- Decision: Ship EP-1 and EP-2 in a single shibuya-core 0.9.1.0 release, with EP-2 forbidden
  from releasing on its own.
  Rationale: Two patch-sized releases a day apart cost consumers two pin bumps for no benefit.
  EP-2 is a bound and a process change; it has no reason to reach Hackage ahead of the crash fix.
  Date: 2026-09-16
  (Superseded 2026-09-20 by the sequential-patch decision below.)

- Decision: Put the effectful-core exclusion in every package's own bounds rather than only in
  shibuya-core or only in `cabal.project` constraints.
  Rationale: Project-level constraints do not reach consumers. shibuya-core's `effectful` bound
  alone cannot exclude effectful-core 2.7.1.0, because effectful 2.7.1.0 pins
  `effectful-core >=2.7.1.0 && <2.7.2.0`, which spans both the regressed and the fixed core.
  The adapters are the packages whose effects are dynamically dispatched, so they must carry
  the exclusion themselves; the core carries it too so that a consumer depending only on the
  core is protected. Promoted to
  `docs/adr/0005-exclude-regressed-effectful-core-releases-in-every-package.md`.
  Date: 2026-09-16

- Decision: Exclude the batch-span dead-letter code attribute, the pgmq prefetch shutdown
  strand, the legacy DLQ field removal, Kafka static membership, and the accepted `Async`
  allocation residual from this initiative.
  Rationale: Each is documented as intentional, accepted with a bounded guard, gated on
  adoption evidence, or a feature rather than a defect, in the plans cited under Vision & Scope.
  Re-litigating them here would not be a review finding.
  Date: 2026-09-16

- Decision: Include the kiroku-hosted adapter in EP-3 even though its repository has its own
  release cadence and cohort.
  Rationale: It is one of the maintained adapters and it excluded effectful 2.7; the plan could
  state the exact bound and the exact blocker (kiroku-store) so the kiroku cohort release that
  lifts it would be a documented follow-up rather than an unknown.
  Date: 2026-09-16

- Decision: No Intention ID is linked to this MasterPlan or its new child plans.
  Rationale: The initiative was created in an autonomous session with no user available to
  supply one.
  Date: 2026-09-16
  (Superseded 2026-09-20 by the intention link below.)

- Decision: Link the initiative and affected child plans to
  `intention_01m2ycc3fxedxtw5339e0efzy1`.
  Rationale: The user created this intention when implementation of EP-1 began; it supersedes
  the creation-time absence recorded above.
  Date: 2026-09-20 UTC

- Decision: Preserve the existing MLS-only consumer follow-up while refreshing EP-1.
  Rationale: The user explicitly excluded `mori://tan/registration-service-v2`.
  Its incident informed the investigation but does not expand implementation scope.
  Date: 2026-09-20 UTC

- Decision: Run the GC regression as a dedicated test process and preserve its release gate.
  Rationale: Cleanup must not accidentally keep the master alive. EP-1 owns this gate; EP-2's
  release-policy edits must keep it.
  Date: 2026-09-20 UTC

- Decision: Supersede the combined 0.9.1.0 release with sequential patches: EP-1 at 0.9.0.2
  and EP-2 provisionally at 0.9.0.3.
  Rationale: EP-1 was complete and was the initiative's most serious runtime defect, while EP-2
  had not started and was independent. The release skill classifies the internal-representation
  fix as a patch.
  Date: 2026-09-20 UTC

- Decision: Move EP-2's provisional release target from 0.9.0.3 to 0.9.0.4.
  Rationale: 0.9.0.3 was published on 2026-09-20 by the standalone plan
  docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md.
  EP-3's verification target moved with it. Plan 35's title and file name keep "0.9.0.3" for
  stable identity.
  Date: 2026-09-20
  (Superseded 2026-09-21 by the cohort decision below.)

- Decision: Cancel EP-4.
  Rationale: The project owner declared the MessageDB adapter deprecated on 2026-09-19 and
  limited supported adapters to Kafka, PGMQ, and Kiroku. Migrating it across four core majors
  would have cost a database-backed migration for code that will not ship. The lifecycle
  release verdict names it unsupported and uncertified. EP-4's body is kept as the migration
  recipe in case the adapter is ever revived. No other child depended on it.
  Date: 2026-09-19 (recorded here 2026-09-22)

- Decision: Publish EP-2's bounds in the lifecycle cohort (shibuya-core 0.10.0.0) and EP-3's
  adapter bounds in the matching adapter releases, instead of a separate 0.9.0.4 and adapter
  patches.
  Rationale: The bound commits were already tested and were independent of the version number.
  The lifecycle candidate was being frozen across the same repositories, and ADR 0002 requires
  a new candidate and fresh evidence for any dependency-solution change after freezing. A
  separate 0.9.x patch cohort would have cost consumers two pin bumps and re-run certification
  for no safety gain. EP-2's own benchmark evidence (Milestone 3) already covered the
  dependency swap. The cohort's paired N1/N4 performance matrix from
  `docs/plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md`
  then passed on the frozen candidate, whose single solver plan includes the bound.
  Date: 2026-09-21

- Decision: Close the initiative and promote its two durable decisions into ADRs 0005 and 0006.
  Rationale: Every non-cancelled child is published. The exclusion range and the gating rule
  will outlive these plans and govern every future bound change.
  Date: 2026-09-22


## Outcomes & Retrospective

**Final outcome (2026-09-22).** Three of four child plans are complete and published; one was
cancelled by owner decision. Measured against the vision:

- Idle-worker crash: fixed in 0.9.0.2. The failure class (a linked thread whose only waker is
  reachable only through a droppable handle) was fully closed by the standalone 0.9.0.3. ADR
  0001 records both.
- Effectful bounds: every supported package in the 0.10 cohort accepts effectful-core 2.6.1
  and 2.7.1.1 or later, and rejects 2.7.0.0 through 2.7.1.0. The rejection is proven by a
  combined solve and recorded in ADR 0005.
- Release gating: the release skill runs the benchmark for any runtime-dependency change,
  including patches, and compares old and new dependency versions on one tree. Recorded in
  ADR 0006.
- MessageDB adapter: not upgraded. It is deprecated and unsupported at core 0.10.

Gaps: the MessageDB adapter still declares `shibuya-core ^>=0.5.0.0`, and REV-12's findings
against it are still true. Its public repository does not yet say it is deprecated; that is
the owner's call. The exclusion itself is still backed by the upstream changelog and the
adapters being dynamically dispatched, not by an adapter benchmark on 2.7.1.0 (EP-2 recorded
that as optional).

Lessons:

- Every release number here was provisional, and three of them moved (0.9.1.0, 0.9.0.3,
  0.9.0.4, then 0.10.0.0). Plans that separated version-neutral milestones (bounds, tests,
  solves) from the publication milestone could absorb those moves without rework. The
  publication step is where the plans went stale.
- Two MasterPlans shipping through the same repositories need one release owner. This plan
  and the lifecycle plan each assumed they would own the next core release. The collision was
  resolved well, but by the candidate rather than by either plan.
- A crash fix proven by a regression test can still leave the bug class open. Plan 46 found
  the finished-application case that EP-1's test could not reach. Independent review of a
  liveness fix is worth its cost.

EP-1 detail: the idle actor is removed, the process-isolated GC regression passes repeatedly,
the pre-fix tree reproduces the crash, and the core build, test, and flake gates pass. 0.9.0.2
is public, and the MLS consumer pins it and survives the bounded isolated-worker observation.

Revision 2026-09-20 UTC: Synchronize EP-33's confirmed regression history, completed
failing-test milestone, isolated-test/release gate, and provisional release-version
coordination. The core fix and all publication/consumer milestones remain pending;
the user-confirmed consumer scope remains MLS only.

Revision 2026-09-20 UTC: Linked the user-created intention, recorded EP-1's completed code and
documentation milestones, and replaced the provisional combined 0.9.1.0 release with EP-1
patch 0.9.0.2 followed by EP-2's provisional 0.9.0.3. Cascaded the targets to plans 34–36.

Revision 2026-09-20 UTC: Recorded the published 0.9.0.2 packages, Haddocks, annotated tag, and
GitHub release. EP-1 now waits only on the MLS consumer pin and isolated worker observation.

Revision 2026-09-20 UTC: Marked EP-1 complete after the MLS consumer selected 0.9.0.2 without
unrelated dependency movement, passed its build/test/flake gates, and survived the bounded
isolated-worker observation. Added ADR 0001 for the durable concurrency and test decision.

2026-09-20 UTC: Moved EP-2's provisional release target, and EP-3's verification target with it, from 0.9.0.3 to 0.9.0.4, because the standalone supervisor-link fix in docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md was published as 0.9.0.3. Historical entries that mention 0.9.0.3 as the then-provisional target are left as written; the new Decision Log entry supersedes them. Cascaded to plans 34 and 35.

Revision 2026-09-22 UTC: Brought the plan up to date with the published state. EP-2 and EP-3 are
marked Complete: their bounds shipped in the 0.10.0.0 lifecycle cohort, not in 0.9.0.4 and
adapter patches. EP-4 is marked Cancelled because the MessageDB adapter was deprecated on
2026-09-19. Rewrote Vision & Scope, Dependency Graph, and Integration Points to describe what
happened rather than what was scheduled. Put the Decision Log in date order and marked the
superseded entries. Added the cohort and cancellation decisions, and wrote ADRs 0005 and 0006.
Filled in the final retrospective. Cascaded the changes to plans 34, 35, and 36.
