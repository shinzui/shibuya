---
id: 5
slug: post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity
title: "Post-0.9 review remediation: master loop removal, dependency bound hardening, and adapter parity"
kind: master-plan
created_at: 2026-09-16T23:04:43Z
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
---

# Post-0.9 review remediation: master loop removal, dependency bound hardening, and adapter parity

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

This initiative closes the issues found by a review, on 2026-09-16, of every change made to
shibuya and its adapters since the `v0.8.0.1` release of 2026-07-04. The review covered
shibuya-core and shibuya-metrics 0.9.0.0 and 0.9.0.1 (application-defined dead-letter reasons,
the effectful 2.7 bound, the seihou nix migration), shibuya-pgmq-adapter 0.12.0.0 through
0.16.0.0 (idle-stream shutdown fix, pgmq-hs 0.4/0.5/0.6, structured dead-letter payloads,
grouped-head FIFO polling), shibuya-kafka-adapter 0.9.0.0 and 0.9.0.1 (dead-letter rendering,
effectful-core 2.7 bound, a whitespace-and-comment-only reformat), and the kiroku-hosted
shibuya-kiroku-adapter 0.5.1.0 and 0.5.1.1 (core 0.9 upgrade with a total reason match). The
code in those releases is correct as far as the review could determine: the dead-letter changes
are gated behind the disabled-tracing short circuit, the pgmq shutdown gate reorder is right,
the grouped-head dispatch is covered by mutation-checked tests, and a hot-path benchmark run
during the review shows effectful 2.7.1 at parity with 2.6.1 (the numbers are recorded in
`docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md`).

Four things do need fixing, and this MasterPlan coordinates them.

First, a bare `runApp` followed by `waitApp` still crashes at the first major garbage collection
with `ExceptionInLinkedThread ... thread blocked indefinitely in an STM transaction`, because the
master starts a linked actor loop that nothing ever sends to. This is not a regression of the
0.9 releases; commit `f364183` first shipped it in 0.8.0.0, but it is the most serious open defect in the cohort and it is
already diagnosed and planned in
`docs/plans/33-remove-the-idle-linked-master-loop-that-deadlocks-bare-waitapp-callers.md`.
That plan becomes a child of this initiative rather than being duplicated.

Second, the effectful bounds that 0.9.0.1 and the Kafka adapter's 0.9.0.1 widened to `<2.8`
admit `effectful-core` 2.7.0.0 and 2.7.1.0, the two releases whose changelog records a
per-operation overhead regression for dynamically dispatched effects, fixed in 2.7.1.1. Every
adapter's queue effect (`Pgmq`, `KafkaConsumer`) is dynamically dispatched, so a consumer whose
solver or freeze file lands on those versions pays that cost on the hot path with nothing in
the cohort's bounds to stop it. The bump was also released as a patch, which under the current
release rule skips the benchmark regression gate, so the cohort never measured the swap. The
pgmq adapter has the opposite problem: its `effectful-core ^>=2.6.1.0` bound excludes 2.7
entirely, so a consumer that follows shibuya-core to effectful 2.7 cannot build the pgmq
adapter alongside it even though pgmq-hs 0.6.1.0 already supports 2.7. The kiroku adapter
excludes 2.7 the same way.

Third, shibuya-message-db-adapter is stranded on `shibuya-core ^>=0.5.0.0`. It constructs
`Envelope` without the `headers` field added in 0.7, its handlers take the `Ingested` type that
0.8 replaced with `Message`, and its dead-letter metadata renderer is an exhaustive match over
the three pre-0.9 constructors, so it cannot build against any current core and would fail at
runtime on the first `ApplicationFailure` if the match were merely widened.

After this initiative, an idle single-processor worker runs for as long as its processors do;
shibuya-core, the pgmq adapter, the Kafka adapter, and the kiroku adapter can all be built
together on effectful 2.6.1 or on effectful 2.7.1.1 and later, and none of them can resolve to
the regressed effectful-core releases; runtime-dependency bumps are benchmark-gated regardless
of release level; and the message-db adapter builds against core 0.9, stores dead-letter code
and detail structurally, and is released.

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
several different reasons. Consumers other than the `mls-service-v2` follow-up already named in
plan 33 are also out of scope.


## Decomposition Strategy

The work splits by functional concern into four child plans: a runtime crash fix in the core
(the master loop), a dependency-and-process hardening in the core (bounds and the release
gate), the same hardening propagated to the three maintained adapters, and a multi-version API
migration of the one adapter that fell behind. Each produces an independently checkable
result: a garbage-collection regression test that fails today and passes after; a cabal solve
that rejects the regressed effectful-core versions and accepts the fixed ones; a combined
dependency solve of core plus adapters on both effectful families; and a message-db adapter
test suite that passes against core 0.9 with an `ApplicationFailure` round-trip.

Alternatives considered. Folding the bound change into plan 33 would have kept one release but
would have widened a plan that was written and scoped to a single defect; instead the two core
plans are sequenced so that plan 33's release milestone ships both, and plan 34 is forbidden
from cutting a release of its own. One child plan per adapter repository was rejected because
each adapter change is a bound edit, a changelog line, and a patch release; a single plan with
one milestone per adapter keeps the bound expression identical across all three. Folding the
message-db upgrade into the adapter alignment plan was rejected because it is a four-major-
version API migration with its own database test harness, a different size and risk from a
bound edit. Cancelling the message-db adapter instead of upgrading it was considered and
rejected here because that is the maintainer's call, not a review finding; the plan records
the cost so the maintainer can make it.

ADRs: this repository has no `docs/adr/` directory, `mori show --full` lists no ADR bundle for
it, and no ADR bundle was found in the adapter repositories consulted during the review. No
relevant ADR exists. The durable decisions this initiative produces (the effectful-core
exclusion range and the benchmark-gating rule for runtime-dependency bumps) are candidates for
a first ADR, recorded in the Decision Log below and revisited at completion.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Remove the idle linked master loop that deadlocks bare waitApp callers | docs/plans/33-remove-the-idle-linked-master-loop-that-deadlocks-bare-waitapp-callers.md | None | EP-2 | In Progress (regression added; fix pending) |
| 2 | Harden shibuya-core dependency bounds and release gating for effectful 2.7 | docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md | None | None | Not Started |
| 3 | Align adapter effectful bounds and releases with shibuya-core 0.9.1 | docs/plans/35-align-adapter-effectful-bounds-and-releases-with-shibuya-core-0-9-1.md | None | EP-1, EP-2 | Not Started |
| 4 | Upgrade shibuya-message-db-adapter to shibuya-core 0.9 and structured dead-letter reasons | docs/plans/36-upgrade-shibuya-message-db-adapter-to-shibuya-core-0-9-and-structured-dead-letter-reasons.md | None | EP-1 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled; parenthetical notes describe the current milestone.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

No child plan is blocked at the compiler level by another, so there are no hard dependencies.
The ordering constraints are about releases.

Phase 1 is the core. EP-2 goes first and changes only cabal bounds, the changelog's unreleased
section, and the release skill; it must not cut a release. EP-1 then removes the master loop
and, at its release milestone, cuts shibuya-core and shibuya-metrics 0.9.1.0 carrying both
changes. EP-1's soft dependency on EP-2 exists only so that one release, not two, reaches
Hackage; if EP-2 is delayed, EP-1 may release alone and EP-2 then ships as 0.9.1.1.

The 0.9.1.0 and 0.9.1.1 numbers above are provisional coordination targets, not
reserved versions. EP-33's refresh requires checking the full release diff against
the installed release skill and live Hackage/upstream tags before selecting the
actual version. If it differs, synchronize this parent and plans 34–36 before
their release steps; do not force a minor bump solely because it appears here.

Phase 2 is the adapters and can run EP-3 and EP-4 in parallel once 0.9.1.0 is on Hackage.
EP-3's soft dependency on EP-1 and EP-2 is that each adapter release should be verified against
0.9.1.0 (so the master-loop fix is what its tests exercise) and must copy EP-2's bound
expression verbatim. EP-4's soft dependency on EP-1 is the same verification preference; it can
be developed against 0.9.0.1, which is already on Hackage, and only its final bound and
verification step want 0.9.1.0.


## Integration Points

The shibuya-core version, `shibuya-core/shibuya-core.cabal`, and the unreleased section of
`shibuya-core/CHANGELOG.md` are touched by EP-1 and EP-2. EP-1 owns the version bump to
0.9.1.0, the `shibuya-metrics` tracking bump, and the release; EP-2 adds its bound change and
its changelog lines under the same unreleased heading without touching the version. If the
release skill decides EP-1's diff warrants 0.10.0.0 rather than 0.9.1.0 (plan 33 records that
possibility), EP-3 must bump the adapters' `shibuya-core` bounds accordingly and EP-4 must
target the same version.

The effectful-core bound expression is defined by EP-2 and consumed verbatim by EP-3 (pgmq,
Kafka, and kiroku adapters) and EP-4 (message-db adapter). It is written once, in EP-2's
Interfaces and Dependencies section, as `effectful-core >=2.6.1 && <2.7 || >=2.7.1.1 && <2.8`,
with the matching `effectful >=2.6.1 && <2.8` where a package depends on the umbrella package.
Any later change to that range is made in EP-2 first and propagated.

The release skill's benchmark gate, `.agents/skills/release/SKILL.md` step 5, is changed by
EP-2 and is then binding on EP-1's release (which is a minor release and would have been gated
anyway) and, by the same rule copied into their own release skills where they have one, on the
adapter releases in EP-3.

EP-1 adds `shibuya-core-gc-test` as a separate test process and updates the release
skill's core validation command to `cabal test shibuya-core`, selecting both core
suites. EP-2 must preserve that gate when editing the same skill's benchmark policy.

The structured dead-letter projections `deadLetterReasonCode`, `deadLetterReasonDetail`, and
`renderDeadLetterReason` in `shibuya-core/src/Shibuya/Core/Ack.hs` are consumed by EP-4. They
are owned by the already-released core 0.9 and are not changed by any plan here.

Two cross-plan decisions deserve ADR records at completion: the effectful-core exclusion range
and why it lives in every package rather than only at the root, and the rule that a runtime
dependency bump is benchmark-gated regardless of PVP bump level.


## Progress

- [ ] EP-2: effectful-core exclusion bound applied to shibuya-core, shibuya-example, and shibuya-core-bench; both effectful families still build
- [ ] EP-2: release skill gates runtime-dependency bumps on the benchmark regardless of bump level
- [ ] EP-2: 2.6.1-versus-2.7.1 and 2.7.1.0-versus-2.7.1.2 benchmark evidence recorded in the plan
- [x] (2026-09-20 UTC) EP-1: dedicated garbage-collection regression test compiles and fails with the linked STM exception on 0.9.0.1
- [ ] EP-1: master loop, mailbox, and `MasterMessage` removed; suite green
- [ ] EP-1: documentation no longer describes the master as an actor
- [ ] EP-1: shibuya-core and shibuya-metrics 0.9.1.0 released with EP-2's changes
- [ ] EP-1: `mls-service-v2` single-processor subcommands run past the crash point
- [ ] EP-3: shibuya-pgmq-adapter bound widened and released
- [ ] EP-3: shibuya-kafka-adapter bound tightened and released
- [ ] EP-3: shibuya-kiroku-adapter bound widened and released, or its blocker on kiroku-store recorded
- [ ] EP-3: combined solve of core plus adapters proven on effectful 2.6.1 and 2.7.1.2, and rejected on 2.7.1.0
- [ ] EP-4: message-db adapter builds against shibuya-core 0.9
- [ ] EP-4: dead-letter metadata carries structured code and detail; `ApplicationFailure` round-trips through a real database
- [ ] EP-4: examples and tests migrated; 0.2.0.0 tagged


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- 2026-09-20 UTC: EP-33's regression is now `shibuya-core/test-gc/Main.hs`, in a
  dedicated Cabal test executable. Weak-pointer cleanup could lose its target and
  leak threads into later tests; process isolation avoids retaining the handle to
  clean up. Normal core/release checks must select both test suites. The library
  fix is still pending, so the new test is intentionally failing.

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
- 2026-09-16: The kiroku adapter's widening in EP-3 is conditional. `kiroku-store` declares
  `effectful-core >=2.4 && <2.7` in `kiroku-store/kiroku-store.cabal`, so the adapter cannot
  reach effectful 2.7 until kiroku-store does; EP-3 records the blocker rather than forcing a
  cohort release it does not own.


## Decision Log

- Decision: Preserve the existing MLS-only consumer follow-up while refreshing EP-33.
  Rationale: The user explicitly excluded `mori://tan/registration-service-v2`.
  Its incident informed the investigation but does not expand implementation scope.
  Date: 2026-09-20 UTC

- Decision: Run the GC regression as a dedicated test process and preserve its release gate.
  Rationale: Cleanup must not accidentally keep the master alive. EP-1 owns this
  gate; EP-2's release-policy edits must keep it. The version target remains
  provisional until release-time analysis, as detailed in Dependency Graph.
  Date: 2026-09-20 UTC

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

- Decision: Put the effectful-core exclusion in every package's own bounds rather than only in
  shibuya-core or only in `cabal.project` constraints.
  Rationale: Project-level constraints do not reach consumers. shibuya-core's `effectful` bound
  alone cannot exclude effectful-core 2.7.1.0, because effectful 2.7.1.0 pins
  `effectful-core >=2.7.1.0 && <2.7.2.0`, which spans both the regressed and the fixed core.
  The adapters are the packages whose effects are dynamically dispatched, so they must carry
  the exclusion themselves; the core carries it too so that a consumer depending only on the
  core is protected.
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
  Rationale: It is one of the four maintained adapters and it excludes effectful 2.7 today; the
  plan can state the exact bound and the exact blocker (kiroku-store) so the kiroku cohort
  release that lifts it is a documented follow-up rather than an unknown.
  Date: 2026-09-16

- Decision: No Intention ID is linked to this MasterPlan or its new child plans.
  Rationale: The initiative was created in an autonomous session with no user available to
  supply one. Add `intention:` to the frontmatter of each plan if one is assigned later.
  Date: 2026-09-16


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

(To be filled during and after implementation.)

Revision 2026-09-20 UTC: Synchronize EP-33's confirmed regression history, completed
failing-test milestone, isolated-test/release gate, and provisional release-version
coordination. The core fix and all publication/consumer milestones remain pending;
the user-confirmed consumer scope remains MLS only.
